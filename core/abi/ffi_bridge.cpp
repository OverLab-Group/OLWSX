// ============================================================================
// OLWSX - OverLab Web ServerX
// File: core/abi/ffi_bridge.cpp
// Role: C ABI implementation bridge (final, frozen)
// ----------------------------------------------------------------------------
// Implements the C ABI declared in c_api.h by delegating to core/main.cpp
// internal facilities. This file exposes only extern "C" functions.
// ============================================================================

#include "c_api.h"

#ifdef __cplusplus
extern "C" {
#endif

// Declarations implemented in core/main.cpp (internal symbols)
int  olwsx__core_version_impl(uint32_t* major, uint32_t* minor, uint32_t* patch);
int  olwsx__core_init_impl(olwsx_core_state_t* out_state);
int  olwsx__core_shutdown_impl();
int  olwsx__core_status_impl(uint32_t* flags_out, uint32_t* generation_out);

int  olwsx__arena_reset_impl();
void olwsx__free_impl(void* p);

int  olwsx__stage_config_impl(const olwsx_config_blob_t* blob);
int  olwsx__apply_config_impl(uint32_t generation);

int  olwsx__process_request_impl(const olwsx_request_t* req, olwsx_response_t* resp);

int  olwsx__cache_invalidate_l2_impl(const uint8_t* key, uint32_t key_len);
int  olwsx__cache_insert_l2_impl(const uint8_t* key, uint32_t key_len,
                                 const uint8_t* val, uint32_t val_len,
                                 uint32_t flags);

// Forwarders (stable C ABI)
void olwsx_core_version(uint32_t* major, uint32_t* minor, uint32_t* patch) {
    (void)olwsx__core_version_impl(major, minor, patch);
}

int  olwsx_core_init(olwsx_core_state_t* out_state) {
    return olwsx__core_init_impl(out_state);
}
int  olwsx_core_shutdown() {
    return olwsx__core_shutdown_impl();
}
int  olwsx_core_status(uint32_t* flags_out, uint32_t* generation_out) {
    return olwsx__core_status_impl(flags_out, generation_out);
}

int  olwsx_arena_reset() {
    return olwsx__arena_reset_impl();
}
void olwsx_free(void* p) {
    olwsx__free_impl(p);
}

int  olwsx_stage_config(const olwsx_config_blob_t* blob) {
    return olwsx__stage_config_impl(blob);
}
int  olwsx_apply_config(uint32_t generation) {
    return olwsx__apply_config_impl(generation);
}

int  olwsx_process_request(const olwsx_request_t* req, olwsx_response_t* resp) {
    return olwsx__process_request_impl(req, resp);
}

int  olwsx_cache_invalidate_l2(const uint8_t* key, uint32_t key_len) {
    return olwsx__cache_invalidate_l2_impl(key, key_len);
}
int  olwsx_cache_insert_l2(const uint8_t* key, uint32_t key_len,
                           const uint8_t* val, uint32_t val_len,
                           uint32_t flags) {
    return olwsx__cache_insert_l2_impl(key, key_len, val, val_len, flags);
}

#ifdef __cplusplus
}
#endif