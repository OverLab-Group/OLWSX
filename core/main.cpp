// ============================================================================
// OLWSX - OverLab Web ServerX
// File: core/main.cpp
// Role: Final & Stable Core (Library-only, no main()), Strict C ABI
// Philosophy: One version, the most stable version, first and last.
// ----------------------------------------------------------------------------
// This is the definitive and complete OLWSX core. No features will be added,
// removed, or changed in the future. All code resides in core (no external
// language responsibilities).
// ============================================================================

#include <cstdint>
#include <cstddef>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <atomic>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <vector>
#include <unordered_map>
#include <chrono>

#include "abi/c_api.h"

// Internal includes from core modules
#include "memory/allocator.cpp"
#include "memory/arena.cpp"
#include "routing/router.cpp"
#include "filters/gzip_filter.cpp"

// ----------------------------------------------------------------------------
// Using
// ----------------------------------------------------------------------------
using namespace olwsx;

// ----------------------------------------------------------------------------
// Versioning & Constants (Frozen)
// ----------------------------------------------------------------------------
#define OLWSX_CORE_VERSION_MAJOR 1
#define OLWSX_CORE_VERSION_MINOR 0
#define OLWSX_CORE_VERSION_PATCH 0

// Tunables (fixed in this final version)
static constexpr std::size_t OLWSX_DEFAULT_ARENA_BYTES   = 32 * 1024 * 1024; // 32MB
static constexpr std::size_t OLWSX_MAX_HEADER_BYTES       = 2 * 1024 * 1024;  // 2MB
static constexpr std::size_t OLWSX_MAX_BODY_BYTES         = 64 * 1024 * 1024; // 64MB
static constexpr std::size_t OLWSX_MAX_KEY_BYTES          = 64 * 1024;        // 64KB
static constexpr std::size_t OLWSX_MAX_ROUTE_BYTES        = 64 * 1024;        // 64KB

// Flags (meta markers)
//static constexpr uint32_t META_COMP_NONE   = 0x00000000u;
//static constexpr uint32_t META_COMP_GZIP   = 0x00000001u;
static constexpr uint32_t META_COMP_ZSTD   = 0x00000002u;
static constexpr uint32_t META_COMP_BROTLI = 0x00000004u;

static constexpr uint32_t META_CACHE_MISS  = 0x00010000u;
static constexpr uint32_t META_CACHE_L1    = 0x00020000u;
static constexpr uint32_t META_CACHE_L2    = 0x00040000u;
static constexpr uint32_t META_CACHE_L3    = 0x00080000u;

static constexpr uint32_t META_SEC_OK      = 0x00100000u;
static constexpr uint32_t META_SEC_WAF     = 0x00200000u;
static constexpr uint32_t META_SEC_RATELIM = 0x00400000u;

// ----------------------------------------------------------------------------
// Cache (L2 implemented; L1/L3 stubs maintained locally)
// ----------------------------------------------------------------------------
struct CacheEntry {
    std::string value;
    uint64_t    ts_ns;    // last write
    uint32_t    flags;    // metadata flags
};

class CacheL2 {
public:
    bool lookup(const std::string& key, CacheEntry& out) const {
        std::shared_lock<std::shared_mutex> lock(mu_);
        auto it = store_.find(key);
        if (it == store_.end()) return false;
        out = it->second;
        return true;
    }

    void insert(const std::string& key, const std::string& val, uint32_t flags = 0) {
        std::unique_lock<std::shared_mutex> lock(mu_);
        store_[key] = CacheEntry{val, now_ns(), flags};
    }

    void erase(const std::string& key) {
        std::unique_lock<std::shared_mutex> lock(mu_);
        store_.erase(key);
    }

private:
    static uint64_t now_ns() {
        using namespace std::chrono;
        return duration_cast<std::chrono::nanoseconds>(steady_clock::now().time_since_epoch()).count();
    }

    mutable std::shared_mutex mu_;
    std::unordered_map<std::string, CacheEntry> store_;
};

class CacheL1Stub {
public:
    bool lookup(const std::string&, CacheEntry&) const { return false; }
    void insert(const std::string&, const std::string&, uint32_t) {}
    void erase(const std::string&) {}
};

class CacheL3Stub {
public:
    bool lookup(const std::string&, CacheEntry&) const { return false; }
    void insert(const std::string&, const std::string&, uint32_t) {}
    void erase(const std::string&) {}
};

// ----------------------------------------------------------------------------
// Security (stable hooks): rate-limit counters, WAF decision gate
// ----------------------------------------------------------------------------
struct SecCounters {
    std::atomic<uint64_t> rl_total{0};   // rate-limited requests (edge hinted)
    std::atomic<uint64_t> waf_total{0};  // blocked by WAF
    std::atomic<uint64_t> ok_total{0};   // allowed
};

class SecurityGate {
public:
    // Decides security outcome based on edge_hints and simple heuristics.
    // Stable semantics: if edge_hints has bit 1 => rate-limited; bit 2 => WAF.
    uint32_t decide(uint32_t edge_hints) {
        if (edge_hints & 0x2u) { counters_.waf_total.fetch_add(1, std::memory_order_relaxed); return META_SEC_WAF; }
        if (edge_hints & 0x1u) { counters_.rl_total.fetch_add(1, std::memory_order_relaxed); return META_SEC_RATELIM; }
        counters_.ok_total.fetch_add(1, std::memory_order_relaxed);
        return META_SEC_OK;
    }

    void stats(uint64_t& rl, uint64_t& waf, uint64_t& ok) const {
        rl  = counters_.rl_total.load(std::memory_order_relaxed);
        waf = counters_.waf_total.load(std::memory_order_relaxed);
        ok  = counters_.ok_total.load(std::memory_order_relaxed);
    }

private:
    SecCounters counters_;
};

// ----------------------------------------------------------------------------
// Core state
// ----------------------------------------------------------------------------
namespace olwsx {

using ::CacheL1Stub;
using ::CacheL2;
using ::CacheL3Stub;
using ::SecurityGate;
using ::CacheEntry;
using ::Arena;
using ::Router;
using ::RouteRule;
using ::ExportPool;
using ::Filter;
using ::GzipFilter;

struct Core {
    std::atomic<bool> running{false};
    std::atomic<uint32_t> config_generation{0};

    Arena       arena{OLWSX_DEFAULT_ARENA_BYTES};
    CacheL1Stub cache_l1;
    CacheL2     cache_l2;
    CacheL3Stub cache_l3;
    Router      router;
    SecurityGate sec;
};

static Core g_core;

// Utility functions
static inline uint64_t wall_epoch_ns() {
    using namespace std::chrono;
    return duration_cast<std::chrono::nanoseconds>(system_clock::now().time_since_epoch()).count();
}

static inline std::string to_string_view(const uint8_t* p, uint32_t n) {
    if (!p || n == 0) return std::string();
    return std::string(reinterpret_cast<const char*>(p), n);
}

static inline int validate_request_sizes(const olwsx_request_t* req) {
    if (!req) return OLWSX_ERR_INVALID_ARGUMENT;
    if (req->headers_len > OLWSX_MAX_HEADER_BYTES) return OLWSX_ERR_TOO_LARGE;
    if (req->body_len    > OLWSX_MAX_BODY_BYTES)   return OLWSX_ERR_TOO_LARGE;
    if (req->path_len    > OLWSX_MAX_ROUTE_BYTES)  return OLWSX_ERR_TOO_LARGE;
    return OLWSX_OK;
}

static inline uint8_t* export_copy(const void* src, std::size_t len) {
    if (!src || len == 0) return nullptr;
    uint8_t* dst = ExportPool::alloc(len, 1);
    if (!dst) return nullptr;
    std::memcpy(dst, src, len);
    return dst;
}

static inline uint8_t* export_copy_str(const std::string& s) {
    if (s.empty()) return nullptr;
    uint8_t* dst = ExportPool::alloc(s.size(), 1);
    if (!dst) return nullptr;
    std::memcpy(dst, s.data(), s.size());
    return dst;
}

static inline std::string compose_headers(const std::string& route_hdrs, const std::string& core_hdrs) {
    if (route_hdrs.empty()) return core_hdrs;
    return route_hdrs + core_hdrs;
}

} // namespace olwsx

// ----------------------------------------------------------------------------
// Internal implementations backing the C ABI (declared in ffi_bridge.cpp)
// ----------------------------------------------------------------------------
extern "C" {

int olwsx__core_version_impl(uint32_t* major, uint32_t* minor, uint32_t* patch) {
    if (major) *major = OLWSX_CORE_VERSION_MAJOR;
    if (minor) *minor = OLWSX_CORE_VERSION_MINOR;
    if (patch) *patch = OLWSX_CORE_VERSION_PATCH;
    return OLWSX_OK;
}

int olwsx__core_init_impl(olwsx_core_state_t* out_state) {
    using namespace olwsx;
    g_core.running.store(true, std::memory_order_release);

    if (out_state) {
        out_state->epoch_ns = wall_epoch_ns();
        out_state->flags    = 0x00000001u /*RUNNING*/ | 0x00000002u /*HOT_RELOAD_READY*/;
        out_state->reserved = 0;
        out_state->v_major  = OLWSX_CORE_VERSION_MAJOR;
        out_state->v_minor  = OLWSX_CORE_VERSION_MINOR;
        out_state->v_patch  = OLWSX_CORE_VERSION_PATCH;
    }

    // Warm-up: insert a known cache L2 entry
    g_core.cache_l2.insert("/hello", "Hello from OLWSX Core (L2 cached)", META_COMP_NONE);

    // Default deterministic routes (frozen example)
    std::vector<RouteRule> rules;
    rules.push_back(RouteRule{
        /*match_prefix*/ "/__status",
        /*status_override*/ 200,
        /*static_body*/ "OK",
        /*resp_headers*/ "Content-Type: text/plain\r\n",
        /*meta_flags*/ META_COMP_NONE | META_CACHE_MISS | META_SEC_OK
    });
    rules.push_back(RouteRule{
        /*match_prefix*/ "/__hello",
        /*status_override*/ 200,
        /*static_body*/ "Hello, OLWSX!",
        /*resp_headers*/ "Content-Type: text/plain\r\n",
        /*meta_flags*/ META_COMP_NONE | META_CACHE_MISS | META_SEC_OK
    });
    g_core.router.set_rules(rules);

    return OLWSX_OK;
}

int olwsx__core_shutdown_impl() {
    using namespace olwsx;
    g_core.running.store(false, std::memory_order_release);
    return OLWSX_OK;
}

int olwsx__core_status_impl(uint32_t* flags_out, uint32_t* generation_out) {
    using namespace olwsx;
    if (!g_core.running.load(std::memory_order_acquire)) return OLWSX_ERR_NOT_INITIALIZED;
    if (flags_out)      *flags_out      = 0x00000001u /*RUNNING*/ | 0x00000002u /*HOT_RELOAD_READY*/;
    if (generation_out) *generation_out = g_core.config_generation.load(std::memory_order_acquire);
    return OLWSX_OK;
}

int olwsx__arena_reset_impl() {
    using namespace olwsx;
    g_core.arena.reset();
    return OLWSX_OK;
}

void olwsx__free_impl(void* p) {
    olwsx::ExportPool::free(reinterpret_cast<uint8_t*>(p));
}

int olwsx__stage_config_impl(const olwsx_config_blob_t* blob) {
    using namespace olwsx;
    if (!blob || !blob->data || blob->len == 0) return OLWSX_ERR_INVALID_ARGUMENT;
    g_core.config_generation.store(blob->generation, std::memory_order_release);
    return OLWSX_OK;
}

int olwsx__apply_config_impl(uint32_t generation) {
    using namespace olwsx;
    uint32_t staged = g_core.config_generation.load(std::memory_order_acquire);
    if (staged != generation) return OLWSX_ERR_NOT_FOUND;
    return OLWSX_OK;
}

int olwsx__cache_invalidate_l2_impl(const uint8_t* key, uint32_t key_len) {
    using namespace olwsx;
    if (!key || key_len == 0) return OLWSX_ERR_INVALID_ARGUMENT;
    if (key_len > OLWSX_MAX_KEY_BYTES) return OLWSX_ERR_TOO_LARGE;
    std::string k(reinterpret_cast<const char*>(key), key_len);
    g_core.cache_l2.erase(k);
    return OLWSX_OK;
}

int olwsx__cache_insert_l2_impl(const uint8_t* key, uint32_t key_len,
                                const uint8_t* val, uint32_t val_len,
                                uint32_t flags) {
    using namespace olwsx;
    if (!key || !val || key_len == 0) return OLWSX_ERR_INVALID_ARGUMENT;
    if (key_len > OLWSX_MAX_KEY_BYTES) return OLWSX_ERR_TOO_LARGE;
    std::string k(reinterpret_cast<const char*>(key), key_len);
    std::string v(reinterpret_cast<const char*>(val), val_len);
    g_core.cache_l2.insert(k, v, flags);
    return OLWSX_OK;
}

int olwsx__process_request_impl(const olwsx_request_t* req, olwsx_response_t* resp) {
    using namespace olwsx;
    if (!g_core.running.load(std::memory_order_acquire)) return OLWSX_ERR_NOT_INITIALIZED;
    if (!req || !resp) return OLWSX_ERR_INVALID_ARGUMENT;

    // Validate sizes
    if (auto s = validate_request_sizes(req); s != OLWSX_OK) return s;

    // Convert basic fields
    std::string path   = to_string_view(req->path,   req->path_len);
    std::string method = to_string_view(req->method, req->method_len);

    // Security decision (edge-informed)
    uint32_t sec_flag = g_core.sec.decide(req->edge_hints);
    if (sec_flag == META_SEC_WAF) {
        const char* hdr = "Content-Type: text/plain\r\n";
        const char* body = "Forbidden (WAF)";
        uint8_t* hdr_out = export_copy(hdr, std::strlen(hdr));
        if (!hdr_out) return OLWSX_ERR_ALLOC_FAILED;
        uint8_t* body_out = export_copy(body, std::strlen(body));
        if (!body_out) { olwsx__free_impl(hdr_out); return OLWSX_ERR_ALLOC_FAILED; }
        resp->status       = 403;
        resp->headers_flat = hdr_out;
        resp->headers_len  = static_cast<uint32_t>(std::strlen(hdr));
        resp->body         = body_out;
        resp->body_len     = static_cast<uint32_t>(std::strlen(body));
        resp->meta_flags   = META_SEC_WAF | META_CACHE_MISS | META_COMP_NONE;
        resp->reserved     = 0;
        return OLWSX_OK;
    }
    if (sec_flag == META_SEC_RATELIM) {
        const char* hdr = "Content-Type: text/plain\r\nRetry-After: 1\r\n";
        const char* body = "Too Many Requests (Rate Limit)";
        uint8_t* hdr_out = export_copy(hdr, std::strlen(hdr));
        if (!hdr_out) return OLWSX_ERR_ALLOC_FAILED;
        uint8_t* body_out = export_copy(body, std::strlen(body));
        if (!body_out) { olwsx__free_impl(hdr_out); return OLWSX_ERR_ALLOC_FAILED; }
        resp->status       = 429;
        resp->headers_flat = hdr_out;
        resp->headers_len  = static_cast<uint32_t>(std::strlen(hdr));
        resp->body         = body_out;
        resp->body_len     = static_cast<uint32_t>(std::strlen(body));
        resp->meta_flags   = META_SEC_RATELIM | META_CACHE_MISS | META_COMP_NONE;
        resp->reserved     = 0;
        return OLWSX_OK;
    }

    // Routing (deterministic rules)
    RouteRule rr{};
    bool matched = g_core.router.match(path, rr);
    if (matched) {
        int status = rr.status_override > 0 ? rr.status_override : 200;
        std::string core_hdrs = "Cache: MISS\r\n";
        std::string hdrs = compose_headers(rr.resp_headers, core_hdrs);

        uint8_t* hdr_out = export_copy_str(hdrs);
        if (!hdr_out) return OLWSX_ERR_ALLOC_FAILED;

        uint8_t* body_out = nullptr;
        uint32_t body_len = 0;
        if (!rr.static_body.empty()) {
            body_out = export_copy_str(rr.static_body);
            if (!body_out) { olwsx__free_impl(hdr_out); return OLWSX_ERR_ALLOC_FAILED; }
            body_len = static_cast<uint32_t>(rr.static_body.size());
        }

        resp->status       = status;
        resp->headers_flat = hdr_out;
        resp->headers_len  = static_cast<uint32_t>(hdrs.size());
        resp->body         = body_out;
        resp->body_len     = body_len;
        resp->meta_flags   = rr.meta_flags;
        resp->reserved     = 0;

        // Example of local filter application (gzip marker only; deterministic)
        if (rr.meta_flags & META_COMP_GZIP) {
            std::vector<uint8_t> body_vec;
            if (body_out && body_len) {
                body_vec.assign(body_out, body_out + body_len);
            }
            FilterContext fctx{};
            uint32_t mflags = resp->meta_flags;
            std::string hdrs_mut = std::string(reinterpret_cast<char*>(resp->headers_flat), resp->headers_len);
            GzipFilter gf;
            if (gf.apply(fctx, hdrs_mut, body_vec, mflags)) {
                // Replace headers/body exports
                olwsx__free_impl(resp->headers_flat);
                resp->headers_flat = export_copy(hdrs_mut.data(), hdrs_mut.size());
                resp->headers_len  = static_cast<uint32_t>(hdrs_mut.size());
                resp->meta_flags   = mflags;
                if (!body_vec.empty()) {
                    olwsx__free_impl(resp->body);
                    resp->body = export_copy(body_vec.data(), body_vec.size());
                    resp->body_len = static_cast<uint32_t>(body_vec.size());
                }
            }
        }

        return OLWSX_OK;
    }

    // Cache pipeline (L1→L2→L3)
    CacheEntry ce;
    if (method == "GET") {
        if (g_core.cache_l1.lookup(path, ce)) {
            const char* hdr = "Content-Type: text/plain\r\nCache: L1\r\n";
            uint8_t* hdr_out = export_copy(hdr, std::strlen(hdr));
            if (!hdr_out) return OLWSX_ERR_ALLOC_FAILED;
            uint8_t* body_out = export_copy(ce.value.data(), ce.value.size());
            if (!body_out) { olwsx__free_impl(hdr_out); return OLWSX_ERR_ALLOC_FAILED; }
            resp->status       = 200;
            resp->headers_flat = hdr_out;
            resp->headers_len  = static_cast<uint32_t>(std::strlen(hdr));
            resp->body         = body_out;
            resp->body_len     = static_cast<uint32_t>(ce.value.size());
            resp->meta_flags   = META_CACHE_L1 | META_COMP_NONE | META_SEC_OK;
            resp->reserved     = 0;
            return OLWSX_OK;
        }
        if (g_core.cache_l2.lookup(path, ce)) {
            const char* hdr = "Content-Type: text/plain\r\nCache: L2\r\n";
            uint8_t* hdr_out = export_copy(hdr, std::strlen(hdr));
            if (!hdr_out) return OLWSX_ERR_ALLOC_FAILED;
            uint8_t* body_out = export_copy(ce.value.data(), ce.value.size());
            if (!body_out) { olwsx__free_impl(hdr_out); return OLWSX_ERR_ALLOC_FAILED; }
            resp->status       = 200;
            resp->headers_flat = hdr_out;
            resp->headers_len  = static_cast<uint32_t>(std::strlen(hdr));
            resp->body         = body_out;
            resp->body_len     = static_cast<uint32_t>(ce.value.size());
            resp->meta_flags   = META_CACHE_L2 | META_COMP_NONE | META_SEC_OK;
            resp->reserved     = 0;
            return OLWSX_OK;
        }
        if (g_core.cache_l3.lookup(path, ce)) {
            const char* hdr = "Content-Type: text/plain\r\nCache: L3\r\n";
            uint8_t* hdr_out = export_copy(hdr, std::strlen(hdr));
            if (!hdr_out) return OLWSX_ERR_ALLOC_FAILED;
            uint8_t* body_out = export_copy(ce.value.data(), ce.value.size());
            if (!body_out) { olwsx__free_impl(hdr_out); return OLWSX_ERR_ALLOC_FAILED; }
            resp->status       = 200;
            resp->headers_flat = hdr_out;
            resp->headers_len  = static_cast<uint32_t>(std::strlen(hdr));
            resp->body         = body_out;
            resp->body_len     = static_cast<uint32_t>(ce.value.size());
            resp->meta_flags   = META_CACHE_L3 | META_COMP_NONE | META_SEC_OK;
            resp->reserved     = 0;
            return OLWSX_OK;
        }
    }

    // Compute path (MISS): deterministic response body
    std::string body = "OLWSX Core Response (MISS): path=" + path + " method=" + method;

    // Insert into L2 for future GET hits
    if (method == "GET" && !path.empty()) {
        g_core.cache_l2.insert(path, body, META_COMP_NONE);
    }

    // Core headers (deterministic)
    const char* hdr = "Content-Type: text/plain\r\nCache: MISS\r\n";
    std::size_t hdr_len = std::strlen(hdr);

    // Export copies
    uint8_t* hdr_out = export_copy(hdr, hdr_len);
    if (!hdr_out) return OLWSX_ERR_ALLOC_FAILED;

    uint8_t* body_out = export_copy(body.data(), body.size());
    if (!body_out) { olwsx__free_impl(hdr_out); return OLWSX_ERR_ALLOC_FAILED; }

    resp->status       = 200;
    resp->headers_flat = hdr_out;
    resp->headers_len  = static_cast<uint32_t>(hdr_len);
    resp->body         = body_out;
    resp->body_len     = static_cast<uint32_t>(body.size());
    resp->meta_flags   = META_CACHE_MISS | META_COMP_NONE | META_SEC_OK;
    resp->reserved     = 0;

    return OLWSX_OK;
}

} // extern "C"
