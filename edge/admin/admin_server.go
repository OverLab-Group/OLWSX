package admin

import (
	"log"
	"net/http"
)

// ListenAndServe starts a minimal admin server providing health and metrics endpoints.
func ListenAndServe(addr string, health http.HandlerFunc, metrics http.HandlerFunc) {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", health)
	mux.HandleFunc("/metrics", metrics)
	s := &http.Server{
		Addr:    addr,
		Handler: mux,
	}
	log.Printf("Admin server on %s", addr)
	if err := s.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Printf("admin server error: %v", err)
	}
}