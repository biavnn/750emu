// The whole of user space: a static program with no C library and no
// floating point. It proves the kernel can run a process, take system calls
// and keep time, then powers the machine off.
typedef unsigned long ulong;

static long sys(long nr, long a, long b, long c, long d)
{
	register long r0 __asm__("r0") = nr;
	register long r3 __asm__("r3") = a;
	register long r4 __asm__("r4") = b;
	register long r5 __asm__("r5") = c;
	register long r6 __asm__("r6") = d;
	__asm__ volatile("sc; bns+ 1f; neg 3,3; 1:"
			 : "+r"(r0), "+r"(r3), "+r"(r4), "+r"(r5), "+r"(r6)
			 : : "r7", "r8", "r9", "r10", "r11", "r12", "cr0", "ctr", "xer", "memory");
	return r3;
}

static ulong slen(const char *s) { ulong n = 0; while (s[n]) n++; return n; }
static void put(const char *s) { sys(4, 1, (long)s, (long)slen(s), 0); }

static void putn(ulong v)
{
	char b[12]; int i = 11;
	b[i] = 0;
	do { b[--i] = (char)('0' + v % 10); v /= 10; } while (v);
	put(b + i);
}

struct utsname { char f[6][65]; };
struct timespec { long long sec, nsec; };	/* 64-bit time_t system calls */

static void msleep(long ms)
{
	struct timespec ts = { 0, ms * 1000000LL };
	if (sys(407, 1, 0, (long)&ts, 0) != 0)		/* clock_nanosleep_time64(CLOCK_MONOTONIC) */
		put("init: sleep failed\n");
}

void _start(void)
{
	static struct utsname u;
	struct timespec t0, t1;

	put("\ninit: hello from user space\n");
	if (sys(122, (long)&u, 0, 0, 0) == 0) {
		put("init: Linux "); put(u.f[2]); put(" on "); put(u.f[4]); put("\n");
	}
	put("init: pid "); putn((ulong)sys(20, 0, 0, 0, 0)); put("\n");

	sys(403, 1, (long)&t0, 0, 0);			/* clock_gettime64(CLOCK_MONOTONIC) */
	for (int i = 1; i <= 3; i++) {
		msleep(30);
		put("init: tick "); putn((ulong)i); put("\n");
	}
	sys(403, 1, (long)&t1, 0, 0);
	put("init: slept at least 90 ms: ");
	put(((t1.sec - t0.sec) * 1000 + (t1.nsec - t0.nsec) / 1000000) >= 90 ? "yes" : "no");
	put("\n<<EXIT 0>>\n");

	/* the polled UART drains a few characters per timer tick: let it finish */
	msleep(500);
	sys(88, 0xfee1dead, 672274793, 0x4321fedc, 0);	/* reboot(POWER_OFF) */
	for (;;) ;
}
