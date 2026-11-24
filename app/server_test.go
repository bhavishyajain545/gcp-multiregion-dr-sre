package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func newTestServer(t *testing.T, outage bool) (*httptest.Server, *memoryLedger) {
	t.Helper()
	l := NewMemoryLedger()
	s := NewServer(Config{Region: "test-region", Revision: "r1", Outage: outage, AdminToken: "secret"}, l)
	ts := httptest.NewServer(s.Routes())
	t.Cleanup(ts.Close)
	return ts, l
}

func do(t *testing.T, method, url string, body any, headers ...string) (*http.Response, map[string]any) {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		_ = json.NewEncoder(&buf).Encode(body)
	}
	req, _ := http.NewRequest(method, url, &buf)
	for i := 0; i+1 < len(headers); i += 2 {
		req.Header.Set(headers[i], headers[i+1])
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp, out
}

func TestRegionHeaderAndHealth(t *testing.T) {
	ts, _ := newTestServer(t, false)
	resp, _ := do(t, "GET", ts.URL+"/healthz", nil)
	if resp.StatusCode != 200 || resp.Header.Get("X-Served-By-Region") != "test-region" {
		t.Fatalf("healthz: %d %q", resp.StatusCode, resp.Header.Get("X-Served-By-Region"))
	}
}

func TestOutageKnobFailsEverythingButVersion(t *testing.T) {
	ts, _ := newTestServer(t, true)
	if resp, _ := do(t, "GET", ts.URL+"/healthz", nil); resp.StatusCode != 503 {
		t.Fatalf("outage healthz = %d, want 503", resp.StatusCode)
	}
	if resp, _ := do(t, "GET", ts.URL+"/version", nil); resp.StatusCode != 200 {
		t.Fatalf("version during outage = %d, want 200", resp.StatusCode)
	}
}

func TestTransferMovesMoneyAndKeepsTheInvariant(t *testing.T) {
	ts, _ := newTestServer(t, false)
	do(t, "POST", ts.URL+"/seed?n=3&balance=100", nil)
	resp, out := do(t, "POST", ts.URL+"/transfers", map[string]any{"key": "k1", "from": "acc-000", "to": "acc-001", "amount": 40})
	if resp.StatusCode != 201 || out["duplicate"] != false {
		t.Fatalf("transfer: %d %v", resp.StatusCode, out)
	}
	_, a := do(t, "GET", ts.URL+"/accounts/acc-000", nil)
	if a["account"].(map[string]any)["balance"].(float64) != 60 {
		t.Fatalf("from balance: %v", a)
	}
	_, s := do(t, "GET", ts.URL+"/ledger/summary", nil)
	if s["summary"].(map[string]any)["total_balance"].(float64) != 300 {
		t.Fatalf("invariant broken: %v", s)
	}
}

func TestIdempotentRetryDoesNotDoubleSpend(t *testing.T) {
	ts, _ := newTestServer(t, false)
	do(t, "POST", ts.URL+"/seed?n=2&balance=100", nil)
	body := map[string]any{"key": "retry-1", "from": "acc-000", "to": "acc-001", "amount": 30}
	do(t, "POST", ts.URL+"/transfers", body)
	resp, out := do(t, "POST", ts.URL+"/transfers", body) // the retry after a failover
	if resp.StatusCode != 200 || out["duplicate"] != true {
		t.Fatalf("retry: %d %v", resp.StatusCode, out)
	}
	_, a := do(t, "GET", ts.URL+"/accounts/acc-000", nil)
	if a["account"].(map[string]any)["balance"].(float64) != 70 {
		t.Fatalf("double spend: %v", a)
	}
}

func TestInsufficientFundsIs409(t *testing.T) {
	ts, _ := newTestServer(t, false)
	do(t, "POST", ts.URL+"/seed?n=2&balance=10", nil)
	resp, _ := do(t, "POST", ts.URL+"/transfers", map[string]any{"from": "acc-000", "to": "acc-001", "amount": 11})
	if resp.StatusCode != 409 {
		t.Fatalf("want 409, got %d", resp.StatusCode)
	}
}

func TestConcurrentTransfersKeepTheInvariant(t *testing.T) {
	ts, _ := newTestServer(t, false)
	do(t, "POST", ts.URL+"/seed?n=5&balance=1000", nil)
	var wg sync.WaitGroup
	for i := 0; i < 200; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			do(t, "POST", ts.URL+"/transfers", map[string]any{"from": fmt.Sprintf("acc-%03d", i%5), "to": fmt.Sprintf("acc-%03d", (i+1)%5), "amount": 7})
		}(i)
	}
	wg.Wait()
	_, s := do(t, "GET", ts.URL+"/ledger/summary", nil)
	if s["summary"].(map[string]any)["total_balance"].(float64) != 5000 {
		t.Fatalf("invariant broken under concurrency: %v", s)
	}
}

func TestTimeTravelAndRestore(t *testing.T) {
	ts, _ := newTestServer(t, false)
	do(t, "POST", ts.URL+"/seed?n=2&balance=100", nil)
	time.Sleep(5 * time.Millisecond)
	before := time.Now()
	time.Sleep(5 * time.Millisecond)
	do(t, "POST", ts.URL+"/transfers", map[string]any{"from": "acc-000", "to": "acc-001", "amount": 90})
	_, past := do(t, "GET", ts.URL+"/ledger/summary?asof="+before.Format(time.RFC3339Nano), nil)
	if past["read"].(map[string]any)["read_kind"] != "as_of" {
		t.Fatalf("as_of read: %v", past)
	}
	if resp, _ := do(t, "POST", ts.URL+"/ledger/restore?asof="+before.Format(time.RFC3339Nano), nil); resp.StatusCode != 403 {
		t.Fatalf("restore without token = %d, want 403", resp.StatusCode)
	}
	resp, out := do(t, "POST", ts.URL+"/ledger/restore?asof="+before.Format(time.RFC3339Nano), nil, "X-Admin-Token", "secret")
	if resp.StatusCode != 200 || out["restored_accounts"].(float64) != 2 {
		t.Fatalf("restore: %d %v", resp.StatusCode, out)
	}
	_, a := do(t, "GET", ts.URL+"/accounts/acc-000", nil)
	if a["account"].(map[string]any)["balance"].(float64) != 100 {
		t.Fatalf("restore did not rewind: %v", a)
	}
}
