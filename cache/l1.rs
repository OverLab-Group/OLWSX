use crate::{Cache, CacheError, Entry};
use std::collections::VecDeque;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

const MAX_ENTRIES: usize = 1024; // frozen cap

#[derive(Clone)]
pub struct L1 {
    inner: Arc<Mutex<State>>,
}

struct State {
    map: HashMap<Vec<u8>, Entry>,
    order: VecDeque<Vec<u8>>, // simple FIFO eviction
}

impl L1 {
    pub fn new() -> Self {
        let st = State { map: HashMap::new(), order: VecDeque::new() };
        return L1 { inner: Arc::new(Mutex::new(st)) };
    }
}

impl Cache for L1 {
    fn lookup(&self, key: &[u8]) -> Result<Entry, CacheError> {
        let mut st = self.inner.lock().unwrap();
        if let Some(e) = st.map.get(key) {
            if e.is_expired() {
                st.map.remove(key);
                return Err(CacheError::Expired);
            }
            return Ok(e.clone());
        }
        return Err(CacheError::NotFound);
    }

    fn insert(&self, key: &[u8], entry: Entry) -> Result<(), CacheError> {
        let mut st = self.inner.lock().unwrap();
        let k = key.to_vec();
        if !st.map.contains_key(&k) {
            st.order.push_back(k.clone());
        }
        st.map.insert(k.clone(), entry);
        // eviction if over cap
        while st.order.len() > MAX_ENTRIES {
            if let Some(old) = st.order.pop_front() {
                st.map.remove(&old);
            }
        }
        return Ok(());
    }

    fn invalidate(&self, key: &[u8]) -> Result<(), CacheError> {
        let mut st = self.inner.lock().unwrap();
        let k = key.to_vec();
        if st.map.remove(&k).is_some() {
            // remove from order (linear scan, bounded by cap)
            st.order = st.order.iter().filter(|x| **x != k).cloned().collect();
            return Ok(());
        }
        return Err(CacheError::NotFound);
    }
}