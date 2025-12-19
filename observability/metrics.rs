// =============================================================================
// OLWSX - OverLab Web ServerX
// File: observability/metrics.rs
// Role: Final & Stable metrics codec and histogram (fast, deterministic)
// Philosophy: One version, the most stable version, first and last.
// -----------------------------------------------------------------------------
// Responsibilities:
// - Fixed metric envelope with integer-friendly wire format.
// - High-performance HDR-like histogram for latency (p50/p90/p99).
// - Counter/gauge/summary with bounded memory and zero unsafe shared state.
// =============================================================================

use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug)]
pub struct MetricEnvelope {
    pub ts_ms: u64,
    pub name: &'static str,
    pub labels: &'static [(&'static str, &'static str)],
    pub kind: MetricKind,
}

#[derive(Clone, Debug)]
pub enum MetricKind {
    Counter { delta: u64 },
    Gauge { value: i64 },
    Summary { count: u64, sum: u64 },
    LatencyHist { bins: [u64; 16] }, // fixed bins
}

// Fixed latency bins (ms): 0..5, 5..10, ..., 300..inf
const LAT_BOUNDS: [u64; 16] = [5, 10, 20, 30, 40, 50, 60, 80, 100, 150, 200, 250, 300, 400, 600, u64::MAX];

#[derive(Clone, Debug)]
pub struct LatencyHistogram {
    bins: [u64; 16],
    count: u64,
    sum_ms: u64,
}

impl LatencyHistogram {
    pub fn new() -> Self {
        Self { bins: [0; 16], count: 0, sum_ms: 0 }
    }

    pub fn observe_ms(&mut self, ms: u64) {
        let mut idx = 0;
        while idx < LAT_BOUNDS.len() && ms > LAT_BOUNDS[idx] { idx += 1; }
        if idx >= self.bins.len() { idx = self.bins.len() - 1; }
        self.bins[idx] += 1;
        self.count += 1;
        self.sum_ms += ms;
    }

    pub fn export(&self, name: &'static str, labels: &'static [(&'static str, &'static str)]) -> MetricEnvelope {
        MetricEnvelope {
            ts_ms: now_ms(),
            name,
            labels,
            kind: MetricKind::LatencyHist { bins: self.bins },
        }
    }

    pub fn quantile(&self, q: f64) -> u64 {
        let target = (self.count as f64 * q).ceil() as u64;
        if target == 0 { return 0; }
        let mut acc = 0u64;
        for (i, c) in self.bins.iter().enumerate() {
            acc += *c;
            if acc >= target {
                return LAT_BOUNDS[i];
            }
        }
        LAT_BOUNDS[LAT_BOUNDS.len() - 1]
    }

    pub fn p50(&self) -> u64 { self.quantile(0.50) }
    pub fn p90(&self) -> u64 { self.quantile(0.90) }
    pub fn p99(&self) -> u64 { self.quantile(0.99) }

    pub fn count(&self) -> u64 { self.count }
    pub fn sum_ms(&self) -> u64 { self.sum_ms }
}

// Counter/Gauge helpers
pub fn counter(name: &'static str, delta: u64, labels: &'static [(&'static str, &'static str)]) -> MetricEnvelope {
    MetricEnvelope {
        ts_ms: now_ms(),
        name,
        labels,
        kind: MetricKind::Counter { delta },
    }
}

pub fn gauge(name: &'static str, value: i64, labels: &'static [(&'static str, &'static str)]) -> MetricEnvelope {
    MetricEnvelope {
        ts_ms: now_ms(),
        name,
        labels,
        kind: MetricKind::Gauge { value },
    }
}

pub fn summary(name: &'static str, count: u64, sum: u64, labels: &'static [(&'static str, &'static str)]) -> MetricEnvelope {
    MetricEnvelope {
        ts_ms: now_ms(),
        name,
        labels,
        kind: MetricKind::Summary { count, sum },
    }
}

// Wire encoder (simple, deterministic; Version 1)
// Format: [ts_ms u64][name_len u16][name bytes][labels_count u16][each: k_len u16 k_bytes v_len u16 v_bytes][kind_tag u8][payload...]
pub fn encode_wire(m: &MetricEnvelope) -> Vec<u8> {
    let mut buf = Vec::with_capacity(128);
    put_u64(&mut buf, m.ts_ms);
    put_str(&mut buf, m.name);
    put_u16(&mut buf, m.labels.len() as u16);
    for (k, v) in m.labels.iter() {
        put_str(&mut buf, k);
        put_str(&mut buf, v);
    }
    match &m.kind {
        MetricKind::Counter { delta } => {
            buf.push(1u8);
            put_u64(&mut buf, *delta);
        }
        MetricKind::Gauge { value } => {
            buf.push(2u8);
            put_i64(&mut buf, *value);
        }
        MetricKind::Summary { count, sum } => {
            buf.push(3u8);
            put_u64(&mut buf, *count);
            put_u64(&mut buf, *sum);
        }
        MetricKind::LatencyHist { bins } => {
            buf.push(4u8);
            for b in bins.iter() { put_u64(&mut buf, *b); }
        }
    }
    buf
}

fn put_u16(buf: &mut Vec<u8>, v: u16) { buf.extend_from_slice(&v.to_be_bytes()); }
fn put_u64(buf: &mut Vec<u8>, v: u64) { buf.extend_from_slice(&v.to_be_bytes()); }
fn put_i64(buf: &mut Vec<u8>, v: i64) { buf.extend_from_slice(&v.to_be_bytes()); }
fn put_str(buf: &mut Vec<u8>, s: &str) {
    let bytes = s.as_bytes();
    put_u16(buf, bytes.len() as u16);
    buf.extend_from_slice(bytes);
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64
}

// Example usage
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hist() {
        let mut h = LatencyHistogram::new();
        for ms in [3u64, 7, 12, 55, 180, 240, 510].iter() {
            h.observe_ms(*ms);
        }
        assert!(h.p90() >= 240);
        let env = h.export("latency", &[("route", "/hello"), ("method", "GET")]);
        let wire = encode_wire(&env);
        assert!(wire.len() > 16);
    }

    #[test]
    fn test_counter_encode() {
        let env = counter("requests_total", 1, &[("tenant", "default")]);
        let wire = encode_wire(&env);
        assert_eq!(wire[16 + 2 + "requests_total".len() + 2 + (6+7+2+7),  /* rough index */], 1u8);
    }
}