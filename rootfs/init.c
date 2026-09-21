/*
 * Production PID-1 for the ELTEC Eurocom E17, built against the kernel's own
 * nolibc (tools/include/nolibc) so it is a few KB instead of ~550 KB of static
 * glibc.  The bloated glibc inits pushed the vmlinux ELF past the size where
 * u-boot's bootelf load collides on the real board (garbage BSS memset), so
 * keeping init tiny matters for the netboot image, not just for elegance.
 *
 * Uses raw syscalls only (no BusyBox), so it runs identically under QEMU and on
 * real hardware -- unlike BusyBox, which aborts with "stack smashing detected"
 * under QEMU system emulation.
 *
 * Responsibilities:
 *   1. mount /proc, /sys, /dev
 *   2. bring the second 68040 (CPU1) online via the hotplug sysfs node
 *   3. print a status banner + /proc/interrupts so both CPUs are visible
 *   4. keep PID 1 alive (park) -- console shows the SMP bring-up dmesg
 */

static void cat(const char *path)
{
	char buf[1024];
	int fd = open(path, O_RDONLY);
	if (fd < 0) {
		write(1, "  <open ", 8); write(1, path, strlen(path));
		write(1, " failed>\n", 9);
		return;
	}
	int n;
	while ((n = read(fd, buf, sizeof(buf))) > 0)
		write(1, buf, n);
	close(fd);
}

static void put(const char *s) { write(1, s, strlen(s)); }

#ifndef TIOCSCTTY
#define TIOCSCTTY 0x540E
#endif

static char *sh_env[] = {
	"HOME=/root",
	"TERM=vt100",
	"PATH=/bin:/sbin:/usr/bin:/usr/sbin",
	"PS1=e17:\\w# ",
	0
};

/* fork+exec argv[0], wait for it.  Returns 0, or -1 if fork is unavailable. */
static int spawn_wait(char *const argv[])
{
	int st, pid = fork();

	if (pid < 0)
		return -1;
	if (pid == 0) {
		execve(argv[0], argv, sh_env);
		_exit(127);
	}
	while (waitpid(pid, &st, 0) != pid)
		;
	return 0;
}

/* fork+exec argv[0] without waiting (for daemons like telnetd).  Returns pid. */
static int spawn_nowait(char *const argv[])
{
	int pid = fork();

	if (pid == 0) {
		execve(argv[0], argv, sh_env);
		_exit(127);
	}
	return pid;
}

/* New session with /dev/console as the controlling terminal (job control). */
static void console_ctty(void)
{
	int fd;

	setsid();
	fd = open("/dev/console", O_RDWR);
	if (fd < 0)
		return;
	dup2(fd, 0);
	dup2(fd, 1);
	dup2(fd, 2);
	if (fd > 2)
		close(fd);
	ioctl(0, TIOCSCTTY, 0);		/* best effort */
}

/* Start an interactive login shell on /dev/console.  Returns its pid, or -1. */
static int spawn_console_shell(void)
{
	int pid = fork();

	if (pid == 0) {
		char *sh[] = { "-sh", 0 };	/* leading '-' => login shell */

		console_ctty();
		execve("/bin/sh", sh, sh_env);
		_exit(127);
	}
	return pid;
}

int main(void)
{
	mount("proc", "/proc", "proc", 0, 0);
	mount("sys", "/sys", "sysfs", 0, 0);
	mount("dev", "/dev", "devtmpfs", 0, 0);
	mkdir("/dev/pts", 0755);
	mount("devpts", "/dev/pts", "devpts", 0, 0);	/* ptys for telnetd */

	put("\n================================================\n");
	put(" ELTEC Eurocom E17 - Linux/m68k SMP (dual 68040)\n");
	put("================================================\n");

	if (access("/sys/devices/system/cpu/cpu1/online", F_OK) == 0) {
		int fd = open("/sys/devices/system/cpu/cpu1/online", O_WRONLY);
		if (fd >= 0) { write(fd, "1\n", 2); close(fd); }
		put("CPU1: onlined\n");
	} else {
		put("CPU1: no hotplug node (CONFIG_HOTPLUG_CPU / maxcpus?)\n");
	}

	put("CPUs online : ");  cat("/sys/devices/system/cpu/online");
	put("CPUs present: ");  cat("/sys/devices/system/cpu/present");
	put("--- /proc/interrupts (ap-tick=CPU1 VIC-clock, ipi-mailbox=CPU1) ---\n");
	cat("/proc/interrupts");

	/* Make BusyBox applets available as /bin/<applet> (best effort). */
	{
		char *iarg[] = { "/bin/busybox", "--install", "-s", "/bin", 0 };

		spawn_wait(iarg);
	}

	/* eth0 is configured by the kernel (ip= boot arg); just show it. */
	put("--- network (eth0, configured by kernel ip= boot arg) ---\n");
	{
		char *ifc[] = { "/bin/busybox", "ifconfig", "eth0", 0 };

		spawn_wait(ifc);
	}

	/* Start telnetd on port 23 (busybox telnetd daemonizes itself). */
	put("--- starting telnetd on port 23 (telnet in for a shell) ---\n");
	{
		char *td[] = { "/bin/busybox", "telnetd", "-l", "/bin/sh", 0 };

		spawn_nowait(td);
	}

	put("--- E17 SMP up; starting shell on /dev/console ---\n\n");

	/*
	 * If fork is unavailable (QEMU's clone emulation), we can't supervise --
	 * just exec the shell directly so there's still a prompt.
	 */
	{
		int shpid = spawn_console_shell();

		if (shpid < 0) {
			char *sh[] = { "-sh", 0 };

			console_ctty();
			execve("/bin/sh", sh, sh_env);
			put("--- exec /bin/sh failed; PID1 parked ---\n");
			for (;;)
				sleep(3600);
		}

		/*
		 * PID 1 is the reaper for the whole system: reap ANY child (telnetd's
		 * reparented session processes end up here), and respawn the console
		 * shell whenever it -- and only it -- exits, so the board never panics
		 * on shell exit and telnetd keeps serving logins.
		 */
		for (;;) {
			int st, w = waitpid(-1, &st, 0);

			if (w < 0) {
				sleep(1);
				continue;
			}
			if (w == shpid) {
				put("\n[init] console shell exited; respawning...\n");
				shpid = spawn_console_shell();
			}
		}
	}
	return 0;
}
