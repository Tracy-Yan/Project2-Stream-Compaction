#include <cuda.h>
#include <cuda_runtime.h>
#include "common.h"
#include "efficient.h"

namespace StreamCompaction {
    namespace Efficient {
        using StreamCompaction::Common::PerformanceTimer;
        PerformanceTimer& timer()
        {
            static PerformanceTimer timer;
            return timer;
        }

		// GPU Gems 3 example
		__global__ void prescan(float *g_odata, float *g_idata, int n) {
			extern __shared__ float temp[];  // allocated on invocation 
			int thid = threadIdx.x;
			int offset = 1;
			temp[2 * thid] = g_idata[2 * thid]; // load input into shared memory 
			temp[2 * thid + 1] = g_idata[2 * thid + 1];
			for (int d = n >> 1; d > 0; d >>= 1)                    // build sum in place up the tree 
			{
				__syncthreads();
				if (thid < d) {
					int ai = offset * (2 * thid + 1) - 1;
					int bi = offset * (2 * thid + 2) - 1;
					temp[bi] += temp[ai];
				}
				offset *= 2;
			}
			if (thid == 0) { temp[n - 1] = 0; } // clear the last element 
			for (int d = 1; d < n; d *= 2) // traverse down tree & build scan 
			{
				offset >>= 1;
				__syncthreads();
				if (thid < d) {
					int ai = offset * (2 * thid + 1) - 1;
					int bi = offset * (2 * thid + 2) - 1;
					float t = temp[ai];
					temp[ai] = temp[bi];
					temp[bi] += t;
				}
			}
			__syncthreads();
			g_odata[2 * thid] = temp[2 * thid]; // write results to device memory      
			g_odata[2 * thid + 1] = temp[2 * thid + 1];
		}

		__global__ void kernelEfficientScan(int *g_odata, int *g_idata, int n, int N) {
			int index = threadIdx.x;
			int offset = 2;
			g_odata[index] = g_idata[index];
			// up-sweep
			for (int d = N / 2; d >= 1; d >>= 1) {
				__syncthreads();
				if (index < d) {
					int a = n - 1 - (index * offset);
					int b = a - offset / 2;
					if (a >= 0 && b >= 0) {
						g_odata[a] += g_odata[b];
					}
				}
				offset *= 2;
			}
			// down-sweep
			if (index == 0 && n > 0) {
				g_odata[n - 1] = 0;
			}
			offset /= 2;
			for (int d = 1; d <= N / 2; d *= 2) {
				__syncthreads();
				if (index < d) {
					int a = n - 1 - (index * offset);
					int b = a - offset / 2;
					if (a >= 0 && b >= 0) {
						int tmp = g_odata[b];
						g_odata[b] = g_odata[a];
						g_odata[a] += tmp;
					}
				}
				offset /= 2;
			}
		}

		__global__ void kernelEfficientCompact(int *g_odata, int *g_idata, int *g_sdata, int *g_bdata, int n, int N) {
			int index = threadIdx.x;
			// Build binary array
			if (g_idata[index] == 0) {
				g_bdata[index] = 0;
			}
			else {
				g_bdata[index] = 1;
			}
			// Efficient scan
			__syncthreads();
			int offset = 2;
			g_sdata[index] = g_bdata[index];
			// up-sweep
			for (int d = N / 2; d >= 1; d >>= 1) {
				__syncthreads();
				if (index < d) {
					int a = n - 1 - (index * offset);
					int b = a - offset / 2;
					if (a >= 0 && b >= 0) {
						g_sdata[a] += g_sdata[b];
					}
				}
				offset *= 2;
			}
			// down-sweep
			if (index == 0 && n > 0) {
				g_sdata[n - 1] = 0;
			}
			offset /= 2;
			for (int d = 1; d <= N / 2; d *= 2) {
				__syncthreads();
				if (index < d) {
					int a = n - 1 - (index * offset);
					int b = a - offset / 2;
					if (a >= 0 && b >= 0) {
						int tmp = g_sdata[b];
						g_sdata[b] = g_sdata[a];
						g_sdata[a] += tmp;
					}
				}
				offset /= 2;
			}
			// Scatter
			__syncthreads();
			if (g_bdata[index] == 1) {
				int idx = g_sdata[index];
				g_odata[idx] = g_idata[index];
			}
		}


        /**
         * Performs prefix-sum (aka scan) on idata, storing the result into odata.
         */
        void scan(int n, int *odata, const int *idata) {
			int k = ilog2ceil(n);
			int N = (int) pow(2, k);
			
			int *g_odata;
			int *g_idata;
			cudaMalloc((void**)&g_idata, n * sizeof(int));
			checkCUDAErrorFn("cudaMalloc g_idata failed!");
			cudaMalloc((void**)&g_odata, n * sizeof(int));
			checkCUDAErrorFn("cudaMalloc g_odata failed!");
			cudaMemcpy(g_idata, idata, sizeof(int) * n, cudaMemcpyHostToDevice);

            timer().startGpuTimer();
            // TODO
			kernelEfficientScan<<<1, n >>>(g_odata, g_idata, n, N);

            timer().endGpuTimer();

			// copy back ouput
			cudaMemcpy(odata, g_odata, sizeof(int) * n, cudaMemcpyDeviceToHost);
			checkCUDAErrorFn("cudaMemcpy odata failed!");

			cudaFree(g_odata);
			cudaFree(g_idata);
        }

        /**
         * Performs stream compaction on idata, storing the result into odata.
         * All zeroes are discarded.
         *
         * @param n      The number of elements in idata.
         * @param odata  The array into which to store elements.
         * @param idata  The array of elements to compact.
         * @returns      The number of elements remaining after compaction.
         */
        int compact(int n, int *odata, const int *idata) {
			int k = ilog2ceil(n);
			int N = (int)pow(2, k);

			int *g_odata;
			int *g_idata;
			int *g_bdata;
			int *g_sdata;
			cudaMalloc((void**)&g_idata, n * sizeof(int));
			checkCUDAErrorFn("cudaMalloc g_idata failed!");
			cudaMalloc((void**)&g_odata, n * sizeof(int));
			checkCUDAErrorFn("cudaMalloc g_odata failed!");
			cudaMalloc((void**)&g_bdata, n * sizeof(int));
			checkCUDAErrorFn("cudaMalloc g_bdata failed!");
			cudaMalloc((void**)&g_sdata, n * sizeof(int));
			checkCUDAErrorFn("cudaMalloc g_sdata failed!");

			cudaMemcpy(g_idata, idata, sizeof(int) * n, cudaMemcpyHostToDevice);

            timer().startGpuTimer();
            // TODO
			//kernelEfficientCompact<<<1, n>>>(g_odata, g_idata, g_sdata, g_bdata, n, N);
			Common::kernMapToBoolean<<<1, n>>>(n, g_bdata, g_idata);
			kernelEfficientScan<<<1, n>>>(g_sdata, g_bdata, n, N);
			Common::kernScatter<<<1, n>>>(n, g_odata, g_idata, g_bdata, g_sdata);

            timer().endGpuTimer();

			// copy back output
			int c1, c2;
			cudaMemcpy(&c1, g_bdata + n - 1, sizeof(int), cudaMemcpyDeviceToHost);
			cudaMemcpy(&c2, g_sdata + n - 1, sizeof(int), cudaMemcpyDeviceToHost);
			int count = c1 + c2;
			cudaMemcpy(odata, g_odata, sizeof(int) * count, cudaMemcpyDeviceToHost);

			cudaFree(g_odata);
			cudaFree(g_idata);
			cudaFree(g_sdata);
			cudaFree(g_bdata);

            return count;
        }
    }
}
