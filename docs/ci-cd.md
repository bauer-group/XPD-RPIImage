# 🚀 CI / CD — GitHub Actions

The build pipeline lives in
[`.github/workflows/build.yml`](../.github/workflows/build.yml). It covers
validation, parallel matrix builds, and tagged releases.

---

## ⏱️ When it triggers

| Event | Triggers build? | Produces release? |
| --- | --- | --- |
| Push to `main` | ✅ (outside `paths-ignore`) | — |
| Push tag `v*.*.*` | ✅ | ✅ |
| Pull request to `main` | ✅ | — |
| `workflow_dispatch` (manual) | ✅ (`skip_build` toggle available) | — |

### `paths-ignore`

Pushes that only touch these paths do **not** trigger the workflow:

- `**.md` — documentation
- `docs/**` — this directory
- `LICENSE`
- `.gitignore`
- `.github/**` — workflow-only edits (run `workflow_dispatch` to test)

> Mixed commits — e.g. a workflow edit **plus** a `scripts/` change — DO trigger,
> because `paths-ignore` requires ALL changed files to match.

---

## 🧬 Jobs

```text
  ┌─────────────┐       ┌──────────────────────┐       ┌─────────────┐
  │ 🔍 Validate │──▶──▶│ 📦 Build <variant>   │──▶──▶│ 🚀 Release  │
  │  (10 min)   │       │  (parallel matrix)   │       │ (tag only)  │
  └─────────────┘       │      (120 min)       │       └─────────────┘
                        └──────────────────────┘
```

### 🔍 Validate

- Python 3.14 + `scripts/requirements.txt`
- `py_compile` on the generator
- `--dry-run` on every `config/variants/*.json`
- Smoke-render of `canbus-plattform` (catches code-path regressions)
- Computes the build matrix from `config/variants/*.json`
- Emits a Markdown summary: variant × version × schema pass

### 📦 Build (`matrix.variant`)

One parallel job per variant. Steps:

1. Checkout
2. Setup Python 3.14, install deps
3. Free runner disk (strips .NET / Android / Boost — saves ~10 GB)
4. Install host build deps (`qemu-user-static`, `kpartx`, `xz-utils`, …)
5. **Cache CustomPiOS** — keyed on `scripts/bootstrap.sh` hash
6. Resolve variant metadata → `full_tag`, suffix, start timestamp
7. Run `bash scripts/build.sh <variant>`
8. Compute SHA-256, size, byte count
9. Emit a full **build summary** (see below)
10. Upload artifact

### 🚀 Release

Fires only on `refs/tags/v*`. Downloads all variant artifacts, uploads as
Release assets, generates changelog from commits since last tag.

---

## 🏷️ Artifact naming

```text
  tag push          →  bgrpiimage-<variant>-v<version>
  push to main      →  bgrpiimage-<variant>-v<version>-<sha7>
  pull_request      →  bgrpiimage-<variant>-v<version>-pr<n>-<sha7>
  workflow_dispatch →  bgrpiimage-<variant>-v<version>-<sha7>
```

The same suffix flows through `scripts/build.sh` (via `VERSION` and
`IMAGE_SUFFIX` env vars) into the `.img.xz` filename — so the downloaded
file matches the artifact container name exactly.

### Why SHA-suffix on push?

Between `v0.1.0` and `v0.2.0` there can be dozens of commits, all declaring
`version: "0.1.0"` in the JSON. Without the SHA suffix, every push would
produce `bgrpiimage-canbus-plattform-v0.1.0.img.xz` and overwrite the prior
run's artifact. The SHA keeps them distinct.

---

## 🗄️ Storage

| Location | Lifetime | Trigger |
| --- | --- | --- |
| Actions artifact | **14 days** | every build |
| GitHub Release asset | **permanent** | tag push only |

> The TTL applies **only** to the Actions artifact. Release assets live in
> Release storage and persist until deleted manually. Tag builds therefore
> end up in BOTH stores — the artifact is a transient mirror.

Download locations:

- Actions artifact: _Actions → Run → Artifacts section_ (ZIP-wrapped)
- Release asset: _Releases → Tag → Assets_ (raw `.img.xz`)

---

## 📋 Step summary

Every build job writes a rich Markdown summary to `$GITHUB_STEP_SUMMARY`,
visible in the Actions UI sidebar:

```text
# 📦 canbus-plattform · v0.1.0-abc1234 · 🚧 DEV BUILD

> BAUER GROUP CANbus plattform - base image + Waveshare 17912 …

## 🎯 Target

| Variant | canbus-plattform |
| Hostname | bg-canbus |
| Architecture | arm64 |
| Hardware targets | rpi4, rpi5, cm4, cm5 |

## ⚙️ Feature matrix

| 🔒 SSH | ✅ | password auth, no root |
| 🐳 Docker | ✅ | CE + compose plugin, IPv6 NAT |
| 🚌 CAN | ✅ | can0 @ 500 kbit/s (txq=65535), can1 @ 500 kbit/s (txq=65535) |
| 🔄 Unattended upgrades | ✅ | window 02:00-04:00, reboot 03:00-05:00 |

## 🧩 Contents

| Installed packages | 17 |
| Users | 1 · admin |
| Device tree overlays | 2 · mcp2515-can0, mcp2515-can1 |

## 📦 Artifact

| File | bgrpiimage-canbus-plattform-v0.1.0-abc1234.img.xz |
| Compressed size | 651 MB |
| SHA-256 | 0123…abc |

## 🏷️ Build context

| Commit | abc1234 (linked) |
| Duration | 42m 17s |

### 🔐 Verify

echo "…  bgrpiimage-…img.xz" | sha256sum -c -
```

Kind badge:

| Badge | Event |
| --- | --- |
| 🏷️ RELEASE | tag push |
| 🔀 PR BUILD | pull_request |
| 🚧 DEV BUILD | push / dispatch |

---

## 🔐 Secrets

Set in _Repository Settings → Secrets and variables → Actions_:

| Name | Purpose | Default (CI) |
| --- | --- | --- |
| `ADMIN_PASSWORD` | Bakes into `users[].password` | `ci-placeholder-pw` |
| `WIFI_PSK` | Bakes into `network.wifi.networks[].psk` | `ci-placeholder-psk` |

Missing secrets fall back to the placeholders (so CI passes) — real
deployments should always set them.

---

## 🔁 Manual runs

_Actions → 📦 Build Image → Run workflow_:

- **Variant** — single variant name, or blank for all.
- **Skip build** — runs validate only (useful after tweaking the generator).

---

## 🧹 Cancel-on-push

`concurrency.group: build-${{ github.ref }}` with
`cancel-in-progress: true` means a new push to `main` cancels any running
build for `main`. Pull requests get separate concurrency groups per PR, so
PRs do not cancel each other.

This saves ~1 runner-hour per wasted build when force-pushing or fixing
typos rapidly.

---

## 📈 Performance knobs

| Lever | Impact |
| --- | --- |
| Cache hit on CustomPiOS clone | -5 s per build |
| Runner disk free-up step | enables the build to finish at all (stock image leaves ~15 GB) |
| Matrix parallelism | one runner per variant, runs in parallel |
| `fail-fast: false` | variant A's failure does not kill variant B mid-build |
| `concurrency.cancel-in-progress` | saves runner-hours on rapid pushes |
