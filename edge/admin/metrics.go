package admin

import (
	"fmt"
	"net/http"
)

// MetricsHandler exposes simple placeholder metrics; integrate Prometheus exporter in production.
func MetricsHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintln(w, "# HELP olwsx_edge_requests_total total requests processed")
	fmt.Fprintln(w, "# TYPE olwsx_edge_requests_total counter")
	// In real deployment, counters would be tracked and exposed here.
	fmt.Fprintln(w, "olwsx_edge_requests_total 0")
}