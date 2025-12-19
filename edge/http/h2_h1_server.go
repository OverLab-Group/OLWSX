package http

import (
	stdhttp "net/http"
	"time"
)

type Timeouts struct {
	Read       time.Duration
	Write      time.Duration
	Idle       time.Duration
	ReadHeader time.Duration
}

// NewH2H1Server constructs a net/http server ready for TLS ALPN (h2 + http/1.1).
func NewH2H1Server(handler stdhttp.Handler, maxHeaderBytes int, timeouts Timeouts) *stdhttp.Server {
	return &stdhttp.Server{
		Handler:           handler,
		ReadTimeout:       timeouts.Read,
		WriteTimeout:      timeouts.Write,
		IdleTimeout:       timeouts.Idle,
		ReadHeaderTimeout: timeouts.ReadHeader,
		MaxHeaderBytes:    maxHeaderBytes,
	}
}