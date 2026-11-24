// ledger-api: a small money-transfer service whose only job is to make a
// multi-region disaster-recovery story measurable. It runs identically in two
// regions behind one global load balancer and keeps its state in one
// multi-region Cloud Spanner database, so a regional outage changes *where*
// requests are served, never *what* the ledger says.
//
// The interesting parts:
//   - transfers are serializable Spanner read-write transactions with an
//     idempotency key, so retries across a failover never double-spend;
//   - reads come in three flavours: strong, bounded-stale (served by the
//     nearest replica) and time-travel (AS OF a past timestamp), which is
//     also how a bad DML is undone;
//   - one knob, OUTAGE=1, makes a whole region answer 503 so the load
//     balancer's outlier detection can be watched evicting it.
package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

var Version = "dev"

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		ReplaceAttr: func(_ []string, a slog.Attr) slog.Attr {
			switch a.Key {
			case slog.LevelKey:
				a.Key = "severity"
			case slog.MessageKey:
				a.Key = "message"
			}
			return a
		},
	})))
	cfg := Config{
		Port:       env("PORT", "8080"),
		Region:     env("REGION", "local"),
		Revision:   env("K_REVISION", "local"),
		Database:   env("SPANNER_DATABASE", ""), // projects/p/instances/i/databases/d
		Outage:     env("OUTAGE", "") == "1",
		AdminToken: env("ADMIN_TOKEN", ""),
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	var ledger Ledger
	if cfg.Database != "" {
		l, err := NewSpannerLedger(ctx, cfg.Database)
		if err != nil {
			slog.Error("spanner", "err", err)
			os.Exit(1)
		}
		defer l.Close()
		ledger = l
	} else {
		ledger = NewMemoryLedger()
	}
	srv := NewServer(cfg, ledger)
	hs := &http.Server{Addr: ":" + cfg.Port, Handler: srv.Routes(), ReadHeaderTimeout: 5 * time.Second}
	go func() {
		slog.Info("listening", "port", cfg.Port, "version", Version, "region", cfg.Region, "revision", cfg.Revision,
			"database", cfg.Database, "outage", cfg.Outage)
		if err := hs.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("serve", "err", err)
			os.Exit(1)
		}
	}()
	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	_ = hs.Shutdown(shutdownCtx)
}

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
