package server

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

func newTestServer(t *testing.T, token string) (*Server, *bytes.Buffer) {
	t.Helper()
	var buf bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug}))
	return New(Options{Version: "1.2.3", Environment: "test", AdminToken: token, Logger: logger}), &buf
}

func do(t *testing.T, s http.Handler, method, path string, hdr map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, nil)
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	rr := httptest.NewRecorder()
	s.ServeHTTP(rr, req)
	return rr
}

func TestRoot(t *testing.T) {
	s, _ := newTestServer(t, "")
	rr := do(t, s, http.MethodGet, "/", nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	if ct := rr.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("content-type = %q", ct)
	}
	var body map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"message": "Hello from DevOps Task!", "status": "running", "version": "1.2.3"}
	for k, v := range want {
		if body[k] != v {
			t.Errorf("%s = %q, want %q", k, body[k], v)
		}
	}
}

func TestHealth(t *testing.T) {
	s, _ := newTestServer(t, "")
	if rr := do(t, s, http.MethodGet, "/health", nil); rr.Code != http.StatusOK ||
		!strings.Contains(rr.Body.String(), `"ok"`) {
		t.Fatalf("healthy: got %d %s", rr.Code, rr.Body)
	}

	s.MarkShuttingDown()
	if rr := do(t, s, http.MethodGet, "/health", nil); rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("shutting down: got %d, want 503", rr.Code)
	}
}

func TestMetricsEndpoint(t *testing.T) {
	s, _ := newTestServer(t, "")
	do(t, s, http.MethodGet, "/", nil)
	do(t, s, http.MethodGet, "/", nil)

	rr := do(t, s, http.MethodGet, "/metrics", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d", rr.Code)
	}
	body := rr.Body.String()
	for _, want := range []string{
		`http_requests_total{method="GET",route="/",status="200"} 2`,
		`http_request_duration_seconds_bucket{method="GET",route="/",le="0.005"}`,
		`app_build_info{env="test",version="1.2.3"} 1`,
		`go_goroutines`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("metrics output missing %q", want)
		}
	}
}

func TestUnknownPathsCollapseToUnmatched(t *testing.T) {
	s, _ := newTestServer(t, "")
	for _, p := range []string{"/a", "/b", "/wp-admin.php", "/health/x"} {
		if rr := do(t, s, http.MethodGet, p, nil); rr.Code != http.StatusNotFound {
			t.Fatalf("%s: got %d", p, rr.Code)
		}
	}
	// Wrong method on a known route is also "unmatched" (405).
	do(t, s, http.MethodPost, "/", nil)

	got := testutil.ToFloat64(s.Metrics().Requests.WithLabelValues("GET", "unmatched", "404"))
	if got != 4 {
		t.Fatalf("unmatched 404 count = %v, want 4", got)
	}
	if n := testutil.CollectAndCount(s.Metrics().Requests); n != 2 {
		t.Fatalf("expected 2 series (404 + 405), got %d", n)
	}
}

func TestDebugErrorDisabledWithoutToken(t *testing.T) {
	s, _ := newTestServer(t, "")
	if rr := do(t, s, http.MethodGet, "/debug/error", nil); rr.Code != http.StatusNotFound {
		t.Fatalf("got %d, want 404", rr.Code)
	}
}

func TestDebugErrorRequiresToken(t *testing.T) {
	s, _ := newTestServer(t, "s3cret")
	if rr := do(t, s, http.MethodGet, "/debug/error", map[string]string{"X-Admin-Token": "wrong"}); rr.Code != http.StatusForbidden {
		t.Fatalf("wrong token: got %d, want 403", rr.Code)
	}
	if testutil.ToFloat64(s.Metrics().Errors.WithLabelValues("GET", "/debug/error")) != 0 {
		t.Fatal("403 must not count as a server error")
	}
}

func TestDebugErrorCountsAsError(t *testing.T) {
	s, logs := newTestServer(t, "s3cret")
	rr := do(t, s, http.MethodGet, "/debug/error", map[string]string{"X-Admin-Token": "s3cret"})
	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("got %d, want 500", rr.Code)
	}
	if got := testutil.ToFloat64(s.Metrics().Errors.WithLabelValues("GET", "/debug/error")); got != 1 {
		t.Fatalf("error counter = %v, want 1", got)
	}
	if !strings.Contains(logs.String(), `"level":"ERROR"`) {
		t.Fatal("expected an ERROR level log line")
	}
}

func TestAccessLogIsStructuredJSON(t *testing.T) {
	s, logs := newTestServer(t, "")
	do(t, s, http.MethodGet, "/", nil)

	dec := json.NewDecoder(logs)
	var entry map[string]any
	for {
		var e map[string]any
		if err := dec.Decode(&e); err == io.EOF {
			break
		} else if err != nil {
			t.Fatalf("log line is not JSON: %v", err)
		}
		if e["msg"] == "request completed" {
			entry = e
		}
	}
	if entry == nil {
		t.Fatal("no access log line written")
	}
	for k, want := range map[string]any{"level": "INFO", "method": "GET", "path": "/", "status": float64(200)} {
		if entry[k] != want {
			t.Errorf("log %s = %v, want %v", k, entry[k], want)
		}
	}
	if _, ok := entry["duration_ms"]; !ok {
		t.Error("log missing duration_ms")
	}
}
