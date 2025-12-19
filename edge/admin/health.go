package admin

import (
	"fmt"
	"net/http"
)

// HealthHandler returns OK for liveness/readiness checks.
func HealthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	fmt.Fprintln(w, "OK")
}