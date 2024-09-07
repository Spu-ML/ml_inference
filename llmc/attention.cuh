/*
Attention, as a fallback when we do not use the Flash Attention from cuDNN
*/
#include <assert.h>
// llmc internal imports
#include "cuda_common.h"
#include "cuda_utils.cuh"
#include "cublas_common.h"

// ----------------------------------------------------------------------------
// CUDA kernels

// inputs floatX, outputs FP32 (for current FP32-only activation path for this WIP)
__global__ void permute_kernel(floatX* q, floatX* k, floatX* v,
                               tensorX inp,
                               int B, int N, int NH, int d) {
    // okay so now, this kernel wants Q,K,V to all be of shape (B, NH, N, d)
    // but instead, we have a single tensor QKV (inp) of shape (B, N, 3, NH, d)
    int idx = (blockIdx.x * blockDim.x + threadIdx.x) * inp.num_per_128();
    if (idx >= B * NH * N * d) { return; }

    // Q[b][nh_][n][d_] = inp[b][n][0][nh_][d_]
    int b = idx / (NH * N * d);
    int rest = idx % (NH * N * d);
    int nh_ = rest / (N * d);
    rest = rest % (N * d);
    int n = rest / d;
    int d_ = rest % d;
    int inp_idx = (b * N * 3 * NH * d) + (n * 3 * NH * d) + (0 * NH * d) + (nh_ * d) + d_;

    auto inp128_q = load_tensor128(inp, inp_idx, true);
    auto inp128_k = load_tensor128(inp, inp_idx + NH * d, true);
    auto inp128_v = load_tensor128(inp, inp_idx + 2 * (NH * d), true);
    for (int i = 0; i < inp.num_per_128(); i++) {
        q[idx+i] = inp128_q.get(i);
        k[idx+i] = inp128_k.get(i);
        v[idx+i] = inp128_v.get(i);
    }
}

__global__ void permute_kernel_backward(tensorX dinp,
                                        const floatX* dq, const floatX* dk, const floatX* dv,
                                        int B, int N, int NH, int d) {
    int idx = (blockIdx.x * blockDim.x + threadIdx.x) * dinp.num_per_128();
    if (idx >= B * NH * N * d) { return; }

    int b = idx / (NH * N * d);
    int rest = idx % (NH * N * d);
    int nh_ = rest / (N * d);
    rest = rest % (N * d);
    int n = rest / d;
    int d_ = rest % d;

    int inp_idx = (b * N * 3 * NH * d) + (n * 3 * NH * d) + (0 * NH * d) + (nh_ * d) + d_;
    dinp[inp_idx] = dq[idx];
    dinp[inp_idx + NH * d] = dk[idx];
    dinp[inp_idx + 2 * (NH * d)] = dv[idx];

    auto dinp128_q = new_tensor128(dinp);
    auto dinp128_k = new_tensor128(dinp);
    auto dinp128_v = new_tensor128(dinp);
    for (int i = 0; i < dinp.num_per_128(); i++) {
        dinp128_q.set(i, dq[idx+i]);
        dinp128_k.set(i, dk[idx+i]);
        dinp128_v.set(i, dv[idx+i]);
        // to allow us to update the absmax only once
        dinp128_k.add_value_stats(dk[idx+i], dinp128_k.get128()[i]);
        dinp128_v.add_value_stats(dv[idx+i], dinp128_v.get128()[i]);
    }
    dinp128_q.store(inp_idx);
    dinp128_k.store(inp_idx + NH * d);
    dinp128_v.store(inp_idx + 2 * (NH * d));
    dinp128_q.update_absmax(threadIdx.x, blockDim.x, true);
}

__global__ void unpermute_kernel(tensorX out, floatX* inp, int B, int N, int NH, int d) {
   // out has shape (B, nh, N, d) but we need to unpermute it to (B, N, nh, d)

    int idx = (blockIdx.x * blockDim.x + threadIdx.x) * out.num_per_128();
    // out[b][n][nh_][d_] <- inp[b][nh_][n][d_]
    if (idx >= B * NH * N * d) { return; }

    int b = idx / (NH * N * d);
    int rest = idx % (NH * N * d);
    int nh_ = rest / (N * d);
    rest = rest % (N * d);
    int n = rest / d;
    int d_ = rest % d;
    int other_idx = (b * NH * N * d) + (n * NH * d) + (nh_ * d) + d_;
    auto out128 = new_tensor128(out);
    for (int i = 0; i < out.num_per_128(); i++) {
        out128.set(i, __ldcs(&inp[idx + i]));
    }
    out128.store(other_idx);
    out128.update_absmax(threadIdx.x, blockDim.x, true);
}

__global__ void unpermute_kernel_backward(floatX* dout_permuted, tensorX dout, int B, int N, int NH, int d) {
    int idx = (blockIdx.x * blockDim.x + threadIdx.x) * dout.num_per_128();
    if (idx >= B * NH * N * d) { return; }

    int b = idx / (NH * N * d);
    int rest = idx % (NH * N * d);
    int nh_ = rest / (N * d);
    rest = rest % (N * d);
    int n = rest / d;
    int d_ = rest % d;
    int other_idx = (b * NH * N * d) + (n * NH * d) + (nh_ * d) + d_;
    auto dout128 = load_tensor128(dout, other_idx);
    for (int k = 0; k < dout128.elements; k++) {
        dout_permuted[idx+k] = (floatX)dout128.get(k);
    }
}

__global__ void softmax_forward_kernel5(floatX* out, float inv_temperature, floatX* inp, int N, int T) {
    // inp, out shape: (N, T, T), where N = B * NH
    // fuses the multiplication by scale inside attention
    // directly autoregressive, so we only compute the lower triangular part
    // uses the online softmax algorithm
    assert(T % 4  == 0);
    int lane_id = threadIdx.x % WARP_SIZE;
    int warp_id = threadIdx.x / WARP_SIZE;
    int num_warps = blockDim.x / WARP_SIZE;

    // micro-optimization: we iterate backwards so that
    // after the softmax backward operation completes, the cache retains the
    // part of the matrix close to the upper left corner, which benefits the
    // matmul operation that immediately follows.
    // int idx = blockIdx.x * warp.meta_group_size() + warp.meta_group_rank(); // forward order
    int idx = (gridDim.x - blockIdx.x - 1) * num_warps + warp_id; // backward order
    if(idx >= N * T) {
        return;
    }
    int own_pos = idx % T;
    int pos_by_4 = own_pos / 4;

    // one row of inp, i.e. inp[idx, :] of shape (T,)
    const floatX* x = inp + idx * T;

    // not INF, so we don't get NaNs accidentally when subtracting two values.
    const float flt_max = 340282346638528859811704183484516925440.0f; // to avoid including float.h
    float maxval = -flt_max;
    float sumval = 0.0f;

    const floatX* x_aligned = reinterpret_cast<const floatX*>(__builtin_assume_aligned(x, 16));
    for (int i = lane_id; i < pos_by_4; i += WARP_SIZE) {
        float regarray[4];
        for (int k = 0; k < 4; ++k) {
            regarray[k] = (float)x_aligned[4*i + k];
        }
        float old_maxval = maxval;
        for(int k = 0; k < 4; ++k) {
            maxval = fmaxf(maxval, regarray[k]);
        }
        sumval *= expf(inv_temperature * (old_maxval - maxval));
        for(int k = 0; k < 4; ++k) {
            sumval += expf(inv_temperature * (regarray[k] - maxval));
        }
    }

    if(4*pos_by_4 + lane_id <= own_pos) {
        float old_maxval = maxval;
        maxval = fmaxf(maxval, (float)x[4*pos_by_4 + lane_id]);
        sumval *= expf(inv_temperature * (old_maxval - maxval));
        sumval += expf(inv_temperature * ((float)x[4*pos_by_4 + lane_id] - maxval));
    }

    float global_maxval = warpReduceMax(maxval);
    sumval *= expf(inv_temperature * (maxval - global_maxval));

    float sum = warpReduceSum(sumval);
    float norm = 1.f / sum;

    // divide the whole row by the sum
    for (int i = lane_id; i <= own_pos; i += WARP_SIZE) {
        // recalculation is faster than doing the round-trip through memory.
        float ev = expf(inv_temperature * ((float)__ldcs(x + i) - global_maxval));
        __stcs(out + idx * T + i, (floatX)(ev * norm));
    }
}

__global__ void softmax_autoregressive_backward_inplace_kernel(floatX* datt, floatX* att,
                                                               int B, int T, int C, float scale) {
    constexpr const int BlockSize = 256;
    constexpr int T_per_block = 4;

    // go through blocks in reverse order, so the slowest block starts first
    int t0 = T - 1 - T_per_block*blockIdx.x;
    int idx = blockIdx.y;

    att += idx * T * T;
    datt += idx * T * T;

    for(int to = 0; to < T_per_block; ++to) {
        int t = t0 - to;
        if(t < 0) return;
        const floatX* att_bth = att + t * T;
        const floatX* datt_bth = datt + t * T;
        floatX* dpreatt_bth = datt + t * T;

        float local_sum = 0;
        for (int t2 = threadIdx.x; t2 <= t; t2 += BlockSize) {
            local_sum += (float)att_bth[t2] * (float)datt_bth[t2];
        }

        local_sum = blockReduce<warpReduceSum>(local_sum);

        for (int t3 = threadIdx.x; t3 < T; t3 += BlockSize) {
            // don't touch the cache. Some parts will still be here from the previous loop, and
            // we want to exploit those.
            if(t3 <= t) {
                float acc = (float) __ldcs(att_bth + t3) * ((float) __ldcs(datt_bth + t3) - local_sum);
                __stcs(dpreatt_bth + t3, (floatX) (scale * acc));
            } else {
                // explicitly set non-causal elements to zero
                __stcs(dpreatt_bth + t3, (floatX)0.f);
            }
        }
    }
}

// ----------------------------------------------------------------------------
// kernel launchers

void attention_forward(tensorX out, floatX* qkvr, floatX* att,
                       tensorX inp,
                       int B, int T, int C, int NH, cudaStream_t stream=main_stream) {
    NVTX_RANGE_FN();
    // Note: `inp` is not needed for backward pass, so we re-use it as a scratch buffer.
    // Its contents will be overwritten by this function.
    const int block_size = 256;

    // inp is (B, T, 3C) QKV
    // preatt, att are (B, NH, T, T)
    // output is (B, T, C)
    const int HS = C / NH; // head size

    // permute and separate inp from (B, T, 3, NH, HS) to 3X (B, NH, T, HS)
    floatX *q, *k, *v;
    q = qkvr + 0 * B * T * C;
    k = qkvr + 1 * B * T * C;
    v = qkvr + 2 * B * T * C;
    int total_threads = B * NH * T * HS;
    int num_blocks = CEIL_DIV(total_threads, block_size * inp.num_per_128());
    permute_kernel<<<num_blocks, block_size, 0, stream>>>(q, k, v, inp, B, T, NH, HS);

    floatX* preatt = inp; // reuse inp as scratch buffer
    matmul_cublaslt(tensorX::from(preatt), tensorX::from(k), tensorX::from(q), nullptr, T, T, HS, stream, true, false, B * NH, T * HS, T * HS, T * T);

    // multiply all elements of preatt elementwise by scale
    float scale = 1.f / sqrtf(HS);
    int grid_size = CEIL_DIV(B * NH * T * WARP_SIZE, block_size);
    softmax_forward_kernel5<<<grid_size, block_size, 0, stream>>>(att, scale, preatt, B * NH, T);

    // new approach: first cuBLAS another batched matmul
    floatX* vaccum = inp;
    // y = att @ v # (B, nh, T, T) @ (B, nh, T, hs) -> (B, nh, T, hs)
    matmul_cublaslt(tensorX::from(vaccum), tensorX::from(v), tensorX::from(att), nullptr, HS, T, T, stream, false, false, B * NH, T * HS, T * T, T * HS);

    // now unpermute
    // y = y.transpose(1, 2).contiguous().view(B, T, C) # re-assemble all head outputs side by side
    num_blocks = CEIL_DIV(B * T * C, block_size * out.num_per_128());
    unpermute_kernel<<<num_blocks, block_size, 0, stream>>>(out, vaccum, B, T, NH, HS);
    cudaCheck(cudaGetLastError());
}

// the sequence of transformations in this compound op is:
// inp (B,T,3C) -> qkvr (B,T,3C) -> preatt (B,NH,T,T) -> att (B,NH,T,T) -> vaccum (B,T,C) -> out (B,T,C)
void attention_backward(tensorX dinp, floatX* dqkvr, floatX* datt, floatX* scratch,
                        tensorX dout, tensorX qkvr, floatX* att,
                        int B, int T, int C, int NH, cudaStream_t stream=main_stream) {
    NVTX_RANGE_FN();
    const int block_size = 256;
    const int HS = C / NH; // head size

    // unpack convenience pointers into q, k, v
    floatX *q, *k, *v;
    q = qkvr + 0 * B * T * C;
    k = qkvr + 1 * B * T * C;
    v = qkvr + 2 * B * T * C;
    floatX *dq, *dk, *dv;
    dq = dqkvr + 0 * B * T * C;
    dk = dqkvr + 1 * B * T * C;
    dv = dqkvr + 2 * B * T * C;

    // backward through the unpermute operation
    int num_blocks = CEIL_DIV(B * T * C, block_size * dout.num_per_128());
    unpermute_kernel_backward<<<num_blocks, block_size, 0, stream>>>(scratch, dout, B, T, NH, HS);
    // backward into datt
    matmul_cublaslt(tensorX::from(datt), tensorX::from(v), tensorX::from(scratch), nullptr, T, T, HS, stream, true, false, B * NH, T * HS, T * HS, T * T);
    // backward into dv
    matmul_cublaslt(tensorX::from(dv), tensorX::from(scratch), tensorX::from(att), nullptr, HS, T, T, stream, false, true, B * NH, T * HS, T * T, T * HS);
    const float scale = 1.0f / sqrtf((float)HS);
    // backward into preatt. this is an in-place operation; datt turns into dpreatt here
    softmax_autoregressive_backward_inplace_kernel<<<dim3(T / 4, B * NH), 256>>>(datt, att, B, T, C, scale);
    floatX* dpreatt = datt;
    // backward into q
    matmul_cublaslt(tensorX::from(dq), tensorX::from(k), tensorX::from(dpreatt), nullptr, HS, T, T, stream, false, false, B * NH, T * HS, T * T, T * HS);
    // backward into k
    matmul_cublaslt(tensorX::from(dk), tensorX::from(q), tensorX::from(dpreatt), nullptr, HS, T, T, stream, false, true, B * NH, T * HS, T * T, T * HS);
    // backward into inp
    num_blocks = CEIL_DIV(B * NH * T * HS, block_size * dinp.num_per_128());
    permute_kernel_backward<<<num_blocks, block_size, 0, stream>>>(dinp, dq, dk, dv, B, T, NH, HS);
    cudaCheck(cudaGetLastError());
}
