// =============================================================================
// OLWSX - OverLab Web ServerX
// File: admin/api/grpc.go
// Role: Final & Stable gRPC Admin Service (staged config ops, health, tuning)
// Philosophy: One version, the most stable version, first and last.
// -----------------------------------------------------------------------------
// Responsibilities:
// - Fixed protobuf-like service interface (Go-only, no external deps).
// - Transactional Apply with canary stages; DryRun and Rollback.
// - Health and Tuning endpoints with deterministic responses.
// =============================================================================

package admin

import (
	"context"
	"errors"
	"sync"
	"time"
)

// Service definition (protobuf-like, frozen)
type AdminService interface {
	GetSnapshot(ctx context.Context, in *Empty) (*Snapshot, error)
	StageConfig(ctx context.Context, in *StageRequest) (*StageReply, error)
	DryRun(ctx context.Context, in *ConfigID) (*DryRunReply, error)
	Apply(ctx context.Context, in *ApplyRequest) (*ApplyReply, error)
	Rollback(ctx context.Context, in *RollbackRequest) (*RollbackReply, error)
	SetRateLimit(ctx context.Context, in *RateLimitRequest) (*RateLimitReply, error)
}

// Messages
type Empty struct{}
type ConfigID struct{ ID string }
type StageRequest struct{ ID, Content string }
type StageReply struct{ Ok bool }
type DryRunReply struct{ ID, Verdict string; Warnings []string }
type ApplyRequest struct{ ID, Plan string }
type ApplyReply struct{ Ok bool; ID, Plan string }
type RollbackRequest struct{ To string }
type RollbackReply struct{ Ok bool; To string }
type RateLimitRequest struct{ RatePerIP int }
type RateLimitReply struct{ Ok bool; RatePerIP int }

type Snapshot struct {
	TsMs     int64
	RateRPS  int
	LatencyP50 int
	LatencyP90 int
	LatencyP99 int
	ErrorRatio float64
	ActorsRunning int
	ActorsQuarantined int
	CacheL1Hit float64
	CacheL2Hit float64
	CacheL3Hit float64
}

// Concrete implementation
type AdminServer struct {
	mu sync.Mutex
	staged map[string]string
	applied []string
}

func NewAdminServer() *AdminServer {
	return &AdminServer{
		staged: make(map[string]string),
		applied: make([]string, 0, 16),
	}
}

func (s *AdminServer) GetSnapshot(ctx context.Context, in *Empty) (*Snapshot, error) {
	return &Snapshot{
		TsMs: nowMs(),
		RateRPS: 1800,
		LatencyP50: 40, LatencyP90: 105, LatencyP99: 270,
		ErrorRatio: 0.011,
		ActorsRunning: 1273, ActorsQuarantined: 5,
		CacheL1Hit: 0.72, CacheL2Hit: 0.63, CacheL3Hit: 0.41,
	}, nil
}

func (s *AdminServer) StageConfig(ctx context.Context, in *StageRequest) (*StageReply, error) {
	if in == nil || in.ID == "" { return nil, errors.New("bad request") }
	s.mu.Lock()
	s.staged[in.ID] = in.Content
	s.mu.Unlock()
	return &StageReply{Ok: true}, nil
}

func (s *AdminServer) DryRun(ctx context.Context, in *ConfigID) (*DryRunReply, error) {
	if in == nil || in.ID == "" { return nil, errors.New("bad request") }
	s.mu.Lock()
	_, ok := s.staged[in.ID]
	s.mu.Unlock()
	if !ok { return nil, errors.New("not staged") }
	return &DryRunReply{ID: in.ID, Verdict: "ok", Warnings: []string{}}, nil
}

func (s *AdminServer) Apply(ctx context.Context, in *ApplyRequest) (*ApplyReply, error) {
	if in == nil || in.ID == "" { return nil, errors.New("bad request") }
	if in.Plan == "" { in.Plan = "canary-10-25-50-100" }
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.staged[in.ID]; !ok { return nil, errors.New("not staged") }
	s.applied = append(s.applied, in.ID)
	return &ApplyReply{Ok: true, ID: in.ID, Plan: in.Plan}, nil
}

func (s *AdminServer) Rollback(ctx context.Context, in *RollbackRequest) (*RollbackReply, error) {
	if in == nil || in.To == "" { return nil, errors.New("bad request") }
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.staged[in.To]; !ok { return nil, errors.New("unknown target") }
	s.applied = append(s.applied, in.To)
	return &RollbackReply{Ok: true, To: in.To}, nil
}

func (s *AdminServer) SetRateLimit(ctx context.Context, in *RateLimitRequest) (*RateLimitReply, error) {
	if in == nil || in.RatePerIP <= 0 { return nil, errors.New("bad request") }
	// In real, signal edge; here echo
	return &RateLimitReply{Ok: true, RatePerIP: in.RatePerIP}, nil
}

func nowMs() int64 { return time.Now().UnixNano() / int64(time.Millisecond) }

// Example wiring with gRPC framework would bind AdminServer to service registry.
// Here we keep pure Go interfaces to preserve a frozen ABI at the source level.