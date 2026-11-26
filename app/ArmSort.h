#ifndef ArmSort_h
#define ArmSort_h

#include <stdint.h>

// Stable LSD radix sort of 64-bit keys on Apple M-series NEON.
// `keys` is the full column. `indices` is a subset of positions into `keys`
// and is permuted in place. `descending` is 0 or 1.
void m_series_radix_u64(const uint64_t * _Nonnull keys,
                        uint32_t * _Nonnull indices,
                        uint32_t n,
                        int descending);

#endif
