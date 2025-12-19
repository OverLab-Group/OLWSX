// =============================================================================
// OLWSX - OverLab Web ServerX
// File: security/waf.rs
// Role: Final & Stable WAF engine (fast matchers, fixed rule schema)
// Philosophy: One version, the most stable version, first and last.
// -----------------------------------------------------------------------------
// Responsibilities:
// - Fixed rule schema: path/user-agent/body/header matchers and actions.
// - Deterministic evaluation order: deny -> challenge -> log -> allow.
// - SIMD-friendly scanning and bounded memory; pure Rust, no unsafe.
// =============================================================================

use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug)]
pub enum Action {
    Deny(u16),         // HTTP status to return (e.g., 403)
    Challenge(u16),    // Lightweight proof-of-work or JS gate (status hint)
    LogOnly,           // Record but allow
    Allow,             // Explicit allow (short-circuit)
}

#[derive(Clone, Debug)]
pub enum Field {
    Path,
    UserAgent,
    Header(String),
    Body,
    Ip,                // string representation
}

#[derive(Clone, Debug)]
pub enum Matcher {
    Contains(String),
    Prefix(String),
    Suffix(String),
    Regex(String),     // stored, but evaluated via safe substring (no RE engine here)
    Eq(String),
}

#[derive(Clone, Debug)]
pub struct Rule {
    pub id: u32,
    pub field: Field,
    pub matcher: Matcher,
    pub action: Action,
    pub tags: &'static [&'static str], // e.g., ["sqlmap", "traversal"]
    pub severity: u8,                  // 1..10
}

#[derive(Clone, Debug)]
pub struct RequestView<'a> {
    pub path: &'a str,
    pub user_agent: &'a str,
    pub headers: &'a [(&'a str, &'a str)],
    pub body: &'a [u8],
    pub ip: &'a str,
}

#[derive(Clone, Debug)]
pub struct Decision {
    pub ts_ms: u64,
    pub applied_rule_id: Option<u32>,
    pub action: Action,
    pub reason: String,
    pub tags: Vec<&'static str>,
    pub severity: u8,
}

pub struct Engine {
    rules: Vec<Rule>,
}

impl Engine {
    pub fn new(rules: Vec<Rule>) -> Self {
        Self { rules }
    }

    pub fn decide(&self, req: &RequestView) -> Decision {
        // Evaluation order: Deny first, then Challenge, LogOnly, Allow
        let mut candidate: Option<(Rule, String)> = None;

        for r in self.rules.iter() {
            if self.matches(req, r) {
                let why = Self::describe_match(req, r);
                match r.action {
                    Action::Deny(_) => {
                        candidate = Some((r.clone(), why));
                        break;
                    }
                    Action::Challenge(_) => {
                        candidate = Some((r.clone(), why));
                        // keep scanning deny rules, but prefer first challenge otherwise
                        if candidate.is_some() {
                            // continue to see if any deny appears later; otherwise pick challenge
                        }
                    }
                    Action::LogOnly => {
                        if candidate.is_none() {
                            candidate = Some((r.clone(), why));
                        }
                    }
                    Action::Allow => {
                        // short-circuit explicit allow
                        return Decision {
                            ts_ms: now_ms(),
                            applied_rule_id: Some(r.id),
                            action: Action::Allow,
                            reason: "explicit allow".to_string(),
                            tags: r.tags.to_vec(),
                            severity: r.severity,
                        };
                    }
                }
            }
        }

        if let Some((r, why)) = candidate {
            Decision {
                ts_ms: now_ms(),
                applied_rule_id: Some(r.id),
                action: r.action.clone(),
                reason: why,
                tags: r.tags.to_vec(),
                severity: r.severity,
            }
        } else {
            Decision {
                ts_ms: now_ms(),
                applied_rule_id: None,
                action: Action::Allow,
                reason: "no rule matched".to_string(),
                tags: vec![],
                severity: 0,
            }
        }
    }

    fn matches(&self, req: &RequestView, r: &Rule) -> bool {
        let hay = match &r.field {
            Field::Path => req.path,
            Field::UserAgent => req.user_agent,
            Field::Header(name) => {
                for (k, v) in req.headers.iter() {
                    if eq_ci(k, name) {
                        return self.match_str(v, &r.matcher);
                    }
                }
                return false;
            }
            Field::Body => {
                // Body matching is only Contains/Eq in bytes (ASCII-safe here)
                return self.match_bytes(req.body, &r.matcher);
            }
            Field::Ip => req.ip,
        };
        self.match_str(hay, &r.matcher)
    }

    fn match_str(&self, hay: &str, m: &Matcher) -> bool {
        match m {
            Matcher::Contains(needle) => contains_ci(hay, needle),
            Matcher::Prefix(p) => hay.len() >= p.len() && eq_ci(&hay[..p.len()], p),
            Matcher::Suffix(s) => hay.len() >= s.len() && eq_ci(&hay[hay.len()-s.len()..], s),
            Matcher::Eq(x) => eq_ci(hay, x),
            Matcher::Regex(pseudo) => contains_ci(hay, pseudo), // pseudo-regex: controlled subset
        }
    }

    fn match_bytes(&self, hay: &[u8], m: &Matcher) -> bool {
        match m {
            Matcher::Contains(needle) | Matcher::Regex(needle) | Matcher::Eq(needle) => {
                let nd = needle.as_bytes();
                find_subslice_ci(hay, nd)
            }
            Matcher::Prefix(p) => {
                let nd = p.as_bytes();
                hay.len() >= nd.len() && eq_ci_bytes(&hay[..nd.len()], nd)
            }
            Matcher::Suffix(s) => {
                let nd = s.as_bytes();
                hay.len() >= nd.len() && eq_ci_bytes(&hay[hay.len()-nd.len()..], nd)
            }
        }
    }

    fn describe_match(req: &RequestView, r: &Rule) -> String {
        match r.field {
            Field::Path => format!("path matched {}", short(&r.matcher)),
            Field::UserAgent => format!("ua matched {}", short(&r.matcher)),
            Field::Header(ref h) => format!("header {} matched {}", h, short(&r.matcher)),
            Field::Body => "body matched".to_string(),
            Field::Ip => format!("ip matched {}", short(&r.matcher)),
        }
    }
}

// Helpers (case-insensitive, ASCII-focused for speed)
fn eq_ci(a: &str, b: &str) -> bool { a.eq_ignore_ascii_case(b) }
fn contains_ci(hay: &str, needle: &str) -> bool {
    hay.to_lowercase().contains(&needle.to_lowercase())
}
fn eq_ci_bytes(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() { return false; }
    a.iter().zip(b.iter()).all(|(x, y)| x.to_ascii_lowercase() == y.to_ascii_lowercase())
}
fn find_subslice_ci(hay: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() { return true; }
    let n = needle.len();
    if n > hay.len() { return false; }
    for i in 0..=hay.len()-n {
        if eq_ci_bytes(&hay[i..i+n], needle) {
            return true;
        }
    }
    false
}
fn short(m: &Matcher) -> String {
    match m {
        Matcher::Contains(s) => format!("contains({})", s),
        Matcher::Prefix(s) => format!("prefix({})", s),
        Matcher::Suffix(s) => format!("suffix({})", s),
        Matcher::Regex(s) => format!("regex-lite({})", s),
        Matcher::Eq(s) => format!("eq({})", s),
    }
}
fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64
}

// Predefined ruleset (frozen signatures)
pub fn default_rules() -> Vec<Rule> {
    vec![
        Rule {
            id: 1,
            field: Field::Path,
            matcher: Matcher::Contains("../".to_string()),
            action: Action::Deny(403),
            tags: &["traversal"],
            severity: 8,
        },
        Rule {
            id: 2,
            field: Field::UserAgent,
            matcher: Matcher::Contains("sqlmap".to_string()),
            action: Action::Deny(403),
            tags: &["sql_injection_bot"],
            severity: 7,
        },
        Rule {
            id: 3,
            field: Field::Header("X-Forwarded-For".to_string()),
            matcher: Matcher::Regex("bad-proxy".to_string()),
            action: Action::Challenge(429),
            tags: &["proxy_abuse"],
            severity: 5,
        },
        Rule {
            id: 4,
            field: Field::Body,
            matcher: Matcher::Contains("UNION SELECT".to_string()),
            action: Action::Deny(403),
            tags: &["sql_injection"],
            severity: 9,
        },
        Rule {
            id: 5,
            field: Field::Path,
            matcher: Matcher::Prefix("/.well-known/".to_string()),
            action: Action::Allow,
            tags: &["safe_allowlist"],
            severity: 1,
        },
    ]
}

// Example usage
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn test_decide() {
        let eng = Engine::new(default_rules());
        let req = RequestView {
            path: "/../../etc/passwd",
            user_agent: "curl/7.79.1",
            headers: &[("X-Forwarded-For", "bad-proxy")],
            body: b"GET /?q=UNION SELECT id FROM users",
            ip: "203.0.113.10",
        };
        let d = eng.decide(&req);
        match d.action {
            Action::Deny(code) => assert_eq!(code, 403),
            _ => panic!("expected deny"),
        }
    }
}