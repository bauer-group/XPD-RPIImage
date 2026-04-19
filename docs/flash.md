# 💾 Flashing a BAUER GROUP Raspberry Pi image

Three supported paths, ordered by convenience:

1. [**Raspberry Pi Imager** (recommended)](#1-raspberry-pi-imager-recommended) — via our custom repository URL, includes Compute Module (CM4 / CM5) eMMC flashing.
2. [**balenaEtcher** "Flash from URL"](#2-balenaetcher-flash-from-url) — works for SD cards and manually-mounted CM eMMC.
3. [**Manual `dd`**](#3-manual-dd) — air-gapped / scripted bootstrap.

All three verify against the same SHA-256 checksums published alongside every release.

---

## 🌐 Catalog URL

```text
https://rpi.pages.dvcs.app.bauer-group.com/rpi-imager.json
```

This JSON catalog always points at the **latest release**. The same origin
also serves a browsable landing page:
[https://rpi.pages.dvcs.app.bauer-group.com/](https://rpi.pages.dvcs.app.bauer-group.com/).

The catalog is regenerated automatically on every new GitHub release.

---

## 1) Raspberry Pi Imager (recommended)

Requires **Raspberry Pi Imager 1.8.5 or later** — older builds don't know about
Compute Modules and can't talk to `rpiboot`.

### Add the BAUER GROUP repository once

1. Install [Raspberry Pi Imager](https://www.raspberrypi.com/software/).
2. Launch it, click the **⚙ Settings** icon (lower-right).
3. Scroll to **Custom repository**.
4. Paste:
   ```text
   https://rpi.pages.dvcs.app.bauer-group.com/rpi-imager.json
   ```
5. Close the settings dialog → **restart Imager**.

Our variants now appear under **CHOOSE OS → BAUER GROUP** whenever you pick
a compatible target device.

### Flashing an SD card / USB SSD

1. Pick your device under **CHOOSE DEVICE** (Pi 4, Pi 5, etc.).
2. **CHOOSE OS → BAUER GROUP → <variant>**.
3. **CHOOSE STORAGE → your SD card / SSD**.
4. Click **NEXT**, confirm, wait for verify.

Imager verifies both the compressed `.img.xz` (download) and the extracted
`.img` (after xz decode) against the published SHA-256. No manual verification
needed.

### Flashing a Compute Module eMMC via `rpiboot`

The CM doesn't expose its eMMC as a plain USB drive by default; it has to be
put into **rpiboot mode** first. Raspberry Pi Imager ≥ 1.8.5 integrates
`rpiboot` so you don't need the standalone tool.

#### CM4 (official IO-board)

1. Fit the jumper on **J2 "Disable eMMC Boot"**.
2. Connect the **USB-C slave port** (the *lower* one) to your computer. Do not
   use the "host" USB port.
3. Power the IO-board.
4. In Imager, **CHOOSE DEVICE → Compute Module 4**.
5. Imager will show "Connecting to Raspberry Pi..." and the CM appears as the
   target under **CHOOSE STORAGE** within a few seconds.
6. Pick the BAUER GROUP variant, flash.
7. Remove the jumper, power-cycle → the CM boots from eMMC.

#### CM5 (official IO-board)

1. Bridge the **`nRPIBOOT` test pad** (or use the fit-jumper on variants that
   have one — check the silkscreen; consumer IO-boards have a dedicated switch).
2. Connect the **USB-C slave port** → your computer.
3. Power the IO-board.
4. Imager detects the CM5 automatically. Flash as above.

> **Third-party carriers** (Waveshare, Seeed, Radxa, etc.) use different
> mechanisms to enter rpiboot. Check the carrier manual — usually a button
> press while powering up, or a jumper labelled `BOOT` / `nRPIBOOT`.

---

## 2) balenaEtcher "Flash from URL"

For SD cards and USB drives. balenaEtcher has **no `rpiboot` integration** —
Compute Modules need an external tool (`rpiboot` from
[raspberrypi/usbboot](https://github.com/raspberrypi/usbboot)) to be put into
mass-storage mode before Etcher sees them.

1. Open [balenaEtcher](https://etcher.balena.io/).
2. Click **Flash from URL**.
3. Paste the direct release URL, e.g. for the latest canbus-plattform:
   ```text
   https://github.com/bauer-group/XPD-RPIImage/releases/latest/download/bgrpiimage-canbus-plattform-vX.Y.Z.img.xz
   ```
   Replace `X.Y.Z` with the actual version — check our
   [landing page](https://rpi.pages.dvcs.app.bauer-group.com/) for current tags.
4. Select target → Flash.

Etcher verifies the SHA-256 of the decompressed image if our catalog is
reachable; otherwise it flashes without integrity check. For critical systems
prefer RPi Imager.

---

## 3) Manual `dd`

```bash
# 1) Fetch + verify
VARIANT=canbus-plattform
TAG=v0.1.0
BASE="https://github.com/bauer-group/XPD-RPIImage/releases/download/${TAG}"
curl -fLO "${BASE}/bgrpiimage-${VARIANT}-${TAG}.img.xz"
curl -fLO "${BASE}/bgrpiimage-${VARIANT}-${TAG}.img.xz.sha256"
sha256sum -c "bgrpiimage-${VARIANT}-${TAG}.img.xz.sha256"

# 2) Decompress
unxz "bgrpiimage-${VARIANT}-${TAG}.img.xz"

# 3) Flash (adjust /dev/sdX to YOUR target - double-check with lsblk!)
sudo dd if="bgrpiimage-${VARIANT}-${TAG}.img" \
        of=/dev/sdX \
        bs=4M conv=fsync status=progress
sync
```

For CM4 / CM5 via `rpiboot`:

```bash
# Linux: put the CM in USB mass-storage mode
git clone --depth=1 https://github.com/raspberrypi/usbboot
cd usbboot && make && sudo ./rpiboot

# The CM now appears as /dev/sdX - continue with dd as above.
```

---

## 🔐 Verify anytime

Every release asset is paired with a `.sha256` file. The landing page also
shows SHA-256 of both the compressed `.img.xz` AND the raw `.img` (useful if
you extract before flashing).

```bash
sha256sum -c bgrpiimage-*.img.xz.sha256
```

---

## 🚨 Default credentials

> The images ship with **demo credentials** — safe only on isolated lab
> networks.
>
> - `admin` → `12345678`
> - WiFi PSK (`IOT @ BAUER-GROUP`) → `12345678`

Rotate immediately on first boot, or bake real values at build time via
`.env` → see [post-flash-setup.md](post-flash-setup.md) and the security
section of the main [README](../README.md).
