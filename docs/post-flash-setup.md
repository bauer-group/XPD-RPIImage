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
> | `can status` showing `restart-ms` guidance | v0.7.3 |
> | `can status` showing the error counters; argument validation and wrong-interface guards | v0.7.4 |
> | `ip ... static` accepting `""` for "no DNS" | v0.7.4 |
>
> From **v0.8.0** the helper can replace itself, so a newer one no longer
> needs a new image:
>
> ```bash
> sudo bgrpiimage-setup update --self
> ```
>
> On an image older than that the subcommand does not exist yet — bootstrap
> it once, then use the subcommand from then on:
>
> ```bash
> sudo curl -fsSL --proto '=https' --tlsv1.2 -o /usr/local/sbin/bgrpiimage-setup \
>     https://github.com/bauer-group/XPD-RPIImage/releases/latest/download/bgrpiimage-setup
> sudo chmod 0755 /usr/local/sbin/bgrpiimage-setup
> ```
>
> This updates the **helper only**. `config.txt` overlays, systemd units and
> the MOTD still come from the flashed image — see
> [Updating an installed system](#-updating-an-installed-system).

---

## 🔐 Password

```bash
# change admin's password (the default user)

sudo bgrpiimage-setup password

# change another account

sudo bgrpiimage-setup password alice
```

Behind the scenes this runs `passwd <user>` and clears **that user's**
line from `/etc/bgrpiimage-default-password-active`; the file is removed only
once the last line is gone. The MOTD stops warning about that account on the
next login, and keeps warning about any other account still on its shipped
password.

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
   a ~2 minute `wait-online` stall back into every boot — and, if the image
   uses the (non-default) Docker runtime, Docker plus the Portainer
   first-boot install queue behind `network-online.target` too. Under the
   default Podman runtime there is no such dependency (`podman.socket` and
   Portainer's Quadlet unit don't order on `network-online.target`), but the
   boot stall itself is reason enough on its own.

Bluetooth is unaffected by all of this — it is enabled by the image itself.

```bash
networkctl status wlan0
```

---

## 🚌 CAN

```bash
# chip select, IRQ line + count, bitrate, link state, restart-ms and
# the CAN error counters, per interface

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
which sorts before — and therefore **replaces** — the shipped
`40-can<N>.network`. systemd applies the first matching `.network` in
alphanumeric order and ignores every later one; two `.network` files are never
merged. An override written by a helper older than v0.7.3 carries no
`RestartSec=`, so it silently turns bus-off recovery back off. `can txqueuelen` writes
`/etc/systemd/network/05-bgrpiimage-<iface>.link`, which sorts before — and
likewise replaces — the shipped `70-can<N>.link`. Delete either to go back to
the image default.

Both commands refuse an interface that is not a CAN device, and `ip` refuses
one that is. The file they would write replaces the real configuration for
that interface, so `can bitrate eth0` used to swap eth0's DHCP settings for an
inert `[CAN]` section — dropping the operator's own SSH session — and `ip can0
dhcp` used to delete the bitrate and bus-off recovery. Both now fail with an
error and write nothing.
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

### Bus-off auto-recovery

`can status` prints the controller state and its recovery setting together:

```text
can state ERROR-ACTIVE restart-ms 100
```

`ERROR-ACTIVE` is healthy. **`restart-ms 0` is not** — it means a controller
that goes bus-off stays there until someone cycles the link by hand, and on the
MCP2515 the driver additionally puts the chip to sleep. Images from **v0.7.3**
ship `restart-ms 100`; see
[`hardware.md`](hardware.md#bus-off-recovery) for the mechanism.

> ⚠️ **Units flashed before v0.7.3 have `restart-ms 0`.** There is no in-place
> update path for the shipped `.network` files, so a new image reaches them
> only by reflashing. Remediate over SSH instead — no reflash, no reboot.

**1 — Apply now** (bounces the bus briefly; `restart-ms` cannot be changed
while the link is up, so the link must go down first):

```bash
for i in can0 can1; do
  sudo ip link set "$i" down
  sudo ip link set "$i" type can bitrate 500000 restart-ms 100
  sudo ip link set "$i" up
done
```

**2 — Make it survive a reboot.** Write a drop-in against whichever `.network`
file actually applied — a `40-`/`05-` guess is what breaks here, and unlike a
second `.network` file, a `.network.d/*.conf` drop-in **is** merged onto the
file it belongs to:

```bash
for i in can0 can1; do
  f=$(networkctl status "$i" | awk -F': *' '/Network File:/{print $2}')
  sudo mkdir -p "$f.d"
  sudo tee "$f.d/10-bus-off-recovery.conf" >/dev/null <<'EOF'
[CAN]
RestartSec=100ms
EOF
done
sudo networkctl reload
```

**3 — Verify** (assert on the setting, not on symptoms — once `restart-ms` is
non-zero the driver stops emitting `bus-off` journal lines and the `bus-off`
counter stays at 0):

```bash
ip -details link show can0 | grep 'restart-ms 100'
```

Note that `ip link set can0 type can restart` returns `-EINVAL` once
`restart-ms` is set. That is expected: automatic recovery replaces the manual
one-shot.

---

## 🌐 IP configuration

All changes land as `/etc/systemd/network/05-bgrpiimage-<iface>.network`.
The `05-` prefix makes the file sort **before** the image default
`10-eth.network`, which is what makes it win:
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

# no DNS at all - an isolated plant LAN with no resolver

sudo bgrpiimage-setup ip eth0 static 10.0.0.5/24 10.0.0.1 ""
```

The address, gateway and DNS are validated before anything is written. An
out-of-range octet or prefix is refused here rather than by networkd, which
would otherwise reject the whole file and leave the interface with no address
while the command still reported success.

After each change the script reloads `systemd-networkd` and `reconfigures` the
affected interface — that one interface only. A failure is reported with a
pointer to `journalctl -u systemd-networkd`; the tool never restarts
`systemd-networkd` wholesale, because that re-applies every link including the
one carrying your SSH session. Verify:

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

## 🎛 Reaching Portainer

Images with `portainer.enabled` ship it pre-configured and bind it to
`0.0.0.0`, so it is reachable from the network as soon as the runtime brings
the unit up — at boot via Quadlet under Podman (the default), or via the
first-boot oneshot under the non-default Docker runtime:

| URL | Port |
| --- | --- |
| `https://<device>:9443` | HTTPS (self-signed certificate — expect a browser warning) |
| `http://<device>:9000` | HTTP |
| — | `8000` is the Edge agent tunnel, not a UI |

Portainer asks you to create the admin account **on first visit** and locks
itself after a timeout if nobody does. If you are greeted by "your Portainer
instance timed out for security purposes", restart it:

```bash
sudo systemctl restart portainer.service    # Podman (default)
sudo docker restart portainer               # Docker (non-default)
```

Check that Portainer actually started. Under Podman there is no sentinel
file and no oneshot — the Quadlet unit is generated fresh from
`/etc/containers/systemd/portainer.{container,image}` on every boot:

```bash
systemctl status portainer.service          # Podman (default) — quadlet-generated unit
sudo podman ps                              # confirm the container is up

systemctl status bgrpiimage-portainer-install.service   # Docker (non-default) only
```

---

## ⌨️ Shell aliases

Images from **v0.7.0** ship the usual list shortcuts, for every account
including `root` (Debian leaves these commented out in `/etc/skel/.bashrc` and
Raspberry Pi OS does not uncomment them, so stock images have no `ll`):

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
`networkctl status`), the CAN table from `can status`, the state of Bluetooth,
WiFi and rfkill, and both drop-in directories — `.network` files (owned by
`systemd-networkd`) and `.link` files (owned by `systemd-udevd`), listed
separately because the two are not interchangeable.

---

## 🔄 What `bgrpiimage-setup` does NOT do

- **Does not modify the underlying image.** Changes persist until you
  delete the drop-in file.
- **Does not configure Podman, Docker, Portainer or unattended-upgrades** — those are
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
| Portainer (Podman, default) | `sudo podman auto-update` (automatic at 05:30 via `podman-auto-update.timer`); manually: `sudo systemctl start podman-auto-update.service` |
| Portainer (Docker, non-default) | `docker compose -f /etc/bgrpiimage/portainer/docker-compose.yml pull && ... up -d` |
| `bgrpiimage-setup` itself | `sudo bgrpiimage-setup update --self` — fetches the helper from the latest release, verifies its checksum, and swaps it in. |
| Everything else bgRPIImage generates — `config.txt` overlays, systemd units, the MOTD, network and CAN configuration | `sudo bgrpiimage-update apply`. Run `plan` first to see what would change. Needs outbound HTTPS to github.com. |
| Users, passwords, sudo, PAM, sshd | **Reflash.** Deliberately out of scope — see below. |
| A release that moved to a new Raspberry Pi OS | **Reflash.** The updater refuses it rather than applying configuration built against a different base. |

```bash
sudo bgrpiimage-update check      # is there anything new?
sudo bgrpiimage-update plan       # what would change, without changing it
sudo bgrpiimage-update apply      # do it
sudo bgrpiimage-update status     # image version, config version, pending reboot
sudo bgrpiimage-update rollback   # restore the files the last apply replaced
```

### What it will refuse to do

The refusals are the point. Each one exists because the alternative is a
device that reports success and is quietly wrong:

- **A bundle for another variant, or an older version.** `--version` overrides
  the second: going back deliberately is how you undo a bad release.
- **A release built on a different Raspberry Pi OS.** That is a reflash, and
  the device knows because `/etc/bgrpiimage-release` records the base image it
  was built from.
- **An image that predates in-place updates.** It carries none of the identity
  the checks need, and guessing is not better than saying so.
- **An operator override that would swallow a new setting.** `bgrpiimage-setup
  can bitrate` writes `05-bgrpiimage-<iface>.network`, which sorts before — and
  therefore *replaces* — the shipped file. If a release adds a key the override
  does not carry, that key can never reach the interface, and nothing would
  warn. The updater stops and names the setting that would be lost.
- **Anything during the unattended-upgrades reboot window**, which issues
  `shutdown -r +1` and could land mid-apply.
- **A bundle that is not signed, or signed by a key this device does not
  trust.** See below.

### Signatures

Every bundle carries an Ed25519 signature over its manifest, and the manifest
carries a SHA-256 for every file in it — so one signature covers the whole
bundle: the signature authenticates the manifest, the manifest authenticates
the contents. The device checks it *before* it reads anything else.

The checksum published beside a bundle is not a substitute. It proves the
download was not corrupted; it proves nothing about who produced it, because
whoever can replace the bundle can replace the checksum next to it.

Public keys live in `/usr/share/bgrpiimage/trusted-keys.d/` and ship with the
image. Any key in that directory may vouch for a bundle, which is what allows
a key to be rotated without reflashing: a release signed with the current key
can deliver a new public key into that directory, and the next release may be
signed with either. Nothing is ever trusted that was not already on the device
or delivered by something that was.

Verification uses `openssl`, which is already present on every image as a
dependency of `ca-certificates` — a signature format needing a package the
device cannot install without an update would be circular.

> **Images from before signing carry no trust directory** and will refuse every
> bundle, saying so explicitly. They can be brought up by hand once — see
> below — or reflashed.

### Bootstrapping a device from before in-place updates

A unit flashed before this mechanism existed is missing four things: the
updater itself, the trust directory, a current helper, and the identity fields
the safety checks read. All four can be installed once, over SSH, without
reflashing. Everything fetched here is a published release asset.

```bash
R=https://github.com/bauer-group/XPD-RPIImage/releases/latest/download

sudo curl -fsSL --proto '=https' -o /usr/local/sbin/bgrpiimage-update "$R/bgrpiimage-update"
sudo curl -fsSL --proto '=https' -o /usr/local/sbin/bgrpiimage-setup  "$R/bgrpiimage-setup"
sudo chmod 0755 /usr/local/sbin/bgrpiimage-update /usr/local/sbin/bgrpiimage-setup

sudo install -d /usr/share/bgrpiimage/trusted-keys.d
sudo curl -fsSL --proto '=https' \
     -o /usr/share/bgrpiimage/trusted-keys.d/bgrpiimage-recovery.pub \
     "$R/bgrpiimage-recovery.pub"
```

Then record what the image was built from, which the old release file does not
say:

```bash
sudo tee -a /etc/bgrpiimage-release >/dev/null <<'EOF'
BGRPIIMAGE_BASE_IMAGE_SHA256='acff736ca7945e3b305f07cda4abdb870910e12634991da69783611756e381b3'
BGRPIIMAGE_APPLY_CONTRACT=1
EOF

sudo bgrpiimage-update plan     # look before you leap
sudo bgrpiimage-update apply
```

**Why that hash is safe to write.** It is the base image every release since
**v0.5.0** has been built on — the switch to Raspberry Pi OS Lite — and it has
not changed since. Check the first line of `sudo bgrpiimage-setup status`: if
the device reports **v0.5.0 or newer**, it is provably on that base and the
value above is correct for it.

> ⚠️ **A device older than v0.5.0 is on a different base OS.** Do not write
> that hash there. Reflash instead — the whole point of the check is that
> configuration built for one base must not be applied on top of another.

Nothing here is a special code path: after the four files are in place the
device is indistinguishable from one flashed with a current image, and every
refusal and verification described above applies to it unchanged. The procedure
is exercised end to end in `tests/test-update.sh`.

### What it never touches

`/etc/shadow`, `/etc/passwd`, sudoers, PAM, sshd host keys, `/etc/hostname`,
`/etc/hosts`, `/etc/resolv.conf`, stored WiFi PSKs, rfkill state, your own
`05-bgrpiimage-*` overrides, `/etc/docker/daemon.json`, `cmdline.txt` and
`fstab`. The list is enforced inside the one function that writes, not left to
each module to respect. The Podman equivalents (`/etc/containers/*`,
`/etc/sysctl.d/98-podman.conf`,
`/etc/systemd/journald.conf.d/99-bgrpiimage-containers.conf`) are image-only
for the same reason, without needing their own deny-glob entry —
`bgrpiimage-podman` ships no `apply.sh`, so there is no live-update code path
that could touch them in the first place.

`/etc/bgrpiimage-release` is on that list too: it records the **flashed**
image and has to keep doing so, because it is the input to the base-image
check. The applied configuration version lives in `/etc/bgrpiimage-applied`,
and the MOTD shows both when they differ.

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
