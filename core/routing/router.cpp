// ============================================================================
// OLWSX - OverLab Web ServerX
// File: core/routing/router.cpp
// Role: Router with deterministic rule set (final, frozen)
// ----------------------------------------------------------------------------
// Maintains an ordered set of routing rules. Thread-safe reads.
// ============================================================================

#include <vector>
#include <mutex>
#include <shared_mutex>
#include "matcher.cpp"

namespace olwsx {

class Router {
public:
    void set_rules(const std::vector<RouteRule>& rules) {
        std::unique_lock<std::shared_mutex> lock(mu_);
        rules_ = rules; // preserve order
    }

    bool match(const std::string& path, RouteRule& out) const {
        std::shared_lock<std::shared_mutex> lock(mu_);
        return Matcher::match_prefix(path, rules_, out);
    }

private:
    mutable std::shared_mutex mu_;
    std::vector<RouteRule> rules_;
};

} // namespace olwsx
