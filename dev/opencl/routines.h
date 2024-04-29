#include "common.h"

void cl_matmul_forward(GPT2_CL *gcl, float* out,
                    float* inp, float* weight, float* bias,
                    int B, int T, int C, int OC) {
    // inp is (B,T,C), weight is (OC, C), bias is (OC)
    // out will be (B,T,OC)
    cl_int err = 0;

    err = clEnqueueWriteBuffer(gcl->queue, gcl->matmul_A, CL_TRUE, 0, sizeof(float) * B * T * C, inp, 0, NULL, NULL);
    err |= clEnqueueWriteBuffer(gcl->queue, gcl->matmul_B, CL_TRUE, 0, sizeof(float) * OC * C, weight, 0, NULL, NULL);
    if(bias != NULL) {
        err |= clEnqueueWriteBuffer(gcl->queue, gcl->matmul_bias, CL_TRUE, 0, sizeof(float) * OC, bias, 0, NULL, NULL);
    }
    if (err != CL_SUCCESS)
    {
        printf("error: failed to write to source array!\n");
        exit(1);
    }

    cl_int use_bias = bias != NULL;
    err = clSetKernelArg(gcl->matmul_forward, 4, sizeof(int), &B);
    err |= clSetKernelArg(gcl->matmul_forward, 5, sizeof(int), &T);
    err |= clSetKernelArg(gcl->matmul_forward, 6, sizeof(int), &C);
    err |= clSetKernelArg(gcl->matmul_forward, 7, sizeof(int), &OC);
    err |= clSetKernelArg(gcl->matmul_forward, 8, sizeof(cl_int), &use_bias);
    if (err != CL_SUCCESS)
    {
        printf("error: failed to set kernel arguments! %d\n", err);
        exit(1);
    }

    size_t tile_size = MATMUL_TILE_SIZE;
    size_t bt_round = (((B * T) + tile_size - 1) / tile_size) * tile_size;
    size_t oc_round = ((OC + tile_size - 1) / tile_size) * tile_size;
    size_t size_global[2] = {bt_round, oc_round};
    size_t size_local[2] = {tile_size, tile_size};
    err = clEnqueueNDRangeKernel(gcl->queue, gcl->matmul_forward, 2, NULL, size_global, size_local, 0, NULL, NULL);
    if (err != CL_SUCCESS)
    {
        printf("error: failed to execute kernel! %d\n", err);
        exit(1);
    }
    clFinish(gcl->queue);

    err = clEnqueueReadBuffer(gcl->queue, gcl->matmul_out, CL_TRUE, 0, sizeof(float) * B * T * OC, out, 0, NULL, NULL );
    if (err != CL_SUCCESS)
    {
        printf("error: failed to read output array! %d\n", err);
        exit(1);
    }
}

void cl_matmul_backward(GPT2_CL *gcl, float* dinp, float* dweight, float* dbias,
                     float* dout, float* inp, float* weight,
                     int B, int T, int C, int OC) {
    // dout is (B,T,OC), weight is (OC, C)
    // dinp will be (B,T,C)
    // dinp = dout * weight

    #pragma omp parallel for collapse(2)
    for (int b = 0; b < B; b++) {
        for (int t = 0; t < T; t++) {
            float* dout_bt = dout + b * T * OC + t * OC;
            float* dinp_bt = dinp + b * T * C + t * C;
            for (int o = 0; o < OC; o++) {
                float* wrow = weight + o*C;
                float d = dout_bt[o];
                for (int i = 0; i < C; i++) {
                    dinp_bt[i] += wrow[i] * d;
                }
            }
        }
    }

    // inp is (B,T,C), dout is (B,T,OC)
    // dweight will be (OC,C), dbias will be (OC)
    // dweight = dout^T * inp
    #pragma omp parallel for
    for (int o = 0; o < OC; o++) {
        for (int b = 0; b < B; b++) {
            for (int t = 0; t < T; t++) {
                float* dout_bt = dout + b * T * OC + t * OC;
                float* inp_bt = inp + b * T * C + t * C;
                float* dwrow = dweight + o*C;
                float d = dout_bt[o];
                if (dbias != NULL) { dbias[o] += d; }
                for (int i = 0; i < C; i++) {
                    dwrow[i] += inp_bt[i] * d;
                }
            }
        }
    }
}
