#include "cuda_runtime.h"
#include "curand.h"
#include "cublas_v2.h"

extern "C" {
#include "im2col.h"
#include "cuda.h"
}

// src: https://github.com/BVLC/caffe/blob/master/src/caffe/util/im2col.cu
// You may also want to read: https://github.com/BVLC/caffe/blob/master/LICENSE

__global__ void im2col_gpu_kernel(const int n, const float* data_im,
        const int height, const int width, const int ksize,
        const int pad,
        const int stride,
        const int height_col, const int width_col,
        float *data_col) {
    int index = blockIdx.x*blockDim.x+threadIdx.x;
    for(; index < n; index += blockDim.x*gridDim.x){
        int w_out = index % width_col;
        int h_index = index / width_col;
        int h_out = h_index % height_col;
        int channel_in = h_index / height_col;
        int channel_out = channel_in * ksize * ksize;
        int h_in = h_out * stride - pad;
        int w_in = w_out * stride - pad;
        float* data_col_ptr = data_col;
        data_col_ptr += (channel_out * height_col + h_out) * width_col + w_out;
        const float* data_im_ptr = data_im;
        data_im_ptr += (channel_in * height + h_in) * width + w_in;
        for (int i = 0; i < ksize; ++i) {
            for (int j = 0; j < ksize; ++j) {
                int h = h_in + i;
                int w = w_in + j;

                *data_col_ptr = (h >= 0 && w >= 0 && h < height && w < width) ?
                    data_im_ptr[i * width + j] : 0;

                //*data_col_ptr = data_im_ptr[ii * width + jj];

                data_col_ptr += height_col * width_col;
            }
        }
    }
}

void im2col_ongpu(float *im,
         int channels, int height, int width,
         int ksize, int stride, int pad, float *data_col){
    // We are going to launch channels * height_col * width_col kernels, each
    // kernel responsible for copying a single-channel grid.
    int height_col = (height + 2 * pad - ksize) / stride + 1;
    int width_col = (width + 2 * pad - ksize) / stride + 1;
    int num_kernels = channels * height_col * width_col;
    im2col_gpu_kernel<<<(num_kernels+BLOCK-1)/BLOCK,
        BLOCK, 0, get_cuda_stream()>>>(
                num_kernels, im, height, width, ksize, pad,
                stride, height_col,
                width_col, data_col);
}
// --------------------------------

#define WARP_SIZE 32

__global__ void im2col_align_gpu_kernel(const int n, const float* data_im,
    const int height, const int width, const int ksize,
    const int pad,
    const int stride,
    const int height_col, const int width_col,
    float *data_col, const int bit_align)
{
    int index = blockIdx.x*blockDim.x + threadIdx.x;
    for (; index < n; index += blockDim.x*gridDim.x) {
        int w_out = index % width_col;
        int h_index = index / width_col;
        int h_out = h_index % height_col;
        int channel_in = h_index / height_col;
        int channel_out = channel_in * ksize * ksize;
        int h_in = h_out * stride - pad;
        int w_in = w_out * stride - pad;
        float* data_col_ptr = data_col;
        //data_col_ptr += (channel_out * height_col + h_out) * width_col + w_out;
        data_col_ptr += channel_out * bit_align + h_out * width_col + w_out;
        float* data_col_ptr_32 = data_col + (channel_out * bit_align + h_out * width_col + w_out)/32;
        const float* data_im_ptr = data_im;
        data_im_ptr += (channel_in * height + h_in) * width + w_in;
        for (int i = 0; i < ksize; ++i) {
            for (int j = 0; j < ksize; ++j) {
                int h = h_in + i;
                int w = w_in + j;

                *data_col_ptr = (h >= 0 && w >= 0 && h < height && w < width) ?
                    data_im_ptr[i * width + j] : 0;

                //float src_val = (h >= 0 && w >= 0 && h < height && w < width) ? data_im_ptr[i * width + j] : 0;
                //unsigned int bit_mask = __ballot_sync(0xffffffff, src_val > 0);
                //if (threadIdx.x % WARP_SIZE == 0) *((unsigned int*)data_col_ptr_32) = bit_mask;
                //data_col_ptr_32 += bit_align / 32;

                //data_col_ptr += height_col * width_col;
                data_col_ptr += bit_align;
            }
        }
    }
}

void im2col_align_ongpu(float *im,
    int channels, int height, int width,
    int ksize, int stride, int pad, float *data_col, int bit_align) {
    // We are going to launch channels * height_col * width_col kernels, each
    // kernel responsible for copying a single-channel grid.
    int height_col = (height + 2 * pad - ksize) / stride + 1;
    int width_col = (width + 2 * pad - ksize) / stride + 1;
    int num_kernels = channels * height_col * width_col;
    im2col_align_gpu_kernel << <(num_kernels + BLOCK - 1) / BLOCK,
        BLOCK, 0, get_cuda_stream() >> >(
            num_kernels, im, height, width, ksize, pad,
            stride, height_col,
            width_col, data_col, bit_align);
}
// --------------------------------


__global__ void float_to_bit_gpu_kernel(float *src, unsigned char *dst, size_t size)
{
    //const int size_aligned = size + (WARP_SIZE - size % WARP_SIZE);

    int index = blockIdx.x*blockDim.x + threadIdx.x;
    float src_val;

    //for (; index < size_aligned; index += blockDim.x*gridDim.x)
    {
        //src_val = src[index];
        if(index < size) src_val = src[index];
        else src_val = 0;
        //unsigned int bit_mask = __ballot_sync(0xffffffff, src_val > 0);
        unsigned int bit_mask = __ballot(src_val > 0);
        if (threadIdx.x % WARP_SIZE == 0) ((unsigned int*)dst)[index / 32] = bit_mask;
    }
}


void float_to_bit_gpu(float *src, unsigned char *dst, size_t size)
{
    const int num_blocks = size / BLOCK + 1;
    float_to_bit_gpu_kernel<<<num_blocks, BLOCK, 0, get_cuda_stream()>>>(src, dst, size);
}
// --------------------------------


__device__ __host__ static inline void remove_bit(unsigned char *const dst, size_t index) {
    size_t dst_i = index / 8;
    int dst_shift = index % 8;
    dst[dst_i] &= ~(1 << dst_shift);
}

__device__ __host__ static inline void set_bit(unsigned char *const dst, size_t index) {
    size_t dst_i = index / 8;
    int dst_shift = index % 8;
    dst[dst_i] |= 1 << dst_shift;
    //dst[dst_i] |= 1 << (8 - dst_shift);
}

__device__ __host__ static inline unsigned char get_bit(unsigned char const*const src, size_t index) {
    size_t src_i = index / 8;
    int src_shift = index % 8;
    unsigned char val = (src[src_i] & (1 << src_shift)) > 0;
    //unsigned char val = (src[src_i] & (1 << (8 - src_shift))) > 0;
    return val;
}

// Intel CPUs and nVidia CUDA GPU are little endian
__device__ __host__ unsigned char reverse_byte(unsigned char a)
{
    return ((a & 0x1) << 7) | ((a & 0x2) << 5) |
        ((a & 0x4) << 3) | ((a & 0x8) << 1) |
        ((a & 0x10) >> 1) | ((a & 0x20) >> 3) |
        ((a & 0x40) >> 5) | ((a & 0x80) >> 7);
}

__device__ __host__ unsigned char reverse_byte_2(unsigned char a)
{
    return ((a * 0x0802LU & 0x22110LU) | (a * 0x8020LU & 0x88440LU)) * 0x10101LU >> 16;
}

__device__ __host__ void transpose8rS32_reversed_diagonale(unsigned char* A, int m, int n, unsigned char* B)
{
    unsigned x, y, t;

    // Load the array and pack it into x and y.
    x = (A[0] << 24) | (A[m] << 16) | (A[2 * m] << 8) | A[3 * m];
    y = (A[4 * m] << 24) | (A[5 * m] << 16) | (A[6 * m] << 8) | A[7 * m];

    t = (x ^ (x >> 7)) & 0x00AA00AA;  x = x ^ t ^ (t << 7);
    t = (y ^ (y >> 7)) & 0x00AA00AA;  y = y ^ t ^ (t << 7);

    t = (x ^ (x >> 14)) & 0x0000CCCC;  x = x ^ t ^ (t << 14);
    t = (y ^ (y >> 14)) & 0x0000CCCC;  y = y ^ t ^ (t << 14);

    t = (x & 0xF0F0F0F0) | ((y >> 4) & 0x0F0F0F0F);
    y = ((x << 4) & 0xF0F0F0F0) | (y & 0x0F0F0F0F);
    x = t;

    B[7 * n] = reverse_byte(x >> 24);  B[6 * n] = reverse_byte(x >> 16);  B[5 * n] = reverse_byte(x >> 8);  B[4 * n] = reverse_byte(x);
    B[3 * n] = reverse_byte(y >> 24);  B[2 * n] = reverse_byte(y >> 16);  B[1 * n] = reverse_byte(y >> 8);  B[0 * n] = reverse_byte(y);
}


__global__ void transpose_bin_gpu_kernel(unsigned char *A, unsigned char *B, const int n, const int m,
    const int lda, const int ldb, const int block_size)
{
    int i;
    int index = blockIdx.x*blockDim.x + threadIdx.x;

    //for (i = 0; i < n; i += 8)
    {
        i = (index*8) % n;
        int j;
        //for (j = 0; j < m - 8; j += 8)
        {
            j = ((index * 8) / n) * 8;
            if (j < m - 8) {
                int a_index = i*lda + j;
                int b_index = j*ldb + i;
                transpose8rS32_reversed_diagonale(&A[a_index / 8], lda / 8, ldb / 8, &B[b_index / 8]);
            }
            else if (j < m) {
                for (; j < m; ++j) {
                    if (get_bit(A, i*lda + j)) set_bit(B, j*ldb + i);
                    else remove_bit(B, j*ldb + i);
                }
            }
        }
    }
}


void transpose_bin_gpu(unsigned char *A, unsigned char *B, const int n, const int m,
    const int lda, const int ldb, const int block_size)
{
    size_t size = n*m/64 + 1;
    const int num_blocks = size / BLOCK + 1;
    transpose_bin_gpu_kernel << <num_blocks, BLOCK, 0, get_cuda_stream() >> >(A, B, n, m, lda, ldb, block_size);
}
// --------------------------------


__global__ void fill_int8_gpu_kernel(unsigned char *src, unsigned char val, size_t size) {
    int index = blockIdx.x*blockDim.x + threadIdx.x;
    if(index < size) src[index] = 0;
}

void fill_int8_gpu(unsigned char *src, unsigned char val, size_t size) {
    const int num_blocks = size / BLOCK + 1;
    fill_int8_gpu_kernel<<<num_blocks, BLOCK, 0, get_cuda_stream()>>>(src, val, size);
}
// --------------------------------

typedef unsigned long long int uint64_t;
typedef unsigned char uint8_t;

__device__ __host__ static inline uint64_t xnor_int64(uint64_t a, uint64_t b) {
    return ~(a^b);
}

/*
__global__ void gemm_nn_custom_bin_mean_transposed_gpu_kernel(int M, int N, int K,
    unsigned char *A, int lda,
    unsigned char *B, int ldb,
    float *C, int ldc, float *mean_arr)
{
    int index = blockIdx.x*blockDim.x + threadIdx.x;

    //if (index == 0)
    {
        int i, j, k, h;

        //#pragma omp parallel for
        //for (i = 0; i < M; ++i)
        i = index % M;
        //if(i < M)
        {   // l.n - filters [16 - 55 - 1024]
            float mean_val = mean_arr[i];

            //for (j = 0; j < N; ++j)
            j = index / M;
            if(j < N)
            { // out_h*out_w - one channel output size [169 - 173056]
                int count = 0;

                for (k = 0; k < K; k += 64) {   // l.size*l.size*l.c - one filter size [27 - 9216]
                    uint64_t a_bit64 = *((uint64_t *)(A + (i*lda + k) / 8));
                    uint64_t b_bit64 = *((uint64_t *)(B + (j*ldb + k) / 8));
                    uint64_t c_bit64 = xnor_int64(a_bit64, b_bit64);

                    int tmp_count = __popcll(c_bit64);

                    if (K - k < 64)  tmp_count = tmp_count - (64 - (K - k));    // remove extra bits
                    count += tmp_count;
                    //binary_int64_printf(c_bit64);
                    //printf(", count = %d \n\n", tmp_count);
                }

                C[i*ldc + j] = (2 * count - K) * mean_val;
            }
        }
    }
}
*/


/*
// B (input) in the shared_memory
__global__ void gemm_nn_custom_bin_mean_transposed_gpu_kernel(int M, int N, int K,
    unsigned char *A, int lda,
    unsigned char *B, int ldb,
    float *C, int ldc, float *mean_arr)
{
    int index = blockIdx.x*blockDim.x + threadIdx.x;

    __shared__ uint64_t B_s[4096];  // 32 KB // [ldb x N`]

    int start_j = blockIdx.x*blockDim.x / M;
    int end_j = (blockIdx.x*blockDim.x + blockDim.x) / M + 1;

    size_t shared_size = ldb * (end_j - start_j);

    int j_cur = index / M;
    int local_j = j_cur - start_j;

    for (int k = threadIdx.x * 64; k < shared_size; k += blockDim.x * 64) {
        int x = start_j*ldb + k;
        if (x < (N*ldb)) *((uint64_t *)(B_s + k / 8)) = *((uint64_t *)(B + x / 8));
    }

    //if (j_cur < N && (index % M == 0 || threadIdx.x == 0)) {
      //  for (int k = 0; k < K; k += 64) {   // l.size*l.size*l.c - one filter size [27 - 9216]
        //    *((uint64_t *)(B_s + (local_j*ldb + k) / 8)) = *((uint64_t *)(B + (j_cur*ldb + k) / 8));    // input
        //}
    //}
    __syncthreads();

    //if (index == 0)
    {
        int i, j, k, h;

        //#pragma omp parallel for
        //for (i = 0; i < M; ++i)
        i = index % M;
        //if(i < M)
        {   // l.n - filters [16 - 55 - 1024]
            float mean_val = mean_arr[i];

            //for (j = 0; j < N; ++j)
            j = index / M;
            if (j < N)
            { // out_h*out_w - one channel output size [169 - 173056]
                int count = 0;

                for (k = 0; k < K; k += 64) {   // l.size*l.size*l.c - one filter size [27 - 9216]
                    uint64_t a_bit64 = *((uint64_t *)(A + (i*lda + k) / 8));    // weights
                    //uint64_t b_bit64 = *((uint64_t *)(B + (j*ldb + k) / 8));
                    uint64_t b_bit64 = *((uint64_t *)(B_s + (local_j*ldb + k) / 8));    // input
                    uint64_t c_bit64 = xnor_int64(a_bit64, b_bit64);

                    int tmp_count = __popcll(c_bit64);

                    if (K - k < 64)  tmp_count = tmp_count - (64 - (K - k));    // remove extra bits
                    count += tmp_count;
                    //binary_int64_printf(c_bit64);
                    //printf(", count = %d \n\n", tmp_count);
                }

                C[i*ldc + j] = (2 * count - K) * mean_val;
            }
        }
    }
}
*/

// A (weights) in the shared_memory
__global__ void gemm_nn_custom_bin_mean_transposed_gpu_kernel(int M, int N, int K,
    unsigned char *A, int lda,
    unsigned char *B, int ldb,
    float *C, int ldc, float *mean_arr)
{
    int index = blockIdx.x*blockDim.x + threadIdx.x;

    __shared__ uint64_t A_s[6144];  // 48 KB // [lda x M`]
                                    //__shared__ uint8_t A_s[6144*8];  // 48 KB // [lda x M`]

    int start_i = blockIdx.x*blockDim.x / N;
    int end_i = (blockIdx.x*blockDim.x + blockDim.x) / N + 1;

    size_t shared_size = lda * (end_i - start_i);

    int i_cur = index / N;
    int local_i = i_cur - start_i;

    for (int k = threadIdx.x * 64; k < shared_size; k += blockDim.x * 64) {
        int x = start_i*lda + k;
        if (x < (M*lda)) *((uint64_t *)(A_s + k / 8)) = *((uint64_t *)(A + x / 8));
    }

    //if (i_cur < M && (index % N == 0 || threadIdx.x == 0)) {
    //for (int k = 0; k < K; k += 64) {   // l.size*l.size*l.c - one filter size [27 - 9216]
    //*((uint64_t *)(A_s + (local_i*lda + k) / 8)) = *((uint64_t *)(A + (i_cur*lda + k) / 8));    // weights
    //  }
    //}

    __syncthreads();

    int i, j, k, h;

    j = index % N;
    {    // out_h*out_w - one channel output size [169 - 173056]
        i = index / N;
        if (i < M)  // l.n - filters [16 - 55 - 1024]
        {
            float mean_val = mean_arr[i];
            int count = 0;

            for (k = 0; k < K; k += 64) {   // l.size*l.size*l.c - one filter size [27 - 9216]
                //uint64_t a_bit64 = *((uint64_t *)(A + (i*lda + k) / 8));    // weights
                uint64_t a_bit64 = *((uint64_t *)(A_s + (local_i*lda + k) / 8));    // weights
                uint64_t b_bit64 = *((uint64_t *)(B + (j*ldb + k) / 8));            // input
                uint64_t c_bit64 = xnor_int64(a_bit64, b_bit64);

                int tmp_count = __popcll(c_bit64);

                if (K - k < 64)  tmp_count = tmp_count - (64 - (K - k));    // remove extra bits
                count += tmp_count;
            }

            C[i*ldc + j] = (2 * count - K) * mean_val;
        }
    }
}

#include <cstdio>

void gemm_nn_custom_bin_mean_transposed_gpu(int M, int N, int K,
    unsigned char *A, int lda,
    unsigned char *B, int ldb,
    float *C, int ldc, float *mean_arr)
{
    size_t size = M*N;
    const int num_blocks = size / BLOCK + 1;

    /*
    printf("\n gemm_bin size = %d, num_blocks = %d, M*K = %d KB, N*K = %d KB \n (w) M*K/num_blocks = %d KB, (i) N*K/num_blocks = %d KB \n",
        size, num_blocks, M*K / 1024, N*K / 1024, M*lda / num_blocks / 1024, N*ldb / num_blocks / 1024);
    printf(" M / 512 = %d, N / 512 = %d, M*lda / 512 = %d, N*ldb / 512 = %d \n", M / 512, N / 512, M*lda/512, N*ldb/512);
    */
    //printf(" shared_memory: (w) lda*BLOCK/N = %d, (i) ldb*BLOCK/M = %d, \t lda = %d \n\n", lda*BLOCK / N, ldb*BLOCK / M, lda);

    gemm_nn_custom_bin_mean_transposed_gpu_kernel<<<num_blocks, BLOCK, 0, get_cuda_stream() >>>(
        M, N, K,
        A, lda,
        B, ldb,
        C, ldc,
        mean_arr);
}

// --------------------------------


__global__ void convolve_bin_gpu_kernel(float *input, float *weights, float *output, int in_w, int in_h, int in_c, int n, int size, int pad)
{
    int index = blockIdx.x*blockDim.x + threadIdx.x;

    int fil;
    // filter index
    //for (fil = 0; fil < n; ++fil)
    int chan, y, x, f_y, f_x;
    // channel index
    //for (chan = 0; chan < in_c; ++chan)
    // input - y
    //for (y = 0; y < in_h; ++y)
    // input - x
    //for (x = 0; x < in_w; ++x)
    x = index % in_w;
    int index2 = index / in_w;
    y = index2 % in_h;
    fil = index2 / in_h;
    if (fil < n)
    {

                int const output_index = fil*in_w*in_h + y*in_w + x;
                float sum = 0;

                for (chan = 0; chan < in_c; ++chan)
                {
                    int const weights_pre_index = fil*in_c*size*size + chan*size*size;
                    int const input_pre_index = chan*in_w*in_h;

                    // filter - y
                    for (f_y = 0; f_y < size; ++f_y)
                    {
                        int input_y = y + f_y - pad;
                        // filter - x
                        for (f_x = 0; f_x < size; ++f_x)
                        {
                            int input_x = x + f_x - pad;
                            if (input_y < 0 || input_x < 0 || input_y >= in_h || input_x >= in_w) continue;

                            int input_index = input_pre_index + input_y*in_w + input_x;
                            int weights_index = weights_pre_index + f_y*size + f_x;

                            sum += input[input_index] *weights[weights_index];

                        }
                    }
                    // l.output[filters][width][height] +=
                    //        state.input[channels][width][height] *
                    //        l.weights[filters][channels][filter_width][filter_height];
                    //output[output_index] += sum;
                }
                output[output_index] = sum;
    }

}

void convolve_bin_gpu(float *input, float *weights, float *output, int in_w, int in_h, int in_c, int n, int size, int pad)
{
    size_t array_size = in_w*in_h*n;    // width X height X filters
    const int num_blocks = array_size / BLOCK + 1;
    //printf("\n array_size = %d, num_blocks = %d, w = %d, h = %d, n = %d, c = %d, pad = %d \n", array_size, num_blocks, in_w, in_h, n, in_c, pad);

    convolve_bin_gpu_kernel << <num_blocks, BLOCK, 0, get_cuda_stream() >> > (input, weights, output, in_w, in_h, in_c, n, size, pad);
}



void convolve_bin_cpu(float *input, float *weights, float *output, int in_w, int in_h, int in_c, int n, int size, int pad)
{
    int fil;
    // filter index
#pragma omp parallel for      // "omp parallel for" - automatic parallelization of loop by using OpenMP
    for (fil = 0; fil < n; ++fil) {
        int chan, y, x, f_y, f_x;
        // channel index
        for (chan = 0; chan < in_c; ++chan)
            // input - y
            for (y = 0; y < in_h; ++y)
                // input - x
                for (x = 0; x < in_w; ++x)
                {
                    int const output_index = fil*in_w*in_h + y*in_w + x;
                    int const weights_pre_index = fil*in_c*size*size + chan*size*size;
                    int const input_pre_index = chan*in_w*in_h;
                    float sum = 0;

                    // filter - y
                    for (f_y = 0; f_y < size; ++f_y)
                    {
                        int input_y = y + f_y - pad;
                        // filter - x
                        for (f_x = 0; f_x < size; ++f_x)
                        {
                            int input_x = x + f_x - pad;
                            if (input_y < 0 || input_x < 0 || input_y >= in_h || input_x >= in_w) continue;

                            int input_index = input_pre_index + input_y*in_w + input_x;
                            int weights_index = weights_pre_index + f_y*size + f_x;

                            sum += input[input_index] * weights[weights_index];
                        }
                    }
                    // l.output[filters][width][height] +=
                    //        state.input[channels][width][height] *
                    //        l.weights[filters][channels][filter_width][filter_height];
                    output[output_index] += sum;
                }
    }


}