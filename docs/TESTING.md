# The EUROCOM-17 test environment

This describes how the board is developed against: what gets built, how the
pieces fit together, and how each of the two targets (the QEMU model and the
real machine) is driven.

Quick start:

    make deps          # host packages (needs sudo); or: make toolchain
    make all           # sources + qemu + u-boot + rootfs + kernel + staging
    make run-linux     # boot it in the model

`make help` lists every target. All paths and versions live in `config.mk`.

## The pieces

| piece | where the source comes from | what it produces |
| --- | --- | --- |
| QEMU fork | `QEMU_SRC` / `QEMU_GIT` branch `e17-linux` | `build/qemu/qemu-system-m68k` with `-M e17` |
| Linux fork | `LINUX_SRC` / `LINUX_GIT` branch `e17-clean` | `build/linux/vmlinux`, `eltec-e17.dtb` |
| U-Boot fork | `UBOOT_SRC` / `UBOOT_GIT` branch `e17-fixes` | `u-boot`, `u-boot.bin`, `u-boot.srec` |
| initramfs | `rootfs/` + BusyBox tarball | `build/rootfs/e17-rootfs.cpio` |
| RMON ROM | `rmon.bin` in this repo | the board's own firmware |

The three forks are not public. Each is resolved by looking at `<NAME>_SRC`
first (the working trees on the development machine, used in place) and falling
back to cloning `<NAME>_GIT`. Builds are always out-of-tree, so pointing at a
working tree does not dirty it.

> `make sources` warns if a working tree has commits its remote does not — a
> fresh clone elsewhere would silently build older code.

### Toolchain

Two options, and the difference matters:

* `make deps` installs Debian's `gcc-m68k-linux-gnu` + `libc6-dev-m68k-cross`.
  This is the full thing and is what BusyBox needs. It requires root.
* `make toolchain` downloads the kernel.org crosstool build into
  `build/toolchain` with no root at all. It has no target libc, so the kernel,
  U-Boot and the nolibc userspace build fine but BusyBox is skipped.

The build scripts put `build/toolchain/bin` on `PATH` automatically.

## The initramfs

`build-rootfs.sh` assembles three things:

* **`/init`** — `rootfs/init.c`, built against the kernel's own nolibc. It
  mounts `/proc`, `/sys` and `/dev`, brings CPU1 online through the hotplug
  sysfs node, prints a banner plus `/proc/interrupts`, and parks PID 1.
  It is a few KB; a static-glibc init pushed the vmlinux ELF past the size
  where U-Boot's `bootelf` load collides with itself on the real board, so
  staying small is functional, not cosmetic.
  Also: **BusyBox aborts with "stack smashing detected" under QEMU system
  emulation** (an emulation artifact — it is fine on real hardware), so the
  default PID 1 deliberately avoids it. `ROOTFS_INIT=busybox` switches to
  `rootfs/init.sh` if you want the shell-script version.
* **`/init-smptest`** — `tests/smpstress.c`, the SMP/hotplug stress harness.
  Boot it with `rdinit=/init-smptest` (`make run-smptest`). It onlines CPU1,
  migrates onto it and checks CPU1 actually accrues time in `/proc/stat`,
  ping-pongs affinity to exercise the IPI paths, cycles hotplug eight times,
  and does a 10 s soak watching for a stalled AP tick or an RCU stall.
* **static device nodes** from `rootfs/dev.list`, appended with the kernel's
  `gen_init_cpio`. These must be baked in: the kernel opens `/dev/console` for
  PID 1 *before* `/init` runs, and without the node PID 1 starts with no stdio
  and the kernel panics with "Attempted to kill init".

## Target 1: the QEMU model

    make run-rmon      # just the monitor, i.e. the board as it ships
    make run-uboot     # RMON + U-Boot via -kernel
    make run-linux     # the kernel via -kernel
    make run-smptest   # ... with rdinit=/init-smptest

Defaults (override in `config.mk` or on the command line): `RAM=32M`, `SMP=2`,
`VIDEO=off`, `NVRAM=build/nvram.img`.

Things worth knowing:

* **`-bios rmon.bin` is always needed**, even with `-kernel`. The 680x0 reset
  SP/PC are read from the ROM file; `-kernel` only loads an ELF and enters it.
* `VIDEO=off` matches our real board (no video fitted) and puts the console on
  serial, so `-nographic` gives one terminal with the QEMU monitor multiplexed
  in (`Ctrl-A c` to switch, `Ctrl-A x` to quit). `VIDEO=on` opens a display
  window with the Bt445 framebuffer and a PS/2 keyboard — RMON is fully
  interactive there.
* `SMP=1` removes the second 68040; RMON then says
  `Secondary CPU : Not installed`. This is also the uniprocessor A/B test for
  the hang investigation (see the README).
* The NVRAM image is a 2 KB M48T02 backing file (`-drive if=mtd`). A blank one
  makes RMON warn about the parameter checksum once, exactly like a board with
  a dead battery. `make nvram` creates one.
* RMON only reads its configuration out of NVRAM when the DIP-switch low nibble
  is 1 or 2; otherwise it uses a ROM profile. In the model:
  `EXTRA='-global e17-sysc.dip-switches=1' make run-rmon`.
* Serial capture for scripted runs: with
  `-serial unix:...,server,nowait` QEMU **drops guest output before the client
  connects**. Use `-serial file:...` or have the client connect and send a byte
  immediately — this is why the driver scripts send a CR first.

## Target 2: the real board

The board netboots. U-Boot's default environment does DHCP and then TFTPs three
files from `${serverip}`:

| file | env var | loaded at |
| --- | --- | --- |
| `vmlinux.e17.stripped.lz4` | `bootfile` | `loadaddr` `0x1000000`, `unlz4`'d to `bootaddr` `0x800000`, then `bootelf` |
| `eltec-e17.dtb` | `fdtfile` | `fdtaddr` `0x1800000` |
| `e17-rootfs.cpio` | `initrd_file` | `initrd_start` `0x1810000` |

RAM map on a 32 MB board:

    0x0000000-0x0700000  kernel image (bootelf copies LOAD segments to phys 0)
    0x0800000-0x1000000  bootaddr: decompressed ELF (temporary)
    0x1000000-0x1800000  loadaddr: the compressed kernel (temporary)
    0x1800000-0x1810000  fdtaddr: the .dtb, patched in place
    0x1810000-...        initrd_start: the initramfs, growing toward U-Boot

`make boot-images` stages exactly those names into `build/tftp`, and
`make tftp` serves that directory (`scripts/tftpd.py`, or `in.tftpd` if
installed). DHCP is not provided — use the lab's, or set a static
`ipaddr`/`serverip` in the U-Boot environment.

`build-rootfs.sh` warns if the initramfs grows past `0x1810000 + size` into
U-Boot's headroom at the top of RAM.

### Getting U-Boot onto a board that has none

RMON can load it over the serial console:

    ***> sload 1 0        <- download on Serial Port 1, offset 0
     Waiting              <- now upload build/u-boot/u-boot.srec as plain text
     Transfer complete
    ***> gm 600000        <- start: SP <- [0x600000], PC <- [0x600004]
    U-Boot ... e17 =>

`gm` consumes a module header, so the S-records must be made from
`u-boot.bin`, not from the ELF (`build-uboot.sh` does this). `sload` uses
XON/XOFF, so upload through something that honours software flow control — a
raw blast overruns it and drops records, which then F-lines in `gm`.

### Talking to the board from here

The board's serial console is bridged to MQTT by smolmqtt's `serial2mqtt`:

    serial2mqtt -b 9600 -c 8N1 /dev/ttyUSB1 <broker> m68k/e17/serial

which publishes what the board says to `m68k/e17/serial/rx` and writes what
you publish to `m68k/e17/serial/tx` out of the port. `scripts/e17con.py` is a
dependency-free MQTT client wrapped around that:

    make console SECS=60                       # watch the console
    make console-cmd CMD='db fec20600 10'      # one RMON command + its reply
    python3 scripts/e17con.py expect 'e17 =>' 120

Broker and topic default to `$E17_BROKER` (192.168.3.2) and `$E17_TOPIC`
(`m68k/e17/serial`).

**Once Linux is up, the serial console is output-only** — nothing typed at it
reaches the shell, because the CD2401 receive path is the very thing under
investigation. `/init` therefore starts BusyBox telnetd, and
`scripts/e17sh.py` is the way in:

    make shell CMD='cat /proc/interrupts'
    python3 scripts/e17sh.py -f commands.txt

`telnetd` blocks until the kernel's CRNG is seeded, which on a 68040 with no
entropy source takes several minutes after boot. A connection that times out
right after boot is that, not a dead network — wait for
`random: crng init done` on the serial console.

### Updating what the board boots

The lab TFTP server cannot be reached directly: this container sits behind a
NAT, and TFTP answers a request from a *new* source port, for which the NAT has
no mapping (ordinary UDP is fine - DNS works - it is the port change that is
fatal). So file transfer goes over MQTT instead, using smolmqtt's file bridge.

In the lab, serving the TFTP root:

    file2mqtt /path/to/tftproot <broker> m68k/e17/file

From here:

    mqttfile <broker> m68k/e17/file list
    mqttfile <broker> m68k/e17/file put build/tftp/vmlinux.e17.stripped.lz4
    mqttfile <broker> m68k/e17/file get vmlinux.e17.stripped.lz4 backup.lz4

A push is written to `<name>.part` and only renamed over the live file once its
size and CRC-32 match, so a half-finished transfer can never leave the board
unbootable. `make push-kernel` does the staged kernel.

### Probing the hardware

`tools/e17probe.py` is a **read-only** RMON probe: it issues only display
commands (`$`, `db`, `dl`) plus a SCSI scan, never writes, never boots, and
skips the CD2401 console and its IACK window so it cannot disturb the serial
link.

    make probe-board PORT=/dev/ttyUSB0 [BAUD=9600]
    make probe-qemu                      # the same commands against the model

It writes a timestamped log; `logs/real-board/` holds the reference runs, and
`tools/e17probe-qemu-reference.txt` is the model's output for the same
commands, so a real-vs-model diff is one `diff` away.

> The probe deliberately does **not** read `0xfec54000`. A plain memory read of
> the I2C/IPIN port stalls the CPU long enough that RMON stops petting the
> watchdog, and the resulting watchdog reset drives VMEbus SYSRESET — it resets
> every board in the crate.

### Dual-CPU mailbox probe

`tools/mboxprobe.py` (+ `tools/cpu2payload.s`, prebuilt as `cpu2mbox.srec`)
loads a tiny DRAM-only payload onto the secondary CPU and talks to it from RMON
through shared memory: it `sload`s the payload, pulses `0xfec58000` to release
CPU2, then exchanges longwords at `0x10100` (command), `0x10104` (response),
`0x10108` (heartbeat) and `0x1010c` (quit). It touches no I/O and no VMEbus, so
it cannot disturb other boards, and it re-parks CPU2 on the way out.

### After a watchdog reset

The kernel keeps a breadcrumb record in battery-backed NVRAM at `0xfec20600`
(see `include/linux/e17_breadcrumb.h` in the kernel tree). It survives the reset
pulse, and the watchdog driver prints it on the next boot: both CPUs'
heartbeats, the PC each was interrupted at, `irq_err_count`, the last unexpected
vector, and which suspect bus region CPU0 was in. That decode is the primary
evidence for the hang investigation described in the README.

## Other tools in `tools/`

* `mke17boot.py` — wraps a raw binary in RMON's 22-byte netboot header
  (magic `0x134FEE73`, RFC 1071 checksums) so RMON's own TFTP bootstrap will
  load and run it. Used for RE payloads, not needed for the U-Boot flow.
* `netserv.py` — a minimal BOOTP+TFTP peer speaking QEMU's `-netdev socket`
  framing, used to drive RMON's *own* netboot in the model while it was being
  reverse-engineered. Not the server for the real board; use `make tftp`.

## Reproducing without the private forks

If you only have this repo, `make run-rmon` still works once QEMU is built —
but QEMU is where the `e17` machine lives, so without that fork there is
nothing to run the ROM on. The ROM, the register documentation in the README
and the tools here are enough to re-derive the model; the forks are a
convenience, not a secret ingredient.
