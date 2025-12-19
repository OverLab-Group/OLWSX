// ============================================================================
// OLWSX - OverLab Web ServerX
// File: cache/l3.rs
// Role: Final L3 cache (distributed-ready facade with local store)
// ----------------------------------------------------------------------------

use crate::{Cache, CacheError, Entry};
use std::collections::HashMap;
use std::sync::{Arc, RwLock};

/// L3 is designed as a facade: for now a local concurrent map,
/// but keeping the interface future-proof for sharding/clustered backends.
#[derive(Clone)]
pub struct L3 {
    inner: Arc<RwLock<HashMap<Vec<u8>, Entry>>>,
}

impl L3 {
    pub fn new() -> Self {
        return L3 { inner: Arc::new(RwLock::new(HashMap::new())) };
    }
}

impl Cache for L3 {
    fn lookup(&self, key: &[u8]) -> Result<Entry, CacheError> {
        let mut map = self.inner.write().unwrap();
        if let Some(e) = map.get(key) {
            if e.is_expired() {
                map.remove(key);
                return Err(CacheError::Expired);
            }
            return Ok(e.clone());
        }
        return Err(CacheError::NotFound);
    }

    fn insert(&self, key: &[u8], entry: Entry) -> Result<(), CacheError> {
        let mut map = self.inner.write().unwrap();
        map.insert(key.to_vec(), entry);
        return Ok(());
    }

    fn invalidate(&self, key: &[u8]) -> Result<(), CacheError> {
        let mut map = self.inner.write().unwrap();
        if map.remove(key).is_some() {
            return Ok(());
        }
        return Err(CacheError::NotFound);
    }
}