////////////////////////////////////////////////////////////////////////////////
// BSD 3-Clause License
//
// Copyright (c) 2021, NVIDIA Corporation
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// 3. Neither the name of the copyright holder nor the names of its
//    contributors may be used to endorse or promote products derived from
//    this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
/////////////////////////////////////////////////////////////////////////////////

#include "matx.h"
#include <cassert>
#include <cstdio>
#include <math.h>
#include <memory>

using namespace matx;

/**
 * MatX uses C++ expression templates to build arithmetic expressions that compile into a lazily-evaluated
 * type for executing on the device. Currently, nvcc cannot see certain optimizations
 * when building the expression tree that would be obvious by looking at the code. Specifically any code reusing
 * the same tensor multiple times appears to the compiler as separate tensors, and it may issue multiple load
 * instructions. While caching helps, this can have a slight performance impact when compared to native CUDA
 * kernels. To work around this problem, complex expressions can be placed in a custom operator by adding some
 * boilerplate code around the original expression. This custom operator can then be used either alone or inside
 * other arithmetic expressions, and only a single load is issues for each tensor.
 *
 * This example uses the Black-Scholes equtation to demonstrate three ways to implement the equation in MatX, and
 * shows the performance difference between them. The three ways are:
 * 1. Using a custom operator
 * 2. Using a lambda function via apply()
 * 3. Using a MatX expression
 *
 * Which method to use depends on the use case, but the lambda function is preferred for simplicity and readability.
 */

/* Custom operator */
template <class I1>
class BlackScholes : public BaseOp<BlackScholes<I1>> {
private:
  I1 V_, S_, K_, r_, T_;

public:
  using matxop = bool;

  BlackScholes(I1 K, I1 V, I1 S, I1 r, I1 T)
      : V_(V), S_(S), K_(K), r_(r), T_(T)  {}

  template <detail::ElementsPerThread EPT>
  __MATX_INLINE__ __MATX_HOST__ __MATX_DEVICE__ auto operator()(index_t idx) const
  {
    auto V = V_(idx);
    auto K = K_(idx);
    auto S = S_(idx);
    auto T = T_(idx);
    auto r = r_(idx);

    auto VsqrtT = V * sqrt(T);
    auto d1 = (log(S / K) + (r + 0.5f * V * V) * T) / VsqrtT ;
    auto d2 = d1 - VsqrtT;
    auto cdf_d1 = normcdff(d1); // Note in a custom op we call the CUDA math function directly
    auto cdf_d2 = normcdff(d2);
    auto expRT = exp(-1.f * r * T);

    return S * cdf_d1 - K * expRT * cdf_d2;
  }

  __MATX_INLINE__ __MATX_HOST__ __MATX_DEVICE__  void operator()(index_t idx) {
    return this->operator()<detail::ElementsPerThread::ONE>(idx);
  }

  __MATX_INLINE__ __MATX_HOST__ __MATX_DEVICE__ index_t Size(uint32_t i) const  { return V_.Size(i); }
  static constexpr __MATX_INLINE__ __MATX_HOST__ __MATX_DEVICE__ int32_t Rank() { return I1::Rank(); }

  template <detail::OperatorCapability Cap>
  __MATX_INLINE__ __MATX_HOST__ auto get_capability() const {  
    // Don't support vectorization yet
    if constexpr (Cap == detail::OperatorCapability::ELEMENTS_PER_THREAD) {
      return detail::ElementsPerThread::ONE;
    } else {    
      auto self_has_cap = detail::capability_attributes<Cap>::default_value;
      return detail::combine_capabilities<Cap>(
          self_has_cap,
        detail::get_operator_capability<Cap>(V_),
        detail::get_operator_capability<Cap>(S_),
        detail::get_operator_capability<Cap>(K_),
        detail::get_operator_capability<Cap>(r_),
        detail::get_operator_capability<Cap>(T_)
      );
    }
  }
};

/* Arithmetic expression */
template<typename T1>
void compute_black_scholes_matx(tensor_t<T1,1>& K,
                                tensor_t<T1,1>& S,
                                tensor_t<T1,1>& V,
                                tensor_t<T1,1>& r,
                                tensor_t<T1,1>& T,
                                tensor_t<T1,1>& output,
                                cudaExecutor& exec)
{
    auto VsqrtT = V * sqrt(T);
    auto d1 = (log(S / K) + (r + 0.5f * V * V) * T) / VsqrtT ;
    auto d2 = d1 - VsqrtT;
    auto cdf_d1 = normcdf(d1);
    auto cdf_d2 = normcdf(d2);
    auto expRT = exp(-1.f * r * T);

    (output = S * cdf_d1 - K * expRT * cdf_d2).run(exec);
}

int main([[maybe_unused]] int argc, [[maybe_unused]] char **argv)
{
  MATX_ENTER_HANDLER();

  using dtype = float;

  index_t input_size = 100000000;
  constexpr uint32_t num_iterations = 100;
  float time_ms;

  tensor_t<dtype, 1> K_tensor{{input_size}};
  tensor_t<dtype, 1> S_tensor{{input_size}};
  tensor_t<dtype, 1> V_tensor{{input_size}};
  tensor_t<dtype, 1> r_tensor{{input_size}};
  tensor_t<dtype, 1> T_tensor{{input_size}};
  tensor_t<dtype, 1> output_tensor{{input_size}};
  tensor_t<dtype, 1> output_tensor2{{input_size}};
  tensor_t<dtype, 1> output_tensor3{{input_size}};

  (K_tensor = random<float>({input_size}, UNIFORM)).run();
  (S_tensor = random<float>({input_size}, UNIFORM)).run();
  (V_tensor = random<float>({input_size}, UNIFORM)).run();
  (r_tensor = random<float>({input_size}, UNIFORM)).run();
  (T_tensor = random<float>({input_size}, UNIFORM)).run();

  cudaStream_t stream;
  cudaStreamCreate(&stream);
  cudaExecutor exec{stream};

  //compute_black_scholes_matx(K_tensor, S_tensor, V_tensor, r_tensor, T_tensor, output_tensor, exec);

  cudaEvent_t start, stop;
  cudaEventCreate(&start);
  cudaEventCreate(&stop);

  cudaEventRecord(start, stream);
  // Time non-operator version
  for (uint32_t i = 0; i < num_iterations; i++) {
    compute_black_scholes_matx(K_tensor, S_tensor, V_tensor, r_tensor, T_tensor, output_tensor, exec);
  }
  cudaEventRecord(stop, stream);
  exec.sync();

  cudaEventElapsedTime(&time_ms, start, stop);

  printf("Time without custom operator = %.2fms per iteration\n",
         time_ms / num_iterations);

  cudaEventRecord(start, stream);
  // Time non-operator version
  for (uint32_t i = 0; i < num_iterations; i++) {
    (output_tensor2 = BlackScholes(K_tensor, V_tensor, S_tensor, r_tensor, T_tensor)).run(exec);
  }
  cudaEventRecord(stop, stream);
  exec.sync();

  cudaEventElapsedTime(&time_ms, start, stop);
  printf("Time with custom operator = %.2fms per iteration\n",
    time_ms / num_iterations);

  auto bs_lambda = [] __device__ (auto K,
                                  auto S,
                                  auto V,
                                  auto r,
                                  auto T) {
      auto VsqrtT = V * sqrt(T);
      auto d1 = (log(S / K) + (r + 0.5f * V * V) * T) / VsqrtT ;
      auto d2 = d1 - VsqrtT;
      auto cdf_d1 = normcdf(d1);
      auto cdf_d2 = normcdf(d2);
      auto expRT = exp(-1.f * r * T);
  
      return S * cdf_d1 - K * expRT * cdf_d2; 
  };

  cudaEventRecord(start, stream);
  for (uint32_t i = 0; i < num_iterations; i++) {
    (output_tensor3 = matx::apply(bs_lambda, K_tensor, S_tensor, V_tensor, r_tensor, T_tensor)).run(exec);
  }
  
  cudaEventRecord(stop, stream);
  exec.sync();

  cudaEventElapsedTime(&time_ms, start, stop);
  printf("Time with lambda = %.2fms per iteration\n",
    time_ms / num_iterations);

  // Verify all 3 outputs match within 1e-6 using operator() (Managed Memory)
  bool all_match = true;
  constexpr float tol = 1e-6f;
  auto n = K_tensor.Size(0);

  for (index_t i = 0; i < n; i++) {
    float v1 = output_tensor(i);
    float v2 = output_tensor2(i);
    float v3 = output_tensor3(i);
    if (fabsf(v1 - v2) > tol || fabsf(v1 - v3) > tol || fabsf(v2 - v3) > tol) {
      printf("Mismatch at idx %lld: v1=%.8f v2=%.8f v3=%.8f\n", i, v1, v2, v3);
      all_match = false;
      break;
    }
  }
  if (all_match) {
    printf("All outputs match within %.1e tolerance.\n", tol);
  } else {
    printf("Outputs do NOT match within %.1e tolerance!\n", tol);
  }

  cudaEventDestroy(start);
  cudaEventDestroy(stop);
  cudaStreamDestroy(stream);
  MATX_CUDA_CHECK_LAST_ERROR();
  MATX_EXIT_HANDLER();
}
