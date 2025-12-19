// ============================================================================
// OLWSX - OverLab Web ServerX
// File: core/filters/gzip_filter.cpp
// Role: Gzip marker filter (final, frozen)
// ----------------------------------------------------------------------------
// NOTE: To maintain full self-containment and avoid external deps, this filter
// does NOT perform actual compression. It sets a deterministic header and
// meta flag indicating "gzip" would be applied by outer layers if present.
// This keeps core behavior stable and predictable within this module.
// ============================================================================

#include "filter_base.cpp"

namespace olwsx {

// Meta flags (mirror core/main.cpp definitions)
static constexpr uint32_t META_COMP_NONE   = 0x00000000u;
static constexpr uint32_t META_COMP_GZIP   = 0x00000001u;

class GzipFilter final : public Filter {
public:
    bool apply(const FilterContext&,
               std::string& headers_flat,
               std::vector<uint8_t>& body,
               uint32_t& meta_flags) override {
        // Idempotent header append (simple check to avoid duplicates)
        const char* hdr = "Content-Encoding: gzip\r\n";
        if (headers_flat.find("Content-Encoding: gzip") == std::string::npos) {
            headers_flat += hdr;
        }
        meta_flags |= META_COMP_GZIP;
        // No change to body for core determinism.
        (void)body;
        return true;
    }
};

} // namespace olwsx