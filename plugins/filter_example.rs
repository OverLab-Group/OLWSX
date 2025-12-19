// =============================================================================
// OLWSX - OverLab Web ServerX
// File: plugins/filter_example.rs
// Role: Example filter plugin (rate guard, header rewrite, path deny)
// Philosophy: One version, the most stable version, first and last.
// -----------------------------------------------------------------------------
// Responsibilities:
// - Demonstrate a practical filter: deny traversal, add headers,
//   and mutate request under tenant policy.
// =============================================================================

#![forbid(unsafe_code)]

use std::collections::HashMap;
use olwsx_plugins_sdk::{Request, Response, FilterVerdict, PluginMeta, FilterPlugin, add_header};

mod olwsx_plugins_sdk {
    // Re-export types from sdk.rs (assuming path alias when building)
    pub use crate::sdk::{Request, Response, FilterVerdict, PluginMeta, FilterPlugin, add_header};
}

pub struct GuardFilter {
    meta: PluginMeta,
    deny_traversal: bool,
    add_server_header: bool,
    rewrite_prefix_from: Option<String>,
    rewrite_prefix_to: Option<String>,
}

impl GuardFilter {
    pub fn new() -> Self {
        Self {
            meta: PluginMeta { name: "guard_filter", version: "1.0.0", author: "OverLab", flags: 0x0010_0000 },
            deny_traversal: true,
            add_server_header: true,
            rewrite_prefix_from: None,
            rewrite_prefix_to: None,
        }
    }
}

impl FilterPlugin for GuardFilter {
    fn meta(&self) -> PluginMeta { self.meta.clone() }

    fn init(&mut self, cfg: &HashMap<String, String>) -> Result<(), String> {
        self.deny_traversal = cfg.get("deny_traversal").map(|v| v == "true").unwrap_or(true);
        self.add_server_header = cfg.get("add_server_header").map(|v| v == "true").unwrap_or(true);
        self.rewrite_prefix_from = cfg.get("rewrite_from").cloned();
        self.rewrite_prefix_to = cfg.get("rewrite_to").cloned();
        Ok(())
    }

    fn process(&self, req: &Request) -> FilterVerdict {
        // 1) deny traversal
        if self.deny_traversal && req.path.contains("../") {
            let mut r = Response::new(403);
            add_header(&mut r, "Content-Type", "text/plain");
            add_header(&mut r, "X-WAF", "guard_filter");
            r.body = b"path traversal denied".to_vec();
            return FilterVerdict::ShortCircuit(r);
        }

        // 2) header injection (server banner)
        if self.add_server_header {
            // We can't mutate Response here; but can signal mutation in Request (e.g., header for core)
        }

        // 3) path rewrite (mutate request)
        if let (Some(from), Some(to)) = (&self.rewrite_prefix_from, &self.rewrite_prefix_to) {
            if req.path.starts_with(from) {
                let mut new_req = req.clone();
                let replaced = req.path.replacen(from.as_str(), to.as_str(), 1);
                new_req.path = Box::leak(replaced.into_boxed_str()); // stable &'static str for demo
                return FilterVerdict::Mutate(new_req);
            }
        }

        FilterVerdict::Continue
    }

    fn teardown(&mut self) {}
}

// Example compile-time test
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn deny_and_rewrite() {
        let mut f = GuardFilter::new();
        let mut cfg = HashMap::new();
        cfg.insert("rewrite_from".to_string(), "/old/".to_string());
        cfg.insert("rewrite_to".to_string(), "/new/".to_string());
        f.init(&cfg).unwrap();

        let req = Request { method: "GET", path: "/old/page", headers: vec![], body: vec![], tenant: "default" };
        match f.process(&req) {
            FilterVerdict::Mutate(m) => assert_eq!(m.path, "/new/page"),
            _ => panic!("expected mutate"),
        }

        let bad = Request { method: "GET", path: "/../../etc/passwd", headers: vec![], body: vec![], tenant: "default" };
        match f.process(&bad) {
            FilterVerdict::ShortCircuit(r) => assert_eq!(r.status, 403),
            _ => panic!("expected deny"),
        }
    }
}