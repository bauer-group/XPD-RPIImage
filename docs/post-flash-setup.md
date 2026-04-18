# 🔧 Post-flash setup

How to rotate credentials, change WiFi, switch between DHCP and static IP
**on the device** after flashing — without rebuilding the image.

> ⚠️ **Default credentials shipped by every image:**
>
> - `admin` user password → `12345678`
> - WiFi PSK for `IOT @ BAUER-GROUP` → `12345678`
>
> Change these immediately on first boot. The dynamic MOTD will warn on
> every login until you rotate the admin password.

---

## 🛠️ The `bgrpiimage-setup` helper

Every image installs `/usr/local/sbin/bgrpiimage-setup`. It covers the three
post-flash changes that otherwise require hand-editing `wpa_supplicant.conf`,
`systemd-networkd` drop-ins and `passwd`.

Always run it as root (`sudo`).

```bash
sudo bgrpiimage-setup help
```

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

```bash
# join a network (prompts for the PSK if omitted)
sudo bgrpiimage-setup wifi "MyNetwork"
sudo bgrpiimage-setup wifi "MyNetwork" "s3cret-pass"
sudo bgrpiimage-setup wifi "MyNetwork" "s3cret-pass" AT    # override country

# tear down WiFi entirely
sudo bgrpiimage-setup wifi --disable
```

The PSK is hashed via `wpa_passphrase` before being written to
`/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`, then
`wpa_supplicant@wlan0.service` is reloaded. Connection picks up within
a few seconds:

```bash
networkctl status wlan0
```

---

## 🌐 IP configuration

All changes land as `/etc/systemd/network/50-bgrpiimage-<iface>.network`.
The `50-` prefix wins over the image-default `10-*` / `20-*` unit files,
so changes are non-destructive and trivial to revert (just delete the file).

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
sudo rm /etc/systemd/network/50-bgrpiimage-eth0.network
sudo networkctl reload
```

The image-default drop-in takes over again.

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
- **Does not configure CAN, Docker, Portainer or unattended-upgrades** —
  those are variant-level concerns, change them in the JSON and rebuild.
- **Does not manage SSH keys.** Use `ssh-copy-id` from your workstation;
  `.ssh/authorized_keys` for the admin user is mode 700 / 600 already.
- **Does not configure static IPv6.** Pass `v6` addresses manually by
  editing the generated `50-bgrpiimage-<iface>.network` drop-in. Open an
  issue if you want this added as a subcommand.

---

## 🚚 Build-time alternative (for fleets)

If you manage many devices, bake credentials into the image instead:

```bash
cp .env.example .env
vim .env                         # set ADMIN_PASSWORD, WIFI_PSK
./tools/run.sh build canbus-plattform --env-file ./.env
```

See [`configuration.md`](configuration.md) for per-variant IP overrides
(static addresses, DNS, IPv6) that can be baked in.
