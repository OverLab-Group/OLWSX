// ============================================================================
// OLWSX - OverLab Web ServerX
// File: core/memory/arena.cpp
// Role: Per-call transient arena (final, frozen)
// ----------------------------------------------------------------------------
// Simple thread-safe bump arena for short-lived allocations within a request.
// Resettable between batches.
// ============================================================================

#include <vector>
#include <mutex>
#include <cstddef>
#include <cstdint>

namespace olwsx {

class Arena {
public:
    explicit Arena(std::size_t bytes)
        : buffer_(bytes), offset_(0) {}

    void* allocate(std::size_t bytes, std::size_t align) {
        std::lock_guard<std::mutex> lock(mu_);
        std::size_t base = reinterpret_cast<std::size_t>(buffer_.data());
        std::size_t ptr  = base + offset_;
        std::size_t aligned = ((ptr + align - 1) / align) * align;
        std::size_t delta   = aligned - base;
        if (delta + bytes > buffer_.size()) return nullptr;
        offset_ = delta + bytes;
        return buffer_.data() + delta;
    }

    void reset() {
        std::lock_guard<std::mutex> lock(mu_);
        offset_ = 0;
    }

    std::size_t capacity() const { return buffer_.size(); }
    std::size_t used() const { return offset_; }

private:
    std::vector<uint8_t> buffer_;
    std::size_t offset_;
    std::mutex mu_;
};

} // namespace olwsx