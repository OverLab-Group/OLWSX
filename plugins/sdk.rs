// =============================================================================
// OLWSX - OverLab Web ServerX
// File: plugins/sdk.rs
// Role: Final & Stable plugin SDK (Rust), ABI fixed, safe contracts
// Philosophy: One version, the most stable version, first and last.
// -----------------------------------------------------------------------------
// Responsibilities:
// - Define frozen plugin ABI and traits for filters and handlers.
// - Provide safe wrappers around raw C ABI shims (for core integration).
// - Deterministic registry and lifecycle hooks (init, process, teardown).
// =============================================================================

#![forbid(unsafe_code)]

use std::collections::HashMap;

// ------------------------------- Frozen types -------------------------------

#[derive(Clone, Debug)]
pub struct Request {
    pub method: &'static str,
    pub path: &'static str,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    pub tenant: &'static str,
}

#[derive(Clone, Debug)]
pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn new(status: u16) -> Self {
        Self { status, headers: Vec::new(), body: Vec::new() }
    }
}

// Filter verdict: allow to continue, short-circuit with response, or mutate
#[derive(Clone, Debug)]
pub enum FilterVerdict {
    Continue,
    ShortCircuit(Response),
    Mutate(Request),
}

// Handler result: definitive response
#[derive(Clone, Debug)]
pub struct HandlerResult {
    pub resp: Response,
    pub meta_flags: u32, // frozen bitfield (e.g., COMP_NONE, CACHE_L2, SEC_OK)
}

// Plugin metadata (frozen fields)
#[derive(Clone, Debug)]
pub struct PluginMeta {
    pub name: &'static str,
    pub version: &'static str,
    pub author: &'static str,
    pub flags: u32,
}

// ------------------------------- Plugin traits ------------------------------

pub trait FilterPlugin: Send + Sync {
    fn meta(&self) -> PluginMeta;
    fn init(&mut self, cfg: &HashMap<String, String>) -> Result<(), String>;
    fn process(&self, req: &Request) -> FilterVerdict;
    fn teardown(&mut self) {}
}

pub trait HandlerPlugin: Send + Sync {
    fn meta(&self) -> PluginMeta;
    fn init(&mut self, cfg: &HashMap<String, String>) -> Result<(), String>;
    fn handle(&self, req: &Request) -> HandlerResult;
    fn teardown(&mut self) {}
}

// ------------------------------- Registry -----------------------------------

pub struct Registry {
    filters: HashMap<&'static str, Box<dyn FilterPlugin>>,
    handlers: HashMap<&'static str, Box<dyn HandlerPlugin>>,
}

impl Registry {
    pub fn new() -> Self {
        Self { filters: HashMap::new(), handlers: HashMap::new() }
    }

    pub fn register_filter(&mut self, key: &'static str, plugin: Box<dyn FilterPlugin>) -> Result<(), String> {
        if self.filters.contains_key(key) {
            return Err(format!("filter key '{}' already registered", key));
        }
        self.filters.insert(key, plugin);
        Ok(())
    }

    pub fn register_handler(&mut self, key: &'static str, plugin: Box<dyn HandlerPlugin>) -> Result<(), String> {
        if self.handlers.contains_key(key) {
            return Err(format!("handler key '{}' already registered", key));
        }
        self.handlers.insert(key, plugin);
        Ok(())
    }

    pub fn init_all(&mut self, cfgs: &HashMap<String, HashMap<String, String>>) -> Result<(), String> {
        for (k, p) in self.filters.iter_mut() {
            let cfg = cfgs.get(*k).cloned().unwrap_or_default();
            p.init(&cfg)?;
        }
        for (k, p) in self.handlers.iter_mut() {
            let cfg = cfgs.get(*k).cloned().unwrap_or_default();
            p.init(&cfg)?;
        }
        Ok(())
    }

    pub fn filter(&self, key: &str, req: &Request) -> FilterVerdict {
        if let Some(p) = self.filters.get(key) {
            p.process(req)
        } else {
            FilterVerdict::Continue
        }
    }

    pub fn handle(&self, key: &str, req: &Request) -> Option<HandlerResult> {
        self.handlers.get(key).map(|p| p.handle(req))
    }

    pub fn teardown_all(&mut self) {
        for (_, p) in self.filters.iter_mut() {
            p.teardown();
        }
        for (_, p) in self.handlers.iter_mut() {
            p.teardown();
        }
    }
}

// ---------------------------- Deterministic helpers -------------------------

pub fn add_header(resp: &mut Response, k: &str, v: &str) {
    resp.headers.push((k.to_string(), v.to_string()));
}

pub fn set_body(resp: &mut Response, bytes: &[u8]) {
    resp.body.clear();
    resp.body.extend_from_slice(bytes);
}

pub fn json(bytes: &[u8]) -> Response {
    let mut r = Response::new(200);
    add_header(&mut r, "Content-Type", "application/json");
    set_body(&mut r, bytes);
    r
}

// ------------------------------- Example wire API ---------------------------
// Note: The core loads plugins and invokes registry via a thin ABI boundary.
// In OLWSX, ABI is fixed; here we expose a pure Rust surface for in-process use.

#[cfg(test)]
mod tests {
    use super::*;

    struct NopFilter;
    impl FilterPlugin for NopFilter {
        fn meta(&self) -> PluginMeta { PluginMeta { name: "nop_filter", version: "1.0.0", author: "OLWSX", flags: 0 } }
        fn init(&mut self, _cfg: &HashMap<String, String>) -> Result<(), String> { Ok(()) }
        fn process(&self, _req: &Request) -> FilterVerdict { FilterVerdict::Continue }
    }

    struct EchoHandler;
    impl HandlerPlugin for EchoHandler {
        fn meta(&self) -> PluginMeta { PluginMeta { name: "echo_handler", version: "1.0.0", author: "OLWSX", flags: 0x0010_0000 } }
        fn init(&mut self, _cfg: &HashMap<String, String>) -> Result<(), String> { Ok(()) }
        fn handle(&self, req: &Request) -> HandlerResult {
            let mut r = Response::new(200);
            add_header(&mut r, "X-Plugin", "echo_handler");
            set_body(&mut r, req.body.as_slice());
            HandlerResult { resp: r, meta_flags: 0x0010_0000 }
        }
    }

    #[test]
    fn registry_flow() {
        let mut reg = Registry::new();
        reg.register_filter("pre_nop", Box::new(NopFilter)).unwrap();
        reg.register_handler("echo", Box::new(EchoHandler)).unwrap();

        reg.init_all(&HashMap::new()).unwrap();

        let req = Request { method: "GET", path: "/hello", headers: vec![], body: b"hi".to_vec(), tenant: "default" };
        match reg.filter("pre_nop", &req) {
            FilterVerdict::Continue => {}
            _ => panic!("unexpected"),
        }
        let out = reg.handle("echo", &req).unwrap();
        assert_eq!(out.resp.status, 200);
        assert_eq!(out.resp.body, b"hi".to_vec());
        reg.teardown_all();
    }
}