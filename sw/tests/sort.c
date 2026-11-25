// Quicksort + CRC32 + struct copies: memory-heavy integer code.
#include "tlib.h"

#define N 3000
static int arr[N];
static unsigned crc_table[256];

struct rec { int key; short s; signed char c; unsigned char u; char name[10]; };
static struct rec recs[64];

static void qs(int *a, int lo, int hi) {
    while (lo < hi) {
        int p = a[(lo + hi) / 2], i = lo, j = hi;
        while (i <= j) {
            while (a[i] < p) i++;
            while (a[j] > p) j--;
            if (i <= j) { int t = a[i]; a[i] = a[j]; a[j] = t; i++; j--; }
        }
        if (j - lo < hi - i) { qs(a, lo, j); lo = i; }
        else { qs(a, i, hi); hi = j; }
    }
}

static unsigned crc32(const unsigned char *p, unsigned n) {
    unsigned c = 0xFFFFFFFFu;
    while (n--) c = crc_table[(c ^ *p++) & 0xFF] ^ (c >> 8);
    return ~c;
}

int test_main(void) {
    for (unsigned i = 0; i < 256; i++) {
        unsigned c = i;
        for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        crc_table[i] = c;
    }
    tprintf("crc32(\"123456789\") = %08x\n", crc32((const unsigned char *)"123456789", 9));

    unsigned s = 1;
    for (int i = 0; i < N; i++) { s = s * 1103515245u + 12345u; arr[i] = (int)(s >> 1) - 0x20000000; }
    qs(arr, 0, N - 1);
    int ok = 1;
    for (int i = 1; i < N; i++) if (arr[i - 1] > arr[i]) ok = 0;
    tprintf("sorted=%d min=%d max=%d crc=%08x\n", ok, arr[0], arr[N - 1],
            crc32((const unsigned char *)arr, sizeof arr));

    for (int i = 0; i < 64; i++) {
        struct rec r = { i * 1000 - 7, (short)(i * -517), (signed char)(i * 37), (unsigned char)(i * 91), "rec" };
        r.name[3] = (char)('A' + (i % 26));
        recs[63 - i] = r;
    }
    struct rec tmp = recs[10];
    recs[10] = recs[20];
    recs[20] = tmp;
    long sum = 0;
    for (int i = 0; i < 64; i++) sum += recs[i].key + recs[i].s + recs[i].c + recs[i].u + recs[i].name[3];
    tprintf("recs sum=%d crc=%08x\n", (int)sum, crc32((const unsigned char *)recs, sizeof recs));
    return ok ? 0 : 1;
}
