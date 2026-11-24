package main

import (
	"context"
	"errors"
	"sort"
	"sync"
	"time"
)

// Ledger is the storage contract. The Spanner implementation is the real one;
// the in-memory one keeps the handlers testable without a database.
type Ledger interface {
	CreateAccount(ctx context.Context, id, owner string, balance int64) error
	GetAccount(ctx context.Context, id string, staleness time.Duration) (Account, ReadMeta, error)
	Transfer(ctx context.Context, t TransferRequest, region string) (TransferResult, error)
	Summary(ctx context.Context, asOf time.Time) (Summary, ReadMeta, error)
	RestoreAsOf(ctx context.Context, asOf time.Time) (int, error)
	RecentTransfers(ctx context.Context, limit int) ([]Transfer, error)
	// RegionFlags: the outage switch, shared through the database so every instance of a
	// region sees it within one poll (a new revision cannot carry it: Cloud Run will not
	// route to a revision whose readiness probe fails from the start).
	GetOutage(ctx context.Context, region string) (bool, error)
	SetOutage(ctx context.Context, region string, on bool) error
}

type Account struct {
	ID        string    `json:"id"`
	Owner     string    `json:"owner"`
	Balance   int64     `json:"balance"`
	UpdatedAt time.Time `json:"updated_at"`
}

// ReadMeta says how a read was served: the timestamp Spanner chose and whether
// it was strong, bounded-stale or an explicit point in the past.
type ReadMeta struct {
	Kind          string    `json:"read_kind"`
	ReadTimestamp time.Time `json:"read_timestamp"`
}

type TransferRequest struct {
	Key    string `json:"key"` // idempotency key: retries across regions never double-spend
	From   string `json:"from"`
	To     string `json:"to"`
	Amount int64  `json:"amount"`
}

type TransferResult struct {
	Key       string    `json:"key"`
	Duplicate bool      `json:"duplicate"` // the key was already committed: nothing moved again
	CommitTs  time.Time `json:"commit_ts"`
	Region    string    `json:"committed_from_region"`
}

type Transfer struct {
	Key      string    `json:"key"`
	From     string    `json:"from"`
	To       string    `json:"to"`
	Amount   int64     `json:"amount"`
	Region   string    `json:"region"`
	CommitTs time.Time `json:"commit_ts"`
}

// Summary is the invariant the drills check: money moves between accounts,
// it is never created or destroyed, so TotalBalance must never change.
type Summary struct {
	Accounts     int64 `json:"accounts"`
	TotalBalance int64 `json:"total_balance"`
	Transfers    int64 `json:"transfers"`
}

var (
	ErrNotFound     = errors.New("account not found")
	ErrInsufficient = errors.New("insufficient funds")
	ErrBadRequest   = errors.New("bad request")
)

// ---------------------------------------------------------------- in-memory

type memoryLedger struct {
	mu        sync.Mutex
	accounts  map[string]*Account
	transfers map[string]Transfer
	history   []snapshot // for AS OF reads in tests
	flags     map[string]bool
}

type snapshot struct {
	at       time.Time
	accounts map[string]Account
}

func NewMemoryLedger() *memoryLedger {
	return &memoryLedger{accounts: map[string]*Account{}, transfers: map[string]Transfer{}, flags: map[string]bool{}}
}

func (m *memoryLedger) GetOutage(_ context.Context, region string) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.flags[region], nil
}

func (m *memoryLedger) SetOutage(_ context.Context, region string, on bool) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.flags[region] = on
	return nil
}

func (m *memoryLedger) snap(at time.Time) {
	cp := make(map[string]Account, len(m.accounts))
	for k, v := range m.accounts {
		cp[k] = *v
	}
	m.history = append(m.history, snapshot{at: at, accounts: cp})
}

func (m *memoryLedger) CreateAccount(_ context.Context, id, owner string, balance int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.accounts[id]; ok {
		return nil
	}
	m.accounts[id] = &Account{ID: id, Owner: owner, Balance: balance, UpdatedAt: time.Now()}
	m.snap(time.Now())
	return nil
}

func (m *memoryLedger) GetAccount(_ context.Context, id string, staleness time.Duration) (Account, ReadMeta, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	a, ok := m.accounts[id]
	if !ok {
		return Account{}, ReadMeta{}, ErrNotFound
	}
	kind := "strong"
	if staleness > 0 {
		kind = "stale"
	}
	return *a, ReadMeta{Kind: kind, ReadTimestamp: time.Now().Add(-staleness)}, nil
}

func (m *memoryLedger) Transfer(_ context.Context, t TransferRequest, region string) (TransferResult, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if prev, ok := m.transfers[t.Key]; ok {
		return TransferResult{Key: t.Key, Duplicate: true, CommitTs: prev.CommitTs, Region: prev.Region}, nil
	}
	from, ok1 := m.accounts[t.From]
	to, ok2 := m.accounts[t.To]
	if !ok1 || !ok2 {
		return TransferResult{}, ErrNotFound
	}
	if from.Balance < t.Amount {
		return TransferResult{}, ErrInsufficient
	}
	now := time.Now()
	from.Balance -= t.Amount
	to.Balance += t.Amount
	from.UpdatedAt, to.UpdatedAt = now, now
	m.transfers[t.Key] = Transfer{Key: t.Key, From: t.From, To: t.To, Amount: t.Amount, Region: region, CommitTs: now}
	m.snap(now)
	return TransferResult{Key: t.Key, CommitTs: now, Region: region}, nil
}

func (m *memoryLedger) Summary(_ context.Context, asOf time.Time) (Summary, ReadMeta, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	accounts := m.accounts
	meta := ReadMeta{Kind: "strong", ReadTimestamp: time.Now()}
	if !asOf.IsZero() {
		meta = ReadMeta{Kind: "as_of", ReadTimestamp: asOf}
		past := map[string]*Account{}
		for i := len(m.history) - 1; i >= 0; i-- {
			if !m.history[i].at.After(asOf) {
				for k, v := range m.history[i].accounts {
					v := v
					past[k] = &v
				}
				break
			}
		}
		accounts = past
	}
	var s Summary
	for _, a := range accounts {
		s.Accounts++
		s.TotalBalance += a.Balance
	}
	s.Transfers = int64(len(m.transfers))
	return s, meta, nil
}

func (m *memoryLedger) RestoreAsOf(ctx context.Context, asOf time.Time) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for i := len(m.history) - 1; i >= 0; i-- {
		if !m.history[i].at.After(asOf) {
			n := 0
			for k, v := range m.history[i].accounts {
				v := v
				v.UpdatedAt = time.Now()
				m.accounts[k] = &v
				n++
			}
			m.snap(time.Now())
			return n, nil
		}
	}
	return 0, ErrNotFound
}

func (m *memoryLedger) RecentTransfers(_ context.Context, limit int) ([]Transfer, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Transfer, 0, len(m.transfers))
	for _, t := range m.transfers {
		out = append(out, t)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CommitTs.After(out[j].CommitTs) })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}
