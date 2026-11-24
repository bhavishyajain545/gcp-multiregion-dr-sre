package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Port       string
	Region     string
	Revision   string
	Database   string
	Outage     bool // OUTAGE=1: this region answers 503 to everything (regional-outage drill)
	AdminToken string
}

type Server struct {
	cfg    Config
	ledger Ledger
}

func NewServer(cfg Config, l Ledger) *Server { return &Server{cfg: cfg, ledger: l} }

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.health)
	mux.HandleFunc("GET /version", s.version)
	mux.HandleFunc("POST /accounts", s.createAccount)
	mux.HandleFunc("POST /seed", s.seed)
	mux.HandleFunc("GET /accounts/{id}", s.getAccount)
	mux.HandleFunc("POST /transfers", s.transfer)
	mux.HandleFunc("GET /transfers", s.recent)
	mux.HandleFunc("GET /ledger/summary", s.summary)
	mux.HandleFunc("POST /ledger/restore", s.restore)
	return s.wrap(mux)
}

// wrap: region header on every response, JSON access log, and the outage knob.
func (s *Server) wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		w.Header().Set("X-Served-By-Region", s.cfg.Region)
		w.Header().Set("X-Revision", s.cfg.Revision)
		rec := &recorder{ResponseWriter: w, status: 200}
		if s.cfg.Outage && r.URL.Path != "/version" {
			writeJSON(rec, http.StatusServiceUnavailable, map[string]any{"error": "regional outage drill", "region": s.cfg.Region})
		} else {
			next.ServeHTTP(rec, r)
		}
		slog.Info("request", "method", r.Method, "path", r.URL.Path, "status", rec.status,
			"latency_ms", time.Since(start).Milliseconds(), "region", s.cfg.Region, "revision", s.cfg.Revision)
	})
}

type recorder struct {
	http.ResponseWriter
	status int
}

func (r *recorder) WriteHeader(c int) { r.status = c; r.ResponseWriter.WriteHeader(c) }

func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, 200, map[string]any{"ok": true, "region": s.cfg.Region})
}

func (s *Server) version(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, 200, map[string]any{"version": Version, "region": s.cfg.Region, "revision": s.cfg.Revision,
		"outage": s.cfg.Outage, "database": s.cfg.Database})
}

func (s *Server) createAccount(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ID      string `json:"id"`
		Owner   string `json:"owner"`
		Balance int64  `json:"balance"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.Balance < 0 {
		writeErr(w, http.StatusBadRequest, "body: {id?, owner, balance>=0}")
		return
	}
	if in.ID == "" {
		in.ID = "acc_" + randomHex(6)
	}
	if err := s.ledger.CreateAccount(r.Context(), in.ID, in.Owner, in.Balance); err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"id": in.ID, "owner": in.Owner, "balance": in.Balance, "region": s.cfg.Region})
}

// seed creates n accounts acc-000..acc-(n-1) with the same balance: the demo's fixture.
func (s *Server) seed(w http.ResponseWriter, r *http.Request) {
	n, _ := strconv.Atoi(r.URL.Query().Get("n"))
	bal, _ := strconv.ParseInt(r.URL.Query().Get("balance"), 10, 64)
	if n <= 0 || n > 1000 || bal < 0 {
		writeErr(w, http.StatusBadRequest, "?n=1..1000&balance>=0")
		return
	}
	for i := 0; i < n; i++ {
		if err := s.ledger.CreateAccount(r.Context(), fmt.Sprintf("acc-%03d", i), fmt.Sprintf("owner-%03d", i), bal); err != nil {
			s.fail(w, err)
			return
		}
	}
	writeJSON(w, http.StatusCreated, map[string]any{"accounts": n, "balance_each": bal, "total": int64(n) * bal, "region": s.cfg.Region})
}

func (s *Server) getAccount(w http.ResponseWriter, r *http.Request) {
	var staleness time.Duration
	if v := r.URL.Query().Get("staleness"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d < 0 || d > time.Hour {
			writeErr(w, http.StatusBadRequest, "staleness: e.g. 15s")
			return
		}
		staleness = d
	}
	a, meta, err := s.ledger.GetAccount(r.Context(), r.PathValue("id"), staleness)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"account": a, "read": meta, "region": s.cfg.Region})
}

func (s *Server) transfer(w http.ResponseWriter, r *http.Request) {
	var t TransferRequest
	if err := json.NewDecoder(r.Body).Decode(&t); err != nil || t.From == "" || t.To == "" || t.Amount <= 0 || t.From == t.To {
		writeErr(w, http.StatusBadRequest, "body: {key?, from, to, amount>0}")
		return
	}
	if t.Key == "" {
		t.Key = "tx_" + randomHex(8)
	}
	res, err := s.ledger.Transfer(r.Context(), t, s.cfg.Region)
	if err != nil {
		s.fail(w, err)
		return
	}
	code := http.StatusCreated
	if res.Duplicate {
		code = http.StatusOK
	}
	writeJSON(w, code, res)
}

func (s *Server) recent(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 200 {
		limit = 10
	}
	out, err := s.ledger.RecentTransfers(r.Context(), limit)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"transfers": out, "region": s.cfg.Region})
}

func (s *Server) summary(w http.ResponseWriter, r *http.Request) {
	var asOf time.Time
	if v := r.URL.Query().Get("asof"); v != "" {
		t, err := time.Parse(time.RFC3339Nano, v)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "asof: RFC3339 timestamp")
			return
		}
		asOf = t
	}
	sum, meta, err := s.ledger.Summary(r.Context(), asOf)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"summary": sum, "read": meta, "region": s.cfg.Region})
}

// restore is the point-in-time recovery; it needs the admin token.
func (s *Server) restore(w http.ResponseWriter, r *http.Request) {
	if s.cfg.AdminToken == "" || r.Header.Get("X-Admin-Token") != s.cfg.AdminToken {
		writeErr(w, http.StatusForbidden, "admin token required")
		return
	}
	t, err := time.Parse(time.RFC3339Nano, r.URL.Query().Get("asof"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "asof: RFC3339 timestamp")
		return
	}
	n, err := s.ledger.RestoreAsOf(r.Context(), t)
	if err != nil {
		s.fail(w, err)
		return
	}
	slog.Warn("ledger restored", "as_of", t, "accounts", n, "region", s.cfg.Region)
	writeJSON(w, 200, map[string]any{"restored_accounts": n, "as_of": t, "region": s.cfg.Region})
}

func (s *Server) fail(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrNotFound):
		writeErr(w, http.StatusNotFound, err.Error())
	case errors.Is(err, ErrInsufficient):
		writeErr(w, http.StatusConflict, err.Error())
	case errors.Is(err, ErrBadRequest):
		writeErr(w, http.StatusBadRequest, err.Error())
	default:
		slog.Error("ledger", "err", err, "region", s.cfg.Region)
		writeErr(w, http.StatusInternalServerError, "ledger error")
	}
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]any{"error": msg})
}

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return strings.ToLower(hex.EncodeToString(b))
}
