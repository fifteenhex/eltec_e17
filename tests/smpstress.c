/*
 * E17 SMP / CPU-hotplug stress harness, built against the kernel's nolibc
 * (tiny, no glibc bloat).  QEMU test tool: boot with rdinit=/init-smptest.
 *
 *   1. online cpu1, verify online mask
 *   2. migrate self to cpu1, busy-loop, confirm cpu1 accrues /proc/stat time
 *      (proves the AP executes scheduled userspace work with a real tick)
 *   3. IPI ping-pong: flip affinity cpu0<->cpu1 many times
 *   4. hotplug online/offline cycles
 *   5. long soak on cpu1 (watch for RCU stalls)
 */
#include <asm/unistd.h>

#define CLOCK_MONOTONIC 1

static void put(const char *s) { write(1, s, strlen(s)); }

static void outnum(long v)
{
	char b[24]; int i = sizeof(b); int neg = v < 0;
	unsigned long u = neg ? -v : v;
	b[--i] = 0;
	if (!u) b[--i] = '0';
	while (u) { b[--i] = '0' + u % 10; u /= 10; }
	if (neg) b[--i] = '-';
	put(&b[i]);
}

static void cat(const char *path)
{
	char buf[1024];
	int fd = open(path, O_RDONLY);
	put("--- "); put(path); put(" ---\n");
	if (fd < 0) { put("  <open failed>\n"); return; }
	int n;
	while ((n = read(fd, buf, sizeof(buf))) > 0)
		write(1, buf, n);
	close(fd);
}

static void trimcat(const char *label, const char *path)
{
	char buf[128];
	int fd = open(path, O_RDONLY);
	put(label);
	if (fd < 0) { put("<open failed>\n"); return; }
	int n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0) { put("<empty>\n"); return; }
	buf[n] = 0; write(1, buf, n);
	if (buf[n - 1] != '\n') put("\n");
}

static int writestr(const char *path, const char *val)
{
	int fd = open(path, O_WRONLY);
	if (fd < 0) return -1;
	int n = write(fd, val, strlen(val));
	close(fd);
	return n;
}

/* tiny substring search (avoid relying on nolibc having strstr) */
static char *find(char *hay, const char *needle)
{
	int nl = strlen(needle);
	for (char *p = hay; *p; p++) {
		int i = 0;
		while (i < nl && p[i] == needle[i]) i++;
		if (i == nl) return p;
	}
	return 0;
}

/* sum user+nice+system jiffies from the "cpuN " line of /proc/stat */
static long cpu_busy_jiffies(const char *prefix)
{
	char buf[4096];
	int fd = open("/proc/stat", O_RDONLY);
	if (fd < 0) return -1;
	int n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0) return -1;
	buf[n] = 0;
	char *p = find(buf, prefix);
	if (!p) return -1;
	p += strlen(prefix);
	long sum = 0, val = 0; int innum = 0, fields = 0;
	while (*p && *p != '\n') {
		if (*p >= '0' && *p <= '9') { val = val * 10 + (*p - '0'); innum = 1; }
		else if (innum) { fields++; if (fields <= 3) sum += val; val = 0; innum = 0; }
		p++;
	}
	if (innum) { fields++; if (fields <= 3) sum += val; }
	return sum;
}

static int pin_to(int cpu)
{
	unsigned long mask = 1UL << cpu;
	return __sysret(__nolibc_syscall3(__NR_sched_setaffinity, 0,
					  sizeof(mask), (long)&mask));
}

static long mono_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec;
}

static void busy_for(int seconds)
{
	long start = mono_s();
	volatile unsigned long x = 0;
	while (mono_s() - start < seconds)
		for (int i = 0; i < 200000; i++) x += i;
}

int main(void)
{
	mount("proc", "/proc", "proc", 0, 0);
	mount("sys", "/sys", "sysfs", 0, 0);
	mount("dev", "/dev", "devtmpfs", 0, 0);

	put("\n=== E17 SMP stress init (nolibc) ===\n");
	trimcat("possible: ", "/sys/devices/system/cpu/possible");
	trimcat("present : ", "/sys/devices/system/cpu/present");
	trimcat("online  : ", "/sys/devices/system/cpu/online");

	if (access("/sys/devices/system/cpu/cpu1/online", F_OK) != 0) {
		put("!!! cpu1/online MISSING\n");
		goto park;
	}

	put("\n--- [1] onlining cpu1 ---\n");
	writestr("/sys/devices/system/cpu/cpu1/online", "1\n");
	trimcat("online  : ", "/sys/devices/system/cpu/online");

	put("\n--- [2] migrate to cpu1, busy-loop 4s ---\n");
	long b0 = cpu_busy_jiffies("cpu1 ");
	if (pin_to(1) != 0) put("  !! setaffinity(cpu1) failed\n");
	busy_for(4);
	long b1 = cpu_busy_jiffies("cpu1 ");
	pin_to(0);
	put("  delta cpu1 = "); outnum(b1 - b0);
	put(b1 - b0 > 10 ? "  => AP RAN WORK :)\n" : "  => AP did NOT run work !!\n");

	put("\n--- [2b] /proc/interrupts ---\n");
	cat("/proc/interrupts");

	put("\n--- [3] IPI ping-pong x300 (affinity flips) ---\n");
	for (int i = 0; i < 300; i++) {
		pin_to(i & 1);
		volatile unsigned long x = 0;
		for (int j = 0; j < 20000; j++) x += j;
	}
	pin_to(0);
	put("  ping-pong done (no hang => migration/reschedule IPIs OK)\n");

	put("\n--- [4] hotplug cycle x8 ---\n");
	for (int i = 0; i < 8; i++) {
		writestr("/sys/devices/system/cpu/cpu1/online", "0\n");
		writestr("/sys/devices/system/cpu/cpu1/online", "1\n");
		put("  cycle "); outnum(i); put(" ");
		trimcat("online: ", "/sys/devices/system/cpu/online");
	}

	put("\n--- [5] long soak on cpu1 (10s) ---\n");
	writestr("/sys/devices/system/cpu/cpu1/online", "1\n");
	long c0 = cpu_busy_jiffies("cpu1 ");
	pin_to(1);
	busy_for(10);
	long c1 = cpu_busy_jiffies("cpu1 ");
	pin_to(0);
	put("  delta cpu1 over 10s = "); outnum(c1 - c0);
	put(c1 - c0 > 200 ? "  => AP ticking steadily :)\n" : "  => AP tick STALLED !!\n");

	put("\n--- [5b] /proc/interrupts (final) ---\n");
	cat("/proc/interrupts");
	put("\n=== stress complete ===\n");
park:
	put("=== parking PID1 ===\n");
	for (;;) sleep(3600);
	return 0;
}
