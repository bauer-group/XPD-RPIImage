# 🔧 Post-flash setup

How to rotate credentials, change WiFi, switch between DHCP and static IP
**on the device** after flashing — without rebuilding the image.

> ⚠️ **Default credential shipped by every image:** `admin` → `12345678`
>
> It ships **expired** (`chage -d 0`), so the first login — console or SSH —
> forces a change before a session is granted. The MOTD keeps warning until
> the account has actually been rotated, and stops on its own once it has.
>
> Images no longer carry a WiFi PSK: WiFi ships **disabled**. Enable it per
> device with `bgrpiimage-setup wifi enable`, or bake a network into the
> variant JSON.
>
> The console shows a normal login prompt. Raspberry Pi OS's own first-boot
> wizard (`userconfig.service`, which asked for an optional rename and its own
> password on `tty8`) is disabled at build time — it is `Type=oneshot` and
> ordered `Before=getty.target`, so it blocked the boot until somebody
> answered it.

---

## 🛠️ The `bgrpiimage-setup` helper

Every image installs `/usr/local/sbin/bgrpiimage-setup`. It covers the
post-flash changes that otherwise require hand-editing `wpa_supplicant.conf`,
`systemd-networkd` drop-ins, CAN `.link` files and `passwd`.

Always run it as root (`sudo`).

```bash
sudo bgrpiimage-setup help
```

> ⚠️ **Subcommands belong to the image, not to this page.** These docs track
> `main`; a flashed device is frozen at the version it was built from and
> nothing on it ever updates the helper. If a command below is rejected with
> `unknown command`, your image simply predates it — the docs are not wrong.
>
> Check what you are running — the first line of `status` is
> `bgRPIImage <variant> v<version>`:
>
> ```bash
> sudo bgrpiimage-setup status
> ```
>
> | Subcommand | Requires image |
> | --- | --- |
> | `password`, `ip`, `status` | any |
> | `wifi enable` / `wifi disable` / `wifi status` | v0.6.0 (v0.5.0 used bare `wifi SSID [PSK]` and `wifi --disable`) |
> | `can status`, `can bitrate` | v0.6.0 |
> | `can txqueuelen` | v0.6.1 |
>
> There is no in-place update path for the helper — **reflash** to move up.

---

## 🔐 Password

```bash
# change admin's password (the default user)

sudo bgrpiimage-setup password

# change another account

sudo bgrpiimage-setup password alice
```

Behind the scenes this runs `passwd <user>` and also removes the
`/etc/bgrpiimage-default-password-active` marker — the MOTD stops warning
about default credentials on the next login.

---

## 📡 WiFi

WiFi is **off** in every shipped image: no `20-wlan.network`, no
`wpa_supplicant` config, no stored PSK. `wlan0` therefore stays *unmanaged* by
`systemd-networkd` and cannot hold up `systemd-networkd-wait-online`.

```bash
# join a network (prompts for the PSK if omitted)

sudo bgrpiimage-setup wifi enable "MyNetwork"
sudo bgrpiimage-setup wifi enable "MyNetwork" "s3cret-pass"
sudo bgrpiimage-setup wifi enable "MyNetwork" "s3cret-pass" AT   # override country

# radio, regulatory domain and link state

sudo bgrpiimage-setup wifi status

# tear it down again (also removes the stored PSK)

sudo bgrpiimage-setup wifi disable
```

`wifi enable` does three things that a hand-written `wpa_supplicant.conf`
cannot:

1. **Lifts the rfkill soft block.** Raspberry Pi OS soft-blocks every radio at
   `rfkill` module init via `/etc/modprobe.d/rfkill_default.conf`
   (`options rfkill default_state=0`) until a regulatory domain is set. A
   `country=` line inside `wpa_supplicant.conf` cannot help — `ip link set
   wlan0 up` returns `-ERFKILL` before wpa_supplicant ever runs. The command
   writes `/etc/modprobe.d/zz-bgrpiimage-rfkill.conf`, unblocks the running
   system, and clears any saved WLAN block under `/var/lib/systemd/rfkill`
   (which `systemd-rfkill` would otherwise restore on the next boot).
2. **Hashes the PSK** with `wpa_passphrase`, so the plaintext never lands on
   disk.
3. **Writes `/etc/systemd/network/05-bgrpiimage-wlan0.network` with
   `RequiredForOnline=no`.** Without that line, an AP that is out of range puts
   a ~2 minute `wait-online` stall back into every boot, and Docker plus the
   Portainer first-boot install queue behind `network-online.target`.

Bluetooth is unaffected by all of this — it is enabled by the image itself.

```bash
networkctl status wlan0
```

---

## 🚌 CAN

```bash
# chip select, IRQ line + count, bitrate and link state per interface

sudo bgrpiimage-setup can status

# change a bitrate persistently

sudo bgrpiimage-setup can bitrate can0 250000

# change the tx queue length persistently (applies immediately too)

sudo bgrpiimage-setup can txqueuelen can0 1024
```

`can status` is the diagnosis to run first when a channel is silent. Expected
mapping is `can0` → `spi0.0` and `can1` → `spi0.1`; anything else means the
overlay order in `/boot/firmware/config.txt` is wrong.

> ⚠️ **Coming from v0.5.0 or older:** that mapping is new. Probe order used
> to give the name `can0` to the CS1 chip, i.e. to the terminal labelled CAN1.
> Re-check application config, DBC bindings and cable labelling after
> reflashing — see [`hardware.md`](hardware.md#-can-waveshare-17912-dual-mcp2515).

Read the IRQ counters at idle:

| Symptom | Meaning |
| --- | --- |
| Counter climbing with no bus traffic | The overlay points at a GPIO the HAT does not drive. The pin floats at the SoC pull-down and, because the overlay hard-codes `IRQ_TYPE_LEVEL_LOW`, reads as permanently asserted. |
| Counter stuck at 0 while traffic flows | The overlay points at the *other* chip's INT line. |

`can bitrate` writes `/etc/systemd/network/05-bgrpiimage-<iface>.network`,
which sorts before the shipped `40-can<N>.network`. `can txqueuelen` writes
`/etc/systemd/network/05-bgrpiimage-<iface>.link`, which sorts before the
shipped `70-can<N>.link`. Delete either to go back to the image default.
Bitrate and wiring live in the variant JSON — see
[`hardware.md`](hardware.md) for the INT GPIO map and why the overlay order
matters.

The two file *types* are not interchangeable. `systemd-networkd` reads
`.network` and owns `[CAN] BitRate=`; `systemd-udevd` reads `.link` and owns
`[Link] TransmitQueueLength=`. Both file types contain a section named
`[Link]`, but with disjoint key sets, so a key placed in the wrong one is
logged as unknown and discarded — the rest of the file still applies, which
makes the mistake invisible. The `[Match]` keys differ as well: `.network`
matches on `Name=`, `.link` has no `Name=` and spells it `OriginalName=`.

udev only reads `.link` files on a netdev *add* event, so restarting
`systemd-networkd` will never pick up a change — reboot, or use
`can txqueuelen`, which writes the file *and* sets the live link. The `txq`
column in `can status` shows what is actually in effect; a `txq` of `10` is
the CAN core default, meaning no `.link` file reached udev.

---

## 🌐 IP configuration

All changes land as `/etc/systemd/network/05-bgrpiimage-<iface>.network`.
The `05-` prefix makes the file sort **before** the image defaults
`10-eth.network` / `20-wlan.network`, which is what makes it win:
systemd-networkd applies only the first `.network` file whose `[Match]`
matches, in lexicographic order. The shipped defaults are left untouched, so
reverting is just deleting the file.

### DHCP (the default)

```bash
sudo bgrpiimage-setup ip eth0 dhcp
sudo bgrpiimage-setup ip wlan0 dhcp
```

### Static IPv4

```bash
# minimum: CIDR address

sudo bgrpiimage-setup ip eth0 static 10.0.0.5/24

# with gateway

sudo bgrpiimage-setup ip eth0 static 10.0.0.5/24 10.0.0.1

# with gateway + custom DNS

sudo bgrpiimage-setup ip eth0 static 10.0.0.5/24 10.0.0.1 192.168.1.53
```

After each change the script reloads `systemd-networkd` and
`reconfigures` the affected interface. Verify:

```bash
networkctl status eth0
ip -br addr show eth0
```

### Reverting to image defaults

```bash
sudo rm /etc/systemd/network/05-bgrpiimage-eth0.network
sudo networkctl reload
```

The image-default drop-in takes over again.

---

## ⌨️ Shell aliases

Images ship the usual list shortcuts, for every account including `root`
(Debian leaves these commented out in `/etc/skel/.bashrc` and Raspberry Pi OS
does not uncomment them, so stock images have no `ll`):

```bash
ll      # ls -la
la      # ls -A
l       # ls -CF
```

They are defined in `/etc/profile.d/50-bgrpiimage-shell.sh` and reach every
interactive shell: SSH, the serial console, `sudo -i`, `su -`, `sudo su -`,
plus `sudo su`, `sudo -s` and a bare `bash` via a hook in `/etc/bash.bashrc`.

> Aliases are an interactive convenience only. `sudo <cmd>` execs the binary
> directly and bash never expands aliases in a non-interactive shell, so
> `sudo ll` cannot work — use `sudo ls -la`. The same applies to scripts and
> to `ssh host '<cmd>'`.

Override or extend them per account in `~/.bashrc` or `~/.bash_aliases`; both
are read after the system defaults and win.

---

## 🔎 Current state

```bash
sudo bgrpiimage-setup status
```

Shows variant + version, hostname, all network interfaces (via
`networkctl status`), plus every active systemd-networkd drop-in and the
WiFi config path.

---

## 🔄 What `bgrpiimage-setup` does NOT do

- **Does not modify the underlying image.** Changes persist until you
  delete the drop-in file.
- **Does not configure Docker, Portainer or unattended-upgrades** — those are
  variant-level concerns, change them in the JSON and rebuild. For CAN it
  covers diagnosis and bitrate only; wiring, INT GPIOs and interface count stay
  build-time settings.
- **Does not update the platform.** See below.
- **Does not manage SSH keys.** `ssh-copy-id` from your workstation creates
  `~/.ssh` for you — the image ships no `authorized_keys` for `admin`. To bake
  keys in at build time instead, set `users[].ssh_authorized_keys` in the
  variant JSON (installed as a 700 directory with a 600 file).
- **Does not configure static IPv6.** Pass `v6` addresses manually by
  editing the generated `05-bgrpiimage-<iface>.network` file. Open an
  issue if you want this added as a subcommand.

---

## 🔄 Updating an installed system

Be clear about what can and cannot be updated in place:

| What | How |
| --- | --- |
| Debian and Raspberry Pi packages, including security fixes | Automatic, via `unattended-upgrades` inside the configured maintenance window — see [`banner-and-updates.md`](banner-and-updates.md). |
| Portainer | `docker compose -f /etc/bgrpiimage/portainer/docker-compose.yml pull && ... up -d` |
| Everything bgRPIImage itself generates — `config.txt` overlays, systemd units, the MOTD, `bgrpiimage-setup`, network and CAN configuration | **Reflash.** There is no in-place update mechanism, and nothing on the device knows about releases. |

So a device picks up OS security updates on its own, but a fix to the platform
(a corrected CAN interrupt pin, say) needs a new image. Grab it from
[Releases](https://github.com/bauer-group/XPD-RPIImage/releases) and reflash
per [`flash.md`](flash.md).

---

## 🚚 Build-time alternative (for fleets)

If you manage many devices, bake credentials into the image instead:

```bash
cp .env.example .env
vim .env                         # set ADMIN_PASSWORD (and WIFI_PSK if used)
./tools/run.sh build canbus-plattform --env-file ./.env
```

See [`configuration.md`](configuration.md) for per-variant IP overrides
(static addresses, DNS, IPv6) that can be baked in.
