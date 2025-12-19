# =============================================================================
# OLWSX - OverLab Web ServerX
# File: ai/models.mojo
# Role: Final lightweight inference models (routing score, cache prewarm)
# Philosophy: One version, the most stable version, first and last.
# ----------------------------------------------------------------------------
# Notes:
# - Deterministic, vectorized scoring functions with fixed signatures.
# - No external dependencies; pure arithmetic, explainable outputs.
# =============================================================================

struct RoutingScore:
    score: Float64
    flags: UInt32

struct PrewarmDecision:
    prewarm: Bool
    ttl_s: Int64
    flags: UInt32

# Score a route based on static features (latency class, cache hits, priority)
fn score_route(latency_ms_p90: Float64, cache_hit_l2: Float64, priority: Int64) -> RoutingScore:
    var s: Float64 = 0.0
    # Lower latency → higher score
    s += max(0.0, 1.0 - (latency_ms_p90 / 500.0))
    # Strong cache hit → boost
    s += cache_hit_l2 * 0.5
    # Priority (0..3) → linear boost
    s += clamp(Float64(priority), 0.0, 3.0) * 0.2
    return RoutingScore(score=s, flags=0x00000001)

# Decide prewarm for a key based on recent misses and hit potential
fn decide_prewarm(recent_miss_rate: Float64, projected_hit_rate: Float64) -> PrewarmDecision:
    let prewarm = (recent_miss_rate > 0.4) and (projected_hit_rate > 0.6)
    var ttl: Int64 = 0
    if prewarm:
        # Deterministic TTL selection
        ttl = 120  # seconds
    else:
        ttl = 0
    return PrewarmDecision(prewarm=prewarm, ttl_s=ttl, flags=0x00000002)