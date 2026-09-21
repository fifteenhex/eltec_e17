#!/bin/busybox sh
/bin/busybox mount -t proc     proc /proc
/bin/busybox mount -t sysfs    sys  /sys
/bin/busybox mount -t devtmpfs dev  /dev
/bin/busybox mkdir -p /dev/pts
/bin/busybox mount -t devpts devpts /dev/pts	# ptys for telnetd
# The kernel could not open /dev/console before exec'ing us (the initramfs /dev
# was empty), so PID 1 started with no stdio and the final shell would hit EOF
# and exit -> "Attempted to kill init".  devtmpfs has now created /dev/console;
# attach our stdin/stdout/stderr to it before running anything interactive.
exec 0</dev/console 1>/dev/console 2>/dev/console
/bin/busybox --install -s /bin
export PATH=/bin:/sbin
export PS1='e17:\w# '
echo
echo "================================================"
echo " ELTEC Eurocom E17 - Linux/m68k with BusyBox"
echo "================================================"
uname -a
echo -n "CPU: "; grep -m1 -i 'cpu\|model' /proc/cpuinfo 2>/dev/null
echo
echo "--- network (eth0, configured by kernel ip=dhcp) ---"
ifconfig eth0
echo "--- /proc/interrupts (is the LANCE IRQ 15 counting?) ---"
cat /proc/interrupts
echo "--- starting telnetd on port 23 (telnet in for a shell) ---"
telnetd -l /bin/sh

# ---------------------------------------------------------------------------
# Bring the SECOND CPU online now that the whole system is up (RCU/scheduler
# fully running) -- unlike the early boot-time smp_init(), which wedged in the
# cpuhp online states.  The kernel log for the AP bring-up appears right here
# on the console (and via 'dmesg' over telnet).
# ---------------------------------------------------------------------------
if [ -e /sys/devices/system/cpu/cpu1/online ] ; then
	echo "--- CPUs online before: $(grep -c ^processor /proc/cpuinfo) ---"
	echo "--- onlining CPU1 (echo 1 > .../cpu1/online) ... ---"
	echo 1 > /sys/devices/system/cpu/cpu1/online
	echo "--- online returned; CPUs now: $(grep -c ^processor /proc/cpuinfo) ---"
	cat /proc/cpuinfo
	dmesg | tail -25
else
	echo "--- no cpu1/online node (CONFIG_HOTPLUG_CPU?) ---"
fi

echo "--- PID 1 alive; telnet in for a shell (console input may be unreliable) ---"
# Do NOT 'exec /bin/sh': /dev/console RX EOFs immediately on this board, so the
# shell would exit and take PID 1 with it ("Attempted to kill init").  Keep PID 1
# alive (so telnetd persists) while still offering a console shell if RX works.
while true ; do
	/bin/sh
	sleep 2
done
