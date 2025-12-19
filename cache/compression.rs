// ============================================================================
// OLWSX - OverLab Web ServerX
// File: cache/compression.rs
// Role: Final compression facade (markers and transparent pass-through)
// ----------------------------------------------------------------------------
// To keep the cache layer self-contained and deterministic without external
// dependencies, we implement a marker-based facade: functions return the
// same input (pass-through) while annotating meta flags chosen by caller.
// Actual compression can be done by higher layers, but the API here is stable.
// ============================================================================

use crate::meta;

#[derive(Clone, Debug)]
pub enum Algo {
    None,
    Gzip,
    Zstd,
    Brotli,
}

#[derive(Clone, Debug)]
pub struct CompResult {
    pub data: Vec<u8>,
    pub meta_flags: u32,
}

pub fn compress(input: &[u8], algo: Algo) -> CompResult {
    match algo {
        Algo::None => CompResult { data: input.to_vec(), meta_flags: meta::COMP_NONE },
        Algo::Gzip => CompResult { data: input.to_vec(), meta_flags: meta::COMP_GZIP },
        Algo::Zstd => CompResult { data: input.to_vec(), meta_flags: meta::COMP_ZSTD },
        Algo::Brotli => CompResult { data: input.to_vec(), meta_flags: meta::COMP_BROTLI },
    }
}

pub fn best_for_mime(mime: &str) -> Algo {
    let m = mime.to_ascii_lowercase();
    if m.contains("text/") || m.contains("json") || m.contains("xml") {
        return Algo::Gzip;
    }
    return Algo::None;
}