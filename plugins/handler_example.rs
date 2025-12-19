// =============================================================================
// OLWSX - OverLab Web ServerX
// File: plugins/handler_example.rs
// Role: Example handler plugin (static JSON, health, echo)
// Philosophy: One version, the most stable version, first and last.
// -----------------------------------------------------------------------------
// Responsibilities:
// - Demonstrate a handler that returns deterministic JSON payloads.
// - Fixed meta flags to integrate with cache/security in core.
// =============================================================================

#![forbid(unsafe_code)]

use std::collections::HashMap;
use olwsx_plugins_sdk::{Request, HandlerResult, Response, PluginMeta, HandlerPlugin, add_header, set_body};

mod olwsx_plugins_sdk {
    pub use crate::sdk::{Request, HandlerResult, Response, PluginMeta, HandlerPlugin, add_header, set_body};
}

pub struct StaticJsonHandler {
    meta: PluginMeta,
    route: &'static str,
    content: &'static [u8],
    status: u16,
}

impl StaticJsonHandler {
    pub fn new() -> Self {
        Self {
            meta: PluginMeta { name: "static_json", version: "1.0.0", author: "OverLab", flags: 0x0010_0000 },
            route: "/__health",
            content: br#"{"status":"ok","server":"OLWSX"}"#,
            status: 200,
        }
    }
}

impl HandlerPlugin for StaticJsonHandler {
    fn meta(&self) -> PluginMeta { self.meta.clone() }

    fn init(&mut self, cfg: &HashMap<String, String>) -> Result<(), String> {
        if let Some(r) = cfg.get("route") {
            self.route = Box::leak(r.clone().into_boxed_str());
        }
        if let Some(s) = cfg.get("status") {
            self.status = s.parse::<u16>().map_err(|_| "invalid status".to_string())?;
        }
        Ok(())
    }

    fn handle(&self, req: &Request) -> HandlerResult {
        if req.path == self.route {
            let mut resp = Response::new(self.status);
            add_header(&mut resp, "Content-Type", "application/json");
            add_header(&mut resp, "Cache-Control", "no-store");
            set_body(&mut resp, self.content);
            HandlerResult { resp, meta_flags: 0x0010_0000 }
        } else if req.path.starts_with("/echo") && req.method == "POST" {
            let mut resp = Response::new(200);
            add_header(&mut resp, "Content-Type", "application/octet-stream");
            set_body(&mut resp, &req.body);
            HandlerResult { resp, meta_flags: 0x0001_0000 }
        } else {
            let mut resp = Response::new(404);
            add_header(&mut resp, "Content-Type", "text/plain");
            set_body(&mut resp, b"not found");
            HandlerResult { resp, meta_flags: 0x0000_0000 }
        }
    }

    fn teardown(&mut self) {}
}

// Example tests
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn health_and_echo() {
        let h = StaticJsonHandler::new();
        let health = Request { method: "GET", path: "/__health", headers: vec![], body: vec![], tenant: "default" };
        let r = h.handle(&health);
        assert_eq!(r.resp.status, 200);
        assert!(String::from_utf8(r.resp.body.clone()).unwrap().contains("\"ok\""));

        let echo = Request { method: "POST", path: "/echo", headers: vec![], body: b"OLWSX".to_vec(), tenant: "default" };
        let r2 = h.handle(&echo);
        assert_eq!(r2.resp.status, 200);
        assert_eq!(r2.resp.body, b"OLWSX".to_vec());
    }
}