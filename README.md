# ELTEC EUROCOM-17

Reverse-engineering notes, firmware dumps and hardware documentation for the
**ELTEC EUROCOM-17** (E17) — a 6U VMEbus single-board computer with one or two
MC68040 (or MC68060) CPUs, built by ELTEC Elektronik GmbH, Mainz.

Everything below was established by disassembling the RMON boot ROM, driving
the real board, modelling it in QEMU, and cross-checking against the
EUROCOM-17-5xx programmer's reference (which ships inside the EUROCOM-27
hardware manual — the two boards share a manual, a monitor ROM and most of the
chipset).

Provenance is marked where it matters:

| tag | meaning |
| --- | --- |
| `[MAN]` | stated in the EUROCOM-17-5xx hardware manual |
| `[RE]`  | derived from disassembling RMON / VxWorks, or from the QEMU model |
| `[HW]`  | measured on the real board (serial 187562, rev 1.M, dual 68040) |

## Contents of this repo

    rmon.bin    RMON 3.1.3 boot ROM, dumped from the board (1 MB = 256 KB x4)
    README.md   this file

## The board

RMON banner from the real machine:

```
         **********   RMON   **********

               Version : 3.1.3 (27) for the Eurocom 17 - 68040
         Creation date : 02apr97

Copyright (c) 1994-96 by ELTEC Elektronik GmbH, Mainz

        Board Revision : 1.M
         Serial Number : 187562
         RAM available : 32 MBytes
         Secondary CPU : Not installed

Extended slave address : 0x80000000  256 MByte
          ICF1 address : 0x8000

      Ethernet address : 00:00:xx:xx:xx:xx
```

(The unit actually used for the SMP work reports `Secondary CPU : Installed` —
it is a genuine dual-68040 board.)

### Chipset

| function | part | notes |
| --- | --- | --- |
| CPU | 1-2x MC68040 or MC68060 | sockets are *not* symmetric, see "Dual CPU" |
| VMEbus / interrupts | Cypress **VIC068A** | also the on-board interrupt controller and tick timer |
| memory / chip select | ELTEC **IOC-2** gate array | `[MAN]` |
| serial | Cirrus Logic **CL-CD2401** ("MPC") | 4 channels; ch 1-2 RS232 |
| ethernet | AMD **Am79C900 ILACC** | 32-bit init block/descriptors — *not* a plain LANCE |
| SCSI | NCR **53C720** | second-generation SCRIPTS register map |
| timers / GPIO | 2x Zilog **Z8536 CIO** | "System CIO" and "User CIO" |
| RTC / NVRAM | **MK48T12** timekeeper (MK48T18 / DS1644 alternates) | M48T02-compatible layout |
| video | **Bt445** CLUT/RAMDAC + **LM1882** sync generator + address generator | optional; not fitted on our board |
| keyboard | discrete PS/2-style controller (data + status reg) | raw AT scan code set 2 |
| board identity | 512x8 serial EEPROM ("Revision EEPROM"/IPIN) on an I2C-ish port | serial number, MAC |

## Address map `[MAN]` (Table 26)

    $0000.0000-$0FBF.FFFF  Local RAM (cacheable, burstable)
    $0FC0.0000-$0FCF.FFFF  Video RAM      (RMON clears this and the overlay,
    $0FE0.0000-$0FEF.FFFF  Overlay RAM     which is why RE first read it as "2 MB of VRAM")
    $1000.0000-$1FBF.FFFF  Local RAM, MIRRORED AND NON-CACHEABLE
    $1FC0.0000-$1FCF.FFFF  Video RAM (mirrored, non-cacheable)
    $1FE0.0000-$1FEF.FFFF  Overlay RAM (mirrored, non-cacheable)
    $2000.0000-$FE3F.FFFF  VMEbus extended I/O (A32)
    $FE40.0000-$FE7F.FFFF  LEB (local expansion bus)
    $FE80.0000-$FE9F.FFFF  Flash EPROM   <- RMON lives here, also mapped at 0 out of reset
    $FEA0.0000-$FEBF.FFFF  User EPROM    <- battery SRAM / VxWorks boot ROM socket
    $FEC0.0000-$FECF.FFFF  Local I/O
    $FF00.0000-$FFFE.FFFF  VMEbus standard I/O (A24)
    $FFFF.0000-$FFFF.FFFF  VMEbus short I/O (A16)

The **`$1000.0000` uncached DRAM alias is load-bearing for SMP**: OR-ing
`0x10000000` into any DRAM physical address reaches the same memory with caching
inhibited, from either CPU, regardless of cache state. That is how the AP boot
descriptor and the cross-CPU handshakes are passed without cache maintenance.

DRAM is *mirrored* across the decode window — RMON sizes memory by writing a
pattern at 0 and watching for the wrap. (A model that lets the probe run off
the end of RAM makes RMON report "65535 MBytes" and then boot garbage.)

RMON sets `DTT0=0xfe01a040`, `DTT1=0xfe018040`: `0xfe000000-0xffffffff`
transparently translated, uncached/serialised.

## Local I/O map `[MAN]` (Table 27)

    $FEC0.0000-$FEC0.7FFF  VIC068A                      byte    r/w
    $FEC0.8000-$FEC0.FFFF  VMEbus decoder               lword   w
    $FEC1.0000-$FEC1.FFFF  User CIO (Z8536)             byte    r/w
    $FEC2.0000-$FEC2.FFFF  NVRAM / RTC                  byte    r/w
    $FEC3.0000-$FEC3.FFFF  System CIO (Z8536)           byte    r/w
    $FEC4.0000-$FEC4.FFFF  Video controller             lword   r/w
    $FEC5.0000-$FEC5.3FFF  Watchdog trigger             byte    w
    $FEC5.4000-$FEC5.7FFF  Revision EEPROM / IRQ ctrl   byte    r
    $FEC5.8000-$FEC5.BFFF  Secondary CPU control        byte    r/w
    $FEC5.C000-$FEC5.DFFF  Enable slave select (ESR)    byte    w
    $FEC5.E000-$FEC5.FFFF  Snoop control register       byte    w
    $FEC6.0000-$FEC6.3FFF  Keyboard controller          byte    r/w
    $FEC6.4000-$FEC6.7FFF  Serial I/O (CD2401)          byte    r/w
    $FEC6.8000-$FEC6.BFFF  ILACC ethernet               lword   r/w
    $FEC6.C000-$FEC6.FFFF  SCSI controller              lword   r/w
    $FEC7.0000-$FEC7.FFFF  IOC-2 (chip select / memory) lword   r/w

Each device is decoded across its whole 16/32 KB window, so the "extra"
addresses RMON uses (`$FEC0.1000` for the VIC, `$FEC2.7FF8` for the clock,
`$FEC6.6000` for the CD2401 IACK window) are aliases, not separate devices.

### Per-device detail

**VIC068A — `$FEC0.0000` (aliased at `$FEC0.1000`)** `[RE]`
Registers are byte-wide on **byte lane 3** of 32-bit words: VIC register *n*
lives at byte offset `n*4+3`. So LICR1..LICR7 (regs 9..15) are at
`0x27,0x2b,0x2f,0x33,0x37,0x3b,0x3f`, LIVBR (reg 21) at `0x57`, ICMSICR at
`0x47`, ICMSIVBR at `0x53`, ICFSR at `0x5f`, SSCR0 at `0xc3`.
On the real board this is a live register file — a model that returns zeros is
wrong. NVRAM bytes `0x00-0x1f` hold the (value, offset) pairs RMON replays into
the VIC at boot, and comparing those against the live registers shows RMON
post-processes some of them (see below).
A full dump as RMON leaves it is in
`logs/real-board/session-20260921-registers.txt`; the load-bearing values
`[HW]`: `LIVBR = 0x40`, `LICR2 = 0x37`, every other `LICRn = 0x88` (masked),
`SSCR0 = 0xd2`.

**User CIO — `$FEC1.0000`**, **System CIO — `$FEC3.0000`** (Z8536) `[MAN]`+`[RE]`
Standard hookup: `+3` control (indexed, pointer/data flip-flop), `+2` port A,
`+1` port B, `+0` port C. On the **System CIO**:
* port C (`+0`) drives the front-panel hex/POST display,
* port B (`+1`) reads the configuration DIP switches,
* port A bit 7 (`+2`) reads the **watchdog-reset indicator** (0 = last reset
  was a watchdog reset),
* CT1/CT2 can be linked into a free-running 32-bit counter — Linux uses it as
  the clocksource; RCC latches the count for readback.
The User CIO is the manual's "parallel port" and carries CT3.
CIO PCLK is 2.5 MHz `[RE]` (VxWorks programmed TC 41666 for 60 Hz).
Reset protocol matters: pointer `0x00`, data `0x01` (MICR RESET), then a *bare*
`0x00` that the chip must route to MICR — get that wrong and every subsequent
pointer/data pair desyncs.

**NVRAM / RTC — `$FEC2.0000`** `[RE]`+`[HW]`
Byte-wide battery-backed SRAM with the clock in the last 8 bytes of the device
(`$FEC2.07F8` on a 2 KB part, mirrored at `$FEC2.7FF8`):
`ctl, sec, min, hour, dow, date, month, year`, all BCD; control bit `0x40` =
READ latch, `0x80` = WRITE latch. `[HW]` confirmed: `00 38 40 12 03 21 07 26`
= 2026-07-21 12:40:38. The year register counts from 1970 (Linux's `m48t59`
driver agrees with the raw BCD read).

> `[HW]` On our board the clock runs ten days slow (it read 2026-09-11 on
> 2026-09-21) while the NVRAM contents are perfectly intact, so the battery is
> fine and the oscillator is losing time — probably while powered down.

Contents layout:

    0x000-0x01f  VIC068A init (value, offset) pairs replayed by RMON
    0x000-0x5fb  system configuration block (mirror of DRAM 0x800)
    0x468        board ID block (see below)
    0x5fc-0x5ff  inverted 32-bit checksum of the config block
    0x700        OS-9 bootstrap parameter block (16 B, sum at +0x70e)
    0x7f8        clock registers

Board ID block as read from the real board `[HW]`:

    +468  "1MA54700"            order / part number
    +470  "187562"              serial number (matches the banner)
    +476  02 fc                 type/rev word
    +478  "V-E17.-A547"         board type string
    +48a  00 00 5B 00 49 62     ethernet address (ELTEC OUI 00:00:5B)

**Watchdog — `$FEC5.0000`** `[MAN]`
A single write-triggered register. **The first write arms it**; after that it
must be written every 100 ms (min 70, max 140) or 1.6 s ±30% — jumper selected
— or it fires a reset pulse. After any reset the watchdog is disabled again.
A watchdog reset lights the left decimal point of the front-panel hex display
and is readable as System CIO PA7 = 0; writing `$FEC5.0000` clears the
indicator, as do power-up, the reset switch, VMEbus SYSRESET and a VIC remote
reset. In practice PA7 is only useful very early: RMON pets the watchdog, which
clears the indicator, so by the time you can read it from the monitor prompt it
says nothing `[HW]`. The kernel latches the answer at boot instead.

> A watchdog reset drives **VMEbus SYSRESET** — it resets *every board in the
> crate*, not just this one.

**IRQ control — `$FEC5.4001`** `[MAN]` (Table 37)
Routes the System CIO (`SCIO`), User CIO (`UCIO`) and the video frame
interrupt (`FR`) to either LIRQ6 (default, self-vectored daisy chain) or LIRQ4
(VIC-vectored). The CD2401 is always on LIRQ6.

**Secondary CPU control (CPU2CON) — `$FEC5.8000`**, **Snoop control (SNCR) —
`$FEC5.E000`**: see "Dual CPU" below.

**Keyboard — `$FEC6.0000`** `[MAN]`+`[RE]`
`+0` data, `+1` control/status. Status bit 0 = interface ready, bit 1 = receive
buffer full. No 8042 command port and no translation: the keyboard talks raw AT
**scan code set 2** with `F0` break prefixes. RMON's probe writes `0xFF` and
waits for `0xAA` (BAT OK), tolerating a leading `0xFA`. IRQ on VIC LIRQ1.

**CD2401 serial — `$FEC6.4000`, IACK window `$FEC6.6000`** `[MAN]`+`[RE]`
Same chip as the MVME167. RMON programs `LIVR = 0x50`, so the four interrupt
types vector as `0x50` rx-exception, `0x51` modem, `0x52` tx, `0x53` rx-data.
For *polled* operation the chip can be forced into IACK context by reading
`$FEC6.6000-$FEC6.7FFF` with A0-A6 matching one of its priority-interrupt-level
registers — this is a **software IACK window**, separate from a real CPU IACK.
`CCR` (`0x13`) must be polled until the chip clears it; commands complete
asynchronously.

**ILACC ethernet — `$FEC6.8000`** `[MAN]`+`[RE]`
RAP written at `+6`, RDP accessed at `+2`, both word-size. Am79C900: 32-bit
initialisation block and descriptors (a plain 16-bit LANCE model will not do).
Station address PROM nibbles live around `+0x1d01/+0x1d81` on odd byte lanes;
the authoritative MAC is the one in the NVRAM board-ID block.

> **Open bug** `[HW]`: both U-Boot and Linux currently read that PROM as
> `04:00:04:00:04:00` instead of the board's real `00:00:5B:00:49:62` — the
> nibble/lane extraction is wrong in both. RMON gets it right, and the address
> is also sitting in NVRAM at `0xfec2048a`.

**SCSI — `$FEC6.C000`** `[RE]`
NCR 53C720, **byte lanes reversed within 32-bit words**: big-endian offset =
register number XOR 3. Register map is the 720/8xx one (ISTAT `0x14`, STEST2
`0x4e`, SODL `0x54`, SBDL `0x58`, SOCL `0x09`, SBCL `0x0b`), *not* the 53C710's.
RMON never uses SCRIPTS or interrupts — it bit-bangs the bus in
low-level mode (STEST2 = `0x03`), one REQ/ACK handshake per byte, and never
sends IDENTIFY (LUN travels in CDB byte 1, SCSI-1 style).

**IOC-2 — `$FEC7.0000`** `[RE]`
Chip-select and memory controller. `reg 0x00` = own base (`0xfec00000`);
`0x04..0x38` = per-bank timing; `0x40/0x44/0x48` and `0x50/0x54/0x58` are
CS bank base/mask/control triples (ROM: `0xfe800000 / 0xfff00000 / 0x0a03`;
SRAM: `0xfea00000 / 0xfff00000 / 0x0a04`). `reg 0xa8` is the status/config
register RMON waits on (`(a8 & 0xf00) == 0x200`) and its bits 3-4 feed the VIC
init special-casing; `[HW]` it read `0x0000528b` on the live board.

**Video — `$FEC4.0000` (Bt445) / `$FEC4.8000` (LM1882 + address generator)**
`[MAN]`+`[RE]`
Indirect addressing: write the register number to the address port, access via
the data port, address auto-increments. `+2` reads `0x3a` as a presence/ID
byte. The pixel clock is synthesised per mode from a 25.175 MHz reference.
The CRTC/address generator takes 20 16-bit registers through an index/data
pair; RMON carries ten canned modes (640x480 60 Hz through 1152x900 66 Hz plus
interlaced CCIR/EIA TV modes) — the full table is in the qemu-e17 notes.
The LM1882 **cursor pulse is used as the frame/vblank interrupt** on LIRQ4.

## Interrupts

The VIC068A is the interrupt controller. Seven local inputs, LIRQ1..LIRQ7, plus
VME IRQ1-7 and the VIC's own error/interprocessor groups.

`[MAN]` Table 48, default assignment:

| input | source | CPU level | vector supplied by |
| --- | --- | --- | --- |
| LIRQ7 | ILACC ethernet | 3 | VIC |
| LIRQ6 | CD2401 (highest), System CIO, User CIO | 5 | **the device** (self-vectored daisy chain) |
| LIRQ5 | LEB | 2 | LEB |
| LIRQ4 | video frame inactive | 5 | VIC |
| LIRQ3 | SCSI | 2 | VIC |
| LIRQ2 | **VIC's own clock-tick timer** | 6 | VIC |
| LIRQ1 | keyboard controller | 1 | VIC |
| — | ACFAIL / SYSFAIL / arb timeout / write-post fail | 7 | VIC |
| ICGS | interprocessor global switches | 6 | VIC |
| ICMS | interprocessor module switches | 7 | VIC |

Key facts learned the hard way:

* **LIRQ2 is the VIC's own internal periodic timer, not a CIO.** `[MAN §3.14]`
  It is enabled and its frequency chosen in **slave-select control register 0**
  (SSCR0, reg `0xc3`): bits 7,6 select 50 / 100 / 1000 Hz. The interrupt is
  gated by **LICR2** (`0x2b`). This is the natural OS tick, and it is what the
  Linux port uses for CPU0. An early RE note claimed the tick was a CIO CT3 on
  LIRQ1 — that was wrong twice over.
* **LICR bit 4 = autovector/VIC-vector enable.** Set, the VIC supplies the
  vector (`LIVBR | LIRQn`) *and* DTACK; clear, the line is self-vectored and the
  device on it must answer the IACK itself. LIVBR (`0x57`) is `0x40` `[HW]`, so
  VIC-vectored LIRQ*n* → vector `0x40+n`. That value is not a ROM constant: it
  comes from the VIC init table in NVRAM (`0x40 -> offset 0x57`).
* **What RMON actually leaves running** `[HW]`: LICR2 = `0x37` — the VIC tick
  timer enabled, VIC-vectored, at **CPU level 7** — and every other LICR masked
  (`0x88`). SSCR0 reads `0xd2` although the NVRAM table stores `0x12`: RMON ORs
  in the top two bits (enable + rate) at run time, so a 100 Hz IPL7 interrupt is
  live before your code gets control. U-Boot turns it off in `cpu_init_r`, and
  the kernel consequently sees the un-enabled `0x12`.
* **The LIRQ6 daisy chain is a bus-hang hazard.** Three devices (CD2401,
  System CIO, User CIO) share one self-vectored input at level 5. If a device
  asserts the line and then withdraws the request before the level-5 IACK cycle
  reaches it, nothing supplies a vector or DTACK, and the 68040 stalls
  mid-cycle. There is no bus-error timeout on this board, so the machine
  freezes solid — **both** CPUs — until the watchdog resets the crate. There is
  no recovery path; this failure mode has to be *prevented*, not handled.
* Vector collision to watch for: `0x42` is simultaneously `LIVBR|2`
  (VIC-vectored LIRQ2) and CIO `CTVEC 0x40 | VIS 2` (self-vectored on LIRQ6).
  Seeing vector `0x42` does not by itself tell you which path delivered it.

## Dual CPU

The two sockets are **not symmetric and no CPU reads a socket-ID register**
`[RE]`. Discrimination is by hardware reset hold: the primary runs at power-on,
the secondary is held in reset. (`CPU2CON` bit 6 does read back 1 on the
primary and 0 on the secondary `[MAN]` Tables 50/51, but RMON never uses it.)

**CPU2CON — `$FEC5.8000`**, byte, and its meaning *differs per CPU*:

Seen by the primary (Table 50):

    bit 7  r  mailbox IRQ to secondary pending
    bit 6  r  CPU ID: 1 = primary, 0 = secondary
    bit 5  w  SRESET: 0 = hold secondary in reset, 1 = run
    bits 2-0 w SIPL: IPL driven into the secondary -> autovector IPI

Seen by the secondary (Table 51):

    bit 5  r  VIC clock IRQ pending
    bits 2-0 w SICF, a command:
              0 = disable VIC-clock IRQ     1 = enable VIC-clock IRQ
              2 = LEB disable               3 = LEB enable
              4 = IACK the VIC-clock IRQ    5 = IACK the mailbox IRQ
              6 = VME disable               7 = VME enable

Because the primary's SIPL field and the secondary's SICF field are the *same
three bits*, cross-CPU writes to CPU2CON are unsafe board glue — each CPU
should only write its own view, and the primary must keep SRESET set or it
resets the secondary.

**SNCR — `$FEC5.E000`, write-only** `[MAN]` Tables 52/53. Two bits per CPU
(SC1/SC0): `01` = "supply dirty and sink", the coherent mode for shared
write-through data. Because it is write-only, software must keep a shadow —
and it really is write-only: reading it gave `0x40` in July 2026 and `0xff` in
September `[HW]`, so the read side carries no information. (RMON also writes a
CPU-type code, 1 = 68040 / 4 = 68060, to this address, which is where the old
"CPU type register" label came from.)

**Bringing up the secondary** `[RE]`, verified in QEMU and on hardware:

1. Plant the 680x0 reset vector in DRAM: `[0]` = initial SSP, `[4]` = initial
   PC. (ROM is no longer mapped at 0 by this point.)
2. Pulse CPU2CON: write `0x00` (assert reset), then `0x20` (release).
3. The secondary fetches SP/PC from DRAM 0/4 and runs.

RMON does exactly this with a trampoline that writes `0xfeed` to `0x1004` and
then `STOP`s — which is why the secondary sits halted at the instruction after
the `stop #0x2700` forever after. It can be re-released with a fresh `0x20`
pulse.

Communication is plain **shared DRAM** — there is no hardware mailbox FIFO —
plus two real doorbells:

* primary → secondary: write SIPL into CPU2CON; the secondary takes an
  autovector interrupt at that level and acks with `SICF = 5`.
* secondary → primary: the VIC's **interprocessor communication module
  switches** `[MAN §3.19.2]`. A clear→set transition on ICFSR (`$FEC0.105F`)
  bit 0 raises the ICMS group interrupt on the primary when the matching mask
  bit in ICMSICR (`$FEC0.1047`) bit 4 is clear; ICMSIVBR (`$FEC0.1053`, reset
  `$F0`) sets the vector base.

The secondary also gets its own periodic tick: the VIC clock (LIRQ2) is routed
to it as a **level-4 autovector**, enabled with `SICF = 1` and acked with
`SICF = 4`.

Measured coherency `[RE]`: the two CPUs see each other's DRAM writes even with
the primary's caches on and the secondary's off — write-through plus snooping
is good enough in practice, which is why RMON's own `0x1004` handshake works.

## Firmware

**RMON 3.1.3** (02apr97), 256 KB EPROM image mirrored x4 in the 1 MB dump.
Reset vector `SP=0xfea01000`, `PC=0xfe8005d0`; ROM is also decoded at 0 out of
reset. ROM checksum: the first `0x200` bytes summed bytewise must equal the u32
at ROM offset `0x1c`.

Conventions useful when reading the disassembly `[RE]`:

* `d6` = POST checkpoint, written to System CIO port C before each stage — a
  stuck code on the hex display names the failing stage.
* `fp/a6` = bus-error resume pointer; fatal vectors resume at `*fp`, so
  `lea pc@(X),%fp` before a probe means "on bus error, continue at X".
* `d7` = device presence/error accumulator (bit 16 video absent, 17 NVRAM reg4,
  18 secondary CPU present, 19 SCSI absent, 24 NVRAM reg0, 25 warm boot).
* DRAM globals: `0x000` vector table, `0x800` config block, `0x1000` POST flags,
  `0x1004` secondary handshake, `0x1008` CPU type as decimal, `0x8000` stack.

The DIP switch low nibble on System CIO port B selects the configuration source
`[RE]`: 0 and 3-7 pick ROM profiles, **1 or 2 load the saved NVRAM config**, and
≥8 loads NVRAM *and* autostarts from battery SRAM (`*(0xfea00000)` as SP/PC,
no validation at all).

### Netboot image format `[RE]`, verified by booting payloads

All big-endian, 22-byte header, image data immediately after:

    +0   u32  magic 0x134FEE73
    +4   u16  cpu type (not checked by the TFTP loader)
    +6   u32  size (>100, <= 0x01FE0000)
    +10  u32  load address
    +14  u32  entry address (0 = use the u32 at image offset 4)
    +18  u16  image checksum (stored at load+size; checksum over load..+size+2)
    +20  u16  header checksum

Checksum is the RFC1071 internet checksum. Entry state: `SR = 0x2000`
(supervisor, **interrupts on**), `VBR = 0`, `CACR = 0` (caches off),
`a0` = entry, `sp = 0x7ec4`.

### Loading code over serial

`sload <port> <offset>` takes an S-record stream (XON/XOFF paced; needs an S0
header record and CRLF line endings or it silently loads nothing), then
`gm <addr>` starts it taking **SP from `[addr]` and PC from `[addr+4]`** — a
module header, not a raw jump. Make the S-records from a raw binary, not from
an ELF.

### Other firmware

A **VxWorks 5.3.1 compressed boot ROM** for this board exists on bitsavers
(`e17vxworks.bin`, built Mar 30 1998). It lives in the `$FEA0.0000` socket
(reset SP `0x1000`, PC `0xfea00008`), inflates itself into DRAM and runs there.
Its BSP was the source for several interrupt details above: 60 Hz tick from a
CIO CT3 with `CTVEC = 0x50`, `MICR = 0x84`, and it runs the kernel in **master
mode** (SR.M set).

## Known-dangerous accesses

* **Reading `$FEC5.4000` (the revision EEPROM / I2C port) with a plain memory
  read hangs the CPU** long enough that RMON stops petting the watchdog — the
  result is a watchdog reset that takes down every board in the VME crate
  `[HW]`. Go through the firmware's I2C helper routines instead.
* **The first write to `$FEC5.0000` arms the watchdog.** Do not touch it unless
  you intend to keep petting it.
* Withdrawing an interrupt request on the self-vectored LIRQ6 chain before its
  IACK arrives wedges the whole bus (see "Interrupts").

## Software status

**QEMU** — a full `e17` machine model exists (out of tree, in a qemu fork):
68040/68060, the `$FEC0.0000` I/O block, both CIOs, M48T02, CD2401, ILACC,
ncr53c720, Bt445/LM1882 video with a PS/2 keyboard, and the secondary CPU
release path. RMON boots to an interactive monitor on either the serial or the
video console; SCSI scan, netboot and `sload`/`gm` all work.

**U-Boot** — ported (board `eltec/e17`, `TEXT_BASE 0x600000`), reaches an
interactive prompt with CD2401 console, ILACC, timer and the live RTC.

**Linux/m68k** — ported (out of tree), boots to userspace with:
CD2401 tty (`ttyS0`), VIC068A irqchip, Z8536 CT1/CT2 clocksource, M48T02 RTC,
watchdog, ILACC ethernet, keyboard, and a tiny DRM driver for the Bt445
framebuffer. Device tree in `arch/m68k/dts/eltec-e17.dts`.

**Linux SMP** — m68k had no SMP support at all; it was written for this board
(second CPU released via CPU2CON, hardware IPIs both directions, per-CPU VIC
tick). Two m68k-specific gotchas worth recording: the 68040's `cas` only works
through the SRP, so the user futex has to walk the page tables and operate on
the kernel linear-map alias; and m68k must *not* select
`GENERIC_IRQ_MULTI_HANDLER`, because each CPU dispatches through its own 680x0
vector table via its own VBR.

### Open problem: intermittent whole-bus hangs

The board still takes intermittent hard hangs under Linux — both CPUs frozen
mid-bus-cycle, recovered only by the watchdog. A breadcrumb record in
battery-backed NVRAM at `$FEC2.0600` survives the reset and records both CPUs'
heartbeats, the interrupted PCs, `irq_err_count`, the last unexpected vector,
and which suspect bus region CPU0 was in.

What has been ruled out so far: the ILACC (hangs continue with the interface
down), and the self-vectored LIRQ6 IACK phantom (all three devices on that
chain have been silenced — System CIO interrupts disabled, User CIO CT3
disabled, CD2401 masked and fully polled — and the hangs persist,
`irq_err_count` staying 0 throughout).

Observed directly on 2026-09-21 (`logs/real-board/session-20260921-linux.txt`):
the board hung twice in one session while **completely idle** — no console
input, nothing running — and netbooted itself each time. Both breadcrumbs show
the same signature: `irq_err_count` 0, no bad vector, PHASE 0 (not inside any
marked bus region), CPU1 having ticked zero times after CPU0's last tick. In
one, CPU0 was in `smp_call_function_many_cond+0x278` (mid cross-CPU call) with
CPU1 idle; in the other, CPU0 was idle and CPU1 was in
`_raw_spin_unlock_irqrestore`. Measured at idle on that same build, the two
ticks run at 98.5 Hz and 99.8 Hz — **1.013x, no storm** — so whatever provokes
the over-tick is load-dependent and is not a precondition for the hang.

The surviving suspect is the secondary CPU's VIC-clock path. The VIC timer's
LIRQ2 output is a level-wide square wave; delivered to the secondary through
CPU2CON it reads level-like, so after the `SICF = 4` ack the still-asserted line
re-latches and the secondary re-enters its tick many times per period — a
measured ~2.4x over-tick that is present in every recorded crash, and which on
its own is enough to starve RCU on that CPU. A leaky-bucket detector now
disables the runaway tick from the secondary's own side. The next experiment is
simply booting `maxcpus=1` to see whether the hangs stop.

## Sources

* EUROCOM-27 / EUROCOM-17-5xx hardware manual, ELTEC, Rev 1A, 1995-01 — the
  programmer's reference chapters are written for the EUROCOM-17-5xx.
* [Zilog Z8536 CIO](https://www.zilog.com/docs/serial/z08536_ps.pdf)
* [Cirrus Logic CL-CD2400/2401](https://bitsavers.computerhistory.org/components/cirrusLogic/_dataSheets/CL-CD2400_2401/CL_CD2400_2401_Four-Channel_Multi-Protocol_Communications_Controller_Data_Sheet_199106.pdf)
* AMD Am79C900 ILACC — [programming application note](https://www.amd.com/content/dam/amd/en/documents/archived-tech-docs/application-notes/19669.pdf)
* Cypress VIC068A VMEbus interface controller datasheet
* NCR 53C720 datasheet; Brooktree Bt445 and National LM1882 datasheets
* `rmon.bin` in this repo. Disassemble with:

      m68k-linux-gnu-objdump -b binary -m m68k:68040 -D rmon.bin \
          --adjust-vma=0xfe800000 > rmon.asm
