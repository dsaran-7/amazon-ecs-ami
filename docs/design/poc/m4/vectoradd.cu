// POC CUDA workload: vector add with managed memory; prints device/driver/runtime and verifies result.
#include <cstdio>
#include <cmath>
#include <cuda_runtime.h>
__global__ void add(const float* a, const float* b, float* c, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) c[i] = a[i] + b[i];
}
int main() {
  int n = 1 << 24, dv = 0, rv = 0; size_t sz = n * sizeof(float);
  cudaDriverGetVersion(&dv); cudaRuntimeGetVersion(&rv);
  cudaDeviceProp p; cudaError_t e = cudaGetDeviceProperties(&p, 0);
  if (e) { printf("ERR getDeviceProperties: %s (driverAPI=%d runtime=%d)\n", cudaGetErrorString(e), dv, rv); return 1; }
  printf("device=%s cc=%d.%d mem=%zuMiB driverAPI=%d runtime=%d\n", p.name, p.major, p.minor, p.totalGlobalMem >> 20, dv, rv);
  float *a, *b, *c;
  cudaMallocManaged(&a, sz); cudaMallocManaged(&b, sz); cudaMallocManaged(&c, sz);
  for (int i = 0; i < n; i++) { a[i] = i * 0.5f; b[i] = 2.0f * i; }
  cudaEvent_t s, t; cudaEventCreate(&s); cudaEventCreate(&t); cudaEventRecord(s);
  add<<<(n + 255) / 256, 256>>>(a, b, c, n);
  cudaEventRecord(t); e = cudaDeviceSynchronize();
  if (e) { printf("ERR kernel: %s\n", cudaGetErrorString(e)); return 2; }
  float ms = 0; cudaEventElapsedTime(&ms, s, t); double maxerr = 0;
  for (int i = 0; i < n; i++) maxerr = fmax(maxerr, fabs(c[i] - 2.5f * i));
  printf("vectorAdd n=%d %s maxerr=%g kernel_ms=%.3f\n", n, maxerr < 1e-3 ? "PASS" : "FAIL", maxerr, ms);
  return maxerr < 1e-3 ? 0 : 3;
}
