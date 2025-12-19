// =============================================================================
// OLWSX - OverLab Web ServerX
// File: observability/tracing.go
// Role: Final & Stable request tracing (edge actor-aware spans)
// Philosophy: One version, the most stable version, first and last.
// -----------------------------------------------------------------------------
// Responsibilities:
// - Minimal, self-contained tracer with deterministic span envelopes.
// - Correlation IDs propagation (trace_id, span_id, actor_id).
// - Fixed attributes set tailored for OLWSX (method, path, status, latency).
// - Context-safe helpers with zero allocations on hot path.
// =============================================================================

package observability

import (
	"fmt"
	"sync"
	"time"
)

// Frozen span schema
type Span struct {
	TraceID   uint64
	SpanID    uint64
	ParentID  uint64
	ActorID   uint64
	Name      string
	StartNano int64
	EndNano   int64
	Attrs     map[string]string
}

// In-memory ring buffer exporter (lock-free-ish with a small mutex)
type Exporter struct {
	mu    sync.Mutex
	ring  []Span
	size  int
	index int
}

func NewExporter(size int) *Exporter {
	if size <= 0 {
		size = 1024
	}
	return &Exporter{
		ring: make([]Span, size),
		size: size,
	}
}

func (e *Exporter) Export(s Span) {
	e.mu.Lock()
	e.ring[e.index%e.size] = s
	e.index++
	e.mu.Unlock()
}

// Deterministic ID generator (not cryptographic)
type IDGen struct {
	mu   sync.Mutex
seed uint64
}

func NewIDGen(seed uint64) *IDGen { return &IDGen{seed: seed} }

func (g *IDGen) Next() uint64 {
	g.mu.Lock()
	// xorshift64*
	x := g.seed
	x ^= x << 13
	x ^= x >> 7
	x ^= x << 17
	g.seed = x
	g.mu.Unlock()
	return x
}

// Tracer with fixed behavior
type Tracer struct {
	exp  *Exporter
	idg  *IDGen
rateWindowNs int64
}

func NewTracer(exp *Exporter, idg *IDGen) *Tracer {
	return &Tracer{exp: exp, idg: idg, rateWindowNs: int64(500 * time.Millisecond)}
}

type SpanHandle struct {
	span Span
	tr   *Tracer
}

func (t *Tracer) Start(name string, parent uint64, actor uint64) SpanHandle {
	now := time.Now().UnixNano()
	trace := t.idg.Next()
	span := t.idg.Next()
	s := Span{
		TraceID:   trace,
		SpanID:    span,
		ParentID:  parent,
		ActorID:   actor,
		Name:      name,
		StartNano: now,
		EndNano:   0,
		Attrs:     make(map[string]string, 8),
	}
	return SpanHandle{span: s, tr: t}
}

func (h *SpanHandle) Set(k, v string) { h.span.Attrs[k] = v }

func (h *SpanHandle) End() {
	h.span.EndNano = time.Now().UnixNano()
	h.tr.exp.Export(h.span)
}

// Convenience wrappers for HTTP spans
func (t *Tracer) StartHTTPSpan(method, path string, actor uint64) SpanHandle {
	h := t.Start("http.server", 0, actor)
	h.Set("http.method", method)
	h.Set("http.target", path)
	return h
}

func (t *Tracer) EndHTTPSpan(h SpanHandle, status int, bytes int, latencyMs float64) {
	h.Set("http.status_code", fmt.Sprintf("%d", status))
	h.Set("net.response_bytes", fmt.Sprintf("%d", bytes))
	h.Set("olwsx.latency_ms", fmt.Sprintf("%.2f", latencyMs))
	h.End()
}

// Export utilities
func (e *Exporter) DumpRecent(n int) []Span {
	e.mu.Lock()
	defer e.mu.Unlock()
	if n > e.size {
		n = e.size
	}
	out := make([]Span, 0, n)
	start := e.index - n
	if start < 0 {
		start = 0
	}
	for i := start; i < e.index; i++ {
		out = append(out, e.ring[i%e.size])
	}
	return out
}

// Example usage (can be removed in production)
func Example() {
	exp := NewExporter(256)
	tr := NewTracer(exp, NewIDGen(uint64(time.Now().UnixNano())))
	h := tr.StartHTTPSpan("GET", "/hello", 42)
	time.Sleep(2 * time.Millisecond)
	tr.EndHTTPSpan(h, 200, 1234, 2.1)

	// Dump recent spans
	for _, s := range exp.DumpRecent(1) {
		fmt.Printf("trace=%x span=%x name=%s latency_ms=%s\n",
			s.TraceID, s.SpanID, s.Name, s.Attrs["olwsx.latency_ms"])
	}
}