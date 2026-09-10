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
| `can` | MCP2515 / MCP251XFD CAN HAT: overlay order, chip selects, INT GPIOs, bitrate, CAN FD data phase | ✅ | ✅ | ✅ | ✅ |
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
500 kbit/s that lands on 87.5% — which is both the kernel's own default for
bit rates up to 500 kbit/s and what CiA 301 (CANopen) asks for ("as close as
possible to 87,5 % of the bit time"; the standard does not tier by bit rate,
the 750/800/875 tiering is the kernel's). Deviating is rare and should follow
from a measurement or a bus specification, not from guesswork.

Read the value in effect with:

```bash
ip -details link show can0
```

> ⚠️ **`ip` prints it as a fraction, the config takes a percentage.** The line
> reads `bitrate 500000 sample-point 0.875`, and `0.875` there means **87.5%**.
> In the variant JSON the same setting is written `"sample_point": 87.5`.
> Copying `0.875` across is refused by schema validation — deliberately, because
> it would otherwise render as `SamplePoint=0.9%`. systemd accepts that as 9
> permille, and the kernel then refuses the timing outright, so the unit boots
> with a CAN link that never comes up. Failing in `make validate` beats failing
> in the field.

**On this HAT the setting can only ever lower the sample point.** The 16 MHz
crystal is halved by the `mcp251x` driver to an 8 MHz CAN core clock, and at
500 kbit/s the only reachable values are:

```text
50.0   56.2   62.5   68.7   75.0   81.2   87.5
```

87.5% is the ceiling, and it is also what you get for free by leaving the key
unset. Worse, the kernel treats the configured value as a *target* and rounds
**down** to the nearest reachable point **without reporting it** — ask for 80
and you silently get 75; ask for 90 or 95 and you silently get 87.5. So on this
hardware the key is at best a no-op and at worst a silent downgrade. Leave it
unset unless a bus specification or a measurement says otherwise.

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

## 🚌 `can` FD (Waveshare 17075 dual MCP2518FD)

Used by the [`canbusfd-plattform`](../config/variants/canbusfd-plattform.json)
variant. This is **not** the MCP2515 HAT with a faster chip on it — almost every
detail differs, and each difference has its own silent-failure mode.

```json
"boot_config": {
  "core_freq_fixed": true,
  "enable_spi": true,
  "dtoverlays": [
    { "name": "spi1-3cs" },
    { "id": "canfd0", "name": "mcp251xfd", "params": { "spi0-0": true, "interrupt": "25", "oscillator": "40000000", "speed": "20000000" } },
    { "id": "canfd1", "name": "mcp251xfd", "params": { "spi1-0": true, "interrupt": "24", "oscillator": "40000000", "speed": "20000000" } }
  ]
},
"can": {
  "interfaces": [
    { "name": "can0", "bitrate": 500000, "dbitrate": 2000000, "auto_up": true, "txqueuelen": 1024, "restart_ms": 100 }
  ]
}
```

### What changed against the MCP2515 HAT

| | 17912 (MCP2515) | 17075 (MCP2518FD) |
| --- | --- | --- |
| Overlay | `mcp2515-can0` / `mcp2515-can1` — one per channel | **`mcp251xfd`** — one overlay, loaded twice |
| Chip select | encoded in the overlay *name* | boolean param `spi0-0` / `spi1-0`, marked *"(boolean, required)"* |
| SPI clock param | `spimaxfrequency` | **`speed`** |
| Crystal | 16 MHz | **40 MHz** (schematic X1/X2, both channels) |
| Buses used | spi0 CE0 + spi0 CE1 | **spi0 CE0 + spi1 CE0** in factory "mode A" |
| Frame format | Classic CAN only | CAN FD (`dbitrate`) |

Two consequences fall straight out of the first two rows, and both used to be
silent:

- **Two entries named `mcp251xfd` merge into one.** `dtoverlays` merges by name,
  which is correct for every overlay that appears once. Here it collapsed both
  channels into a single overlay carrying `spi0-0` *and* `spi1-0` with
  `interrupt` resolved last-wins — one interface, wrong INT pin, `make validate`
  green. Hence the `id` key: a merge key that is never rendered.
- **`spimaxfrequency` is accepted by JSON and ignored by the firmware.**
  `dtoverlay` drops parameter names it does not recognise, so the SPI clock would
  quietly stay at the overlay default. It is now refused at build time.

### SPI clock: 20 MHz is a request, 17 MHz is the bus

> **20 MHz is not a value this hardware can run.** It is a request the driver
> discards.

The upstream overlay defaults to `spi-max-frequency = <20000000>`, and real boot
logs do print `m:20.00MHz` — but `m:` is `priv->spi_max_speed_hz_orig`, the
device-tree value echoed back **before clamping**. The fields that describe
reality sit next to it. From a Pi 5 with this exact HAT
([raspberrypi/linux#6644](https://github.com/raspberrypi/linux/issues/6644)):

```text
mcp251xfd spi0.1 can0: MCP2518FD rev0.0 (... o:40.00MHz c:40.00MHz
    m:20.00MHz rs:17.00MHz es:16.66MHz rf:17.00MHz ef:16.66MHz) successfully initialized.
```

| Field | Meaning |
| --- | --- |
| `o:` / `c:` | oscillator / CAN system clock |
| `m:` | SPI clock **as requested in DT** — pre-clamp |
| `rs:` / `rf:` | requested slow / fast clock, **post-clamp** |
| `es:` / `ef:` | **effective** clock measured by the SPI controller |

The clamp is in `mcp251xfd-core.c`:

```c
priv->spi_max_speed_hz_slow = min(spi->max_speed_hz, freq / 2 / 1000 * 850);
```

`40000000 / 2 / 1000 * 850` = **17 000 000**. The 0.85 factor is Microchip's own
fix for silicon errata DS80000789 item 4 — *"The SPI may write corrupted data to
the RAM at fast SPI speeds … Ensure that FSCK is less than or equal to 0.85 \*
(FSYSCLK/2)"* — a **data-corruption** erratum, not a signal-integrity margin.
Microchip applied it to the datasheet too: revision B (December 2020) cut the
`FSCK` maximum in Table 7-6 from 20 MHz to **17 MHz**. The overlay's `<20000000>`
is a leftover from revision A (April 2019).

**The variant ships `speed=20000000`** — upstream's own default, and what
Waveshare's published lines inherit by omitting the parameter. The driver clamps
it to 17 MHz, so the bus behaves identically to writing 17000000 outright; the
only cost is that `config.txt` states a clock nothing honours, which is why
`make render` prints a note about it. Writing `speed=17000000` instead is equally
valid and makes the config, this page and the boot banner agree on one number —
pick whichever you would rather explain to the next reader.

What matters is that neither choice changes the hardware: **17 MHz is the
ceiling either way.** `_semantic_validate()` therefore notes an over-spec `speed`
rather than refusing it — `min()` has already made it safe, and refusing would
reject upstream's own value.

> **Do not de-rate below 17 MHz** the way the MCP2515 is de-rated from 10 to
> 8 MHz. That de-rate is load-bearing because `mcp251x` applies *no* clamp of its
> own — whatever DT says reaches the pins. Here the manufacturer's margin is
> already applied, and the BCM2835/RP1 divisor quantisation applies a second one
> on top (`DIV_ROUND_UP` on the divisor only ever rounds the clock *down*):
> ≈15.6 MHz on Pi 4, ≈16.7 MHz on Pi 5.

### Chip selects and the AUX SPI bus

In the factory jumper setting Waveshare calls **mode A**, the two channels sit on
*different* SPI controllers:

| Terminal | Chip select | INT | Notes |
| --- | --- | --- | --- |
| CAN_0 | `SPI0_CE0` → `spi0.0` (GPIO 8) | GPIO 25 | main SPI controller |
| CAN_1 | `SPI1_CE0` → `spi1.0` (GPIO 18) | GPIO 24 | **AUX** SPI controller |

Alternative jumper positions (0 Ω links, verified against the Rev2.1 schematic):
CAN_0 chip select `CE1` (GPIO 7) with INT GPIO 13; CAN_1 chip select `SPI1_CE1`
(GPIO 17) / `SPI1_CE2` (GPIO 16) with INT GPIO 23 / 22. The fourth, unlabelled
CAN_1 combination — chip select GPIO 26, INT GPIO 16 — is the pre-Rev2.1
compatibility position; GPIO 26 is not an SPI chip select at all but a software
`cs-gpios`.

`spi1` has to be switched on separately — the `mcp251xfd` overlay only enables
`spi0`. The dependency is stronger than a status flag and the **order is
load-bearing**: `mcp251xfd` disables the conflicting `spidev` with
`target-path = "spi1/spidev@0"`, and a `target-path` only resolves against a node
that already exists. Listed after the CAN entries, that fragment is a no-op and
`spidev` keeps the chip select. `_semantic_validate()` enforces both the presence
and the ordering, and that `spi1-<N>cs` exposes enough chip selects for the ones
in use.

> ⚠️ **`dtoverlay=spi1-3cs` claims GPIO 16 and GPIO 17** as CS1/CS2 even though
> mode A uses only CS0. It is what Waveshare publishes, so it is what ships — but
> if something else in a derived variant wants those pins, `spi1-1cs` is
> sufficient for mode A.

There is one in-tree overlay that looks like it should do all of this in a single
line, and it is a trap:

> 🚨 **Do not use `dtoverlay=waveshare-can-fd-hat-mode-a`.** The in-tree overlay
> of that name hardcodes CAN_1 at chip select GPIO 26 and INT GPIO 16 — the
> *pre-Rev2.1* resistor placement. On a current board it produces a `can1` that
> never probes or never receives, and its name actively suggests otherwise.
> Explicit `mcp251xfd` lines are the only safe form.

### ⚠️ Which connector is `can0` is NOT fixed on this variant

> **This image ships the race, deliberately and knowingly.** On any given boot,
> `can0` may be either physical connector. Read this section before wiring a
> production bus.

The MCP2515 HAT gets a stable mapping from the overlay order trick documented
[above](#overlay-order-is-load-bearing), because both chips are children of the
*same* `&spi0` node and device-tree child order decides probe order. **That
argument does not survive mode A**, where the chips sit on two different SPI
controllers.

The kernel assigns the number first-come-first-served. `alloc_candev()` passes
the literal format string:

```c
dev = alloc_netdev_mqs(size, "can%d", NET_NAME_UNKNOWN, can_setup, txqs, rxqs);
```

and the `%d` is only resolved inside `register_netdevice()` → `__dev_alloc_name()`,
which hands out the **lowest free index** to whichever chip calls
`register_candev()` first. Four independent things decide that order, none of
them ordered:

| Source | Why it is not deterministic |
| --- | --- |
| Two driver *modules* | `spi-bcm2835.ko` (SPI0) and `spi-bcm2835aux.ko` (SPI1) are loaded from `MODALIAS` uevents by **parallel udev workers**. No dependency edge between them. |
| Two controller probes | `of_register_spi_devices()` walks children *per controller*. `spi0.0` and `spi1.0` are walked in two separate invocations. |
| Deferred probe | `mcp251xfd_probe()` can return `-EPROBE_DEFER` from `devm_clk_get_optional()` / `devm_regulator_get_optional()`. A device that defers loses its place entirely — and SPI1 depends on the `aux` clock while SPI0 does not, so asymmetric deferral is expected. |
| Waveshare's own FAQ | *"Every time I turn it on, I find that the order of CAN0 and CAN1 is random"* — the vendor documents it as a known property. |

**Renaming to `can0`/`can1` does not fix it either**, which is why nothing here
tries. systemd issues a single `RTM_SETLINK` with no swap handling, and the
kernel refuses a name another interface still holds:

```c
} else if (netdev_name_in_use(net, want_name)) {
        return -EEXIST;
}
```

On the unlucky boot *both* renames target the name the other interface holds, so
both fail and the channels stay swapped. It is at least loud about it —
`log_device_error_errno(… "Failed to rename network interface %i from '%s' to
'%s'")` — but a journal line is not a working bus. `systemd.link(5)` says as
much: *"specifying a name that the kernel might use for another interface … is
dangerous … It is best to use some different prefix."*

#### Living with it

Check the mapping on the device rather than assuming it — the chip select column
is read from `/sys` and is the truth:

```console
$ bgrpiimage-setup can status
  can0   spi0.0   gpio 25 ...
  can1   spi1.0   gpio 24 ...
```

`spi0.0` is the connector labelled **CAN_0**, `spi1.0` is **CAN_1**. If they are
the other way round, they swapped on this boot.

#### Pinning it yourself (opt-in, not shipped)

If a deployment needs a fixed mapping, `.link` files matched on the SPI device
path do it properly. `Path=` matches `ID_PATH`, and udev's `path_id` builtin has
had an SPI handler since **systemd 246** (Trixie ships 257). Note `cs-N` is the
*chip select*, not the bus — both channels are `cs-0`, and the discriminator is
the platform device address.

```ini
# /etc/systemd/network/60-can10.link      → CAN_0, spi0.0, INT GPIO 25
[Match]
Driver=mcp251xfd
Path=platform-3f204000.spi-cs-0 platform-fe204000.spi-cs-0

[Link]
Name=can10
TransmitQueueLength=1024
```

```ini
# /etc/systemd/network/60-can11.link      → CAN_1, spi1.0, INT GPIO 24
[Match]
Driver=mcp251xfd
Path=platform-3f215080.spi-cs-0 platform-fe215080.spi-cs-0

[Link]
Name=can11
TransmitQueueLength=1024
```

`3f…` is BCM2836/2837 (Pi 2/3), `fe…` is BCM2711 (Pi 4/CM4). Read the real value
with `udevadm test /sys/class/net/can0 2>&1 | grep ID_PATH=` and paste it in.

Three things make this work, and each is a way to get it wrong:

- **Rename into a different namespace.** `can10`/`can11` can never be assigned
  automatically, because `__dev_alloc_name()` returns the *lowest* free index —
  with two (or even four, stacked) channels the kernel never reaches 10.
- **Sort before `70-can<N>.link`.** Only the **first** matching `.link` applies,
  so a `60-` file replaces the shipped one entirely — hence
  `TransmitQueueLength=` is repeated above. Omit it and the queue silently falls
  back to the CAN core default of 10.
- **Retarget the `.network` files too**, to `Name=can10` / `Name=can11`, or the
  `[CAN]` block stops matching and the bus comes up unconfigured.

> **Pi 5 / CM5 is different hardware here.** BCM2712 has no AUX block at all —
> `spi0`–`spi5` all come from RP1 over PCIe as `snps,dw-apb-ssi` *with* DMA. The
> `platform-…` `ID_PATH` shape above therefore does not apply and these files
> will not match. The variant still targets Pi 5, it simply has no pinning there
> either; anyone wanting it must read the real `ID_PATH` off the board. See also
> [raspberrypi/linux#6644](https://github.com/raspberrypi/linux/issues/6644),
> an open Pi 5 issue with this exact HAT.

### The AUX SPI controller is the asymmetric half

Broadcom's own datasheet calls SPI1/SPI2 *"secondary **low throughput** SPI
interfaces"* and adds: *"doing so requires significant CPU involvement as they
have shallow FIFOs and **no DMA support**."* The official Raspberry Pi docs list
DMA for SPI0 and SPI3–6 and omit SPI1/2. In the driver, `grep -c dma`
`spi-bcm2835aux.c` returns **0**, and transfers move three bytes at a time with
at most twelve in flight (`pending < 12`, i.e. the 4×32-bit FIFO).

Practically: **CAN_1 costs roughly an order of magnitude more SPI interrupts than
CAN_0 for the same CAN load.** Bandwidth is not the constraint — 2 Mbit/s of FD
traffic is a small fraction of ~16.7 MHz SPI — interrupt rate and latency are.
Expect the two channels to behave *asymmetrically* under load; that is the
defining property of mode A.

It is not all cost. `spi_sync()` runs inline when the controller queue is empty,
and two chips on one controller serialise on `ctlr->io_mutex`. Splitting across
SPI0 and SPI1 gives each chip its own controller and removes that head-of-line
blocking, so **do not "fix" this by consolidating both channels onto spi0.**

Three operational consequences worth knowing:

- **`core_freq_fixed=1` matters more here than anywhere else**, and it is already
  set. Without it the SPI divisor is computed against the turbo core rate while
  the core idles lower, so the bus runs *slower* than intended — up to 2.5× on a
  Pi 4. It cannot violate the errata (SCK only ever ends up too slow), but it
  costs latency and jitter.
- **Do not enable the mini-UART on a board using spi1.** `uart1`, `spi1` and
  `spi2` all carry `interrupts = <1 29>` — one shared IRQ for the whole AUX
  block — and the AUX SPI driver registers `IRQF_SHARED`. `enable_uart=1` on a
  Bluetooth model, or `dtoverlay=miniuart-bt`, puts UART traffic on CAN_1's
  interrupt path. Prefer `dtoverlay=disable-bt`.
- **Keep `cs-gpios`.** Native chip select is broken on AUX — the driver says so
  itself (*"Native CS is not supported - please configure cs-gpio in
  device-tree"*), and `mcp251xfd` relies on `cs_change` across up to 32 transfers
  per message. The stock `spi1-3cs` overlay supplies them, which is the real
  reason to use it rather than hand-rolling an spi1 node.

#### Measuring it

The AUX driver exposes exactly the right counters:

```console
$ ls /sys/kernel/debug/spi-bcm2835aux-fe215080.spi/
count_transfer_polling  count_transfer_irq  count_transfer_irq_after_poll
```

`count_transfer_irq_after_poll` climbing is the direct fingerprint of the core
clock running below the rate the divisor assumed — i.e. proof that
`core_freq_fixed=1` is *not* doing its job. The single most diagnostic
measurement, though, is simpler: run symmetric traffic on both channels and
compare `overrun` in `ip -s -d link show`. A divergence between `can0` and `can1`
is the AUX bottleneck showing itself.

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
| one `mcp251xfd` overlay per `can.interfaces[]` | The overlay carries no interface name, so counts are the only cross-check. Catches two entries collapsing into one for want of an `id`. |
| each `mcp251xfd` ⇒ exactly one real `spi<n>-<m>` | Marked *"(boolean, required)"*; with none the overlay stays on its default target. SPI0 has no `spi0-2`, and an unknown param name is dropped without complaint. |
| each `mcp251xfd` ⇒ its own `params.interrupt`, and no `spimaxfrequency` | Every instance defaults to GPIO 25. `spimaxfrequency` is the MCP2515 spelling and would be silently ignored here. |
| `spi1`/`spi2` in use ⇒ `spi<n>-<N>cs` present, wide enough, and listed **first** | `mcp251xfd` disables `spidev` by `target-path`, which only resolves if that node already exists. |
| `speed` above `oscillator / 2 × 0.85` → **note, not refusal** | The driver clamps to it (errata DS80000789 #4), so a higher value is safe — and upstream's own overlay default exceeds it. The note says `config.txt` states a clock nothing honours. |
| `dbitrate` ⇒ not an `mcp2515-*` board, and `dbitrate ≥ bitrate` | The MCP2515 is Classic-CAN only. A data phase slower than arbitration is a swapped pair. |
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
