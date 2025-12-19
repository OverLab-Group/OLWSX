#!/usr/bin/env python3
# =============================================================================
# OLWSX - OverLab Web ServerX
# File: ai/anomaly.py
# Role: Final & Stable online anomaly detection (EWMA, drift, clustering-lite)
# Philosophy: One version, the most stable version, first and last.
# -----------------------------------------------------------------------------
# Responsibilities:
# - Ingest live metrics (latency, errors, rate) via push API.
# - Maintain EWMA and variance online.
# - Detect spikes, drift, and regime changes deterministically.
# - Produce explainable alerts with fixed schema.
# =============================================================================

from dataclasses import dataclass, asdict
from typing import Dict, Optional, Tuple, List
import math
import time

# Frozen thresholds and decay factors
ALPHA_LAT = 0.2         # EWMA decay for latency
ALPHA_ERR = 0.2         # EWMA decay for error ratio
ALPHA_RATE = 0.15       # EWMA decay for request rate

SPIKE_Z = 3.0           # z-score threshold for spikes
DRIFT_PCT = 0.25        # 25% sustained shift indicates drift
REGIME_MIN_S = 30       # minimum duration to accept regime change
HYSTERESIS_S = 15       # suppress flip-flop

@dataclass
class Point:
    ts: float
    latency_ms_p50: float
    latency_ms_p90: float
    error_ratio: float      # 0..1
    req_rate: float         # req/s
    backpressure: float     # 0..1

@dataclass
class State:
    ewma_lat_p50: float = 0.0
    ewma_lat_p90: float = 0.0
    ewma_err: float = 0.0
    ewma_rate: float = 0.0
    var_lat_p50: float = 0.0
    var_lat_p90: float = 0.0
    last_regime: Optional[str] = None
    regime_since: float = 0.0
    last_alert_ts: float = 0.0

@dataclass
class Alert:
    ts: float
    kind: str              # 'spike' | 'drift' | 'regime'
    severity: str          # 'low' | 'moderate' | 'high'
    reason: str
    metrics: Dict[str, float]

class Detector:
    def __init__(self):
        self.state = State()

    def _ewma(self, x: float, m: float, a: float) -> float:
        if m == 0.0:
            return x
        return a * x + (1 - a) * m

    def _update_var(self, x: float, mean: float, var: float, a: float) -> float:
        # Exponential variance update (approximate)
        diff = x - mean
        return a * (diff * diff) + (1 - a) * var

    def ingest(self, p: Point) -> List[Alert]:
        s = self.state
        # Update EWMA
        s.ewma_lat_p50 = self._ewma(p.latency_ms_p50, s.ewma_lat_p50, ALPHA_LAT)
        s.ewma_lat_p90 = self._ewma(p.latency_ms_p90, s.ewma_lat_p90, ALPHA_LAT)
        s.ewma_err     = self._ewma(p.error_ratio,     s.ewma_err,     ALPHA_ERR)
        s.ewma_rate    = self._ewma(p.req_rate,        s.ewma_rate,    ALPHA_RATE)

        # Update variance
        s.var_lat_p50 = self._update_var(p.latency_ms_p50, s.ewma_lat_p50, s.var_lat_p50, ALPHA_LAT)
        s.var_lat_p90 = self._update_var(p.latency_ms_p90, s.ewma_lat_p90, s.var_lat_p90, ALPHA_LAT)

        alerts: List[Alert] = []

        # Spike detection (z-score)
        z50 = self._zscore(p.latency_ms_p50, s.ewma_lat_p50, s.var_lat_p50)
        z90 = self._zscore(p.latency_ms_p90, s.ewma_lat_p90, s.var_lat_p90)
        if max(z50, z90) >= SPIKE_Z or p.backpressure >= 0.8:
            alerts.append(self._alert(
                kind="spike",
                severity="high" if max(z50, z90) >= 4.0 or p.backpressure >= 0.9 else "moderate",
                reason=f"latency z={max(z50, z90):.2f}, backpressure={p.backpressure:.2f}",
                metrics={
                    "lat_p50": p.latency_ms_p50,
                    "lat_p90": p.latency_ms_p90,
                    "ewma_p50": s.ewma_lat_p50,
                    "ewma_p90": s.ewma_lat_p90,
                    "bp": p.backpressure,
                    "z": max(z50, z90)
                }
            ))

        # Drift detection (sustained shift in EWMA vs previous regime mean)
        # We use error ratio as corroboration
        drift_ratio = self._drift_ratio(p.latency_ms_p90, s.ewma_lat_p90)
        if drift_ratio >= DRIFT_PCT and s.ewma_err >= 0.05:
            alerts.append(self._alert(
                kind="drift",
                severity="moderate",
                reason=f"latency drift {drift_ratio*100:.1f}% with err={s.ewma_err:.3f}",
                metrics={
                    "lat_p90": p.latency_ms_p90,
                    "ewma_p90": s.ewma_lat_p90,
                    "err": s.ewma_err,
                    "drift_pct": drift_ratio
                }
            ))

        # Regime change: rate/latency level shift sustained
        regime = self._regime_label(s.ewma_rate, s.ewma_lat_p90)
        now = p.ts
        if regime != s.last_regime:
            if s.regime_since == 0.0:
                s.regime_since = now
            elif now - s.regime_since >= REGIME_MIN_S:
                if now - s.last_alert_ts >= HYSTERESIS_S:
                    alerts.append(self._alert(
                        kind="regime",
                        severity="low",
                        reason=f"regime -> {regime}",
                        metrics={
                            "rate": s.ewma_rate,
                            "lat_p90": s.ewma_lat_p90
                        }
                    ))
                    s.last_regime = regime
                    s.last_alert_ts = now
                    s.regime_since = 0.0
        else:
            s.regime_since = 0.0

        return alerts

    def _zscore(self, x: float, mean: float, var: float) -> float:
        sd = math.sqrt(max(var, 1e-6))
        return (x - mean) / sd

    def _drift_ratio(self, x: float, mean: float) -> float:
        if mean <= 1e-6:
            return 0.0
        return abs(x - mean) / mean

    def _regime_label(self, rate: float, lat_p90: float) -> str:
        # Simple 3-state regime: low/normal/high based on quantized thresholds
        if rate < 50 and lat_p90 < 50:
            return "low"
        if rate > 300 or lat_p90 > 200:
            return "high"
        return "normal"

    def _alert(self, kind: str, severity: str, reason: str, metrics: Dict[str, float]) -> Alert:
        return Alert(ts=time.time(), kind=kind, severity=severity, reason=reason, metrics=metrics)

# Example usage
if __name__ == "__main__":
    det = Detector()
    now = time.time()
    pts = [
        Point(now+1, 40, 80, 0.01, 100, 0.1),
        Point(now+2, 60, 180, 0.06, 120, 0.2),
        Point(now+3, 65, 220, 0.08, 130, 0.85),  # spike/backpressure
    ]
    for p in pts:
        alerts = det.ingest(p)
        for a in alerts:
            print(asdict(a))