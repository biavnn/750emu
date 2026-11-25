// Compiled floating-point code: series, Newton iterations, single and double
// precision, int <-> FP conversions, comparisons. Results are printed as raw
// bit patterns so both builds must agree exactly.
#include "tlib.h"

const int tlib_fp = 1;

static unsigned long long bits(double d) { union { double d; unsigned long long u; } v = { d }; return v.u; }
static unsigned fbits(float f) { union { float f; unsigned u; } v = { f }; return v.u; }

static double my_sqrt(double x) {
    double r = x > 1.0 ? x * 0.5 : 1.0;
    for (int i = 0; i < 60; i++) r = 0.5 * (r + x / r);
    return r;
}

static double my_exp(double x) {
    double term = 1.0, sum = 1.0;
    for (int n = 1; n < 40; n++) { term *= x / n; sum += term; }
    return sum;
}

static double atan_series(double x) {     // |x| < 1
    double x2 = x * x, p = x, s = 0.0;
    for (int k = 0; k < 60; k++) { s += (k & 1 ? -p : p) / (2 * k + 1); p *= x2; }
    return s;
}

static volatile double vd = 1e300;
static volatile float vf = 3.0e38f;

int test_main(void) {
    tlib_enable_fp();

    double pi = 16.0 * atan_series(1.0 / 5.0) - 4.0 * atan_series(1.0 / 239.0);
    tprintf("pi      %016llx  ~%d/1e6\n", bits(pi), (int)(pi * 1e6));
    tprintf("e       %016llx  ~%d/1e6\n", bits(my_exp(1.0)), (int)(my_exp(1.0) * 1e6));
    tprintf("sqrt2   %016llx  ~%d/1e6\n", bits(my_sqrt(2.0)), (int)(my_sqrt(2.0) * 1e6));
    tprintf("exp(-7) %016llx\n", bits(my_exp(-7.25)));

    float fs = 0.0f;
    double ds = 0.0;
    for (int i = 1; i <= 2000; i++) { fs += 1.0f / (float)i; ds += 1.0 / i; }
    tprintf("harmonic float %08x double %016llx\n", fbits(fs), bits(ds));

    double poly = 0.0;
    for (int i = 0; i < 50; i++) poly = poly * 0.731 + (i % 7) - 3.25;
    tprintf("poly    %016llx\n", bits(poly));

    unsigned h = 0;
    int lt = 0, eq = 0, gt = 0;
    double x = 0.1;
    for (int i = -300; i < 300; i++) {
        double y = (double)i * 1.37 - x;
        float f = (float)(y * y * 1e-3);
        unsigned u = (unsigned)(y < 0 ? -y : y);
        long long q = (long long)(y * 1024.0);
        h = h * 31 + (unsigned)(int)y + u + (unsigned)q + fbits(f);
        x = x * 1.0000001 + (double)u * 1e-9 + (double)(unsigned)(i * i);
        if (y < x) lt++; else if (y == x) eq++; else gt++;
    }
    tprintf("conversions h=%08x lt=%d eq=%d gt=%d x=%016llx\n", h, lt, eq, gt, bits(x));

    double big = vd * vd, tiny = 1.0 / vd / vd, nan = big - big;
    float fbig = vf * vf;
    tprintf("overflow %016llx underflow %016llx nan %016llx float inf %08x\n", bits(big), bits(tiny), bits(nan), fbits(fbig));
    tprintf("nan compares: %d %d %d\n", nan == nan, nan < 1.0, nan != nan);
    return 0;
}
