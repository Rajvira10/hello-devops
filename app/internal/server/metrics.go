package server

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
)

// Metrics groups the Prometheus collectors exposed on /metrics.
//
// Label cardinality is bounded on purpose: "route" is the matched route
// pattern (e.g. "/health"), never the raw URL, and unknown URLs collapse into
// "unmatched". A scanner hitting random paths therefore cannot create new
// time series.
type Metrics struct {
	Registry *prometheus.Registry
	Requests *prometheus.CounterVec
	Errors   *prometheus.CounterVec
	Latency  *prometheus.HistogramVec
	InFlight prometheus.Gauge
}

// NewMetrics creates a dedicated registry (not the global default) so tests
// can build independent servers without duplicate-registration panics.
func NewMetrics(version, env string) *Metrics {
	m := &Metrics{
		Registry: prometheus.NewRegistry(),
		Requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total HTTP requests processed, by method, route and status code.",
		}, []string{"method", "route", "status"}),
		Errors: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "http_request_errors_total",
			Help: "Total HTTP requests that resulted in a 5xx response.",
		}, []string{"method", "route"}),
		Latency: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name: "http_request_duration_seconds",
			Help: "HTTP request latency in seconds.",
			// 5ms..5s covers a fast JSON API; finer buckets at the low end
			// keep p50/p95 accurate for typical sub-50ms responses.
			Buckets: []float64{.005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5},
		}, []string{"method", "route"}),
		InFlight: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "http_requests_in_flight",
			Help: "Number of HTTP requests currently being served.",
		}),
	}

	info := prometheus.NewGauge(prometheus.GaugeOpts{
		Name:        "app_build_info",
		Help:        "Constant 1, labelled with the running version and environment.",
		ConstLabels: prometheus.Labels{"version": version, "env": env},
	})
	info.Set(1)

	m.Registry.MustRegister(
		m.Requests, m.Errors, m.Latency, m.InFlight, info,
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)
	return m
}
