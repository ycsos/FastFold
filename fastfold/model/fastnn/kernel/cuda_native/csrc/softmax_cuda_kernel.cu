#include <c10/cuda/CUDAGuard.h>
#include <math_constants.h>
#include <torch/extension.h>

#include <iostream>

#include "ATen/ATen.h"
#include "ATen/cuda/CUDAContext.h"
#include "compat.h"

#define CHECK_CUDA(x) TORCH_CHECK(x.is_cuda(), #x " must be a CUDA tensor")
#define CHECK_CONTIGUOUS(x) TORCH_CHECK(x.is_contiguous(), #x " must be contiguous")
#define CHECK_INPUT(x) \
    CHECK_CUDA(x);     \
    CHECK_CONTIGUOUS(x)

__inline__ __device__ float WarpAllReduceMax(float val) {
    for (int mask = 1; mask < 32; mask *= 2) {
        val = max(val, __shfl_xor_sync(0xffffffff, val, mask));
    }
    return val;
}

__inline__ __device__ float WarpAllReduceSum(float val) {
    for (int mask = 1; mask < 32; mask *= 2) {
        val += __shfl_xor_sync(0xffffffff, val, mask);
    }
    return val;
}

////////////////

template <typename T>
__global__ void fastfold_softmax(T *input, T *output, long long rows, long long cols) {
    int threadidx_x = threadIdx.x / 32;
    int threadidx_y = threadIdx.x % 32;
    long long row_offset = (long long)blockIdx.x * 4 + threadidx_x;
    int cols_per_thread = (cols + 31) / 32;
    int cols_this_thread = cols_per_thread;

    int last_y = (cols / cols_per_thread);

    if (threadidx_y == last_y) {
        cols_this_thread = cols - cols_per_thread * last_y;
    } else if (threadidx_y > last_y) {
        cols_this_thread = 0;
    }

    float buf[32];

    int lane_id = threadidx_y;

    if (row_offset < rows) {
        T *row_input = input + row_offset * cols;
        T *row_output = output + row_offset * cols;

        float thread_max = -1 * CUDART_INF_F;

#pragma unroll
        for (int i = 0; i < cols_this_thread; i++) {
            buf[i] = static_cast<float>(row_input[lane_id * cols_per_thread + i]);
        }

#pragma unroll
        for (int i = 0; i < cols_this_thread; i++) {
            thread_max = max(thread_max, buf[i]);
        }

        float warp_max = WarpAllReduceMax(thread_max);

        float thread_sum = 0.f;
#pragma unroll
        for (int i = 0; i < cols_this_thread; ++i) {
            buf[i] = __expf(buf[i] - warp_max);
            thread_sum += buf[i];
        }

        float warp_sum = WarpAllReduceSum(thread_sum);
#pragma unroll
        for (int i = 0; i < cols_this_thread; ++i) {
            row_output[lane_id * cols_per_thread + i] =
                static_cast<T>(__fdividef(buf[i], warp_sum));
        }
    }
}

at::Tensor softmax(at::Tensor input, long long rows, long long cols) {
    CHECK_INPUT(input);
    const at::cuda::OptionalCUDAGuard device_guard(device_of(input));

    at::Tensor output = at::empty_like(input);

    int grid = (rows + 3) / 4;
    dim3 block(128);

    if (input.dtype() == torch::kFloat32) {
        fastfold_softmax<float>
            <<<grid, block>>>((float *)input.data_ptr(), (float *)output.data_ptr(), rows, cols);
    } else if (input.dtype() == torch::kFloat16) {
        fastfold_softmax<at::Half><<<grid, block>>>((at::Half *)input.data_ptr(),
                                                    (at::Half *)output.data_ptr(), rows, cols);
    } else if (input.dtype() == torch::kBFloat16) {
        fastfold_softmax<at::BFloat16><<<grid, block>>>(
            (at::BFloat16 *)input.data_ptr(), (at::BFloat16 *)output.data_ptr(), rows, cols);
    }

    return output;
}

template <typename T>
__global__ void fastfold_softmax_grad(T *d_output, T *output, T *d_input, long long rows,
                                      long long cols) {
    int threadidx_x = threadIdx.x / 32;
    int threadidx_y = threadIdx.x % 32;
    long long row_offset = (long long)blockIdx.x * 4 + threadidx_x;
    int cols_per_thread = (cols + 31) / 32;
    int cols_this_thread = cols_per_thread;

    int last_y = (cols / cols_per_thread);

    if (threadidx_y == last_y) {
        cols_this_thread = cols - cols_per_thread * last_y;
    } else if (threadidx_y > last_y) {
        cols_this_thread = 0;
    }

    float y_buf[32];
    float dy_buf[32];

    int lane_id = threadidx_y;

    if (row_offset < rows) {
        T *row_d_output = d_output + row_offset * cols;
        T *row_output = output + row_offset * cols;
        T *row_d_input = d_input + row_offset * cols;

        float thread_max = -1 * CUDART_INF_F;

#pragma unroll
        for (int i = 0; i < cols_this_thread; i++) {
            y_buf[i] = static_cast<T>(row_output[lane_id * cols_per_thread + i]);
            dy_buf[i] = static_cast<T>(row_d_output[lane_id * cols_per_thread + i]);
        }

        float thread_sum = 0.f;

#pragma unroll
        for (int i = 0; i < cols_this_thread; i++) {
            thread_sum += y_buf[i] * dy_buf[i];
        }

        float warp_sum = WarpAllReduceSum(thread_sum);

#pragma unroll
        for (int i = 0; i < cols_this_thread; ++i) {
            row_d_input[lane_id * cols_per_thread + i] =
                static_cast<T>((dy_buf[i] - warp_sum) * y_buf[i]);
        }
    }
}

at::Tensor softmax_gradient(at::Tensor d_output, at::Tensor output, long long rows,
                            long long cols) {
    CHECK_INPUT(output);
    const at::cuda::OptionalCUDAGuard device_guard(device_of(output));
    at::Tensor grad_input = at::empty_like(output);

    int grid = (rows + 3) / 4;
    dim3 block(128);

    if (output.dtype() == torch::kFloat32) {
        fastfold_softmax_grad<float><<<grid, block>>>((float *)d_output.data_ptr(),
                                                      (float *)output.data_ptr(),
                                                      (float *)grad_input.data_ptr(), rows, cols);
    } else if (output.dtype() == torch::kFloat16) {
        fastfold_softmax_grad<at::Half>
            <<<grid, block>>>((at::Half *)d_output.data_ptr(), (at::Half *)output.data_ptr(),
                              (at::Half *)grad_input.data_ptr(), rows, cols);
    } else if (output.dtype() == torch::kBFloat16) {
        fastfold_softmax_grad<at::BFloat16><<<grid, block>>>(
            (at::BFloat16 *)d_output.data_ptr(), (at::BFloat16 *)output.data_ptr(),
            (at::BFloat16 *)grad_input.data_ptr(), rows, cols);
    }

    return grad_input;
}

////////////////

template <typename T>
__global__ void fastfold_softmax_scale_mask(T *input, T *mask, T *output, long long rows,
                                            long long cols, float scale, int head) {
    int threadidx_x = threadIdx.x / 32;
    int threadidx_y = threadIdx.x % 32;
    long long row_offset = (long long)blockIdx.x * 4 + threadidx_x;
    int cols_per_thread = (cols + 31) / 32;
    int cols_this_thread = cols_per_thread;

    int last_y = (cols / cols_per_thread);

    if (threadidx_y == last_y) {
        cols_this_thread = cols - cols_per_thread * last_y;
    } else if (threadidx_y > last_y) {
        cols_this_thread = 0;
    }

    float buf[32];

    int lane_id = threadidx_y;

    if (row_offset < rows) {
        T *row_input = input + row_offset * cols;
        T *row_output = output + row_offset * cols;
        T *mask_ptr = mask + ((row_offset / (head * cols)) * cols);

#pragma unroll
        for (int i = 0; i < cols_this_thread; i++) {
            if (mask_ptr[lane_id * cols_per_thread + i] == 0) {
                buf[i] = -1 * 1e9;
            } else {
                buf[i] = static_cast<T>(row_input[lane_id * cols_per_thread + i]) * scale;
            }
        }

        float thread_max = -1 * CUDART_INF_F;
#pragma unroll
        for (int i = 0; i < cols_this_thread; i++) {
            thread_max = max(thread_max, buf[i]);
        }

        float warp_max = WarpAllReduceMax(thread_max);

        float thread_sum = 0.f;
#pragma unroll
        for (int i = 0; i < cols_this_thread; ++i) {
            buf[i] = __expf(buf[i] - warp_max);
            thread_sum += buf[i];
        }

        float warp_sum = WarpAllReduceSum(thread_sum);
#pragma unroll
        for (int i = 0; i < cols_this_thread; ++i) {
            row_output[lane_id * cols_per_thread + i] =
                static_cast<T>(__fdividef(buf[i], warp_sum));
        }
    }
}

at::Tensor fused_scale_mask_softmax_forward(at::Tensor input, at::Tensor mask, long long rows,
                                            long long cols, float scale) {
    CHECK_INPUT(input);
    CHECK_INPUT(mask);
    const at::cuda::OptionalCUDAGuard device_guard(device_of(input));
    int head = input.sizes()[2];
    at::Tensor output = at::empty_like(input);

    int grid = (rows + 3) / 4;
    dim3 block(128);

    if (input.dtype() == torch::kFloat32) {
        fastfold_softmax_scale_mask<float>
            <<<grid, block>>>((float *)input.data_ptr(), (float *)mask.data_ptr(),
                              (float *)output.data_ptr(), rows, cols, scale, head);
    } else if (input.dtype() == torch::kFloat16) {
        fastfold_softmax_scale_mask<at::Half>
            <<<grid, block>>>((at::Half *)input.data_ptr(), (at::Half *)mask.data_ptr(),
                              (at::Half *)output.data_ptr(), rows, cols, scale, head);
    } else if (input.dtype() == torch::kBFloat16) {
        fastfold_softmax_scale_mask<at::BFloat16>
            <<<grid, block>>>((at::BFloat16 *)input.data_ptr(), (at::BFloat16 *)mask.data_ptr(),
                              (at::BFloat16 *)output.data_ptr(), rows, cols, scale, head);
    }

    return output;
}

template <typename T>
__global__ void fastfold_softmax_scale_mask_grad(T *d_output, T *output, T *d_input, T *mask,
                                                 long long rows, long long cols, float scale,
                                                 int head) {
    int threadidx_x = threadIdx.x / 32;
    int threadidx_y = threadIdx.x % 32;
    long long row_offset = (long long)blockIdx.x * 4 + threadidx_x;
    int cols_per_thread = (cols + 31) / 32;
    int cols_this_thread = cols_per_thread;

    int last_y = (cols / cols_per_thread);

    if (threadidx_y == last_y) {
        cols_this_thread = cols - cols_per_thread * last_y;
    } else if (threadidx_y > last_y) {
        cols_this_thread = 0;
    }

    float y_buf[32];
    float dy_buf[32];

    int lane_id = threadidx_y;

    if (row_offset < rows) {
        T *row_d_output = d_output + row_offset * cols;
        T *row_output = output + row_offset * cols;
        T *row_d_input = d_input + row_offset * cols;
        T *mask_ptr = mask + ((row_offset / (head * cols)) * cols);

        float thread_max = -1 * CUDART_INF_F;

#pragma unroll
        for (int i = 0; i < cols_this_thread; i++) {
            y_buf[i] = static_cast<T>(row_output[lane_id * cols_per_thread + i]);
            dy_buf[i] = static_cast<T>(row_d_output[lane_id * cols_per_thread + i]);
        }

        float thread_sum = 0.f;

#pragma unroll
        for (int i = 0; i < cols_this_thread; i++) {
            thread_sum += y_buf[i] * dy_buf[i];
        }

        float warp_sum = WarpAllReduceSum(thread_sum);

#pragma unroll
        for (int i = 0; i < cols_this_thread; ++i) {
            if (mask_ptr[lane_id * cols_per_thread + i] != 0) {
                row_d_input[lane_id * cols_per_thread + i] =
                    static_cast<T>(scale * ((dy_buf[i] - warp_sum) * y_buf[i]));
            } else {
                row_d_input = 0;
            }
        }
    }
}

at::Tensor fused_scale_mask_softmax_backward(at::Tensor d_output, at::Tensor output,
                                             at::Tensor mask, long long rows, long long cols,
                                             float scale) {
    CHECK_INPUT(output);
    CHECK_INPUT(mask);
    const at::cuda::OptionalCUDAGuard device_guard(device_of(mask));
    int head = output.sizes()[2];
    at::Tensor grad_input = at::empty_like(output);

    int grid = (rows + 3) / 4;
    dim3 block(128);

    if (output.dtype() == torch::kFloat32) {
        fastfold_softmax_scale_mask_grad<float><<<grid, block>>>(
            (float *)d_output.data_ptr(), (float *)output.data_ptr(),
            (float *)grad_input.data_ptr(), (float *)mask.data_ptr(), rows, cols, scale, head);
    } else if (output.dtype() == torch::kFloat16) {
        fastfold_softmax_scale_mask_grad<at::Half>
            <<<grid, block>>>((at::Half *)d_output.data_ptr(), (at::Half *)output.data_ptr(),
                              (at::Half *)grad_input.data_ptr(), (at::Half *)mask.data_ptr(), rows,
                              cols, scale, head);
    } else if (output.dtype() == torch::kBFloat16) {
        fastfold_softmax_scale_mask_grad<at::BFloat16><<<grid, block>>>(
            (at::BFloat16 *)d_output.data_ptr(), (at::BFloat16 *)output.data_ptr(),
            (at::BFloat16 *)grad_input.data_ptr(), (at::BFloat16 *)mask.data_ptr(), rows, cols,
            scale, head);
    }

    return grad_input;
}

////////////////

template <typename T>
__global__ void fastfold_softmax_scale_mask_bias(T *input, T *mask, T *bias, T *output,
                                                 long long rows, long long cols, float scale,
                                                 int head) {
    int threadidx_x = threadIdx.x / 32;
    int threadidx_y = threadIdx.x % 32;
    long long row_offset = (long long)blockIdx.x * 4 + threadidx_x;
    int cols_per_thread = (cols + 31) / 32;
    int cols_this_thread = cols_per_thread;

    int last_y = (cols / cols_per_thread);

    if (threadidx_y == last_y) {
        cols_this_thread = cols - cols_per_thread * last_y;
    } else if (threadidx_y > last_y) {
        cols_this_thread = 0;
    }

    float buf[32];

    int lane_id = threadidx_y;

    if (row_offset < rows) {
        T *row_input = input + row_offset * cols;
        T *row_output = output + row_offset * cols;
        T *mask_ptr = mask + ((row_offset / (head * cols)) * cols);
        T *bias_ptr = bias + ((row_offset % (head * cols)) * cols);

#pragma unroll
        for (int i = 0; i < cols_this_thread; i++) {
            if (mask_ptr[lane_id * cols_per_thread + i] == 0) {
                buf[i] = -1 * 10e9;
            } else {
                buf[i] = static_cast<T>(row_input[lane_id * cols_per_thread + i]) * scale;
                buf[i] += static_cast<T>(bias_ptr[lane_id * cols_per_thread + i]);
            }
        }

        float thread_max = -1 * CUDART_INF_F;
#pragma unroll
        for (int i = 0; i < cols_this_thread; i++) {
            thread_max = max(thread_max, buf[i]);
        }

        float warp_max = WarpAllReduceMax(thread_max);

        float thread_sum = 0.f;
#pragma unroll
        for (int i = 0; i < cols_this_thread; ++i) {
            buf[i] = __expf(buf[i] - warp_max);
            thread_sum += buf[i];
        }

        float warp_sum = WarpAllReduceSum(thread_sum);
#pragma unroll
        for (int i = 0; i < cols_this_thread; ++i) {
            row_output[lane_id * cols_per_thread + i] =
                static_cast<T>(__fdividef(buf[i], warp_sum));
        }
    }
}

at::Tensor fused_scale_mask_bias_softmax_forward(at::Tensor input, at::Tensor mask, at::Tensor bias,
                                                 long long rows, long long cols, float scale) {
    CHECK_INPUT(input);
    CHECK_INPUT(mask);
    CHECK_INPUT(bias);
    const at::cuda::OptionalCUDAGuard device_guard(device_of(input));
    int head = input.sizes()[2];
    at::Tensor output = at::empty_like(input);

    int grid = (rows + 3) / 4;
    dim3 block(128);

    if (input.dtype() == torch::kFloat32) {
        fastfold_softmax_scale_mask_bias<float><<<grid, block>>>(
            (float *)input.data_ptr(), (float *)mask.data_ptr(), (float *)bias.data_ptr(),
            (float *)output.data_ptr(), rows, cols, scale, head);
    } else if (input.dtype() == torch::kFloat16) {
        fastfold_softmax_scale_mask_bias<at::Half><<<grid, block>>>(
            (at::Half *)input.data_ptr(), (at::Half *)mask.data_ptr(), (at::Half *)bias.data_ptr(),
            (at::Half *)output.data_ptr(), rows, cols, scale, head);
    } else if (input.dtype() == torch::kBFloat16) {
        fastfold_softmax_scale_mask_bias<at::BFloat16>
            <<<grid, block>>>((at::BFloat16 *)input.data_ptr(), (at::BFloat16 *)mask.data_ptr(),
                              (at::BFloat16 *)bias.data_ptr(), (at::BFloat16 *)output.data_ptr(),
                              rows, cols, scale, head);
    }

    return output;
}

at::Tensor fused_scale_mask_bias_softmax_backward(at::Tensor d_output, at::Tensor output,
                                                  at::Tensor mask, at::Tensor bias, long long rows,
                                                  long long cols, float scale) {
    CHECK_INPUT(output);
    CHECK_INPUT(mask);
    const at::cuda::OptionalCUDAGuard device_guard(device_of(mask));
    int head = output.sizes()[2];
    at::Tensor grad_input = at::empty_like(output);

    int grid = (rows + 3) / 4;
    dim3 block(128);

    if (output.dtype() == torch::kFloat32) {
        fastfold_softmax_scale_mask_grad<float><<<grid, block>>>(
            (float *)d_output.data_ptr(), (float *)output.data_ptr(),
            (float *)grad_input.data_ptr(), (float *)mask.data_ptr(), rows, cols, scale, head);
    } else if (output.dtype() == torch::kFloat16) {
        fastfold_softmax_scale_mask_grad<at::Half>
            <<<grid, block>>>((at::Half *)d_output.data_ptr(), (at::Half *)output.data_ptr(),
                              (at::Half *)grad_input.data_ptr(), (at::Half *)mask.data_ptr(), rows,
                              cols, scale, head);
    } else if (output.dtype() == torch::kBFloat16) {
        fastfold_softmax_scale_mask_grad<at::BFloat16><<<grid, block>>>(
            (at::BFloat16 *)d_output.data_ptr(), (at::BFloat16 *)output.data_ptr(),
            (at::BFloat16 *)grad_input.data_ptr(), (at::BFloat16 *)mask.data_ptr(), rows, cols,
            scale, head);
    }

    return grad_input;
}
