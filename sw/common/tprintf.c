// Minimal printf: %d %u %x %X %s %c %%, optional '0' flag, width, and 'll'.
#include "tlib.h"

void tputs(const char *s) {
    while (*s) tputc(*s++);
}

static void put_num(unsigned long long v, int base, int neg, int width,
                    char pad, int upper) {
    char buf[24];
    int n = 0;
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    do {
        buf[n++] = digits[v % base];
        v /= base;
    } while (v);
    if (neg) {
        if (pad == '0') { tputc('-'); width--; }
        else buf[n++] = '-';
    }
    while (width-- > n) tputc(pad);
    while (n) tputc(buf[--n]);
}

void tprintf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    for (; *fmt; fmt++) {
        if (*fmt != '%') { tputc(*fmt); continue; }
        fmt++;
        char pad = ' ';
        int width = 0, ll = 0;
        if (*fmt == '0') { pad = '0'; fmt++; }
        while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
        while (*fmt == 'l') { ll++; fmt++; }
        switch (*fmt) {
        case 'd': {
            long long v = ll >= 2 ? va_arg(ap, long long) : va_arg(ap, int);
            int neg = v < 0;
            put_num(neg ? -(unsigned long long)v : (unsigned long long)v, 10, neg, width, pad, 0);
            break;
        }
        case 'u': case 'x': case 'X': {
            unsigned long long v = ll >= 2 ? va_arg(ap, unsigned long long)
                                           : va_arg(ap, unsigned);
            put_num(v, *fmt == 'u' ? 10 : 16, 0, width, pad, *fmt == 'X');
            break;
        }
        case 's': tputs(va_arg(ap, const char *)); break;
        case 'c': tputc((char)va_arg(ap, int)); break;
        case '%': tputc('%'); break;
        default:  tputc('?'); break;
        }
    }
    va_end(ap);
}
