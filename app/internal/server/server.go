// Package server implements the HTTP API, its middleware and metrics.
package server

import (
	"crypto/subtle"
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Server wires handlers, logging and metrics together.
type Server struct {
	version    string
	env        string
	adminToken string
	log        *slog.Logger
	metrics    *Metrics
	shutting   atomic.Bool
	handler    http.Handler
}

// Options configures a Server.
type Options struct {
	Version     string
	Environment string
	AdminToken  string
	Logger      *slog.Logger
}

// New builds a Server with all routes registered.
func New(o Options) *Server {
	s := &Server{
		version:    o.Version,
		env:        o.Environment,
		adminToken: o.AdminToken,
		log:        o.Logger,
		metrics:    NewMetrics(o.Version, o.Environment),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", s.handleRoot)
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.Handle("GET /metrics", promhttp.HandlerFor(s.metrics.Registry, promhttp.HandlerOpts{}))
	mux.HandleFunc("GET /debug/error", s.handleDebugError)

	s.handler = s.instrument(mux)
	return s
}

// ServeHTTP implements http.Handler.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) { s.handler.ServeHTTP(w, r) }

// Metrics exposes the collectors (used by tests).
func (s *Server) Metrics() *Metrics { return s.metrics }

// MarkShuttingDown makes /health return 503 so the instance is taken out of
// rotation while in-flight requests finish.
func (s *Server) MarkShuttingDown() { s.shutting.Store(true) }

func (s *Server) handleRoot(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"message": "Hello from DevOps Task!",
		"status":  "running",
		"version": s.version,
	})
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	if s.shutting.Load() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "shutting_down"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// handleDebugError deliberately returns a 500. It exists so error-rate
// dashboards and alerts can be demonstrated, and is disabled unless an
// ADMIN_TOKEN secret is configured and supplied in the X-Admin-Token header.
func (s *Server) handleDebugError(w http.ResponseWriter, r *http.Request) {
	if s.adminToken == "" {
		http.NotFound(w, r)
		return
	}
	got := r.Header.Get("X-Admin-Token")
	if subtle.ConstantTimeCompare([]byte(got), []byte(s.adminToken)) != 1 {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
		return
	}
	s.log.Error("simulated failure triggered", "path", "/debug/error", "reason", "debug endpoint")
	writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "simulated internal error"})
}

// statusRecorder captures the response code for logging and metrics.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// instrument records metrics and emits one structured access-log line per
// request.
func (s *Server) instrument(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		s.metrics.InFlight.Inc()
		defer s.metrics.InFlight.Dec()

		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)

		elapsed := time.Since(start)
		route := routeOf(r)
		status := strconv.Itoa(rec.status)

		s.metrics.Requests.WithLabelValues(r.Method, route, status).Inc()
		s.metrics.Latency.WithLabelValues(r.Method, route).Observe(elapsed.Seconds())
		if rec.status >= 500 {
			s.metrics.Errors.WithLabelValues(r.Method, route).Inc()
		}

		level := slog.LevelInfo
		switch {
		case rec.status >= 500:
			level = slog.LevelError
		case rec.status >= 400:
			level = slog.LevelWarn
		case route == "/health" || route == "/metrics":
			// Probes and scrapes hit these every few seconds; keep them out
			// of the default log stream.
			level = slog.LevelDebug
		}
		s.log.LogAttrs(r.Context(), level, "request completed",
			slog.String("method", r.Method),
			slog.String("path", route),
			slog.String("url", r.URL.Path),
			slog.Int("status", rec.status),
			slog.Float64("duration_ms", float64(elapsed.Microseconds())/1000),
			slog.String("remote_addr", r.RemoteAddr),
			slog.String("user_agent", r.UserAgent()),
		)
	})
}

// routeOf returns the matched route pattern without the method prefix, or
// "unmatched" for 404/405s, keeping metric/log label cardinality bounded.
func routeOf(r *http.Request) string {
	p := r.Pattern
	if p == "" {
		return "unmatched"
	}
	if i := strings.IndexByte(p, ' '); i >= 0 {
		p = p[i+1:]
	}
	if p == "/{$}" {
		return "/"
	}
	return p
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
