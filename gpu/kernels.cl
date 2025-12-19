// ============================================================================
// OLWSX - OverLab Web ServerX
// File: gpu/kernels.cl
// Role: Final OpenCL kernels (deterministic transforms and reductions)
// ----------------------------------------------------------------------------
// Interfaces and semantics are frozen.
// ============================================================================

__kernel void xor_transform(__global uchar* data, int n, uchar key) {
    int i = get_global_id(0);
    if (i < n) {
        data[i] ^= key;
    }
}

__kernel void reduce_sum(__global const uchar* data, int n, __global double* out_sum) {
    int i = get_global_id(0);
    double val = (i < n) ? (double)data[i] : 0.0;
    // atomic add for simplicity
    atomic_add((__global long*)out_sum, (long)val);
}