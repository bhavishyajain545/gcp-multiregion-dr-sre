package main

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/spanner"
	"google.golang.org/grpc/codes"
)

// spannerLedger keeps every rule in the database: the transfer is one
// serializable read-write transaction, the idempotency key is the primary key
// of Transfers, and reads choose their consistency explicitly.
type spannerLedger struct {
	c *spanner.Client
}

func NewSpannerLedger(ctx context.Context, database string) (*spannerLedger, error) {
	c, err := spanner.NewClientWithConfig(ctx, database, spanner.ClientConfig{
		SessionPoolConfig: spanner.SessionPoolConfig{MinOpened: 4, MaxOpened: 100},
	})
	if err != nil {
		return nil, err
	}
	return &spannerLedger{c: c}, nil
}

func (s *spannerLedger) Close() { s.c.Close() }

func (s *spannerLedger) CreateAccount(ctx context.Context, id, owner string, balance int64) error {
	_, err := s.c.Apply(ctx, []*spanner.Mutation{
		spanner.InsertOrUpdate("Accounts", []string{"AccountId", "Owner", "Balance", "UpdatedAt"},
			[]interface{}{id, owner, balance, spanner.CommitTimestamp}),
	})
	return err
}

func (s *spannerLedger) GetAccount(ctx context.Context, id string, staleness time.Duration) (Account, ReadMeta, error) {
	tx := s.c.Single()
	meta := ReadMeta{Kind: "strong"}
	if staleness > 0 {
		// Bounded staleness lets the nearest replica answer without a round
		// trip to the leader region: the cheap, fast read for dashboards.
		tx = tx.WithTimestampBound(spanner.MaxStaleness(staleness))
		meta.Kind = "stale"
	}
	defer tx.Close()
	row, err := tx.ReadRow(ctx, "Accounts", spanner.Key{id}, []string{"AccountId", "Owner", "Balance", "UpdatedAt"})
	if err != nil {
		if spanner.ErrCode(err) == codes.NotFound {
			return Account{}, meta, ErrNotFound
		}
		return Account{}, meta, err
	}
	var a Account
	if err := row.Columns(&a.ID, &a.Owner, &a.Balance, &a.UpdatedAt); err != nil {
		return Account{}, meta, err
	}
	if ts, err := tx.Timestamp(); err == nil {
		meta.ReadTimestamp = ts
	}
	return a, meta, nil
}

func (s *spannerLedger) Transfer(ctx context.Context, t TransferRequest, region string) (TransferResult, error) {
	var res TransferResult
	commit, err := s.c.ReadWriteTransaction(ctx, func(ctx context.Context, tx *spanner.ReadWriteTransaction) error {
		// 1. idempotency: a retried request (same key) after a failover must not move money twice
		if row, err := tx.ReadRow(ctx, "Transfers", spanner.Key{t.Key}, []string{"Region", "CommitTs"}); err == nil {
			var prevRegion string
			var prevTs time.Time
			if err := row.Columns(&prevRegion, &prevTs); err != nil {
				return err
			}
			res = TransferResult{Key: t.Key, Duplicate: true, CommitTs: prevTs, Region: prevRegion}
			return nil
		} else if spanner.ErrCode(err) != codes.NotFound {
			return err
		}
		// 2. read both balances inside the transaction (serializable)
		rows := tx.Read(ctx, "Accounts", spanner.KeySets(spanner.Key{t.From}, spanner.Key{t.To}), []string{"AccountId", "Balance"})
		balances := map[string]int64{}
		if err := rows.Do(func(r *spanner.Row) error {
			var id string
			var b int64
			if err := r.Columns(&id, &b); err != nil {
				return err
			}
			balances[id] = b
			return nil
		}); err != nil {
			return err
		}
		fromBal, ok1 := balances[t.From]
		_, ok2 := balances[t.To]
		if !ok1 || !ok2 {
			return ErrNotFound
		}
		if fromBal < t.Amount {
			return ErrInsufficient
		}
		// 3. debit, credit, record: all or nothing, with the commit timestamp as the audit clock
		return tx.BufferWrite([]*spanner.Mutation{
			spanner.Update("Accounts", []string{"AccountId", "Balance", "UpdatedAt"}, []interface{}{t.From, fromBal - t.Amount, spanner.CommitTimestamp}),
			spanner.Update("Accounts", []string{"AccountId", "Balance", "UpdatedAt"}, []interface{}{t.To, balances[t.To] + t.Amount, spanner.CommitTimestamp}),
			spanner.Insert("Transfers", []string{"IdempotencyKey", "FromAccount", "ToAccount", "Amount", "Region", "CommitTs"},
				[]interface{}{t.Key, t.From, t.To, t.Amount, region, spanner.CommitTimestamp}),
		})
	})
	if err != nil {
		if errors.Is(err, ErrNotFound) || errors.Is(err, ErrInsufficient) {
			return TransferResult{}, err
		}
		return TransferResult{}, fmt.Errorf("transfer: %w", err)
	}
	if res.Duplicate {
		return res, nil
	}
	return TransferResult{Key: t.Key, CommitTs: commit, Region: region}, nil
}

func (s *spannerLedger) Summary(ctx context.Context, asOf time.Time) (Summary, ReadMeta, error) {
	tx := s.c.Single()
	meta := ReadMeta{Kind: "strong"}
	if !asOf.IsZero() {
		// Time travel: a read at an exact past timestamp, served from the
		// database's version history (version_retention_period). This is
		// how "what did the ledger say before the bad DML?" gets answered.
		tx = tx.WithTimestampBound(spanner.ReadTimestamp(asOf))
		meta.Kind = "as_of"
	}
	defer tx.Close()
	var sum Summary
	it := tx.Query(ctx, spanner.Statement{SQL: `
		SELECT (SELECT COUNT(*) FROM Accounts), (SELECT COALESCE(SUM(Balance), 0) FROM Accounts), (SELECT COUNT(*) FROM Transfers)`})
	err := it.Do(func(r *spanner.Row) error { return r.Columns(&sum.Accounts, &sum.TotalBalance, &sum.Transfers) })
	if err != nil {
		return Summary{}, meta, err
	}
	if ts, err := tx.Timestamp(); err == nil {
		meta.ReadTimestamp = ts
	}
	return sum, meta, nil
}

// RestoreAsOf rewrites every account balance to what it was at asOf: a
// point-in-time recovery that takes seconds instead of a backup restore.
func (s *spannerLedger) RestoreAsOf(ctx context.Context, asOf time.Time) (int, error) {
	ro := s.c.ReadOnlyTransaction().WithTimestampBound(spanner.ReadTimestamp(asOf))
	defer ro.Close()
	var muts []*spanner.Mutation
	it := ro.Read(ctx, "Accounts", spanner.AllKeys(), []string{"AccountId", "Owner", "Balance"})
	err := it.Do(func(r *spanner.Row) error {
		var id, owner string
		var bal int64
		if err := r.Columns(&id, &owner, &bal); err != nil {
			return err
		}
		muts = append(muts, spanner.InsertOrUpdate("Accounts", []string{"AccountId", "Owner", "Balance", "UpdatedAt"},
			[]interface{}{id, owner, bal, spanner.CommitTimestamp}))
		return nil
	})
	if err != nil {
		return 0, err
	}
	if len(muts) == 0 {
		return 0, ErrNotFound
	}
	if _, err := s.c.Apply(ctx, muts); err != nil {
		return 0, err
	}
	return len(muts), nil
}

func (s *spannerLedger) RecentTransfers(ctx context.Context, limit int) ([]Transfer, error) {
	it := s.c.Single().Query(ctx, spanner.Statement{
		SQL:    `SELECT IdempotencyKey, FromAccount, ToAccount, Amount, Region, CommitTs FROM Transfers ORDER BY CommitTs DESC LIMIT @limit`,
		Params: map[string]interface{}{"limit": int64(limit)},
	})
	var out []Transfer
	err := it.Do(func(r *spanner.Row) error {
		var t Transfer
		var region spanner.NullString
		if err := r.Columns(&t.Key, &t.From, &t.To, &t.Amount, &region, &t.CommitTs); err != nil {
			return err
		}
		t.Region = region.StringVal
		out = append(out, t)
		return nil
	})
	return out, err
}
