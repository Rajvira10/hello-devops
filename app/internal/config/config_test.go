package config

import (
	"log/slog"
	"testing"
	"time"
)

func env(m map[string]string) func(string) (string, bool) {
	return func(k string) (string, bool) { v, ok := m[k]; return v, ok }
}

func TestDefaults(t *testing.T) {
	cfg, err := loadFrom(env(nil))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Port != 8080 || cfg.LogLevel != slog.LevelInfo || cfg.Environment != "development" ||
		cfg.ShutdownTimeout != 15*time.Second || cfg.ShutdownDelay != 0 || cfg.AdminToken != "" {
		t.Fatalf("unexpected defaults: %+v", cfg)
	}
}

func TestOverrides(t *testing.T) {
	cfg, err := loadFrom(env(map[string]string{
		"PORT": "9090", "LOG_LEVEL": "debug", "APP_ENV": "production",
		"SHUTDOWN_TIMEOUT": "30s", "SHUTDOWN_DELAY": "5s", "ADMIN_TOKEN": "s3cret",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Port != 9090 || cfg.LogLevel != slog.LevelDebug || cfg.Environment != "production" ||
		cfg.ShutdownTimeout != 30*time.Second || cfg.ShutdownDelay != 5*time.Second || cfg.AdminToken != "s3cret" {
		t.Fatalf("overrides not applied: %+v", cfg)
	}
}

func TestInvalidValues(t *testing.T) {
	for name, m := range map[string]map[string]string{
		"port not a number": {"PORT": "abc"},
		"port out of range": {"PORT": "70000"},
		"bad log level":     {"LOG_LEVEL": "loud"},
		"bad timeout":       {"SHUTDOWN_TIMEOUT": "soon"},
		"bad delay":         {"SHUTDOWN_DELAY": "later"},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := loadFrom(env(m)); err == nil {
				t.Fatal("expected error")
			}
		})
	}
}
