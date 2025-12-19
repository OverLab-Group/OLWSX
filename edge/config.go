package main

import "time"

// Immutable defaults (can be staged via external config if needed).
const (
	// Limits
	MaxHeaderBytes = 2 * 1024 * 1024  // 2MB
	MaxBodyBytes   = 64 * 1024 * 1024 // 64MB

	// Timeouts
	ReadTimeout     = 10 * time.Second
	WriteTimeout    = 30 * time.Second
	IdleTimeout     = 60 * time.Second
	ReadHeaderTO    = 5 * time.Second
	ShutdownTimeout = 20 * time.Second

	// TLS
	TLSMinVersion13 = true

	// Transports
	EnableHTTP3     = true
	TLSListenAddr   = ":8443"
	WSListenAddr    = ":8080"
	AdminListenAddr = ":9090"

	// Actor IPC (Unix domain socket path)
	ActorManagerSocket = "/run/olwsx/actor_manager.sock"

	// Rate limiting
	BucketCapacity   = 60 // tokens
	RefillPerSecond  = 30 // tokens per second
	RetryAfterSecond = 1  // seconds

	// Observability
	AccessLogEnabled = true
	MetricsEnabled   = true
	TracingEnabled   = true

	// WAF/Challenge toggles
	EnableWAF       = true
	EnableChallenge = true
)