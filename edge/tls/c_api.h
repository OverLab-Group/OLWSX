// ============================================================================
// OLWSX - OverLab Web ServerX
// File: core/abi/c_api.h
// Role: Final & Stable C ABI (frozen)
// Philosophy: One version, the most stable version, first and last.
// ----------------------------------------------------------------------------
// This header defines the stable C ABI for OLWSX Core.
// Layouts and enums are frozen forever.
// ============================================================================

#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Status/result codes (frozen)
typedef enum {
    OLWSX_OK                    = 0,
    OLWSX_ERR_GENERAL           = 1,
    OLWSX_ERR_NOT_INITIALIZED   = 2,
    OLWSX_ERR_INVALID_ARGUMENT  = 3,
    OLWSX_ERR_TOO_LARGE         = 4,
    OLWSX_ERR_ALLOC_FAILED      = 5,
    OLWSX_ERR_NOT_FOUND         = 6,
    OLWSX_ERR_UNSUPPORTED       = 7,
    OLWSX_ERR_BUSY              = 8
} olwsx_status_t;

// Core state descriptor (frozen layout)
typedef struct {
    uint64_t epoch_ns;
    uint32_t flags;
    uint32_t reserved;
    uint32_t v_major;
    uint32_t v_minor;
    uint32_t v_patch;
} olwsx_core_state_t;

// Canonical request (zero-copy friendly)
typedef struct {
    const uint8_t* path;
    uint32_t       path_len;

    const uint8_t* method;
    uint32_t       method_len;

    const uint8_t* headers_flat;   // "key:value\r\nkey2:value2\r\n"
    uint32_t       headers_len;

    const uint8_t* body;
    uint32_t       body_len;

    // Telemetry
    uint64_t trace_id;
    uint64_t span_id;

    // Edge-informed security/backpressure hints (optional)
    uint32_t edge_hints; // bitfield
    uint32_t reserved;
} olwsx_request_t;

// Canonical response (caller frees buffers via olwsx_free)
typedef struct {
    int32_t    status;
    uint8_t*   headers_flat;
    uint32_t   headers_len;
    uint8_t*   body;
    uint32_t   body_len;

    uint32_t   meta_flags;  // cache/compression/security markers
    uint32_t   reserved;
} olwsx_response_t;

// Config blob (staged/apply; frozen format expectation: canonical schema)
typedef struct {
    const uint8_t* data;      // serialized canonical schema (.wsx compiled)
    uint32_t       len;
    uint32_t       generation; // user-assigned generation tag
} olwsx_config_blob_t;

// Public API (frozen)
void olwsx_core_version(uint32_t* major, uint32_t* minor, uint32_t* patch);
int  olwsx_core_init(olwsx_core_state_t* out_state);
int  olwsx_core_shutdown();
int  olwsx_core_status(uint32_t* flags_out, uint32_t* generation_out);

int  olwsx_arena_reset();
void olwsx_free(void* p);

int  olwsx_stage_config(const olwsx_config_blob_t* blob);
int  olwsx_apply_config(uint32_t generation);

int  olwsx_process_request(const olwsx_request_t* req, olwsx_response_t* resp);

int  olwsx_cache_invalidate_l2(const uint8_t* key, uint32_t key_len);
int  olwsx_cache_insert_l2(const uint8_t* key, uint32_t key_len,
                           const uint8_t* val, uint32_t val_len,
                           uint32_t flags);

#ifdef __cplusplus
}
#endif