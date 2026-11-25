// Raw cache integrity tests; does not require Android, curl or a network.
#include <assert.h>
#include <stdio.h>
#include "stream/curl_seek_cache.h"

static unsigned char byte_at(uint64_t p)
{
    return (unsigned char)((p * 37) ^ (p >> 8) ^ (p >> 17) ^ (p >> 32) ^ 0xa5);
}

static void put(struct mp_curl_cache *c, uint64_t pos, size_t n)
{
    unsigned char *data = malloc(n ? n : 1);
    assert(data);
    for (size_t i = 0; i < n; i++)
        data[i] = byte_at(pos + i);
    mp_curl_cache_put(c, pos, data, n);
    free(data);
}

static size_t check(struct mp_curl_cache *c, uint64_t pos, size_t n)
{
    unsigned char *data = malloc(n ? n : 1);
    assert(data);
    size_t got = mp_curl_cache_get(c, pos, data, n);
    assert(got <= n);
    for (size_t i = 0; i < got; i++)
        assert(data[i] == byte_at(pos + i));
    free(data);
    return got;
}

int main(void)
{
    struct mp_curl_cache c;
    mp_curl_cache_init(&c, 0);
    put(&c, 0, 32);
    assert(!mp_curl_cache_has(&c, 0));
    assert(check(&c, 0, 32) == 0);
    mp_curl_cache_uninit(&c);

    mp_curl_cache_init(&c, 1);
    put(&c, 10, 1);
    assert(check(&c, 10, 2) == 1);
    put(&c, 11, 1);
    assert(!mp_curl_cache_has(&c, 10));
    assert(check(&c, 11, 2) == 1);
    mp_curl_cache_uninit(&c);

    // Partial writes cannot expose either an unwritten prefix or a hole.
    mp_curl_cache_init(&c, 32);
    put(&c, 8, 4);
    assert(!mp_curl_cache_has(&c, 7));
    assert(check(&c, 8, 16) == 4);
    put(&c, 12, 4);
    assert(check(&c, 8, 32) == 8);
    put(&c, 24, 4);
    assert(!mp_curl_cache_has(&c, 20));
    assert(!mp_curl_cache_has(&c, 8));
    assert(check(&c, 24, 32) == 4);
    put(&c, 22, 6);
    assert(check(&c, 22, 32) == 6);
    mp_curl_cache_uninit(&c);

    // Retain disjoint track windows, with reads affecting the LRU order.
    const size_t block = 256 * 1024;
    mp_curl_cache_init(&c, 2 * block + 31);
    put(&c, 0, block);
    put(&c, 32 * block, block);
    assert(check(&c, 0, block) == block);
    put(&c, 64 * block, block);
    assert(mp_curl_cache_has(&c, 0));
    assert(!mp_curl_cache_has(&c, 32 * block));
    assert(check(&c, 64 * block, block) == block);
    mp_curl_cache_uninit(&c);

    // Split writes at block boundaries and retain full-width file offsets.
    mp_curl_cache_init(&c, 4 * block);
    uint64_t high = (UINT64_C(1) << 40) + block - 11;
    put(&c, high, 53);
    assert(check(&c, high, 53) == 11);
    assert(check(&c, high + 11, 53) == 42);
    assert(!mp_curl_cache_has(&c, high - 1));
    assert(!mp_curl_cache_has(&c, high + 53));
    mp_curl_cache_uninit(&c);

    // Random sparse traffic: every returned byte was initialized and belongs
    // to its requested offset, even after many overlapping writes/evictions.
    const size_t span = 8 * 1024 * 1024;
    unsigned char *written = calloc(span, 1);
    assert(written);
    mp_curl_cache_init(&c, 2 * 1024 * 1024);
    uint32_t random = 0x31415926;
    size_t hits = 0;
    for (int i = 0; i < 20000; i++) {
        random = random * 1664525u + 1013904223u;
        size_t pos = random % (span - 8192);
        random = random * 1664525u + 1013904223u;
        size_t n = random % 8192 + 1;
        put(&c, pos, n);
        memset(written + pos, 1, n);
        assert(check(&c, pos, n) > 0);
        random = random * 1664525u + 1013904223u;
        size_t read = random % (span - 256);
        size_t got = check(&c, read, 256);
        for (size_t j = 0; j < got; j++)
            assert(written[read + j]);
        hits += got > 0;
        size_t allocated = 0;
        for (size_t j = 0; j < c.count; j++)
            allocated += c.blocks[j].data ? c.block_size : 0;
        assert(allocated <= 2 * 1024 * 1024);
    }
    // Sparse disjoint writes conservatively replace a block's valid span, so
    // hit rate is deliberately not a correctness requirement of this test.
    assert(hits > 0);
    free(written);
    mp_curl_cache_uninit(&c);
    puts("HTTP seek cache integrity, holes, LRU, 64-bit offsets and 20000 sparse operations: PASS");
    return 0;
}
