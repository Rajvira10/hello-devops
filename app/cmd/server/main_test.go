package main

import (
	"bytes"
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// syncBuffer is a goroutine-safe log sink.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = l.Close() }()
	return l.Addr().(*net.TCPAddr).Port
}

func TestRunServesAndShutsDownGracefully(t *testing.T) {
	port := freePort(t)
	t.Setenv("PORT", strconv.Itoa(port))
	t.Setenv("SHUTDOWN_DELAY", "50ms")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	logs := &syncBuffer{}
	done := make(chan error, 1)
	go func() { done <- run(ctx, logs) }()

	// Wait for the server to come up, using the real healthcheck subcommand.
	deadline := time.Now().Add(5 * time.Second)
	for healthcheck() != 0 {
		if time.Now().After(deadline) {
			t.Fatalf("server never became healthy; logs:\n%s", logs)
		}
		time.Sleep(20 * time.Millisecond)
	}

	resp, err := http.Get("http://127.0.0.1:" + strconv.Itoa(port) + "/")
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET / = %d", resp.StatusCode)
	}

	cancel() // what SIGTERM does in production
	stopStart := time.Now()
	defer func() { t.Logf("shutdown took %s", time.Since(stopStart)) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("run returned error: %v", err)
		}
	// Usually ~SHUTDOWN_DELAY, but http.Server.Shutdown may wait up to 5s for
	// a connection still in StateNew (accepted, no request yet), so allow
	// headroom. This is well inside SHUTDOWN_TIMEOUT and the K8s grace period.
	case <-time.After(12 * time.Second):
		t.Fatalf("server did not shut down; logs:\n%s", logs)
	}
	for _, want := range []string{`"msg":"server starting"`, `"msg":"shutdown signal received"`, `"msg":"server stopped cleanly"`} {
		if !strings.Contains(logs.String(), want) {
			t.Errorf("logs missing %s", want)
		}
	}
}

func TestRunRejectsInvalidConfig(t *testing.T) {
	t.Setenv("PORT", "not-a-port")
	if err := run(context.Background(), &syncBuffer{}); err == nil {
		t.Fatal("expected config error")
	}
}

func TestRunFailsWhenPortInUse(t *testing.T) {
	l, err := net.Listen("tcp", ":0")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = l.Close() }()
	t.Setenv("PORT", strconv.Itoa(l.Addr().(*net.TCPAddr).Port))
	if err := run(context.Background(), &syncBuffer{}); err == nil {
		t.Fatal("expected listen error")
	}
}

func TestHealthcheck(t *testing.T) {
	var status atomic.Int32
	status.Store(http.StatusOK)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(int(status.Load())) }))
	defer srv.Close()
	t.Setenv("PORT", strconv.Itoa(srv.Listener.Addr().(*net.TCPAddr).Port))

	if got := healthcheck(); got != 0 {
		t.Fatalf("healthy server: got %d, want 0", got)
	}
	status.Store(http.StatusServiceUnavailable)
	if got := healthcheck(); got != 1 {
		t.Fatalf("503: got %d, want 1", got)
	}
}

func TestHealthcheckNothingListening(t *testing.T) {
	t.Setenv("PORT", strconv.Itoa(freePort(t)))
	if got := healthcheck(); got != 1 {
		t.Fatalf("got %d, want 1", got)
	}
}

func TestHealthcheckInvalidConfig(t *testing.T) {
	t.Setenv("PORT", "0")
	if got := healthcheck(); got != 1 {
		t.Fatalf("got %d, want 1", got)
	}
}
