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
| `boot_config` | I2C/SPI/I2S/UART, BT/WiFi off, raw `dtoverlays`, `extra_lines` | ✅ | ✅ | ✅ | ✅ |
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
  Celsius.
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
- **`nvme_boot: true`** — handled by the `bootloader` block (see below);
  still useful here to signal intent.

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

## 🚨 Cross-field validation

Enforced in [`scripts/generate.py`](../scripts/generate.py) `_semantic_validate()`:

| Rule | Reason |
| --- | --- |
| `overclock.enabled` ⇒ `overclock.accept_warranty_void` | Overclocking flips the OTP warranty bit. |
| `fan.enabled` ⇒ `fan.mode ∈ {gpio,pwm,emc2301}` | `gpio-fan`/`pwm-fan`/`rpi-fan` pick different overlays. |
| `rtc.enabled` ⇒ `rtc.model` | Each chip has its own `i2c-rtc` overlay param. |

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
