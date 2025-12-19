// ============================================================================
// OLWSX - OverLab Web ServerX
// File: core/filters/filter_base.cpp
// Role: Filter base interface (final, frozen)
// ----------------------------------------------------------------------------
// Provides a minimal interface for response filters. Implementations must be
// deterministic and non-blocking in the hot path.
// ============================================================================

#include <string>
#include <cstdint>
#include <vector>

namespace olwsx {

struct FilterContext {
    // Reserved for future immutable fields; kept for ABI-neutrality within core.
    uint32_t reserved{0};
};

class Filter {
public:
    virtual ~Filter() = default;
    // Process headers (flat "k:v\r\n") and body (binary). Return false on failure.
    virtual bool apply(const FilterContext&,
                       std::string& headers_flat,
                       std::vector<uint8_t>& body,
                       uint32_t& meta_flags) = 0;
};

} // namespace olwsx