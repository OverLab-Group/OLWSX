#!/usr/bin/env python3
# =============================================================================
# OLWSX - OverLab Web ServerX
# File: ai/tuning.py
# Role: Final & Stable adaptive tuning (rates, TTL, queue depth) with guardrails
# Philosophy: One version, the most stable version, first and last.
# -----------------------------------------------------------------------------
# Responsibilities:
# - Consume anomaly detector signals and raw metrics.
# - Recommend deterministic parameter updates with explainability.
# - Enforce guardrails (never oscillate aggressively; bounded steps).
# - Provide canary rollout plan with staged percentages.
# =============================================================================

from dataclasses import dataclass, asdict
from typing import Dict, Optional, List
import time

# Frozen bounds
MAX_RATE_PER_IP = 120     # req/s
MIN_RATE_PER_IP = 10
MAX_QUEUE_DEPTH = 1000
MIN_QUEUE_DEPTH = 100
TTL_MIN_S = 5
TTL_MAX_S = 3600

STEP_RATE = 10            # step size for rate changes
STEP_QUEUE = 50
STEP_TTL = 30             # seconds
COOLDOWN_S = 20

@dataclass
class Metrics:
    ts: float
    lat_p90: float
    err_ratio: float
    req_rate: float
    backpressure: float    # 0..1
    cache_hit_l2: float    # 0..1

@dataclass
class Recommendation:
    ts: float
    changes: Dict[str, int]
    ttl_changes: Dict[str, int]
    reason: str
    severity: str          # 'low' | 'moderate' | 'high'
    rollout: Dict[str, int]  # stages in percent

class Tuner:
    def __init__(self):
        self.last_apply_ts = 0.0
        self.state = {
            "rate_per_ip": 60,
            "queue_depth": 500,
            "ttl_static_s": 120,
            "ttl_dynamic_s": 60
        }

    def recommend(self, m: Metrics, alerts: List[Dict]) -> Optional[Recommendation]:
        now = m.ts
        if now - self.last_apply_ts < COOLDOWN_S:
            return None

        changes = {}
        ttl_changes = {}
        severity = "low"
        reason_parts = []

        # Rate limit tuning
        if m.backpressure >= 0.8 or m.err_ratio >= 0.05:
            new_rate = max(MIN_RATE_PER_IP, self.state["rate_per_ip"] - STEP_RATE)
            changes["rate_per_ip"] = new_rate
            severity = "moderate"
            reason_parts.append("reduce rate_per_ip due to backpressure/err")
        elif m.cache_hit_l2 >= 0.7 and m.lat_p90 < 120 and m.err_ratio < 0.02:
            new_rate = min(MAX_RATE_PER_IP, self.state["rate_per_ip"] + STEP_RATE)
            changes["rate_per_ip"] = new_rate
            reason_parts.append("increase rate_per_ip due to healthy cache & latency")

        # Queue depth tuning
        if m.backpressure >= 0.9:
            new_q = max(MIN_QUEUE_DEPTH, self.state["queue_depth"] - STEP_QUEUE)
            changes["queue_depth"] = new_q
            severity = "high"
            reason_parts.append("reduce queue_depth due to severe backpressure")
        elif m.err_ratio < 0.01 and m.lat_p90 < 100:
            new_q = min(MAX_QUEUE_DEPTH, self.state["queue_depth"] + STEP_QUEUE)
            changes["queue_depth"] = new_q
            reason_parts.append("increase queue_depth under low error/latency")

        # TTL tuning (cache)
        if m.cache_hit_l2 < 0.3 and m.lat_p90 > 200:
            # Underperforming cache: shorten TTL for dynamic to avoid stale content
            new_ttl_dyn = max(TTL_MIN_S, self.state["ttl_dynamic_s"] - STEP_TTL)
            ttl_changes["ttl_dynamic_s"] = new_ttl_dyn
            severity = "moderate"
            reason_parts.append("shorten ttl_dynamic due to low L2 hit & high latency")
        elif m.cache_hit_l2 > 0.8 and m.err_ratio < 0.02:
            # Strong cache: lengthen static TTL
            new_ttl_static = min(TTL_MAX_S, self.state["ttl_static_s"] + STEP_TTL)
            ttl_changes["ttl_static_s"] = new_ttl_static
            reason_parts.append("extend ttl_static due to strong L2 hit & low error")

        if not changes and not ttl_changes:
            return None

        rec = Recommendation(
            ts=now,
            changes=changes,
            ttl_changes=ttl_changes,
            reason="; ".join(reason_parts),
            severity=severity,
            rollout=self._rollout_plan()
        )
        return rec

    def apply(self, rec: Recommendation) -> None:
        # Deterministic bounded application
        for k, v in rec.changes.items():
            if k == "rate_per_ip":
                self.state[k] = max(MIN_RATE_PER_IP, min(MAX_RATE_PER_IP, v))
            elif k == "queue_depth":
                self.state[k] = max(MIN_QUEUE_DEPTH, min(MAX_QUEUE_DEPTH, v))
        for k, v in rec.ttl_changes.items():
            if k == "ttl_static_s":
                self.state[k] = max(TTL_MIN_S, min(TTL_MAX_S, v))
            elif k == "ttl_dynamic_s":
                self.state[k] = max(TTL_MIN_S, min(TTL_MAX_S, v))
        self.last_apply_ts = rec.ts

    def _rollout_plan(self) -> Dict[str, int]:
        # Fixed canary stages
        return {"stage1": 10, "stage2": 25, "stage3": 50, "stage4": 100}

# Example usage
if __name__ == "__main__":
    tuner = Tuner()
    m = Metrics(time.time(), lat_p90=230, err_ratio=0.06, req_rate=200, backpressure=0.85, cache_hit_l2=0.25)
    rec = tuner.recommend(m, alerts=[])
    if rec:
        print(asdict(rec))
        tuner.apply(rec)
        print(tuner.state)