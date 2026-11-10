// Command server runs the hello-devops HTTP service.
//
// Usage:
//
//	server               start the HTTP server
//	server healthcheck   probe http://127.0.0.1:$PORT/health and exit 0/1
//	                     (used by Docker HEALTHCHECK; the distroless image
//	                     has no shell or curl)
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/Rajvira10/hello-devops/app/internal/config"
	"github.com/Rajvira10/hello-devops/app/internal/server"
)

// version is injected at build time: -ldflags "-X main.version=1.2.3".
var version = "dev"

func main() {
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(healthcheck())
	}
	if err := run(); err != nil {
		slog.Error("server exited with error", "error", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel})).
		With("service", "hello-devops", "env", cfg.Environment, "version", version)
	slog.SetDefault(logger)

	srv := server.New(server.Options{
		Version:     version,
		Environment: cfg.Environment,
		AdminToken:  cfg.AdminToken,
		Logger:      logger,
	})

	httpSrv := &http.Server{
		Addr:              net.JoinHostPort("", strconv.Itoa(cfg.Port)),
		Handler:           srv,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		logger.Info("server starting", "port", cfg.Port, "log_level", cfg.LogLevel.String())
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
		close(errCh)
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
	}

	logger.Info("shutdown signal received", "delay", cfg.ShutdownDelay.String(), "timeout", cfg.ShutdownTimeout.String())
	srv.MarkShuttingDown()
	time.Sleep(cfg.ShutdownDelay)

	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancel()
	if err := httpSrv.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("graceful shutdown failed: %w", err)
	}
	logger.Info("server stopped cleanly")
	return nil
}

func healthcheck() int {
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintln(os.Stderr, "healthcheck failed:", err)
		return 1
	}
	client := http.Client{Timeout: 3 * time.Second}
	// Target is always loopback with a validated integer port.
	url := fmt.Sprintf("http://127.0.0.1:%d/health", cfg.Port)
	resp, err := client.Get(url) //nolint:gosec // G704: fixed loopback URL, not user-controlled
	if err != nil {
		fmt.Fprintln(os.Stderr, "healthcheck failed:", err)
		return 1
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintln(os.Stderr, "healthcheck failed: status", resp.StatusCode)
		return 1
	}
	return 0
}
