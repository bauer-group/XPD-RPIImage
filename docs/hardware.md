# 🔧 Hardware reference

Every piece of Raspberry Pi hardware that the image system can control today
is exposed as a dedicated JSON block. This reference explains **what it does,
what it emits, and on which board it applies**. Source of truth is always
[`config/schema.json`](../config/schema.json); this doc is the prose layer.

Two output paths exist:

- **`/boot/firmware/config.txt`** lines — rendered by
  [`scripts/generate.py`](../scripts/generate.py) `render_boot()` into
  `src/modules/bgrpiimage-boot/.../config-bgrpiimage.txt`.
- **Userspace runtime** (packages, systemd units, ALSA, EEPROM, hwclock) —
  rendered by `render_hardware()` and applied by the
  [`bgrpiimage-hardware`](../src/modules/bgrpiimage-hardware/start_chroot_script)
  chroot script.

---

## 📋 Overview

| Block | Scope | Pi4 | Pi5 | CM4 | CM5 |
| --- | --- | --- | --- | --- | --- |
| `boot_config` | I2C/SPI/I2S/UART, WiFi off, raw `dtoverlays`, `extra_lines` | ✅ | ✅ | ✅ | ✅ |
| `bluetooth` | Onboard BT radio: bluez + `bluetooth.service`, or `disable-bt` | ✅ | ✅ | ✅ | ✅ |
| `can` | MCP2515 CAN HAT: overlay order, INT GPIOs, bitrate | ✅ | ✅ | ✅ | ✅ |
| `camera` | CSI autodetect + explicit sensor overlays | ✅ | ✅ | ✅ | ✅ |
| `hdmi` | Per-output group/mode/audio/rotation/boost | ✅ | ✅ | ✅ | ✅ |
| `display` | fbcon rotation, DSI LCD rotation | ✅ | ✅ | ✅ | ✅ |
| `audio` | `dtparam=audio` + default ALSA sink | ✅ | ✅ | — | — |
| `gpio.one_wire` | w1-gpio overlay + pin selection | ✅ | ✅ | ✅ | ✅ |
| `rtc` | I2C RTC HAT + hwclock.service + fake-hwclock | ✅ | ✅ | ✅ | ✅ |
| `fan` | gpio-fan / pwm-fan / emc2301 overlay | ✅ | ✅ | ✅ | ✅ |
| `leds` | pwr/act trigger (on/off/heartbeat/mmc0) | ✅ | ✅ | — | — |
| `overclock` | arm/gpu/sdram freq + over_voltage | ✅ | ✅ | ✅ | ✅ |
| `memory` | gpu_mem split + cma size | ✅ | ✅ | ✅ | ✅ |
| `pcie` | PCIe slot + generation | — | ✅ | ✅ | ✅ |
| `usb` | max_usb_current (3A supply) | ✅ | — | — | — |
| `bootloader` | EEPROM BOOT_ORDER, wake-on-GPIO | — | ✅ | — | ✅ |
| `watchdog` | bcm2835-wdt via systemd | ✅ | ✅ | ✅ | ✅ |

---

## 📷 `camera`

```json
"camera": {
  "enabled": true,
  "autodetect": true,
  "sensors": [],
  "legacy": false
}
```

- **`autodetect: true`** (default) — sets `camera_auto_detect=1`. Works for all
  current libcamera-supported sensors on both Pi4 and Pi5.
- **`sensors: ["imx219"]`** — pin an explicit overlay when you want
  deterministic behaviour (slot-specific dual-camera setups on Pi5).
- **`legacy: true`** — Pi4 only: enables `start_x=1` + `gpu_mem=128` for the
  deprecated `raspivid` stack. Pi5 ignores this.

---

## 🖥️ `hdmi`

```json
"hdmi": {
  "outputs": [
    {
      "port": 0,
      "force_hotplug": true,
      "group": 2,
      "mode": 82,
      "drive": "hdmi",
      "audio": true,
      "rotate": 0,
      "boost": 7
    }
  ]
}
```

- **`port: 0|1`** — Pi4/5 have two micro-HDMI ports; `0` is the one next to
  the USB-C. All options are emitted with `:port=` suffix.
- **`group`** — `0=auto`, `1=CEA` (TV), `2=DMT` (PC monitor). Pick `2` +
  `mode` from the DMT table (`82` = 1920×1080 @ 60 Hz) for deterministic
  monitor output.
- **`audio: true`** — forces `hdmi_drive=2` plus `hdmi_ignore_edid_audio=0`.
  Use when a monitor reports no audio capability but you know it has one.
- **`rotate: 90|180|270`** — emitted as `display_hdmi_rotate=<steps>`. On
  Pi5 / KMS, kernel cmdline rotation is usually more reliable.
- **`boost: 0..11`** — raise `config_hdmi_boost` when using long/noisy
  cables. `7` is a safe default if nothing shows up.

---

## 📺 `display`

```json
"display": { "console_rotate": 90, "lcd_rotate": 0 }
```

- **`console_rotate`** → `fbcon=rotate:<N>` (0/1/2/3).
- **`lcd_rotate`** → `display_lcd_rotate=<N>` — applies to the official
  7″ / 11.9″ DSI touch display.

---

## 🔊 `audio`

```json
"audio": {
  "enabled": true,
  "default_output": "hdmi0"
}
```

- **`enabled`** → `dtparam=audio=on/off`. Turns the onboard PWM/headphone
  output on Pi4 on or off. Pi5 has no analogue jack.
- **`default_output`** — `"auto" | "hdmi0" | "hdmi1" | "headphones" | "dac"`.
  Writes `/etc/alsa/conf.d/99-bgrpiimage-default.conf` to pin the default
  ALSA sink (useful for kiosks / unattended media players).

---

## 🔌 `gpio.one_wire`

```json
"gpio": { "one_wire": { "enabled": true, "pin": 4 } }
```

Enables `w1-gpio` overlay. Pin is the BCM number; default is `4` which
matches every DS18B20 "just plug it in" tutorial.

---

## ⏰ `rtc`

```json
"rtc": {
  "enabled": true,
  "model": "ds3231",
  "i2c_bus": 1,
  "fake_hwclock": false
}
```

- **`model`** — enum: `ds3231` | `pcf8523` | `pcf85063`. Emits
  `dtoverlay=i2c-rtc,<model>`. Requires `boot_config.enable_i2c: true`.
- **`i2c_bus`** — which I2C bus the HAT sits on; `1` is the default and emits
  nothing extra. Any other value appends the bus flag that `i2c-buses.dtsi`
  defines, e.g. `i2c_bus: 3` gives `dtoverlay=i2c-rtc,ds3231,i2c3`. Bus `2` is
  deliberately not accepted — it is the HDMI DDC channel.
- **`fake_hwclock: true`** — installs the `fake-hwclock` package as a fallback
  (time survives reboots even without a HAT, but drifts without NTP).

Ensures the systemd `hwclock.service` is enabled on first boot.

---

## 🌬️ `fan`

```json
"fan": {
  "enabled": true,
  "mode": "gpio",
  "gpio": 14,
  "temp_on": 60000,
  "temp_off": 55000
}
```

Three modes:

- **`gpio`** — simple on/off transistor via `dtoverlay=gpio-fan`. `gpio`
  selects the BCM pin (PoE HAT fan is on `14`). `temp_on` is in millidegrees
  Celsius; `temp_off` is the switch-off temperature and is emitted as the
  overlay's `hyst=` hysteresis span (`temp_on - temp_off`), so it must be
  lower than `temp_on`.
- **`pwm`** — PWM-controlled fan via `dtoverlay=pwm-fan`. Needs a dual-FET
  or 4-pin PWM fan on GPIO18/19.
- **`emc2301`** — Pi5 Active Cooler / CM5 IO-Board cooling HAT. Forces
  detection when autoprobe fails.

---

## 💡 `leds`

```json
"leds": { "power": "heartbeat", "activity": "off" }
```

Trigger mapping:

| Value | dtparam trigger | Meaning |
| --- | --- | --- |
| `on` | `default-on` | always on |
| `off` | `none` + `activelow=off` | physically dark |
| `heartbeat` | `heartbeat` | liveness blink |
| `mmc0` | `mmc0` | blink on SD activity |
| `default` | *(unset)* | leave stock behaviour |

Use `"off"` for stealth / embedded deployments in customer-visible spots.

---

## 🏎️ `overclock`

```json
"overclock": {
  "enabled": true,
  "accept_warranty_void": true,
  "arm_freq": 2400,
  "gpu_freq": 750,
  "over_voltage": 6,
  "sdram_freq": 600
}
```

**Failing the `accept_warranty_void` gate fails validation.** Overclocking
permanently sets the warranty-void OTP bit on Pi4 and Pi5 — the image system
refuses to emit these lines unless you explicitly acknowledge that.

All fields are optional; only set what you want to tune. `over_voltage`
ranges `-16..+14` in 0.025 V steps.

---

## 💾 `memory`

```json
"memory": { "gpu_mem": 64, "cma": 256 }
```

- **`gpu_mem`** — generic split in MiB. Headless images should use `16-64`;
  anything doing HDMI decode or libcamera needs `128+`.
- **`gpu_mem_256`/`_512`/`_1024`** — board-size-specific overrides.
- **`cma`** — contiguous memory allocator size, emitted as
  `dtoverlay=vc4-kms-v3d,cma-<MiB>`. Bump when running libcamera with
  large sensors (4K + multiple streams).

---

## 🔗 `pcie`

```json
"pcie": { "enabled": true, "gen": 3, "nvme_boot": true }
```

- **`enabled`** — emits `dtparam=pciex1` (Pi5 / CM4 / CM5).
- **`gen: 3`** — beyond spec but works on most boards; use gen2 for
  stability or bad cables.
- **`nvme_boot: true`** — **advisory only, it emits nothing.** It records
  that the board is meant to boot from NVMe; the EEPROM change is made by the
  `bootloader` block below. Set `"bootloader": { "boot_order": "0xf461" }`
  (NVMe, USB, SD, repeat) or the NVMe stays unbootable.

---

## 🔌 `usb`

```json
"usb": { "max_usb_current": true }
```

Pi4-only. Raises USB-C port current ceiling when paired with a 3 A supply.

---

## 🧭 `bootloader` (Pi5 / CM5 EEPROM)

```json
"bootloader": {
  "boot_order": "0xf461",
  "wake_on_gpio": true,
  "power_off_on_halt": true
}
```

Applied once on first boot via `rpi-eeprom-config --apply`, guarded by a
sentinel file so reboots don't re-flash the EEPROM.

Common `boot_order` values (nibble order is reversed):

| Hex | Sequence |
| --- | --- |
| `0xf41` | SD → USB → repeat |
| `0xf14` | USB → SD → repeat |
| `0xf461` | NVMe → USB → SD → repeat (typical NVMe-first rig) |
| `0xf416` | SD → NVMe → USB → repeat |

- **`wake_on_gpio: true`** — required for the official power button on Pi5.
- **`power_off_on_halt: true`** — makes `poweroff` actually cut power
  instead of idling the SoC.

---

## 🐕 `watchdog`

```json
"watchdog": {
  "enabled": true,
  "runtime_sec": 10,
  "reboot_sec": 120
}
```

Configures the systemd side of `bcm2835-wdt`. Writes
`/etc/systemd/system.conf.d/10-bgrpiimage-watchdog.conf`:

```ini
[Manager]
RuntimeWatchdogSec=10
RebootWatchdogSec=120
```

- **`runtime_sec: 5..15`** — pid1 kicks the watchdog this often. Lower
  values reboot faster on hard hangs.
- **`reboot_sec`** — maximum time allowed for orderly shutdown before the
  watchdog forces a cold boot.

No extra packages needed; the driver + systemd support is in the stock
Raspberry Pi OS kernel and systemd.

---

## 📶 `bluetooth`

```json
"bluetooth": { "enabled": true }
```

Default **on**. This is the single source of truth for the radio - the old
`boot_config.disable_bluetooth` toggle described the same thing from the other
side and nothing kept the two in sync.

| Value | Emitted |
| --- | --- |
| `enabled: true` | `bluez` added to the package list, `bluetooth.service` unmasked + enabled |
| `enabled: false` | `dtoverlay=disable-bt`, `bluetooth.service` disabled + masked |

Two things that are easy to get wrong here:

- **`hciuart.service` does not exist on trixie.** `pi-bluetooth` is gone from
  the package set and the UART attach is handled by the device tree plus
  `bluez`. Enabling it fails with *Unit hciuart.service does not exist*.
- **The radio is rfkill-blocked by default.** `raspberrypi-sys-mods` ships
  `/etc/modprobe.d/rfkill_default.conf` with `options rfkill default_state=0`,
  which soft-blocks *every* radio type at rfkill module init - Bluetooth
  included. It only works on a stock image because pi-gen whitelists a handful
  of known BT device ids under `/var/lib/systemd/rfkill`. We ship
  `/etc/modprobe.d/zz-bgrpiimage-rfkill.conf` with `default_state=1` instead,
  so Bluetooth no longer depends on that whitelist matching the board.

> ⚠️ Lifting the block also lifts it for WLAN, which is the guard rail
> Raspberry Pi added in October 2024 against radiating before a regulatory
> domain is known. That is only defensible because the same file pins
> `ieee80211_regdom` from `network.wifi.country`. **An image rolled out outside
> that domain without changing `country` is a regulatory problem, not a
> technical one.**
>
> Never widen the cleanup glob to `/var/lib/systemd/rfkill/*` - the
> `*:bluetooth` entries are pi-gen's whitelist and deleting them soft-blocks
> Bluetooth on CM4 (`platform-fe215040.serial:bluetooth`).

---

## 🚌 `can` (Waveshare 17912 dual MCP2515)

> ### ⚠️ Upgrading a fleet from v0.5.0 or older
>
> **Which physical connector is `can0` changes.** Up to v0.5.0 the CS1 chip
> won the name `can0` through probe order, so the interface named `can0` was
> the screw terminal labelled **CAN1**. From v0.6.0 the mapping is the
> documented one: `can0` = `spi0.0` = terminal **CAN0**.
>
> Before rolling this out, re-check anything keyed to the interface names -
> application configuration, DBC bindings, routing rules and cable labelling.
> It was invisible until now because both generated `.network` files carry the
> same bitrate; the first asymmetric configuration would have applied the wrong
> rate to the wrong bus.

```json
"boot_config": {
  "core_freq_fixed": true,
  "enable_spi": true,
  "dtoverlays": [
    { "name": "mcp2515-can0", "params": { "oscillator": "16000000", "interrupt": "23", "spimaxfrequency": "8000000" } },
    { "name": "mcp2515-can1", "params": { "oscillator": "16000000", "interrupt": "25", "spimaxfrequency": "8000000" } }
  ]
},
"can": {
  "interfaces": [
    { "name": "can0", "bitrate": 500000, "auto_up": true, "txqueuelen": 1024, "restart_ms": 100 }
  ]
}
```

### SPI clock (`spimaxfrequency` + `core_freq_fixed`)

> **`spimaxfrequency=8000000` is a stability de-rate, not a speed-up.** Do not
> "optimise" it upward — there is nothing above it to win.

The overlays already default to `spi-max-frequency = <10000000>`, and 10 MHz is
the MCP2515's absolute ceiling (datasheet DS20001801J, Table 13-6: `FCLK` max
10 MHz). So the default is *already at spec maximum* and every value of
`spimaxfrequency` can only ever reduce it. We set 8 MHz on purpose:

| | Clock high/low time | Margin over the 45 ns minimum |
| --- | --- | --- |
| 10 MHz default | 50 ns / 50 ns | 5 ns (11%) |
| 8 MHz (this image) | 64 ns / 64 ns | 19 ns (42%) |

On the 17912 the `SCK`/`MOSI` net fans out to **two** MCP2515 loads with stubs,
so the extra setup/hold margin is worth having. The cost is negligible: draining
one RX frame takes ~20 µs at 8 MHz versus ~16 µs at 10 MHz, against a 222 µs
wire time for an 8-byte frame at 500 kbit/s — about 3% of the budget. SPI clock
is not the bottleneck on this bus; interrupt handling and `txqueuelen` are.

Note you do not get exactly 8 MHz. `spi-bcm2835` quantises to an even divider of
the core clock (`cdiv = DIV_ROUND_UP(clk_hz, spi_hz)`, rounded up to even), so on
a CM4 at 500 MHz a request for 8 MHz yields `cdiv = 64` → **7.8125 MHz**.

`core_freq_fixed=1` exists for a related and more dangerous reason. `spi-bcm2835`
calls `clk_get_rate()` **once**, in probe, and registers no clock notifier — the
divisor is computed against whatever the core was running at that instant and is
never recalculated. A CM4 core scales 200–500 MHz, so probing at the low end and
boosting afterwards multiplies the real `SCK` by up to 2.5×, which pushes the
MCP2515 well past its 10 MHz ceiling. The symptom is not obvious: probe failures
(`MCP251x didn't enter in conf mode after reset`, `Cannot initialize MCP%x. Wrong
wiring?`) or intermittent frame corruption that reads as a wiring fault.

It is deliberately **not** a per-model `core_freq_min`. The firmware docs say of
`core_freq_fixed`: *"disables active scaling of the core clock frequency and
ensures that any peripherals that use the core clock will maintain a consistent
speed. The fixed clock speed is the higher/turbo frequency for the platform in
use. Use this in preference to setting specific core_clock frequencies as it
provides portability of config files between platforms."* One line is therefore
correct on Pi 4, CM4, Pi 5 and CM5 alike, and no `[pi4]`/`[cm4]`/`[pi5]` sections
are needed. A hardcoded `core_freq_min=500` would have been wrong per board: it
pins a CM4 (stock `core_freq` 500) but is merely the *stock minimum* on a Pi 5,
whose core runs at 910 — a silent no-op exactly where it was meant to help.
It is not overclocking, which is why it sits in `boot_config` rather than the
warranty-gated `overclock` block.

### Why the block opens with `[all]`

The generated fragment is appended to the **end** of `config.txt`, and conditional
filters are sticky — everything after a `[cm4]`/`[pi5]` header applies only to that
board until the next filter. Stock Raspberry Pi OS happens to end its `config.txt`
with `[all]` (after `[cm4]`, `[cm5]` and `[pi5]` sections), but nothing guarantees
that for a hand-edited or Imager-customised file. Opening our block with `[all]`
resets any inherited scope, which is the reset the firmware docs prescribe for
exactly this case.

### Interrupt GPIOs

The upstream overlays hard-wire the chip select - `mcp2515-can0` is `spi0.0`
(CE0), `mcp2515-can1` is `spi0.1` (CE1) - but **both default to GPIO 25**, so
`params.interrupt` is mandatory on each. From the Waveshare schematic:

| Screw terminal | Chip | Chip select | INT net | Solder default | Alternative |
| --- | --- | --- | --- | --- | --- |
| CAN0 | U1 | `SPI0_CE0` → `spi0.0` | `CAN0_INT` | R14 → **BCM 23** | R15 → BCM 22 |
| CAN1 | U3 | `SPI0_CE1` → `spi0.1` | `CAN1_INT` | R17 → **BCM 25** | R16 → BCM 24 |

Waveshare's "PIN23"/"PIN25" are BCM numbers, not header positions. GPIO 26 is
on neither INT net.

A wrong pin fails **silently**: `mcp251x` requests its IRQ in `ndo_open`, not in
probe, so `dmesg` still logs *MCP2515 successfully initialized* and the
interface comes up - it just never receives. Worse, the overlays hard-code
`IRQ_TYPE_LEVEL_LOW`, and an unconnected GPIO sits at the SoC pull-down, i.e.
permanently asserted: that chip then runs a continuous interrupt storm whose
handler drains its own controller, so the channel *looks* like it works while
the correctly wired one starves.

### Overlay order is load-bearing

`mcp251x` names netdevs with `alloc_candev(..., "can%d")` and the index is
handed out by `dev_alloc_name()` at `register_netdevice()` time - in **probe
order**. Probe order follows the device-tree child order of `&spi0`, and the
firmware merges each `dtoverlay=` with libfdt's `fdt_add_subnode()`, which
inserts the new node *before* the target's existing children. So the overlay
applied **last probes first** and takes `can0`.

`render_boot()` therefore emits `mcp2515-can<N>` sorted by **descending N**,
which is exactly what Waveshare's own `config.txt` does. Keep the variant JSON
in natural order; the generator handles the ordering and writes a comment into
`config-bgrpiimage.txt` saying so.

Renaming afterwards is **not** a workaround: systemd has no temporary-name
scheme for swapping two interface names (`set_link_name()` is a single
`RTM_SETLINK` with no retry, and systemd#16665 is closed as not-a-bug), so a
udev rule either fails mutually with `File exists` or wins a race and produces
a different mapping per boot.

### Sample point

The sample point is the position inside a bit at which the controller reads the
level, given as a percentage of the bit time. It has to sit late enough that a
dominant level driven by the furthest node has actually propagated around the
bus and settled, and early enough to leave room for resynchronisation. It is
therefore a property of the **physical bus** — cable length, propagation delay,
node count — not of any one board.

**It is bus-wide.** Every node has to agree closely. A node sampling at a
noticeably different point still wins arbitration most of the time, so the
failure is not a clean refusal: it shows up as intermittent form and stuff
errors under load, climbing error counters, and — once the counters pass the
thresholds — an `ERROR-PASSIVE` or bus-off controller with no obvious cause.
That is far harder to diagnose than a link that simply refuses to come up,
which is why this is a value you set once for the whole installation rather
than tune per device.

**The default is almost always right.** When no sample point is configured the
kernel computes one from the bitrate and the controller's clock. On this HAT at
500 kbit/s that lands on 87.5%, which is also what CiA 301 (CANopen) specifies
for bit rates up to 800 kbit/s. Deviating is rare and should follow from a
measurement or a bus specification, not from guesswork.

Read the value in effect with:

```bash
ip -details link show can0
```

> ⚠️ **`ip` prints it as a fraction, the config takes a percentage.** The line
> reads `bitrate 500000 sample-point 0.875`, and `0.875` there means **87.5%**.
> In the variant JSON the same setting is written `"sample_point": 87.5`.
> Copying `0.875` across is refused by schema validation — deliberately, because
> it would otherwise render as `SamplePoint=0.9%`, which systemd accepts without
> complaint as **0.9 percent**. A valid line carrying a nonsense value is worse
> than one that is rejected outright.

If you do set it, note that systemd accepts at most **one decimal place** here
(`87.5%` is fine, `87.55%` is rejected outright), so the generator rounds to one
decimal. The value is emitted as `[CAN] SamplePoint=<v>%`; the `%` is mandatory,
and a bare number is silently dropped with only a journal warning — which is why
this key never worked before v0.7.7.

There is deliberately **no** `bgrpiimage-setup can sample-point` command. The
other CAN subcommands change per-device settings — a bitrate has to match the
bus you are plugging into, a queue length absorbs bursts on that one board. The
sample point is neither: changing it on a single node while the rest of the bus
stays at 87.5% makes the bus worse, not better, and a per-device command would
invite exactly that. It belongs in the variant JSON, applied identically to
every unit built from that image.

### On-device diagnosis

```bash
sudo bgrpiimage-setup can status
```

Note that `grep -i mcp /proc/interrupts` is **not** a valid check: the IRQ is
registered under `dev_name(&spi->dev)`, i.e. `spi0.0` / `spi0.1`, so that grep
is empty on a perfectly healthy system. Use:

```bash
grep -E 'spi0\.[01]' /proc/interrupts
```

An idle counter that keeps climbing means the overlay points at a GPIO the HAT
does not drive; a counter stuck at 0 while traffic flows means it points at the
other chip.

#### Bus-off recovery

`can status` prints the controller state and its recovery setting on one line:

```text
can state ERROR-ACTIVE restart-ms 100
```

`ERROR-ACTIVE` is the **healthy** state (TX/RX error counters below 96).
The number that matters for availability is `restart-ms`.

| `restart-ms` | Behaviour after a bus-off |
| --- | --- |
| `0` | **Terminal.** `can_bus_off()` in `drivers/net/can/dev/dev.c` only queues its recovery work `if (priv->restart_ms)`. Worse on this HAT: `mcp251x.c` takes the `restart_ms == 0` branch to set `force_quit` and call `mcp251x_hw_sleep()`, putting the MCP2515 into hardware **sleep** and killing its own ISR loop — which also defeats the controller's built-in bus-off recovery. Nothing but an `ip link` down/up revives it, i.e. an on-site visit. |
| `100` | Shipped default (v0.7.3+). The driver skips the sleep path and the MCP2515 self-recovers in hardware after 128 × 11 bit times — about **2.8 ms** at 500 kbit/s. |

On the MCP2515 the *value* is effectively a boolean: any non-zero setting
declines the sleep path, and the generic `restart_work` timer is never armed,
so 100 ms is not a recovery latency — the real figure is the ~2.8 ms above.
The number only becomes load bearing on a controller that uses the generic
timer. 100 is the value used in the kernel's own documentation.

Two consequences worth knowing before writing acceptance tests:

- With `restart-ms` non-zero the driver never calls `can_bus_off()`, so there
  is **no `bus-off` journal line and the `bus-off` counter stays 0**. Assert on
  `ip -details link show can0 | grep 'restart-ms 100'`, not on symptoms.
- `ip link set can0 type can restart` starts returning `-EINVAL` once
  `restart-ms` is set (`can_restart_now()` refuses when `priv->restart_ms` is
  non-zero). That is expected — automatic recovery replaces the manual poke.

To reproduce a bus-off on the bench: let a single node transmit with no peer to
ACK it. The TX error counter passes 255 within milliseconds at 500 kbit/s, and
the contrast between `restart-ms 0` and `restart-ms 100` is unambiguous.

---

## 🚨 Cross-field validation

Enforced in [`scripts/generate.py`](../scripts/generate.py) `_semantic_validate()`:

| Rule | Reason |
| --- | --- |
| `overclock.enabled` ⇒ `overclock.accept_warranty_void` | Overclocking flips the OTP warranty bit. |
| `fan.enabled` ⇒ `fan.mode ∈ {gpio,pwm,emc2301}` | `gpio-fan`/`pwm-fan`/`rpi-fan` pick different overlays. |
| `rtc.enabled` ⇒ `rtc.model` | Each chip has its own `i2c-rtc` overlay param. |
| every `can.interfaces[].name` ⇒ a matching `mcp2515-<name>` overlay | The two blocks describe one piece of hardware and were rendered independently. |
| each `mcp2515-*` overlay ⇒ its own `params.interrupt` | Both overlays default to GPIO 25; two chips on one line is a pinctrl conflict, not an error message. |
| `bluetooth.enabled` ⇒ no manual `disable-bt` in `extra_lines` | A hand-written overlay would silently win over the block. |

---

## 🪜 Adding new hardware blocks

1. Add the block to [`config/schema.json`](../config/schema.json) with
   `additionalProperties: false` and descriptive `description` fields.
2. If it translates to `config.txt` lines, extend `render_boot()`.
3. If it needs packages / systemd / runtime config, extend `render_hardware()`
   and update the [`bgrpiimage-hardware`](../src/modules/bgrpiimage-hardware/start_chroot_script)
   chroot script.
4. Add sensible defaults to [`config/variants/base.json`](../config/variants/base.json).
5. Document the block here with a minimal example and the boards it applies to.
6. If it has cross-field constraints, add them to `_semantic_validate()`.
