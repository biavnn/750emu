// Integer ALU workout: mul/div, shifts, rotates, 64-bit math, jump tables,
// function pointers, sign extension, recursion. Output is compared against QEMU.
#include "tlib.h"

static unsigned rng = 0x12345678u;
static unsigned xs(void) {
    rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
    return rng;
}

static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

static unsigned rotl(unsigned x, unsigned n) { n &= 31; return (x << n) | (x >> ((32 - n) & 31)); }

static unsigned op_add(unsigned a, unsigned b) { return a + b; }
static unsigned op_sub(unsigned a, unsigned b) { return a - b; }
static unsigned op_xor(unsigned a, unsigned b) { return a ^ b; }
static unsigned op_mul(unsigned a, unsigned b) { return a * b; }
static unsigned (*const ops[4])(unsigned, unsigned) = { op_add, op_sub, op_xor, op_mul };

static __attribute__((noinline)) unsigned jt(unsigned x, unsigned v) {
    switch (x % 13) {
    case 0:  return v + 1;
    case 1:  return v * 3;
    case 2:  return v ^ 0xA5A5A5A5u;
    case 3:  return v >> 3;
    case 4:  return v << 5;
    case 5:  return ~v;
    case 6:  return v - 77;
    case 7:  return rotl(v, 7);
    case 8:  return v | 0x10101010u;
    case 9:  return v & 0x0F0F0F0Fu;
    case 10: return (unsigned)(-(int)v);
    case 11: return v * v;
    default: return v + x;
    }
}

int test_main(void) {
    tprintf("fib(20) = %d\n", fib(20));

    unsigned h = 0;
    long long acc64 = 0;
    for (int i = 0; i < 4000; i++) {
        unsigned a = xs(), b = xs();
        int sa = (int)a, sb = (int)b;
        unsigned d = b | 1;                       // never zero
        int sd = (sb == -1) ? 3 : (sb | 1);       // avoid INT_MIN / -1

        h = h * 31 + a / d;
        h = h * 31 + a % d;
        h = h * 31 + (unsigned)(sa / sd);
        h = h * 31 + (unsigned)(sa % sd);
        h = h * 31 + (unsigned)(((long long)sa * sb) >> 32);
        h = h * 31 + (unsigned)(((unsigned long long)a * b) >> 32);
        h = h * 31 + (a << (b & 31)) + (a >> (b & 31)) + (unsigned)(sa >> (b & 31));
        h = h * 31 + rotl(a, b);
        h = h * 31 + (unsigned)__builtin_clz(a | 1) + (unsigned)__builtin_popcount(b);
        h = h * 31 + (unsigned)(signed char)a + (unsigned)(short)b;
        h = h * 31 + (sa < sb) + 2 * (a < b) + 4 * (sa == sb);
        h = jt(a, h);
        h = ops[b & 3](h, a);

        long long x = ((long long)sa << 20) + sb;
        acc64 += x * 7 - (x >> 3);
        acc64 ^= (long long)((unsigned long long)acc64 >> 13);
        if ((i & 7) == 0 && x != 0) acc64 += acc64 / (x | 1);

        if ((i % 500) == 0) tprintf("  i=%4d h=%08x acc64=%016llx\n", i, h, acc64);
    }
    tprintf("final h=%08x acc64=%lld\n", h, acc64);
    return 0;
}
