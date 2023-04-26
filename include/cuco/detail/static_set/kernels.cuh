/*
 * Copyright (c) 2022-2023, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#pragma once

#include <cuco/detail/utils.hpp>

#include <cub/block/block_reduce.cuh>

#include <cuda/atomic>

#include <cooperative_groups.h>

namespace cuco {
namespace experimental {
namespace detail {

/**
 * @brief Inserts all elements in the range `[first, first + n)` and returns the number of
 * successful insertions.
 *
 * If multiple elements in `[first, first + n)` compare equal, it is unspecified which
 * element is inserted.
 *
 * @tparam CGSize Number of threads in each CG
 * @tparam BlockSize Number of threads in each block
 * @tparam InputIterator Device accessible input iterator whose `value_type` is
 * convertible to the `value_type` of the data structure
 * @tparam StencilIt Device accessible random access iterator whose value_type is
 * convertible to Predicate's argument type
 * @tparam Predicate Unary predicate callable whose return type must be convertible to `bool`
 * and argument type is convertible from `std::iterator_traits<StencilIt>::value_type`
 * @tparam AtomicT Atomic counter type
 * @tparam Ref Type of non-owning device ref allowing access to storage
 *
 * @param first Beginning of the sequence of input elements
 * @param n Number of input elements
 * @param stencil Beginning of the stencil sequence
 * @param pred Predicate to test on every element in the range `[s, s + n)`
 * @param num_successes Number of successful inserted elements
 * @param ref Non-owning set device ref used to access the slot storage
 */
template <int32_t CGSize,
          int32_t BlockSize,
          typename InputIterator,
          typename StencilIt,
          typename Predicate,
          typename AtomicT,
          typename Ref>
__global__ void insert_if_n(InputIterator first,
                            cuco::detail::index_type n,
                            StencilIt stencil,
                            Predicate pred,
                            AtomicT* num_successes,
                            Ref ref)
{
  using BlockReduce = cub::BlockReduce<typename Ref::size_type, BlockSize>;
  __shared__ typename BlockReduce::TempStorage temp_storage;
  typename Ref::size_type thread_num_successes = 0;

  cuco::detail::index_type const loop_stride = gridDim.x * BlockSize / CGSize;
  cuco::detail::index_type idx               = (BlockSize * blockIdx.x + threadIdx.x) / CGSize;

  while (idx < n) {
    if (pred(*(stencil + idx))) {
      typename Ref::value_type const insert_pair{*(first + idx)};
      if constexpr (CGSize == 1) {
        if (ref.insert(insert_pair)) { thread_num_successes++; };
      } else {
        auto const tile =
          cooperative_groups::tiled_partition<CGSize>(cooperative_groups::this_thread_block());
        if (ref.insert(tile, insert_pair) && tile.thread_rank() == 0) { thread_num_successes++; };
      }
    }
    idx += loop_stride;
  }

  // compute number of successfully inserted elements for each block
  // and atomically add to the grand total
  typename Ref::size_type block_num_successes = BlockReduce(temp_storage).Sum(thread_num_successes);
  if (threadIdx.x == 0) {
    num_successes->fetch_add(block_num_successes, cuda::std::memory_order_relaxed);
  }
}

/**
 * @brief Inserts all elements in the range `[first, first + n)`.
 *
 * If multiple elements in `[first, first + n)` compare equal, it is unspecified which
 * element is inserted.
 *
 * @tparam CGSize Number of threads in each CG
 * @tparam BlockSize Number of threads in each block
 * @tparam InputIterator Device accessible input iterator whose `value_type` is
 * convertible to the `value_type` of the data structure
 * @tparam StencilIt Device accessible random access iterator whose value_type is
 * convertible to Predicate's argument type
 * @tparam Predicate Unary predicate callable whose return type must be convertible to `bool`
 * and argument type is convertible from `std::iterator_traits<StencilIt>::value_type`
 * @tparam Ref Type of non-owning device ref allowing access to storage
 *
 * @param first Beginning of the sequence of input elements
 * @param n Number of input elements
 * @param stencil Beginning of the stencil sequence
 * @param pred Predicate to test on every element in the range `[s, s + n)`
 * @param ref Non-owning set device ref used to access the slot storage
 */
template <int32_t CGSize,
          int32_t BlockSize,
          typename InputIterator,
          typename StencilIt,
          typename Predicate,
          typename Ref>
__global__ void insert_if_n(
  InputIterator first, cuco::detail::index_type n, StencilIt stencil, Predicate pred, Ref ref)
{
  cuco::detail::index_type const loop_stride = gridDim.x * BlockSize / CGSize;
  cuco::detail::index_type idx               = (BlockSize * blockIdx.x + threadIdx.x) / CGSize;

  while (idx < n) {
    if (pred(*(stencil + idx))) {
      typename Ref::value_type const insert_pair{*(first + idx)};
      if constexpr (CGSize == 1) {
        ref.insert(insert_pair);
      } else {
        auto const tile =
          cooperative_groups::tiled_partition<CGSize>(cooperative_groups::this_thread_block());
        ref.insert(tile, insert_pair);
      }
    }
    idx += loop_stride;
  }
}

/**
 * @brief Indicates whether the keys in the range `[first, first + n)` are contained in the data
 * structure.
 *
 * Writes a `bool` to `(output + i)` indicating if the key `*(first + i)` exists in the data
 * structure.
 *
 * @tparam BlockSize The size of the thread block
 * @tparam InputIt Device accessible input iterator
 * @tparam OutputIt Device accessible output iterator assignable from `bool`
 * @tparam Ref Type of non-owning device ref allowing access to storage
 *
 * @param first Beginning of the sequence of keys
 * @param n Number of keys
 * @param output_begin Beginning of the sequence of booleans for the presence of each key
 * @param ref Non-owning set device ref used to access the slot storage
 */
template <int32_t BlockSize, typename InputIt, typename OutputIt, typename Ref>
__global__ void contains(InputIt first, cuco::detail::index_type n, OutputIt output_begin, Ref ref)
{
  namespace cg = cooperative_groups;

  auto const block      = cg::this_thread_block();
  auto const thread_idx = block.thread_rank();

  cuco::detail::index_type const loop_stride = gridDim.x * BlockSize;
  cuco::detail::index_type idx               = BlockSize * blockIdx.x + threadIdx.x;
  __shared__ bool output_buffer[BlockSize];

  while (idx - thread_idx < n) {  // the whole thread block falls into the same iteration
    if (idx < n) {
      auto const key = *(first + idx);
      /*
       * The ld.relaxed.gpu instruction causes L1 to flush more frequently, causing increased sector
       * stores from L2 to global memory. By writing results to shared memory and then synchronizing
       * before writing back to global, we no longer rely on L1, preventing the increase in sector
       * stores from L2 to global and improving performance.
       */
      output_buffer[thread_idx] = ref.contains(key);
    }

    block.sync();
    if (idx < n) { *(output_begin + idx) = output_buffer[thread_idx]; }
    idx += loop_stride;
  }
}

/**
 * @brief Indicates whether the keys in the range `[first, first + n)` are contained in the data
 * structure.
 *
 * Writes a `bool` to `(output + i)` indicating if the key `*(first + i)` exists in the data
 * structure.
 *
 * @tparam CGSize Number of threads in each CG
 * @tparam BlockSize The size of the thread block
 * @tparam InputIt Device accessible input iterator
 * @tparam OutputIt Device accessible output iterator assignable from `bool`
 * @tparam Ref Type of non-owning device ref allowing access to storage
 *
 * @param first Beginning of the sequence of keys
 * @param n Number of keys
 * @param output_begin Beginning of the sequence of booleans for the presence of each key
 * @param ref Non-owning set device ref used to access the slot storage
 */
template <int32_t CGSize, int32_t BlockSize, typename InputIt, typename OutputIt, typename Ref>
__global__ void contains(InputIt first, cuco::detail::index_type n, OutputIt output_begin, Ref ref)
{
  namespace cg = cooperative_groups;

  auto block            = cg::this_thread_block();
  auto const thread_idx = block.thread_rank();

  auto tile                                  = cg::tiled_partition<CGSize>(cg::this_thread_block());
  cuco::detail::index_type const loop_stride = gridDim.x * BlockSize / CGSize;
  cuco::detail::index_type idx               = (BlockSize * blockIdx.x + threadIdx.x) / CGSize;

  __shared__ bool output_buffer[BlockSize / CGSize];
  auto const tile_idx = thread_idx / CGSize;

  while (idx - thread_idx < n) {  // the whole thread block falls into the same iteration
    if (idx < n) {
      auto const key   = *(first + idx);
      auto const found = ref.contains(tile, key);
      /*
       * The ld.relaxed.gpu instruction causes L1 to flush more frequently, causing increased sector
       * stores from L2 to global memory. By writing results to shared memory and then synchronizing
       * before writing back to global, we no longer rely on L1, preventing the increase in sector
       * stores from L2 to global and improving performance.
       */
      if (tile.thread_rank() == 0) { output_buffer[tile_idx] = found; }
    }

    block.sync();
    if (idx < n and tile.thread_rank() == 0) { *(output_begin + idx) = output_buffer[tile_idx]; }
    idx += loop_stride;
  }
}

/**
 * @brief Finds the equivalent set elements of all keys in the range `[first, last)`.
 *
 * If the key `*(first + i)` has a match in the set, copies its matched element to `(output_begin +
 * i)`. Else, copies the empty value sentinel. Uses the CUDA Cooperative Groups API to leverage
 * groups of multiple threads to find each key. This provides a significant boost in throughput
 * compared to the non Cooperative Group `find` at moderate to high load factors.
 *
 * @tparam CGSize Number of threads in each CG
 * @tparam BlockSize The size of the thread block
 * @tparam InputIt Device accessible input iterator
 * @tparam OutputIt Device accessible output iterator assignable from the set's `value_type`
 * @tparam Ref Type of non-owning device ref allowing access to storage
 *
 *
 * @param first Beginning of the sequence of keys
 * @param n Number of keys to query
 * @param output_begin Beginning of the sequence of matched elements retrieved for each key
 * @param ref Non-owning set device ref used to access the slot storage
 */
template <int32_t CGSize, int32_t BlockSize, typename InputIt, typename OutputIt, typename Ref>
__global__ void find(InputIt first, cuco::detail::index_type n, OutputIt output_begin, Ref ref)
{
  namespace cg = cooperative_groups;

  auto const block      = cg::this_thread_block();
  auto const thread_idx = block.thread_rank();

  cuco::detail::index_type const loop_stride = gridDim.x * BlockSize / CGSize;
  cuco::detail::index_type idx               = (BlockSize * blockIdx.x + threadIdx.x) / CGSize;
  __shared__ typename Ref::value_type output_buffer[BlockSize / CGSize];

  while (idx - thread_idx < n) {  // the whole thread block falls into the same iteration
    if (idx < n) {
      auto const key = *(first + idx);
      if constexpr (CGSize == 1) {
        auto const found = ref.find(key);
        /*
         * The ld.relaxed.gpu instruction causes L1 to flush more frequently, causing increased
         * sector stores from L2 to global memory. By writing results to shared memory and then
         * synchronizing before writing back to global, we no longer rely on L1, preventing the
         * increase in sector stores from L2 to global and improving performance.
         */
        output_buffer[thread_idx] = found == ref.end() ? ref.empty_key_sentinel() : *found;
        block.sync();
        *(output_begin + idx) = output_buffer[thread_idx];
      } else {
        auto const tile  = cg::tiled_partition<CGSize>(block);
        auto const found = ref.find(tile, key);

        if (tile.thread_rank() == 0) {
          *(output_begin + idx) = found == ref.end() ? ref.empty_key_sentinel() : *found;
        }
      }
    }
    idx += loop_stride;
  }
}

/**
 * @brief Calculates the number of filled slots for the given window storage.
 *
 * @tparam BlockSize Number of threads in each block
 * @tparam StorageRef Type of non-owning ref allowing access to storage
 * @tparam AtomicT Atomic counter type
 *
 * @param storage Non-owning device ref used to access the slot storage
 * @param empty_sentinel Sentinel indicating empty slots
 * @param count Number of filled slots
 */
template <int32_t BlockSize, typename StorageRef, typename AtomicT>
__global__ void size(StorageRef storage,
                     typename StorageRef::value_type empty_sentinel,
                     AtomicT* count)
{
  using size_type = typename StorageRef::size_type;

  cuco::detail::index_type const loop_stride = gridDim.x * BlockSize;
  cuco::detail::index_type idx               = BlockSize * blockIdx.x + threadIdx.x;

  size_type thread_count = 0;
  auto const n           = storage.num_windows();

  while (idx < n) {
    auto const window = storage[idx];
#pragma unroll
    for (auto const& it : window) {
      thread_count += static_cast<size_type>(not cuco::detail::bitwise_compare(it, empty_sentinel));
    }
    idx += loop_stride;
  }

  using BlockReduce = cub::BlockReduce<size_type, BlockSize>;
  __shared__ typename BlockReduce::TempStorage temp_storage;
  size_type const block_count = BlockReduce(temp_storage).Sum(thread_count);
  if (threadIdx.x == 0) { count->fetch_add(block_count, cuda::std::memory_order_relaxed); }
}

}  // namespace detail
}  // namespace experimental
}  // namespace cuco