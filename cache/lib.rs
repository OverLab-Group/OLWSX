// ============================================================================
// OLWSX - OverLab Web ServerX
// File: cache/lib.rs
// Role: Final & Stable cache facade
// Philosophy: One version, the most stable version, first and last.
// ----------------------------------------------------------------------------

#![forbid(unsafe_code)]
#![deny(warnings)]
#![allow(clippy::needless_return)]

pub mod l1;
pub mod l2;
pub mod l3;
pub mod compression;

use std::time::{Duration, Instant};

/// Meta flags (frozen; mirror core)
pub mod meta {
    pub const COMP_NONE: u32   = 0x0000_0000;
    pub const COMP_GZIP: u32   = 0x0000_0001;
    pub const COMP_ZSTD: u32   = 0x0000_0002;
    pub const COMP_BROTLI: u32 = 0x0000_0004;

    pub const CACHE_MISS: u32  = 0x0001_0000;
    pub const CACHE_L1: u32    = 0x0002_0000;
    pub const CACHE_L2: u32    = 0x0004_0000;
    pub const CACHE_L3: u32    = 0x0008_0000;

    pub const SEC_OK: u32      = 0x0010_0000;
    pub const SEC_WAF: u32     = 0x0020_0000;
    pub const SEC_RATELIM: u32 = 0x0040_0000;
}

/// Canonical cache entry (frozen)
#[derive(Clone, Debug)]
pub struct Entry {
    pub value: Vec<u8>,
    pub flags: u32,
    pub ts: Instant,
    pub ttl: Duration,
}

impl Entry {
    pub fn new(value: Vec<u8>, flags: u32, ttl: Duration) -> Self {
        return Entry { value, flags, ts: Instant::now(), ttl };
    }
    pub fn is_expired(&self) -> bool {
        return self.ts.elapsed() > self.ttl;
    }
}

/// Unified errors (frozen)
#[derive(Debug)]
pub enum CacheError {
    TooLarge,
    NotFound,
    Expired,
}

/// Cache trait (frozen)
pub trait Cache {
    fn lookup(&self, key: &[u8]) -> Result<Entry, CacheError>;
    fn insert(&self, key: &[u8], entry: Entry) -> Result<(), CacheError>;
    fn invalidate(&self, key: &[u8]) -> Result<(), CacheError>;
}