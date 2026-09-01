# 💾 Flashing a BAUER GROUP Raspberry Pi image

Three supported paths, ordered by convenience:

1. [**Raspberry Pi Imager** (recommended)](#1-raspberry-pi-imager-recommended) — via our custom repository URL, includes Compute Module (CM4 / CM5) eMMC flashing.
2. [**balenaEtcher** "Flash from URL"](#2-balenaetcher-flash-from-url) — works for SD cards and manually-mounted CM eMMC.
3. [**Manual `dd`**](#3-manual-dd) — air-gapped / scripted bootstrap.

All three verify against the same SHA-256 checksums published alongside every release.

---

## Storage requirements

Check the **uncompressed** size, not the download. Flashing tools compare the
extracted image against the raw capacity of the target device, and a card or
eMMC that is nominally "8 GB" holds noticeably less.

| Source of truth | Where |
| --- | --- |
| Uncompressed size | `extract_size` in the release's `*.manifest.json`, and the "Extracted size" column on the [landing page](https://bauer-group.github.io/XPD-RPIImage/) |
| Locally | `xz -l --robot foo.img.xz \| awk '/^file/{print $5}'` |

Rules of thumb for the current images:

- **SD card / USB SSD** — 8 GB nominal is enough, 16 GB recommended so Docker
  images and volumes have room after the first-boot rootfs expansion.
- **CM4 / CM5 eMMC** — a nominal 8 GB module exposes roughly **7.6–7.82 GB**
  (7.09–7.28 GiB) of user area; the exact figure varies by eMMC vendor by up to
  ~200 MB. Measure it rather than assuming:

  ```bash
  # with the CM in USB mass-storage mode via rpiboot
  sudo blockdev --getsize64 /dev/sdX     # bytes, compare against extract_size
  ```

> **Note on units.** Raspberry Pi Imager labels its figures "GB" but computes
> them in **GiB** (1024³). So an Imager message like "requires 7.6 GB" and a
> module it reports as "7.3 GB" are both GiB — the comparison is consistent, and
> the image simply does not fit. Do not convert only one side of it.

Both variants are built on Raspberry Pi OS **Lite**, specifically so they clear
this ceiling with room to spare. If you fork this repo and repoint
`base_image.url` at the Desktop edition, the produced image will no longer fit a
CM4 eMMC — [`config/schema.json`](../config/schema.json) rejects that URL for
exactly this reason.

---

## 🌐 Catalog URL

```text
https://bauer-group.github.io/XPD-RPIImage/rpi-imager.json
```

This JSON catalog always points at the **latest release**. The same origin
also serves a browsable landing page:
[https://bauer-group.github.io/XPD-RPIImage/](https://bauer-group.github.io/XPD-RPIImage/).

The catalog is regenerated automatically on every new GitHub release.

---

## 1) Raspberry Pi Imager (recommended)

Requires **Raspberry Pi Imager 1.8.5 or later** — older builds don't know about
Compute Modules and can't talk to `rpiboot`.

### Add the BAUER GROUP repository once

You need [Raspberry Pi Imager](https://www.raspberrypi.com/software/) **v2.0.3 or later**.
Older versions either lacked the persisted custom-repo UI entirely or required
launching with `--repo URL` every time (URL was forgotten between sessions).

**Option A — one-click deep link** (Imager 2.0.3+):

> [Open in Raspberry Pi Imager](rpi-imager://open?repo=https://bauer-group.github.io/XPD-RPIImage/rpi-imager.json)

Clicking the link asks your OS to hand the URL to Imager, which opens with
the catalog pre-loaded and a security-confirmation dialog.

**Option B — manual setup:**

1. Launch Imager, click the **⚙ Settings** icon (lower-right).
2. Scroll to **Custom repository**.
3. Paste:

   ```text
   https://bauer-group.github.io/XPD-RPIImage/rpi-imager.json
   ```

4. Close the dialog. Imager resets the current session and reloads the OS
   list automatically — **no manual restart needed**.

Our variants appear in **CHOOSE OS** as top-level entries named
`BAUER GROUP RPIImage - <variant> <version>`, filtered to the device you
picked under CHOOSE DEVICE. The catalog is a flat list, so there is no
"BAUER GROUP" submenu to open.

> **Why not "restart Imager"?** Earlier versions of these docs said to
> restart. That advice was wrong on Imager 2.0+ (the URL change auto-reloads)
> and counter-productive on Imager 1.x (the URL wasn't persisted, so a
> restart wiped it). Upgrade to 2.0.3+ and you're done after one paste.

### What about Imager's "OS Customization" dialog?

When you click **NEXT** after picking an image, Imager offers to set
hostname, username, WiFi, locale, and SSH keys. **Leave it disabled** for
our images — pick **"NO"** when asked whether to apply customization.

Our images bake all of that in at build time from
[`config/variants/<name>.json`](../config/variants/): the `admin` user
already exists (the stock `pi` user is removed), the hostname is per-variant
(`bg-rpi` for `base`, `bg-canbus` for `canbus-plattform` — see the `hostname`
key in the variant JSON), WiFi
and locale are pre-set, SSH is enabled. Imager's customization writes a
`custom.toml` / `firstrun.sh` that the stock raspios firstboot service runs
on first boot — and that service was designed to *rename* `pi`, which we
deleted. Effects when enabled anyway:

| Customization | Effect on our image |
| --- | --- |
| Hostname / locale / timezone | Overrides our defaults — usually harmless. |
| SSH `authorized_keys` | Appended to the existing `admin` user — works. |
| Username + password | Fragile. Tries to rename a `pi` user that doesn't exist; may silently fail or create a duplicate user beside `admin`. |
| WiFi SSID/PSK | Writes a second network config alongside ours — both get tried, messy. |

For per-device tuning either rebuild with an edited variant JSON, or after
flashing SSH in as `admin` / `12345678` (you will be prompted to set a new
password immediately) and change what you need. For
fleet-wide customization the source of truth lives in
[`config/variants/`](../config/variants/) — that's the audit trail.

### Flashing an SD card / USB SSD

1. Pick your device under **CHOOSE DEVICE** (Pi 4, Pi 5, etc.).
2. **CHOOSE OS** → pick `BAUER GROUP RPIImage - <variant> <version>`.
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
   [landing page](https://bauer-group.github.io/XPD-RPIImage/) for current tags.
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

> The images ship with **published default credentials** — deliberately, so a
> public image is usable. The admin password is expired at build time and must
> be changed at first login; the WiFi PSK is not, so treat an untouched image
> as lab-only until you rotate it.
>
> - `admin` → `12345678`
> - WiFi PSK (`IOT @ BAUER-GROUP`) → `12345678`

The admin password change is enforced at first login. Rotate the PSK too, or
bake real values at build time via
`.env` → see [post-flash-setup.md](post-flash-setup.md) and the security
section of the main [README](../README.md).
