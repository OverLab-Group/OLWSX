// ============================================================================
// OLWSX - OverLab Web ServerX
// File: cache/l2.rs
// Role: Final L2 cache (ARC-like with bounded memory, concurrent R/W)
// ----------------------------------------------------------------------------

use crate::{Cache, CacheError, Entry};
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, RwLock};
use std::time::Duration;

// Frozen limits
const MAX_ITEMS: usize = 65_536;
const MAX_VALUE_BYTES: usize = 64 * 1024 * 1024; // 64MB
const DEFAULT_TTL: Duration = Duration::from_secs(300);

#[derive(Clone)]
pub struct L2 {
    inner: Arc<RwLock<State>>,
}

struct State {
    // Simplified ARC partitions
    t1: VecDeque<Vec<u8>>, // recent
    t2: VecDeque<Vec<u8>>, // frequent
    b1: VecDeque<Vec<u8>>, // ghost recent
    b2: VecDeque<Vec<u8>>, // ghost frequent
    map: HashMap<Vec<u8>, Entry>,
    p_target: usize, // balancing target
}

impl L2 {
    pub fn new() -> Self {
        let st = State {
            t1: VecDeque::new(),
            t2: VecDeque::new(),
            b1: VecDeque::new(),
            b2: VecDeque::new(),
            map: HashMap::new(),
            p_target: MAX_ITEMS / 2,
        };
        return L2 { inner: Arc::new(RwLock::new(st)) };
    }

    fn replace(st: &mut State, miss_key: &[u8]) {
        // Balance between t1 and t2 by p_target using ghost hits in b1/b2
        if st.t1.len() > 0 && (st.t1.len() > st.p_target || (st.b2.contains(&miss_key.to_vec()) && st.t1.len() == st.p_target)) {
            if let Some(k) = st.t1.pop_front() {
                st.map.remove(&k);
                st.b1.push_back(k);
                if st.b1.len() > MAX_ITEMS { st.b1.pop_front(); }
            }
        } else {
            if let Some(k) = st.t2.pop_front() {
                st.map.remove(&k);
                st.b2.push_back(k);
                if st.b2.len() > MAX_ITEMS { st.b2.pop_front(); }
            }
        }
    }

    fn touch(st: &mut State, key: &[u8]) {
        let k = key.to_vec();
        // Promote to t2 if present in t1
        if let Some(pos) = st.t1.iter().position(|x| *x == k) {
            st.t1.remove(pos);
            st.t2.push_back(k);
        } else {
            // If in t2, move to back
            if let Some(pos) = st.t2.iter().position(|x| *x == k) {
                st.t2.remove(pos);
                st.t2.push_back(k);
            } else {
                // New item goes to t1
                st.t1.push_back(k);
                while st.t1.len() + st.t2.len() > MAX_ITEMS {
                    Self::replace(st, key);
                }
            }
        }
    }
}

impl Cache for L2 {
    fn lookup(&self, key: &[u8]) -> Result<Entry, CacheError> {
        let mut st = self.inner.write().unwrap();
        if let Some(e) = st.map.get(key) {
            if e.is_expired() {
                st.map.remove(key);
                return Err(CacheError::Expired);
            }
            Self::touch(&mut st, key);
            return Ok(e.clone());
        }
        // ghost hit tuning
        let k = key.to_vec();
        if st.b1.contains(&k) {
            st.p_target = std::cmp::min(MAX_ITEMS, st.p_target + 1);
        } else if st.b2.contains(&k) {
            st.p_target = st.p_target.saturating_sub(1);
        }
        return Err(CacheError::NotFound);
    }

    fn insert(&self, key: &[u8], entry: Entry) -> Result<(), CacheError> {
        if entry.value.len() > MAX_VALUE_BYTES {
            return Err(CacheError::TooLarge);
        }
        let mut st = self.inner.write().unwrap();
        let k = key.to_vec();
        st.map.insert(k.clone(), Entry { ttl: if entry.ttl == Duration::ZERO { DEFAULT_TTL } else { entry.ttl }, ..entry });
        Self::touch(&mut st, &k);
        while st.t1.len() + st.t2.len() > MAX_ITEMS {
            Self::replace(&mut st, &k);
        }
        return Ok(());
    }

    fn invalidate(&self, key: &[u8]) -> Result<(), CacheError> {
        let mut st = self.inner.write().unwrap();
        let k = key.to_vec();
        let existed = st.map.remove(&k).is_some();
        st.t1 = st.t1.iter().filter(|x| **x != k).cloned().collect();
        st.t2 = st.t2.iter().filter(|x| **x != k).cloned().collect();
        if existed { return Ok(()); }
        return Err(CacheError::NotFound);
    }
}