# 🧬 Variants — composition via `extends`

A **variant** is one buildable image configuration. Variants live in
`config/variants/*.json` and are discovered automatically by the CI matrix.

Instead of copy-pasting a 200-line base config into every new variant, a
child variant **extends** a parent and adds only what differs.

---

## 🏗️ How merging works

```text
  base.json                    canbus-plattform.json
  ─────────                    ─────────────────────
  packages: [vim, jq]          packages: [can-utils]
  users:    [admin:[sudo]]     users:    [admin:[spi, i2c]]
  boot_config.dtoverlays: []   boot_config.dtoverlays: [mcp2515-can0,
                                                        mcp2515-can1]
  can: (absent)                can: { interfaces: [can0, can1] }
```
After merge:

```text
  packages: [vim, jq, can-utils]           ← scalar array: concat + dedupe
  users:    [admin:[sudo, spi, i2c]]       ← named record: by-name merge,
                                             groups concat
  boot_config.dtoverlays: [mcp2515-can0,   ← object array with `name` key:
                           mcp2515-can1]     by-name merge (no duplicates)
  can: { interfaces: [can0, can1] }        ← parent had no `can`, inherited
```
Merge rules are implemented in [`scripts/generate.py`](../scripts/generate.py)
(`deep_merge`):

| Value kind | Rule |
| --- | --- |
| Two objects (`dict`) | Recursive merge, child keys win on conflict. |
| Two lists of primitives | `parent + child`, stable-order dedupe. |
| Two lists of `{name: …}` records | Merge by `name`; entries with matching names deep-merge. |
| Two lists (mixed / no `name`) | Plain concatenation. |
| Anything else | Child value replaces parent value. |

---

## 📝 Creating a new variant

### Scenario: a variant for a GPS-equipped Pi 4 fleet

Starting from `base.json`, we want to add:

- a `ublox-gps` APT package
- a `dialout` group membership (for `/dev/ttyS0`)
- UART enabled on the Pi
- a different hostname

Create `config/variants/gps-tracker.json`:

```json
{
  "$schema": "../schema.json",
  "extends": "./base.json",

  "variant": {
    "name": "gps-tracker",
    "description": "BAUER GROUP GPS telemetry image (u-blox via UART)",
    "version": "0.1.0"
  },

  "hostname": "bg-gps",

  "users": [
    { "name": "admin",
      "password": "${ADMIN_PASSWORD:-12345678}",
      "groups": ["dialout"],
      "shell": "/bin/bash",
      "sudo_nopasswd": true }
  ],

  "packages": ["gpsd", "gpsd-clients"],

  "boot_config": {
    "enable_uart": true,
    "disable_bluetooth": true
  }
}
```
That's it. 25 lines. Validate, render, build:

```bash
./tools/run.sh validate gps-tracker
./tools/run.sh render   gps-tracker
./tools/run.sh build    gps-tracker
```
The CI matrix picks it up automatically on the next push.

---

## 🧠 Naming conventions

| What | Convention | Example |
| --- | --- | --- |
| Variant file | `kebab-case.json` | `canbus-plattform.json` |
| Variant name | same slug | `"name": "canbus-plattform"` |
| Hostname | DNS-safe (`[a-z0-9-]{1,63}`) | `bg-canbus` |
| Version | SemVer | `"0.1.0"` |

The hostname schema regex rejects uppercase and underscores — this is
deliberate, matches Linux `hostname` conventions, and keeps DNS happy.

---

## ⛓️ Extends chain

Chains are allowed — a child can extend a parent that itself extends another:

```text
common.json  ◀─── fleet-eu.json  ◀─── gps-tracker-eu.json
```
The generator follows links recursively and detects cycles (raises
`ValueError("circular extends chain")`).

Practical guidance:

- Keep the chain shallow (≤ 2 levels). Debuggability degrades fast with depth.
- If you find yourself writing a 3-level chain, that's a signal the base
  needs refactoring — pull the shared layer up.

---

## 🔍 Inspecting the merged config

The generator can print the fully resolved, schema-validated JSON to stdout:

```bash
./tools/run.sh shell
# inside container:
python scripts/generate.py config/variants/canbus-plattform.json --json | jq '.'
```
Useful for answering "where does this user's group list actually come from"
without grep'ing multiple files.
