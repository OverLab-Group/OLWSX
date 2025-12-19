// ============================================================================
// OLWSX - OverLab Web ServerX
// File: core/memory/allocator.cpp
// Role: Export pool allocator (final, frozen)
// ----------------------------------------------------------------------------
// Provides aligned allocation/free for exported response buffers owned
// by the core but freed by callers via olwsx_free().
// ============================================================================

#include <cstdlib>
#include <cstddef>
#include <cstdint>

namespace olwsx {

static constexpr std::size_t kPtrAlign = alignof(void*);

struct ExportPool {
    static uint8_t* alloc(std::size_t bytes, std::size_t align = 1) {
        void* p = nullptr;
        if (align <= kPtrAlign) {
            p = std::malloc(bytes);
        } else {
        #if defined(_MSC_VER)
            p = _aligned_malloc(bytes, align);
        #else
            if (posix_memalign(&p, align, bytes) != 0) p = nullptr;
        #endif
        }
        return reinterpret_cast<uint8_t*>(p);
    }

    static void free(uint8_t* p) {
        if (!p) return;
        #if defined(_MSC_VER)
            _aligned_free(p);
        #else
            std::free(p);
        #endif
    }
};

} // namespace olwsx