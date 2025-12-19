package quic

import (
	"crypto/tls"
	"log"
	stdhttp "net/http"

	"github.com/quic-go/quic-go/http3"
)

// ListenAndServe starts an HTTP/3 server on the given address with shared handler.
func ListenAndServe(addr string, cfg *tls.Config, handler stdhttp.Handler) {
	s := &http3.Server{
		Addr:      addr,
		TLSConfig: cfg,
		Handler:   handler,
	}
	log.Printf("Edge serving HTTP/3 QUIC on %s", addr)
	if err := s.ListenAndServe(); err != nil {
		log.Printf("HTTP/3 server error: %v", err)
	}
}