// ============================================================================
// OLWSX - OverLab Web ServerX
// File: core/routing/matcher.cpp
// Role: Deterministic prefix matcher (final, frozen)
// ----------------------------------------------------------------------------
// Provides prefix-based routing decisions.
// ============================================================================

#include <string>
#include <vector>
#include <cstdint>

namespace olwsx {

struct RouteRule {
    std::string match_prefix;   // prefix match (deterministic order)
    int         status_override; // optional fixed status (e.g., 301/200)
    std::string static_body;    // optional static body
    std::string resp_headers;   // "Key:Value\r\n..." appended before core headers
    uint32_t    meta_flags;     // compression/cache/security hints
};

class Matcher {
public:
    static bool match_prefix(const std::string& path,
                             const std::vector<RouteRule>& rules,
                             RouteRule& out) {
        for (const auto& r : rules) {
            if (!r.match_prefix.empty() &&
                path.compare(0, r.match_prefix.size(), r.match_prefix) == 0) {
                out = r;
                return true;
            }
        }
        return false;
    }
};

} // namespace olwsx
