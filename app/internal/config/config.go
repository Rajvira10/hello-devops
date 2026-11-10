// Package config loads all runtime configuration from environment variables.
package config

import (
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"time"
)

// Config holds every runtime setting of the service. Nothing is read from
// files or flags so the same image runs unchanged in every environment.
type Config struct {
	Port            int
	LogLevel        slog.Level
	Environment     string
	ShutdownTimeout time.Duration
	// ShutdownDelay is how long the server keeps serving (with /health
	// returning 503) after SIGTERM, so load balancers / kube-proxy can stop
	// routing new traffic before connections are drained.
	ShutdownDelay time.Duration
	// AdminToken protects the /debug/error endpoint. When empty the endpoint
	// is disabled. Treated as a secret.
	AdminToken string
}

// Load reads configuration from the environment, applying defaults.
func Load() (Config, error) {
	return loadFrom(os.LookupEnv)
}

func loadFrom(lookup func(string) (string, bool)) (Config, error) {
	get := func(key, def string) string {
		if v, ok := lookup(key); ok && strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
		return def
	}

	cfg := Config{
		Environment: get("APP_ENV", "development"),
		AdminToken:  get("ADMIN_TOKEN", ""),
	}

	port, err := strconv.Atoi(get("PORT", "8080"))
	if err != nil || port < 1 || port > 65535 {
		return Config{}, fmt.Errorf("invalid PORT %q: must be 1-65535", get("PORT", ""))
	}
	cfg.Port = port

	if err := cfg.LogLevel.UnmarshalText([]byte(get("LOG_LEVEL", "info"))); err != nil {
		return Config{}, fmt.Errorf("invalid LOG_LEVEL: %w", err)
	}

	if cfg.ShutdownTimeout, err = time.ParseDuration(get("SHUTDOWN_TIMEOUT", "15s")); err != nil {
		return Config{}, fmt.Errorf("invalid SHUTDOWN_TIMEOUT: %w", err)
	}
	if cfg.ShutdownDelay, err = time.ParseDuration(get("SHUTDOWN_DELAY", "0s")); err != nil {
		return Config{}, fmt.Errorf("invalid SHUTDOWN_DELAY: %w", err)
	}
	return cfg, nil
}
