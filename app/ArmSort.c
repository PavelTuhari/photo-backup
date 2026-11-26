#include "ArmSort.h"

#include <arm_neon.h>
#include <stdlib.h>
#include <string.h>

// Eight-bit LSD radix. Each pass extracts the current byte with a NEON
// shift (vshlq_u64) and counts those bytes with NEON loads (vld1q_u8).
// Apple M has no sort instruction; this is the integer SIMD path, compiled
// for the M-series pipeline (-mcpu=apple-m1).

static void extract_digits(const uint64_t *keys,
                           const uint32_t *indices,
                           uint8_t *digits,
                           uint32_t n,
                           int shift,
                           int descending) {
    const int64x2_t sh = vdupq_n_s64(-(int64_t)shift);
    const uint64x2_t mask = vdupq_n_u64(0xFFu);
    uint32_t i = 0;
    for (; i + 1 < n; i += 2) {
        uint64x2_t packed = vdupq_n_u64(0);
        packed = vsetq_lane_u64(keys[indices[i]], packed, 0);
        packed = vsetq_lane_u64(keys[indices[i + 1]], packed, 1);
        uint64x2_t low = vandq_u64(vshlq_u64(packed, sh), mask);
        uint8_t a = (uint8_t)vgetq_lane_u64(low, 0);
        uint8_t b = (uint8_t)vgetq_lane_u64(low, 1);
        if (descending) {
            a = (uint8_t)~a;
            b = (uint8_t)~b;
        }
        digits[i] = a;
        digits[i + 1] = b;
    }
    if (i < n) {
        uint8_t digit = (uint8_t)((keys[indices[i]] >> shift) & 0xFFu);
        digits[i] = descending ? (uint8_t)~digit : digit;
    }
}

static void histogram_digits(const uint8_t *digits, uint32_t n, uint32_t offset[256]) {
    // Sixteen private histograms so a 16-wide NEON load never shares a bucket
    // counter inside one vector. 30k rows / 16 fits in uint32 easily.
    uint32_t lane_hist[16][256];
    memset(lane_hist, 0, sizeof lane_hist);
    uint32_t i = 0;
    for (; i + 16 <= n; i += 16) {
        uint8x16_t chunk = vld1q_u8(digits + i);
        uint8_t lane[16];
        vst1q_u8(lane, chunk);
        for (int lane_index = 0; lane_index < 16; lane_index++) {
            lane_hist[lane_index][lane[lane_index]]++;
        }
    }
    for (; i < n; i++) {
        lane_hist[0][digits[i]]++;
    }

    uint32_t sum = 0;
    for (int bucket = 0; bucket < 256; bucket++) {
        uint32_t count = 0;
        for (int lane = 0; lane < 16; lane++) {
            count += lane_hist[lane][bucket];
        }
        offset[bucket] = sum;
        sum += count;
    }
}

void m_series_radix_u64(const uint64_t *keys, uint32_t *indices, uint32_t n, int descending) {
    if (n < 2 || keys == NULL || indices == NULL) {
        return;
    }
    uint8_t *digits = malloc((size_t)n);
    uint32_t *scratch = malloc((size_t)n * sizeof(uint32_t));
    if (digits == NULL || scratch == NULL) {
        free(digits);
        free(scratch);
        return;
    }

    uint32_t *src = indices;
    uint32_t *dst = scratch;
    for (int shift = 0; shift < 64; shift += 8) {
        extract_digits(keys, src, digits, n, shift, descending);
        uint32_t offset[256];
        histogram_digits(digits, n, offset);
        for (uint32_t i = 0; i < n; i++) {
            dst[offset[digits[i]]++] = src[i];
        }
        uint32_t *swap = src;
        src = dst;
        dst = swap;
    }
    // Eight passes is even, so the permutation is already in `indices`.
    if (src != indices) {
        memcpy(indices, src, (size_t)n * sizeof(uint32_t));
    }
    free(digits);
    free(scratch);
}
