# EUROCOM-17 architecture & interconnect

How the ELTEC EUROCOM-17 (E17) — a dual **MC68040** VMEbus single-board
computer — hangs together: the on-board I/O window, the VIC068A interrupt
topology, the dual-CPU/SMP glue, the watchdog, and how the Linux drivers map
onto all of it. Written to make the drivers reviewable without re-deriving the
wiring each time. Facts here come from `arch/m68k/dts/eltec-e17.dts`,
`drivers/irqchip/irq-e17-vic068a.c`, `arch/m68k/eltec/{config.c,smp_e17.c}`, and
the individual drivers.

> Mermaid diagrams render on GitHub and in most Markdown viewers.

---

## 1. On-board I/O memory map (`0xfec00000` window + VRAM)

Everything on-board lives in the `0xfec00000` I/O window (plus the 1 MB VRAM
aperture at `0x0fc00000`). Addresses are physical; the kernel reaches the I/O
window cache-inhibited.

| Address | Device | Linux driver | Notes |
|---|---|---|---|
| `0xfec00000` | VIC068A interrupt controller | `irqchip/irq-e17-vic068a.c` | LICR1..7 at `0x27+(n-1)*4` |
| `0xfec0105f` | VIC ICFSR (ICMS doorbell) | `eltec/smp_e17.c` | CPU1→CPU0 IPI edge |
| `0xfec10000` | CIO0 (Z8536) | — | `intc_user` vector 1 |
| `0xfec20000` | RTC + NVRAM (M48T02, 2 KB) | `rtc/rtc-m48t59.c` | breadcrumb + MAC live here |
| `0xfec20488` | MAC address (6 plain bytes) | lance / u-boot | **not** the LANCE PROM window |
| `0xfec20600` | reset-surviving breadcrumb | `eltec/config.c`, `watchdog/e17_wdt.c` | per-CPU heartbeats + PCs |
| `0xfec30000` | CIO1 "system" (Z8536) | `clocksource/timer-e17-cio.c` | 7-seg POST, DIP switches, 32-bit clocksource |
| `0xfec40000` | Bt445 RAM-DAC | `gpu/drm/tiny/e17_drm.c` | palette + PLL |
| `0xfec48000` | LM1882 address/sync generator | `e17_drm.c` | CRTC timing |
| `0xfec50000` | Watchdog | `watchdog/e17_wdt.c` | **any write pets; first write arms; can't be disabled** |
| `0xfec54000` | I2C / IPIN + frame-IRQ route | `e17_drm.c` (`irqroute`, +1 only) | ⚠ **reading `0xfec54000` triggers a watchdog/SYSRESET** |
| `0xfec58000` | CPU2CON (secondary control) | `eltec/smp_e17.c` | SRESET, SIPL mailbox, SICF |
| `0xfec5e000` | SNCR (snoop control) | `eltec/smp_e17.c` | cache coherency mode |
| `0xfec60000` | AT keyboard controller | `input/keyboard/e17_kbd.c` | |
| `0xfec64000` | CD2401 serial (chan 0 = console) | `tty/serial/serial_e17_cd2401.c` | |
| `0xfec66000` | CD2401 IACK window | `serial_e17_cd2401.c` | software-IACK at `0x7b` |
| `0xfec68000` | LANCE / ILACC ethernet | `net/ethernet/amd/e17-lance.c` | |
| `0xfec6c000` | 53C720 SCSI | — (no driver yet) | |
| `0x0fc00000` | 1 MB video RAM | `e17_drm.c` | scan-out buffer |

⚠ **Danger addresses** (documented so a driver review doesn't reintroduce them):
- **Read** of `0xfec54000` (I2C/IPIN) stalls the CPU long enough to trip the
  watchdog → **VMEbus SYSRESET resets every board in the crate**. Only ever
  *write* the frame-route byte at `0xfec54001`.
- The **first write** to `0xfec50000` arms the watchdog; software cannot disable
  it thereafter.
- Reading undecoded addresses (e.g. `0xfeb00000`) hangs the bus (watchdog
  recovers).

---

## 2. Interrupt topology (VIC068A)

The VIC068A has seven local inputs **LIRQ1..LIRQ7**. Each has a control register
**LICRn** (`0x27 + (n-1)*4`) with a mask bit (`0x80`), a CPU-level field (bits
2:0) and a read-only raw-pin STATE bit (`0x08`). A line is either:

- **VIC-vectored** — the VIC supplies vector `LIVBR|LIRQ` (`LIVBR = VEC_USER =
  0x40`), so the CPU vector == `0x40|LIRQ`; or
- **self-vectored** — the device supplies its own vector during the CPU IACK
  cycle. On this board **LIRQ6 is a self-vectored daisy chain** carrying the
  CD2401 *and* both CIOs, each on its own vector → its own Linux IRQ, all gated
  by the single LICR6.

Every VIC input is dispatched with `handle_simple_irq` (no HW ack/EOI): the CPU
IACK clears the vector and the SR interrupt-priority-level does the masking. A
device whose ISR can't quench a level-held request would re-vector forever, so
the irqchip has a **per-LICR screaming-source guard** (`E17_VIC_STORM`): if a
line exceeds ~4000/jiffy it is masked and a warning names the LIRQ.

```mermaid
flowchart LR
    subgraph devs [On-board interrupters]
        KBD["keyboard@fec60000"]
        SCSI["scsi@fec6c000<br/>(no driver)"]
        VID["video@fec40000<br/>LM1882 frame pulse"]
        CD["CD2401 serial@fec64000<br/>rx/rxexc/tx/modem"]
        CIO1["CIO1 system@fec30000<br/>CT clocksource"]
        LANCE["ethernet@fec68000<br/>LANCE"]
    end

    KBD -->|LIRQ1 lvl1<br/>vec 0x41| VIC
    VID -->|LIRQ4 lvl5<br/>vec 0x44| VIC
    SCSI -->|LIRQ3 lvl2<br/>vec 0x43| VIC
    CD -->|LIRQ6 lvl5<br/>self-vec 0x50-0x53| VIC
    CIO1 -->|LIRQ6 lvl5<br/>self-vec 0x60| VIC
    LANCE -->|LIRQ7 lvl3<br/>vec 0x47| VIC

    VIC["VIC068A @ fec00000<br/>LICR1..7 gate + level"]
    VIC -->|"CPU IACK<br/>vec LIVBR+LIRQ or device vec"| CPU0[("CPU0<br/>68040")]

    subgraph note [LIRQ6 daisy chain]
        direction TB
        n1["one LICR6 gates the whole chain;<br/>irqchip refcounts mask so disabling<br/>the tx child can't mask live rx"]
    end
```

**Per-line summary** (from the DTS):

| LIRQ | CPU level | Vector | Device | Driver |
|---|---|---|---|---|
| LIRQ1 | 1 | 0x41 (VIC) | keyboard | `e17_kbd.c` (has polling backstop) |
| LIRQ2 | 6 | VIC | **CPU0 periodic tick** (VIC clock) | `eltec/config.c` |
| LIRQ3 | 2 | 0x43 (VIC) | SCSI 53C720 | — |
| LIRQ4 | 5 | 0x44 (VIC) | video frame/vblank (LM1882) | `e17_drm.c` |
| LIRQ6 | 5 | self: `0x50` rxexc, `0x51` modem, `0x52` tx, `0x53` rx; `0x60` CIO1 | CD2401 + CIOs | `serial_e17_cd2401.c`, `timer-e17-cio.c` |
| LIRQ7 | 3 | 0x47 (VIC) | LANCE ethernet | `e17-lance.c` |

The CD2401 uses a **shared PILR** (priority level `0xfb`, IACK window `0x7b`):
the driver software-IACKs at that single level and **dispatches on the returned
vector type**, so receive out-ranking transmit inside the chip can't IACK at a
level nothing answers (that was the "type a word and the board dies" hang).
There is **no bus-error timeout** on this board, so an un-DTACKed IACK hangs the
whole bus — hence the care around the IACK window.

---

## 3. Dual-CPU / SMP glue

Two 68040s. CPU0 (boot) releases CPU1 (AP) and they ring each other through two
separate hardware doorbells. All cross-CPU register touches are serialized by
`e17_smp_reg_lock` because **CPU2CON's SIPL/SICF fields overlap** and a
cross-CPU write races corrupt state (this serialization was the major SMP fix
that made `console_rx=1` viable and killed the spurious lockups).

```mermaid
flowchart TB
    subgraph CPU0 [CPU0 - boot]
        T0["periodic tick<br/>VIC LIRQ2 (lvl 6)"]
        RX0["mailbox ACK / IPI recv<br/>via ICMS (IRQ_USER)"]
    end
    subgraph CPU1 [CPU1 - AP]
        T1["AP tick<br/>VIC clock (lvl 4, vec 28)"]
        RX1["mailbox IRQ recv<br/>(lvl 6, vec 30)"]
    end

    CPU0 -->|"ring: CPU2CON SIPL<br/>0xfec58000 (keep SRESET=1)"| RX1
    CPU1 -->|"ring: VIC ICMS edge<br/>ICFSR 0xfec0105f"| RX0
    CPU0 -->|"release/park: CPU2CON SRESET<br/>bit5 (0->1 release, ->0 park)"| CPU1
    T1 -->|"every tick writes SICF<br/>(VIC-clock ack) + pets WDT"| WDT
    T0 -->|"pets WDT"| WDT
    WDT["Watchdog 0xfec50000"]

    LOCK["e17_smp_reg_lock<br/>serializes CPU2CON + ICFSR RMW<br/>(SIPL/SICF overlap = cross-CPU unsafe)"]
    LOCK -.guards.- CPU0
    LOCK -.guards.- CPU1
```

- **CPU0 → CPU1**: write **SIPL** to CPU2CON (`0xfec58000`) with SRESET held —
  the level-6 mailbox IRQ (vector 30) on CPU1.
- **CPU1 → CPU0**: write the **ICMS edge** to the VIC **ICFSR** (`0xfec0105f`)
  — delivered as `IRQ_USER` on CPU0.
- **Bring-up / park**: CPU2CON **SRESET** (bit 5): `0→1` releases the AP, `→0`
  parks it (also used by the offline path and by `e17_reset`).
- **Idle**: `e17_idle=spin` polls for IPIs (register-only bounded spin) instead
  of `stop #0x2000`, which fixed the spontaneous idle lockup.

---

## 4. Watchdog: who pets it, and the reset path

The watchdog (`0xfec50000`) is **armed by u-boot** and cannot be turned off. Any
write pets it; the jumper period is ≤1.6 s. It is petted from **both CPUs'
ticks**, so a CPU0-only stall while CPU1 keeps ticking is **not** caught by the
watchdog alone — which is why `panic_on_rcu_stall=1` exists as the earlier,
finer detector of a half-dead machine.

```mermaid
flowchart TB
    A["u-boot arms WDT<br/>(cpu_init_f)"] --> B["head.S: 2nd instruction<br/>moveb #0,0xfec50000"]
    B --> C["config_eltec_e17 + early board_r"]
    C --> D["steady state pets:"]
    D --> D1["CPU0 100Hz tick (e17_timer_int)"]
    D --> D2["CPU1 AP tick (e17_ap_tick)"]
    D --> D3["CD2401 console write / poll loops"]
    D1 --> E{"petted within<br/>≤1.6 s?"}
    D2 --> E
    D3 --> E
    E -->|yes| D
    E -->|no| F["watchdog fires<br/>→ VMEbus SYSRESET"]

    R["reboot / panic<br/>(mach_reset = e17_reset)"] --> R1["local_irq_disable"]
    R1 --> R2["CPU2CON SRESET=0<br/>park CPU1 (stops its petting)"]
    R2 --> R3["spin, starve WDT"]
    R3 --> F
```

Because CPU1 keeps petting, a plain `for(;;)` restart would never reset — so
`e17_reset` **parks CPU1 first**, then starves the watchdog. On the next boot
the `e17_wdt` driver prints the **breadcrumb** (`0xfec20600`): both CPUs'
heartbeats, the PC each was interrupted at (`E17_BC_PC`, `E17_BC_CPU1PC`),
`irq_err_count`, the last bad vector, and CPU0's tick source snapshot
(`LICR2`/`SSCR0`). That breadcrumb is the primary evidence for hang analysis —
CPU1's *last-tick PC* is where it was just before it went dark.

---

## 5. Display: frame IRQ, vblank, and the SMP deadlock (fixed)

The DRM/KMS driver (`e17_drm.c`) drives the Bt445 DAC + LM1882 sync generator +
address generator, with an 8bpp (C8) shadow-buffered framebuffer that also backs
fbcon. Two independent knobs:

- `e17_drm.frame_irq=1` — request the LM1882 frame pulse on VIC **LIRQ4**
  (~56 Hz). Counting-only unless vblank is on.
- `e17_drm.vblank=1` — enable DRM vblank. Source is the frame IRQ if it's active,
  else a **fork-local hrtimer** (`drm_crtc_vblank_start_timer`, tied to the tick
  because the board has no high-res clockevent).

```mermaid
flowchart TB
    subgraph src [vblank source]
        FI["LM1882 frame IRQ<br/>LIRQ4 → e17_frame_isr<br/>(hard IRQ, IPL5)"]
        HT["hrtimer<br/>drm_vblank_timer_function<br/>(tick context)"]
    end
    FI -->|"if frame_irq_active"| HV["drm_crtc_handle_vblank<br/>→ drm_handle_vblank<br/>(takes vblank_time_lock)"]
    HT -->|"else"| HV
    HV --> ACC["vblank count++/wake waiters"]

    subgraph consumer [fbcon path]
        DW["drm_fb_helper_damage_work"] --> WV["drm_client_modeset_wait_for_vblank<br/>→ drm_crtc_wait_one_vblank"]
        WV -->|"waits for a vblank tick"| ACC
    end
```

**The SMP deadlock (root-caused & fixed — see `logs/real-board/`):**
`drm_crtc_vblank_start_timer()` had a busy-loop `while (hrtimer_active)
hrtimer_try_to_cancel(...)`. `drm_vblank_enable()` calls it **holding
`dev->vblank_time_lock` with IRQs off**, and the timer callback
(`drm_vblank_timer_function → drm_crtc_handle_vblank → drm_handle_vblank`) takes
that **same lock**. If the callback was running on the other CPU: CPU A span
holding the lock waiting for the callback to finish; CPU B (the callback) span
for the lock — cross-CPU deadlock, both IRQs off, both ticks dead → RCU-stall
panic. Fixed by replacing the busy-loop with a single non-blocking
`hrtimer_try_to_cancel()` (`hrtimer_start()` re-arms safely).

- ✅ **`frame_irq=0 vblank=1` (hrtimer path)**: verified working — fbcon +
  vblank ticking + getty-on-tty1, no stalls. This is the recommended vsync path
  (no `handle_vblank` in hard-IRQ context).
- ⚠ **`frame_irq=1 vblank=1`**: still hard-hangs (separate hazard — running
  `drm_crtc_handle_vblank` from the frame ISR in IPL5 hard-IRQ context). Leave
  off.
- **default**: `vblank=0` — fbcon works fine, no vsync.

---

## 6. Device ↔ driver map

```mermaid
flowchart LR
    subgraph HW [on-board devices]
        d_vic["VIC068A"]; d_cd["CD2401"]; d_cio["CIO1 Z8536"]
        d_lance["LANCE"]; d_kbd["AT kbd"]; d_rtc["M48T02"]
        d_wdt["Watchdog"]; d_vid["Bt445+LM1882+VRAM"]
    end
    subgraph DRV [Linux drivers]
        v["irqchip/irq-e17-vic068a.c"]; s["tty/serial/serial_e17_cd2401.c"]
        c["clocksource/timer-e17-cio.c"]; n["net/ethernet/amd/e17-lance.c"]
        k["input/keyboard/e17_kbd.c"]; r["rtc/rtc-m48t59.c"]
        w["watchdog/e17_wdt.c"]; g["gpu/drm/tiny/e17_drm.c"]
    end
    d_vic-->v; d_cd-->s; d_cio-->c; d_lance-->n
    d_kbd-->k; d_rtc-->r; d_wdt-->w; d_vid-->g

    subgraph ARCH [arch/m68k/eltec]
        cfg["config.c<br/>tick, watchdog pet, reset, breadcrumb"]
        smp["smp_e17.c<br/>AP bring-up, IPIs, CPU2CON, snoop"]
    end
```

---

## 7. Open items (see `logs/real-board/` for detail)

- **UART RX in Linux**: the serial console is currently **output-only**
  (`console_rx=0`); the CD2401 receive path (LIRQ6, self-vectored) is the next
  thing to make robust so the physical serial console is interactive.
- **`frame_irq=1` vblank**: separate hard-IRQ hazard; hrtimer path is the
  working vsync.
- **NVRAM size**: 8 KB part, ~6 KB mapped elsewhere (address TBC).
- **U-boot vidconsole**: framebuffer driver probes, but the generic vidconsole
  text layer crashes on m68k/8bpp (not root-caused).

---

*Board driven over MQTT with `clankercontrol` (`clank`), target `e17`. Its Linux
serial is output-only, so `clank shell` needs `--host`.*
