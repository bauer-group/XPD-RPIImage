# 🚀 CI / CD — GitHub Actions

The build pipeline lives in
[`.github/workflows/build.yml`](../.github/workflows/build.yml). It covers
validation, parallel matrix builds, and tagged releases.

---

## ⏱️ When it triggers

| Event | Triggers build? | Produces release? |
| --- | --- | --- |
| Push to `main` | ✅ (outside `paths-ignore`) | — |
| Push tag `v*.*.*` (manual or PAT) | ✅ | ✅ attaches images |
| Tag from semantic-release | ✅ via dispatch — see note | ✅ attaches images |
| Pull request to `main` | ✅ | — |
| `workflow_dispatch` (manual) | ✅ (`skip_build` toggle available) | — |

> ℹ️ **How release images get attached.** semantic-release
> ([`release.yml`](../.github/workflows/release.yml)) creates the tag and the
> GitHub Release using the workflow's `GITHUB_TOKEN`. GitHub deliberately does
> **not** fire other workflows from `GITHUB_TOKEN` events (recursion
> prevention), so `build.yml`'s `tags: ["v*.*.*"]` trigger never runs on a
> released tag. `release.yml`'s `attach-images` job therefore dispatches the
> build itself, authenticated with the `PAT_READWRITE_ORGANISATION` org secret
> — a `workflow_dispatch` made with a PAT is attributed to that token's user,
> not to `GITHUB_TOKEN`, so it starts a real run. On a `refs/tags/v*` ref the
> `🚀 Release` job then attaches the `.img.xz` + `.sha256` +
> `.manifest.json` to the existing release.
>
> The PAT is applied in this repo rather than passed into the shared
> semantic-release template, because that template hardcodes `GITHUB_TOKEN`
> and exposes no token input.
>
> If the secret is ever missing the job fails loudly rather than silently
> publishing an empty release. Recover with:
>
> ```bash
> gh workflow run build.yml --ref v<version>   # e.g. v0.4.3
> ```
>
> Releases v0.2.4 through v0.4.2 predate this job and have no image assets.

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
4. Install host build deps (`qemu-user-static`, `kpartx`, `xz-utils`,
   `python3-git`, `python3-yaml`, …)
5. **Cache CustomPiOS** — keyed on `CUSTOMPIOS_REF` **and** the
   `scripts/bootstrap.sh` hash, with no `restore-keys` (see below)
6. Resolve variant metadata → `full_tag`, suffix, start timestamp
7. Run `bash scripts/build.sh <variant>`
8. Compute SHA-256, size, byte count
9. Emit a full **build summary** (see below)
10. Upload artifact

### 🚀 Release

Runs only on `refs/tags/v*`. Downloads all variant artifacts and **appends**
them as assets to the GitHub Release semantic-release already created for the
tag (`append_body: true` preserves the auto-generated changelog).

> This job is **not** reached automatically: semantic-release tags via
> `GITHUB_TOKEN`, which never triggers `build.yml`. Dispatch the tag build by
> hand (see the ⚠️ note under **When it triggers** above) to populate a
> release's image assets.

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

### Lifetimes

| Location | Lifetime | Trigger | Counts against quota? |
| --- | --- | --- | --- |
| Actions artifact | **3 days** | every build | ✅ shared with Packages |
| Actions logs | 90 days (GitHub default) | every build | ✅ shared with Packages |
| Actions cache | 7 days idle (GitHub default) | cache hit/miss | ❌ separate 10 GB cap per repo |
| GitHub Release asset | **permanent** | dispatched tag build | ❌ **free, no quota** |

> The 3-day TTL applies **only** to the transient Actions artifact. Tag
> builds end up in BOTH stores — the artifact is just a hand-off mirror
> for the release job, which downloads it and reuploads as a Release asset
> once the tag build is dispatched (see the ⚠️ note above). After 3 days the
> artifact disappears; the Release asset persists forever.

The Actions retention is configured in [`build.yml`](../.github/workflows/build.yml)
on the `actions/upload-artifact` step (`retention-days: 3`). It is
deliberately short — main/PR builds are disposable dev artefacts, and 3
days is long enough to grab one off a failing CI run without bloating
the org's shared storage.

### Quota rules at a glance

GitHub splits "storage" across several independent buckets. Knowing
which bucket a file lands in is the difference between "free forever"
and "we hit the 2 GB Free-tier cap".

| Bucket | Counts against | Notes |
| --- | --- | --- |
| **Actions artifacts + logs** | Org shared-storage quota | 500 MB Free / 2 GB Pro/Team / 50 GB Enterprise |
| **GitHub Packages** (ghcr.io) | Same shared-storage quota | Container layers stack up fast — clean old tags |
| **Git LFS** | Separate 1 GB storage + 1 GB egress / month | We do not use LFS in this repo |
| **Git repo size** | Soft cap 5 GB per repo | Just generator code here, ~250 KB |
| **Release assets** | ❌ **not counted, no quota** | Single-file cap 2 GB, soft cap 10 GB per release |

This is why this repo's release strategy works on the Free tier despite
shipping ~0.9 GB images per variant: every tag attaches its `.img.xz`
to a GitHub Release, and Release storage is free for public **and**
private repos.

### Per-file & per-release caps

| Limit | Value | Hard or soft? |
| --- | --- | --- |
| Single file in a Release | 2 GB | hard — upload rejected above |
| Total per Release | 10 GB recommended | soft — over goes through, just discouraged |
| Bandwidth on Release downloads | unlimited | served via GitHub's CDN |

If a variant ever crosses 2 GB compressed (`tegra-*`, image with
pre-baked AI runtime, etc.), the upload will fail. Workaround: split
with `split -b 1900M` or chunk into multi-part `.img.xz.{001,002}`.

### Operational guidance

- **Never lengthen the Actions artifact retention casually.** Each
  variant is ~0.9 GB; 14 days × N variants × M builds/week adds up
  fast and crowds out other repos sharing the org quota.
- **Old releases are the only thing that grow Release storage.** It
  is free, but if you ever need to clean up (e.g. retired variants),
  delete the Release — that detaches its assets. The git tag stays.
- **Cache size is capped automatically.** GitHub evicts least-recently-used
  caches when a repo crosses 10 GB; we cache CustomPiOS clones (~50 MB)
  and never approach the cap.
- **PR artifacts auto-evict per Dependabot wave.** Dependabot batches
  produce 3-4 builds in parallel — they all expire within the same
  3-day window, so disk usage stays bounded.

### Inspecting the actual usage

```bash
# Live (non-expired) Actions artifacts and their sizes
gh api repos/<org>/<repo>/actions/artifacts --paginate \
  --jq '[.artifacts[] | select(.expired==false)
         | {name, size_mb: (.size_in_bytes/1048576|floor),
            created_at, expires_at}]
        | sort_by(-.size_mb)'

# Release assets and total size per tag
gh api repos/<org>/<repo>/releases --paginate \
  --jq '[.[] | {tag: .tag_name, created: .created_at,
                total_mb: ([.assets[].size]|add/1048576|floor // 0)}]'

# Actions cache size for this repo
gh api repos/<org>/<repo>/actions/cache/usage
```

Org-wide billing aggregates live in
_Org Settings → Billing & plans → Storage_. The `/orgs/.../settings/billing/shared-storage`
API endpoint was retired by GitHub in 2025 — the UI is now the only
authoritative source.

### Download locations

- Actions artifact: _Actions → Run → Artifacts section_ (ZIP-wrapped, 3-day TTL)
- Release asset: _Releases → Tag → Assets_ (raw `.img.xz`, permanent)

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

| Name | Purpose | If unset |
| --- | --- | --- |
| `ADMIN_PASSWORD` | Bakes into `users[].password` | the variant default (`12345678`), shipped **expired** |
| `WIFI_PSK` | Bakes into `network.wifi.networks[].psk` | the variant default (`12345678`) |

Both are optional by design. These images are **public**, so a secret admin
password would make a published release asset unusable to everyone who
downloads it. An unset secret resolves to the empty string, which
`generate.py`'s `${VAR:-default}` fills with the documented default from the
variant config — so what ships matches what the docs promise.

> Previously this table was wrong in a way that mattered: the workflow
> substituted `ci-placeholder-pw` when the secret was unset, and no secrets
> were ever configured. Every published release asset therefore carried a
> credential written in plain text in a public repo, and the demo-password
> detection did not recognise it — so neither the build warning nor the
> on-device MOTD nag fired.

The protection is not secrecy but expiry: any account left on a known default
password is created with `chage -d 0`, so console login and sshd (`UsePAM
yes`) both force a change before granting a session. Set `ADMIN_PASSWORD` when
you want a private image with no forced rotation; the WiFi PSK has no
equivalent guard.

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

## 📌 CustomPiOS pinning

`CUSTOMPIOS_REF` pins the upstream build toolchain to a **full 40-char commit
SHA** — currently CustomPiOS 2.0.0, `d293309aac2f606c609645b441962c8f02b6e8c3`.
A SHA rather than a tag, because upstream's tags are lightweight and can be
force-moved.

Three things enforce the pin, and all three are load-bearing:

| Guard | Why it exists |
| --- | --- |
| `scripts/bootstrap.sh` fetches the ref explicitly and **verifies** the resulting `HEAD` | its predecessor ended in `\|\| true`, so a failed update was invisible |
| The cache key contains `CUSTOMPIOS_REF` | otherwise changing the ref does not invalidate the cache |
| **No** `restore-keys` on that cache | a prefix match would restore a checkout of a _different_ revision |

> **Why this matters.** Before these guards the workflow declared
> `CUSTOMPIOS_REF: master` but was in fact frozen on CustomPiOS 1.5.0 for
> 20 months: the cached checkout was shallow, `git pull --ff-only` therefore
> failed, and `|| true` swallowed it. When the Actions cache finally expired,
> a fresh clone jumped straight from v1.5.0 to v2.0.0 and the build broke on a
> missing `GitPython` — on a commit that had nothing to do with the cause.

**To move the pin:** three files must change together, or a local docker
build silently runs a different toolchain than CI:

1. `CUSTOMPIOS_REF` in `.github/workflows/build.yml`
2. the `CUSTOMPIOS_REF` default in `scripts/bootstrap.sh`
3. the `DOCKER_IMAGE` default in `scripts/build.sh` — the sibling container
   `ghcr.io/guysoft/custompios:sha-<short>` must be built from the same commit

Then check whether the new revision adds host dependencies, and let CI prove
it green before relying on it.

## 📈 Performance knobs

| Lever | Impact |
| --- | --- |
| Cache hit on CustomPiOS clone | -5 s per build |
| Runner disk free-up step | enables the build to finish at all (stock image leaves ~15 GB) |
| Matrix parallelism | one runner per variant, runs in parallel |
| `fail-fast: false` | variant A's failure does not kill variant B mid-build |
| `concurrency.cancel-in-progress` | saves runner-hours on rapid pushes |
