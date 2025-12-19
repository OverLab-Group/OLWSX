// ============================================================================
// OLWSX - OverLab Web ServerX
// File: gpu/kernels.cu
// Role: Final CUDA kernels (deterministic transforms and reductions)
// ----------------------------------------------------------------------------
// Note: Designed to compile as a standalone CUDA object. Interfaces are frozen.
// ============================================================================

extern "C" {

__global__ void xor_transform(uint8_t* data, int n, uint8_t key) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        data[i] ^= key;
    }
}

__global__ void reduce_sum(const uint8_t* data, int n, double* out_sum) {
    __shared__ double sdata[256];
    int tid = threadIdx.x;
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    double val = (i < n) ? (double)data[i] : 0.0;
    sdata[tid] = val;
    __syncthreads();
    // naive reduction
    for (int stride = blockDim.x / 2; stride > 0; stride >>= 1) {
        if (tid < stride) sdata[tid] += sdata[tid + stride];
        __syncthreads();
    }
    if (tid == 0) atomicAdd(out_sum, sdata[0]);
}

} // extern "C"