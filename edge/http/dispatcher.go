package http

import (
	"bytes"
	"fmt"
	"io"
	stdhttp "net/http"
	"strings"
	"time"

	"olwsx/edge/wire"
)

// CoreResp is a minimal envelope for edge responses. Edge itself doesn't do cache or heavy ops.
type CoreResp struct {
	Status      int
	HeadersFlat string
	Body        []byte
	MetaFlags   uint32
}

type CoreCaller func(method, path, headers string, body []byte, traceID, spanID uint64, hints uint32) (CoreResp, int)
type IDGen func() (uint64, uint64)
type RateCheck func(remote string) bool
type WAFCheck func(path, ua string) bool
type ChallengeCheck func(remote string) bool
type AccessLogger func(method, path string, status, bodyLen int, hints uint32, dur time.Duration, remote, ua string)
type MetricReject func(reason string)
type MetricError func(name string)

// Handler wires normalization, limits, waf, rate-limit hooks, tracing, and calls into actor/core via CoreCaller.
func Handler(maxHeaderBytes, maxBodyBytes int,
	rateCheck RateCheck,
	wafCheck WAFCheck,
	challengeCheck ChallengeCheck,
	coreCall CoreCaller,
	newIDs IDGen,
	accessLog AccessLogger,
	metricReject MetricReject,
	metricError MetricError,
) stdhttp.Handler {
	return stdhttp.HandlerFunc(func(w stdhttp.ResponseWriter, r *stdhttp.Request) {
		start := time.Now()

		// Hard body limit
		if r.ContentLength > int64(maxBodyBytes) && r.ContentLength >= 0 {
			errorTooLarge(w, "Body too large")
			metricReject("body_too_large")
			return
		}
		r.Body = io.NopCloser(io.LimitReader(r.Body, int64(maxBodyBytes)))

		// Security hints
		var hints uint32

		// Challenge gate
		if challengeCheck != nil && challengeCheck(r.RemoteAddr) {
			hints |= wire.HintChallenged
		}

		// WAF-lite
		if wafCheck != nil && wafCheck(r.URL.RequestURI(), r.UserAgent()) {
			hints |= wire.HintWAFBlocked
		}

		// Rate limit
		if rateCheck != nil && rateCheck(r.RemoteAddr) {
			hints |= wire.HintRateLimited
			w.Header().Set("Retry-After", fmt.Sprintf("%d", 1))
		}

		// Normalize headers
		method, path, headersFlat, hdrSize := Normalize(r, maxHeaderBytes)
		if hdrSize > maxHeaderBytes {
			errorTooLarge(w, "Headers too large")
			metricReject("headers_too_large")
			return
		}

		// Read body
		var bodyBuf bytes.Buffer
		if _, err := bodyBuf.ReadFrom(r.Body); err != nil {
			errorBadGateway(w, "Read body failed")
			metricError("read_body_error")
			return
		}
		bodyBytes := bodyBuf.Bytes()

		// IDs
		traceID, spanID := newIDs()

		// Core/Actor call
		resp, code := coreCall(method, path, headersFlat, bodyBytes, traceID, spanID, hints)
		if code != 0 {
			errorBadGateway(w, fmt.Sprintf("Core/Actor error: %d", code))
			metricError("core_actor_error")
			return
		}

		// Emit response
		for _, hv := range ParseFlat(resp.HeadersFlat) {
			parts := strings.SplitN(hv, ":", 2)
			if len(parts) == 2 {
				w.Header().Add(strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1]))
			}
		}
		w.Header().Set("X-Trace-ID", fmt.Sprintf("%016x", traceID))
		w.WriteHeader(resp.Status)
		if len(resp.Body) > 0 {
			_, _ = w.Write(resp.Body)
		}

		// Access log
		if accessLog != nil {
			accessLog(method, path, resp.Status, len(resp.Body), hints, time.Since(start), r.RemoteAddr, r.UserAgent())
		}
	})
}

func errorTooLarge(w stdhttp.ResponseWriter, msg string) {
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(stdhttp.StatusRequestEntityTooLarge)
	_, _ = w.Write([]byte(msg))
}
func errorBadGateway(w stdhttp.ResponseWriter, msg string) {
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(stdhttp.StatusBadGateway)
	_, _ = w.Write([]byte(msg))
}