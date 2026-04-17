# Bootstrap detection — design

> Imported from the canonical vault copy at `projects/dotfiles/design/bootstrap-detection-design.md`. While the library lands across PRs 1–3, the vault copy remains the work-in-progress; this repo copy is snapshotted per PR so reviewers can read the design alongside the implementation. Wikilinks (`[[...]]`) in the text below point to vault notes and do not render as links on GitHub.

Design for augmenting `bootstrap-dotfiles` (and its siblings in `.chezmoi.toml.tmpl` + `run_onchange_*` scripts) with a **capability-sniffing layer that sits alongside — not in place of — the existing name-based detection**.

## 1. Goals

1. **Correct behavior on variants that share a distro ID** — Fedora Silverblue / Kinoite / Bazzite (immutable, `rpm-ostree`), openSUSE MicroOS, Ubuntu Core, container/minimal images.
2. **Pre-flight pain that name matching can't surface** — IPv6 routing broken (F43 hang), GHCR unreachable, no tar/curl in a slim image, no passwordless sudo.
3. **De-duplicate detection across three call sites** — `bootstrap-dotfiles`, `.chezmoi.toml.tmpl`, `run_onchange_before_install-packages.sh.tmpl`. Today each reimplements `/etc/os-release` parsing.
4. **Graceful fallback for novel distros** — Void, Chimera, Solus: if the pkg manager is recognizable, try; don't drop to `generic` silently.
5. **Keep existing name-based install paths working unchanged.** No regression in the 11 distros already green on the test matrix.

## 2. Non-goals

- Replacing name-based detection. We still need a **candidate list** of package names per logical capability (e.g. "a C toolchain" → `build-essential | build-base | base-devel | @development-tools`). Sniffing narrows the candidate list at runtime but does not eliminate it.
- Operator-side script generation from a remote probe (variant B from the idea note). The existing inline-heredoc flow stays.
- Supporting distros where no pkg manager is recognizable at all (NixOS, GoboLinux). Out of scope.
- Unifying with playbash's host detection. Separate concern.

## 3. Architecture

### 3.1 Single source of truth

One shared library: **`.chezmoitemplates/detect-distro.sh`** in the chezmoi repo.

It is consumed in three ways:

| Consumer | How it gets the lib |
|---|---|
| `bootstrap-dotfiles` (runs before any chezmoi state exists) | Inlined into the generated install heredoc at script-gen time. Bootstrap reads the file from its own repo checkout when run as `./bootstrap-dotfiles`; when run via `curl \| bash`, it fetches from `raw.githubusercontent.com/uhop/dotfiles/main/.chezmoitemplates/detect-distro.sh`. |
| `.chezmoi.toml.tmpl` | `{{ includeTemplate "detect-distro.sh" . }}` fed to `output` / parsed via a small `jq` wrapper. Run at chezmoi-init time; results stored as `.pkgManager`, `.distroFamily`, `.isImmutable`, etc. |
| `run_onchange_*` scripts | `{{ template "detect-distro.sh" . }}` inlined at chezmoi-apply time. Runs fresh each apply — cheap. |

`.chezmoitemplates/` is exactly designed for this: reusable fragments, single file, no duplication.

### 3.2 Layered detection

Detection runs in two passes with clear precedence:

```
Pass 1 — IDENTITY (name-based)
  Parse /etc/os-release → DETECTED_ID, DETECTED_ID_LIKE (tokenized as whole-string-contains list),
  DETECTED_VERSION_ID, DETECTED_VARIANT_ID, DETECTED_FAMILY (debian|rhel|suse|arch|alpine|darwin|unknown).

Pass 2 — CAPABILITIES (sniffed)
  Probe the system: pkg manager, immutable FS, init, pre-installed tools, network,
  sudo posture, arch, container/WSL, locale.

Final decision
  For install actions, capability pass WINS when it contradicts the name pass.
  (E.g. DETECTED_ID=fedora + DETECTED_IMMUTABLE=true → route to rpm-ostree, not dnf.)
  For package NAMES, family pass wins (capabilities don't know "build-essential").
```

### 3.3 API surface

All symbols prefixed `detect::`. Idempotent, safe to source multiple times, no side effects on sourcing — only on explicit call.

**Identity (name-based, Pass 1)**

```bash
detect::identity                 # populate DETECTED_* vars from /etc/os-release; memoized
  # exports: DETECTED_ID, DETECTED_ID_LIKE, DETECTED_VERSION_ID,
  #          DETECTED_VARIANT_ID, DETECTED_NAME, DETECTED_FAMILY
detect::family_contains <token>  # 0 if token is in ID_LIKE (whole-string contains, per os-release-parsing-pitfalls)
detect::is_version_at_least <n>  # 0 if VERSION_ID >= n (numeric compare, first integer)
```

**Capabilities (sniffed, Pass 2)**

```bash
# Package manager
detect::pkgmgr                    # echoes apt|dnf|zypper|pacman|apk|xbps|emerge|eopkg|rpm-ostree|brew|pkg|unknown
detect::pkg_has <pkg>             # 0 if installed
detect::pkg_avail <pkg>           # 0 if in configured repos
detect::pkg_install <pkg>...      # family-correct install command; uses DETECTED_FAMILY for dictionary
detect::pkg_install_if_missing <pkg>...

# Filesystem
detect::is_immutable              # 0 if /usr is read-only or rpm-ostree present
detect::is_container              # 0 if in container (systemd-detect-virt, /.dockerenv)
detect::is_wsl                    # 0 if WSL

# Init
detect::init_system               # echoes systemd|openrc|runit|s6|sysv|unknown

# Network
detect::has_ipv6                  # 0 if real v6 route to a public address (timeout 3s)
detect::can_reach <url>           # 0 if HEAD succeeds within 5s (default URL: https://ghcr.io)

# Sudo / privilege
detect::sudo_group                # echoes wheel|sudo|admin|"" (empty if none present for user)
detect::can_sudo_nopasswd         # 0 if `sudo -n true` works

# Tools
detect::has_cmd <name>            # 0 if command is on PATH (memoized)

# Arch / runtime
detect::arch                      # echoes x86_64|aarch64|armv7l|...
detect::uname_s                   # echoes Linux|Darwin|...

# Summary / debug
detect::summary                   # multi-line human-readable report of all probed values
detect::report_json               # same as JSON; used by bootstrap's --dry-run --report
```

### 3.4 Package-name resolution (sniff names, not just managers)

The library doesn't just detect *which* pkg manager is available — for any logical need, it **probes candidate names against the available manager(s)** and picks the first that exists. This is the core loop:

```
resolve(capability):
  for (mgr, name) in CANDIDATES[capability]:          # ordered list
    if mgr not in available_managers:   continue
    if not pkg_avail(mgr, name):        continue
    if min_version and ver(mgr, name) < min_version:  continue
    return (mgr, name)
  return UNRESOLVED
```

**Candidate table** — data, not code. Keyed by logical capability; value is an ordered list of `(manager, name, min_version?)` tuples.

```bash
# Example entries (shown in Bash-associative-array-ish pseudo-syntax)
CANDIDATES[c_toolchain]="
  apt:build-essential
  dnf:@development-tools
  zypper:patterns-devel-C-C++-devel_C_C++
  pacman:base-devel
  apk:alpine-sdk
  xbps:base-devel
  brew:gcc
"

CANDIDATES[tmux]="
  apt:tmux
  dnf:tmux
  zypper:tmux
  pacman:tmux
  apk:tmux
  xbps:tmux
  brew:tmux
"

CANDIDATES[micro_editor]="
  dnf:micro:2.0        # EPEL / Fedora — preferred native pkg
  apt:micro:2.0        # Debian 12+/Ubuntu 22.04+; older releases fail min_version and fall through
  brew:micro           # universal fallback, always current
  # apt:snap:micro     # snap path — still TBD, see §3.6
"

CANDIDATES[git_lfs]="
  apt:git-lfs
  dnf:git-lfs
  brew:git-lfs
  # Distros without a packaged git-lfs fall through to scripted install
"
```

Ordering rules (guidelines, not absolute):
1. **Native pkg manager of the detected family first** (apt on debian-family, dnf on rhel-family, etc.) — least friction, integrates with system updates.
2. **Universal secondary** — Homebrew. Works on any Linux with build tools, keeps current versions, avoids EPEL/PPA juggling.
3. **Sandboxed / app-store tertiary** — scope differs per manager (see §3.10):
   - **flatpak** — GUI applications only in practice. Not listed in CLI-tool candidates.
   - **snap** — mixed. Canonical ships many CLI tools here (`lxd`, `kubectl`, `multipass`, `microk8s`, `yq`, etc.), sometimes as the *only* supported path on Ubuntu. Listed in CLI candidates when it's the canonical source; opt-in-gated because auto-refresh is polarizing.
4. **Scripted install as last resort** — tar/zip from GitHub releases via `install-artifact`, etc. Captured as a separate candidate type (see below).

**Scope note**: the bootstrap-dotfiles domain is overwhelmingly CLI tools (editors, multiplexers, shell utilities, build toolchains). Practically every candidate list we write lands in ranks 1-2-4 above; rank 3 exists so the library *can* resolve GUI packages when users extend the table, not because bootstrap installs GUI apps itself.

### 3.5 Multi-manager fallback and alternate-source candidates

Some installs genuinely span pkg managers (a "universal" tool like micro, bat, fzf, jq that's packaged everywhere at different versions). The candidate list above handles this naturally — **the resolver walks until one succeeds**.

**Secondary managers** are themselves detected as optional capabilities:

```bash
detect::has_brew          # 0 if Homebrew is installed
detect::has_flatpak       # 0 if flatpak is installed + at least one remote (GUI only — §3.10.1)
detect::has_snap          # 0 if snapd is running — not just installed (mixed CLI + GUI — §3.10.1)
detect::has_nix           # 0 if nix-env or nix profile is usable
# Language-scoped managers — detected but NOT in default candidate lists (§3.10.4):
detect::has_npm_global    # 0 if npm is present with a writable prefix (orphaned by nvm version switch)
detect::has_pip_user      # 0 if pip3 --user works (orphaned by pyenv/uv venv switch)
detect::has_uv_tool       # 0 if `uv tool` is available (uv's "persistent tool" install path)
detect::has_pipx          # 0 if pipx is installed (isolated-venv model, survives python version bumps)
detect::has_cargo         # 0 if cargo is available (cargo install — survives rust toolchain switches via rustup)
detect::has_go_install    # 0 if `go` is available with $GOBIN writable
```

Any of these, if present, becomes a valid manager token — **but whether they appear in a candidate list is a deliberate per-capability choice**, not an automatic fallback (§3.10.4). Their **install syntax** is registered with the library the same way apt/dnf/etc. are:

```bash
# pseudo
MGR_INSTALL[brew]="brew install {pkg}"
MGR_AVAIL[brew]="brew info --json=v2 {pkg} >/dev/null 2>&1"
MGR_VERSION[brew]="brew info --json=v2 {pkg} | jq -r '.formulae[0].versions.stable'"

MGR_INSTALL[flatpak]="detect::_flatpak_install {pkg}"   # dispatches system-vs-user, see §3.10.1.1
MGR_AVAIL[flatpak]="flatpak remote-info flathub {pkg} >/dev/null 2>&1"
MGR_HAS[flatpak]="flatpak info {pkg} >/dev/null 2>&1"   # any scope — system or user
MGR_VERSION[flatpak]="flatpak remote-info flathub {pkg} | awk '/Version:/ {print \$2}'"

MGR_INSTALL[snap]="sudo snap install {pkg}"
MGR_AVAIL[snap]="snap info {pkg} >/dev/null 2>&1"
MGR_VERSION[snap]="snap info {pkg} | awk '/^  latest\\/stable:/ {print \$2}'"
```

New pkg managers are added by registering three strings — no code change in the resolver.

**Scripted-install candidates** (out-of-band, not a pkg manager):

```bash
CANDIDATES[bat]="
  apt:bat:0.20
  dnf:bat
  pacman:bat
  brew:bat
  script:install-artifact-bat         # last resort: curl-based installer
"
```

`script:*` entries map to a handler function registered in the library (e.g., `install_via_artifact bat`). Keeps the escape hatch first-class and unified with normal resolution.

### 3.6 Caching, cost, and update semantics

Availability queries are not free. Real costs observed:

| Manager | Cold query | Hot query | Notes |
|---|---|---|---|
| apt-cache show | 10-50 ms | <5 ms | Needs `apt update` run at least once; we should run it once early in bootstrap |
| dnf info | 1-3 s (metadata sync) | 50-100 ms | `dnf makecache` upfront |
| zypper info | 500 ms | 100 ms | |
| pacman -Si | 200 ms | 50 ms | `pacman -Sy` upfront |
| apk info | fast | fast | `apk update` upfront |
| brew info --json | 200-400 ms | 200-400 ms | No offline cache |
| snap info | 200 ms | 200 ms | Network required |
| flatpak remote-info | 300-500 ms | 300-500 ms | Network required |

Rules:
- **Library performs exactly one metadata refresh per manager per bootstrap run** (idempotent flag file in `$XDG_CACHE_HOME/dotfiles-detect/`). Subsequent probes hit the cache.
- **Per-query memoization in-process** via associative array keyed by `mgr:name`. Results persist for the life of the shell.
- **`--offline` mode** skips metadata refresh; resolution falls back to already-installed detection only (`pkg_has` instead of `pkg_avail`). Useful for airgapped hosts.
- **`--refresh` mode** forces metadata refresh even if the flag file is fresh.

#### 3.6.1 Batch (bulk) availability queries

Every pkg manager we care about accepts multiple package names in a single invocation. On cold caches — and especially for managers with per-call network cost like brew/snap — batching collapses N round-trips into 1.

| Manager | Bulk availability | Bulk installed-check | Notes |
|---|---|---|---|
| apt | `apt-cache show X Y Z` or `apt-cache policy X Y Z` | `dpkg-query -W -f='${Package}\t${Version}\n' X Y Z` | dpkg-query is the fastest installed-check on Debian |
| dnf / dnf5 | `dnf info X Y Z` or `dnf list --available X Y Z` | `rpm -q X Y Z` | `rpm -q` is cheap and needs no metadata |
| zypper | `zypper --xmlout info X Y Z` or `zypper search -x X Y Z` | `rpm -q X Y Z` | XML output is parseable |
| pacman | `pacman -Si X Y Z` | `pacman -Q X Y Z` | both bulk-capable |
| apk | `apk search -e X -e Y -e Z` or `apk policy X Y Z` | `apk info -e X Y Z` | `-e` = exact match |
| brew | `brew info --json=v2 X Y Z` | `brew list X Y Z` (exit nonzero if any missing) | **biggest win** — per-call cost 200-400ms, batched ~same for N names |
| snap | `snap info X Y Z` | `snap list X Y Z` | network-per-call; batching collapses to one round-trip |
| flatpak | **no bulk `remote-info`** — workaround: `flatpak search <term>` and filter locally, or enumerate via `flatpak remote-ls flathub` once and cache | `flatpak list --columns=application` (single call, returns everything; filter locally) | flatpak is the outlier; treat as cache-everything-once |
| npm | `npm view X Y Z version` | `npm ls -g --depth=0 --json` (single call, all globals) | |
| pip | — (no bulk search) | `pip list --format=json` (single call, all installed) | |
| cargo | — (no bulk registry query; `cargo search` takes one term) | `cargo install --list` (single call, all installed) | |
| go | — | `ls $GOBIN` (single call) | `go install` has no registry-side query; we treat `go:*` candidates as opportunistic installs, never pre-availability-checked |
| rpm-ostree | — (query base via `rpm`) | `rpm-ostree status` (single call, layered packages) | |

### 3.6.2 Warmup phase — pre-resolve all candidates at once

The library performs a **warmup pass** at the start of `detect::init`:

```
warmup():
  1. Collect every (mgr, name) tuple from the loaded candidate tables.
  2. Group by manager → { apt: [X, Y, Z], brew: [X, W, V], snap: [lxd] }.
  3. For each manager with a bulk-query command, issue ONE call with all names.
  4. Parse the output; populate the mgr:name memoization cache with availability + version.
  5. For managers without bulk support (flatpak, cargo), either:
     - one-shot "list everything" (flatpak list, cargo install --list) and index locally, OR
     - fall back to per-name lazy query with a visible "slow path" note.
```

This turns a typical bootstrap from ~50-100 individual pkg-manager calls (15-20 capabilities × 3-5 candidates) into **~2-5 bulk calls**, because most candidates cluster on the native manager + brew.

**Measured expectation (rough; to verify in PR 1 testing):**

| Scenario | Individual | Batched | Speedup |
|---|---|---|---|
| 20 capabilities × 4 candidates, brew-dominated | ~40 × 300ms = 12s | ~1 × 400ms + ~1 × 200ms = 0.6s | ~20× |
| Same, apt-dominated (cache-hot) | ~40 × 5ms = 200ms | ~1 × 20ms = 20ms | ~10× |
| Same, dnf-dominated (cache-cold) | ~40 × 100ms = 4s | ~1 × 300ms = 0.3s | ~13× |
| snap candidates on Ubuntu | 5 × 200ms = 1s | 1 × 250ms = 0.25s | ~4× |

### 3.6.3 Batched installs — default for every manager that supports it

The same managers that accept multiple names on *query* calls accept them on *install* calls:

| Manager | Batched install | Notes |
|---|---|---|
| apt | `sudo apt install -y X Y Z` | native; one dep-resolution pass, one sudo |
| dnf / dnf5 | `sudo dnf install -y X Y Z` | native |
| zypper | `sudo zypper install -y X Y Z` | native |
| pacman | `sudo pacman -S --noconfirm X Y Z` | native |
| apk | `sudo apk add X Y Z` | native |
| brew | `brew install X Y Z` | native; shared bottle downloads, one tap-resolution |
| snap | `sudo snap install X Y Z` | native; one snapd notification cycle |
| flatpak | `flatpak install -y flathub X Y Z` | native (both `--system` and `--user`) |
| **`rpm-ostree`** | `sudo rpm-ostree install X Y Z` | **qualitatively important** — see below |
| **`transactional-update`** | `sudo transactional-update pkg install X Y Z` | same reason as rpm-ostree |
| cargo | `cargo install X Y Z` | native |
| npm | `npm install -g X Y Z` | native |
| pip / pipx | no batch — looped internally | pipx creates one venv per tool by design |
| go install | no batch — looped internally | `go install` is per-module |

#### The rpm-ostree / transactional-update case isn't an optimization — it's correctness

On Fedora Silverblue / Kinoite / Bazzite / openSUSE MicroOS, every layered install creates a **new boot deployment** and requires a **reboot** to take effect. Without batching:

```
rpm-ostree install tmux    # deployment 1, needs reboot
rpm-ostree install micro   # deployment 2, needs reboot — previous deployment wasted
rpm-ostree install fzf     # deployment 3, needs reboot
...                        # N reboots for N capabilities
```

With batching:

```
rpm-ostree install tmux micro fzf bat ripgrep jq ...   # one deployment, one reboot
```

For these managers, the batched path isn't "nice to have" — the non-batched path is essentially unusable. Design **requires** batching for immutable-FS managers.

#### General batching design

`MGR_INSTALL` templates switch from `{pkg}` (single placeholder) to `{pkgs}` (space-separated list; degenerate to a single name on a one-element batch):

```bash
MGR_INSTALL[apt]="sudo apt install -y {pkgs}"
MGR_INSTALL[dnf]="sudo dnf install -y {pkgs}"
MGR_INSTALL[brew]="brew install {pkgs}"
MGR_INSTALL[rpm-ostree]="sudo rpm-ostree install {pkgs}"
MGR_INSTALL[flatpak-system]="flatpak install -y --system flathub {pkgs}"
MGR_INSTALL[flatpak-user]="flatpak install -y --user flathub {pkgs}"
MGR_INSTALL[snap]="sudo snap install {pkgs}"   # note: --classic must be per-snap if mixed; see below
# No-batch managers register without {pkgs} support; the dispatcher loops.
MGR_INSTALL_NOBATCH[pipx]="pipx install {pkg}"
MGR_INSTALL_NOBATCH[go-install]="go install {pkg}"
```

**Install flow — revised from earlier §3.4:**

```
pkg_ensure(cap1, cap2, ...):
  # 1. Resolve everything (cached from warmup §3.6.2 — no new queries).
  resolutions = [(mgr, name, flags) for cap in caps]

  # 2. Drop already-installed (pkg_has returns true from bulk cache §3.6.1).

  # 3. Group remaining by (mgr, scope) — keeping original order within groups for determinism.
  groups = groupby(resolutions, key=(mgr, scope))

  # 4. For each group, one install call. Native ordering: system-pkg-mgr first, then brew,
  #    then snap, then flatpak, then language-scoped. Reason: brew may need git from apt,
  #    snap may need base snaps fetched first, etc. Matches today's ordering in bootstrap.

  # 5. Failure handling: if a batch install fails, re-run each package in the failed group
  #    individually to isolate and report which one broke. Only on failure — zero cost in the
  #    happy path.
```

#### Snap's per-package flags (confinement, channel)

Snap is the one manager where per-package flags vary in the same batch: `lxd` uses default strict confinement; `kubectl` needs `--classic`. You can't mix `--classic` and default in one invocation. Dispatcher handles this by **sub-grouping snap installs by flag signature** — usually 1-2 sub-calls (classic vs strict). Still dramatically better than N-per-package, and transparent to the candidate-table author (the flag lives in the candidate entry: `snap:kubectl:classic`).

#### Complexity cost

Small and localized:
- `MGR_INSTALL` templates: one token change (`{pkg}` → `{pkgs}`).
- Dispatcher: a 10-line groupby + loop.
- Failure isolation: a 10-line fallback loop, reached only on non-zero exit.
- Confirmation prompt / dry-run report: *simpler* than before — one line per group, not per package.
- `snap` sub-grouping: handled inside the snap wrapper, invisible elsewhere.

No change to candidate-table authors, consumers, or users.

#### Benchmark — pending PR 1

The real numbers depend on cache state, network speed, and package count. Rough expectations to verify in the PR 1 matrix run (where real distros with real timings are already being exercised):

| Scenario | Individual | Batched | Expected speedup |
|---|---|---|---|
| apt install × 15 packages | ~5 s (sudo overhead + lock + dep solve each time) | ~1.5 s | ~3× |
| brew install × 15 (cold, with deps) | ~45 s | ~15 s (shared deps) | ~3× |
| snap install × 5 (each triggers hooks) | ~30 s | ~10 s | ~3× |
| rpm-ostree install × 8 (Silverblue) | **N reboots required** — unusable | 1 deployment, 1 reboot | **categorically different** |
| pipx install × 5 (no-batch — looped) | ~same either way | ~same | 1× (no gain, no loss) |

If benchmarks show less than ~1.5× on typical cases and no correctness wins on the target distro, we leave the feature available but not used. On rpm-ostree distros, it's always used.

### 3.7 API additions for name resolution

Added to the surface defined in §3.3:

```bash
detect::pkg_resolve <capability>            # echoes "mgr:name" of first viable candidate, or empty
detect::pkg_resolve_all <capability>        # echoes every viable candidate, one per line (for diagnostics)
detect::pkg_ensure <capability>...          # resolve + install_if_missing for each capability
detect::pkg_avail <mgr> <name>              # (was <pkg> only; now mgr-scoped so cross-mgr probing works)
detect::pkg_version <mgr> <name>            # echoes normalized version string
detect::pkg_meets <mgr> <name> <min_ver>    # 0 if installed/available version >= min_ver
detect::mgr_register <mgr> <avail_cmd> <install_cmd> <version_cmd> [bulk_avail_cmd] [bulk_has_cmd]
detect::candidates_load <file>              # load additional/overridden candidate tables

# Bulk primitives (§3.6.1, §3.6.2)
detect::pkg_avail_bulk <mgr> <name>...      # one call; populates mgr:name cache for every name
detect::pkg_has_bulk <mgr> <name>...        # one call; installed check
detect::warmup                              # pre-resolve all candidates from loaded tables in 2-5 bulk calls
```

`mgr_register` takes optional `bulk_*` commands; managers without bulk support (flatpak, cargo registry, pip) register without them and fall back to per-name queries + a "slow path" warning in the report.

Every bulk command produces parseable output in a uniform format: one line per package, `name<TAB>status<TAB>version` where `status` is `available|installed|missing`. Each manager's bulk wrapper normalizes its native output to this shape. Candidate-table authors never see the native format.

The candidate tables live in `.chezmoitemplates/detect-packages.sh` — a separate file from `detect-distro.sh` so the dictionary evolves independently from detection logic. Consumers source both.

### 3.8 Decision rules (where sniff trumps name)

A small table in the library:

| Condition | Override |
|---|---|
| `DETECTED_FAMILY=rhel` AND `detect::has_cmd rpm-ostree` AND `detect::is_immutable` | Use rpm-ostree install path; skip `dnf install` |
| `DETECTED_FAMILY=suse` AND `detect::has_cmd transactional-update` AND `detect::is_immutable` | Use `transactional-update pkg install`; skip zypper |
| Any family AND `detect::is_container` AND `init_system=unknown` | Skip systemd-unit steps entirely |
| Any family AND `!detect::has_ipv6` AND install uses IPv6-default endpoint | Force IPv4 (curl `-4`) |
| `DETECTED_FAMILY=unknown` AND `detect::pkgmgr != unknown` | Proceed with pkgmgr, warn user, log to report |

Table is data, not `if` cascades — easy to add rows as new variants appear.

### 3.9 Worked example: installing `micro` across the matrix

With the resolver + candidate table from §3.4, the flow on each distro reduces to one call:

```bash
detect::pkg_ensure micro_editor
```

What happens per distro:

| Distro | Resolved candidate | Why |
|---|---|---|
| Ubuntu 24.04 | `apt:micro` | apt has 2.0.13, meets min_version 2.0 |
| Debian 12 | `apt:micro` | apt has 2.0.11 |
| Debian 11 (oldstable) | `brew:micro` | apt only has 1.x → fails min_version; falls through to brew |
| Fedora 43 | `dnf:micro` | native package present |
| Rocky 9 | `brew:micro` | dnf+EPEL ships it, but we verified brew already works here; either is fine — ordering decides |
| Alpine edge | `apk:micro` *(if added)* or `brew:micro` | candidate list additive |
| Arch | `pacman:micro` | extra repo |
| Silverblue | `brew:micro` | `@development-tools` impossible on immutable FS; brew installs into `$HOME`, works |

The hard-coded `case "$ID"` branches for "where does micro come from on X?" disappear. New distros need at most one candidate-list entry, and if the candidate list already covers their pkg manager they need zero lines.

### 3.10 Cross-manager reality: flatpak vs. snap scope, apt→snap delegation, volatility

Real-world pkg managers don't partition cleanly. Several wrinkles matter enough to bake into the design rather than discover in production.

#### 3.10.1 Flatpak is GUI-only; snap is mixed (CLI + GUI)

These two superficially similar sandboxed managers have different scopes in practice:

**Flatpak** — Flathub carries essentially only desktop applications (GUI editors, browsers, games, creative tools). The CLI-tool overlap with apt/dnf/brew is near zero, and flatpak-packaged CLI tools are awkward to invoke (`flatpak run org.foo.Bar` instead of `bar`). **Excluded from default CLI-tool candidate lists.** Available as a manager if registered; the library supports it end-to-end for users who extend the table with GUI capabilities. See §3.10.1.1 for the system-vs-user install dispatch.

**Snap** — Canonical actively ships CLI tooling via snap, sometimes as the **only supported path on Ubuntu**:

| Tool | Status | Why snap is listed |
|---|---|---|
| `lxd` | Canonical's canonical path since 2022 | apt package delegates (§3.10.2); snap is the real source |
| `kubectl` | Stable snap channel tracked upstream | Ubuntu prefers this over apt's kubernetes-client |
| `multipass` | Canonical-maintained VM tool | snap-only on Linux |
| `microk8s` | Canonical-maintained k8s | snap-only |
| `yq` | Snap track for latest | Ubuntu apt version lags significantly |
| `core` / `core22` etc. | Runtime bases | required prereq for other snaps |

**Design decision**: snap **is listed in default CLI candidate tables** when it's the canonical or only viable source for a capability. Unlike flatpak it's not blanket-excluded. However:

- **Gated behind `DETECT_ALLOW_SNAP=1` opt-in by default**, because snap auto-refresh is polarizing — snapd decides when to restart a running tool, which surprises users who don't expect update timing to be out of their control.
- **Confinement matters**: `classic` confinement (lxd, kubectl, multipass) behaves like a native CLI — full system access, normal `$PATH` from `/snap/bin`. `strict` confinement confines the snap to its own sandbox; some CLIs work fine, others hit capability walls (e.g., snap-confined editors can't read outside `$HOME`). Candidate table entries for strict-confined snaps carry the `:confined` flag (§3.10.5) so the user is warned before install.
- **Requires sudo for install** (`sudo snap install X`), unlike flatpak `--user` or brew — batched into the already-sudo install phase per §5.3.

For GUI applications (if the user extends the candidate table with them — e.g., Chromium, VS Code, OBS), the tradeoffs the resolver can't judge alone:

- **Version divergence across channels.** Same app on apt, snap, flatpak can differ by months. Naive "most recent wins" is usually wrong — stable channel lag is often intentional.
- **Startup-time differences.** flatpak apps typically start faster than snap (snap's squashfs mount + confinement init adds noticeable latency); both are slower than native.
- **Sandbox capability loss.** Flatpak confines apps — Chrome/Chromium via flatpak can't see system printers without CUPS portal setup; Electron apps lose file-picker native integration; some hardware access (webcams, audio) needs Wayland portals. Daily-use regressions, not theoretical.
- **Auto-refresh friction.** Snap forces it; flatpak doesn't. Dealbreaker for some users.

**Design decision — GUI rank order**: for GUI candidates where multiple ranks match, the library emits a **choice report** rather than silently picking — lists all viable `(mgr, name, version)` tuples and requires either:
- an explicit user preference set via `DETECT_GUI_PREF="native flatpak snap"` (space-separated priority list, defaults to `native flatpak snap`), or
- an interactive prompt when running on a TTY.

Opinionated default order for GUIs: **native → flatpak → snap**. For CLIs: **native → brew → snap (if allowed) → scripted**; flatpak does not appear.

Documented as a decision in [[projects/dotfiles/decisions]] so the choice is discoverable and revisitable.

#### 3.10.1.1 Flatpak install dispatch — system vs. user, dedup across scopes

This project's existing flatpak setup is **system-wide**: `flatpak install flathub <pkg>` installs to `/var/lib/flatpak`, shared across all users. The password-free UX depends on a polkit rule at `/usr/local/share/polkit-1/rules.d/90-flatpak-ssh.rules` (documented in `external_wiki/Application-Notes.md`) that allows members of `sudo`/`wheel` to run `org.freedesktop.Flatpak.*` actions without authentication.

**Two gaps in the current setup** (verified 2026-04-14):

1. **The polkit rule is documented but not installed automatically.** No file in the chezmoi repo deploys `90-flatpak-ssh.rules`; no script writes it. New machines require manual setup per the wiki. This is a queue item ([[projects/dotfiles/queue]] — "Deploy flatpak polkit rule automatically").
2. **Non-sudoers have no viable path.** The polkit rule only applies to `sudo`/`wheel` group members. A non-sudoer on a multi-user machine (e.g., a shared workstation, a guest account, a CI runner with a restricted user) can't trigger the system-wide install at all — today's setup silently doesn't work for them.

**Design: `detect::_flatpak_install` dispatch logic**

```
flatpak_install(pkg):
  # 1. Already installed in ANY scope? Skip. (`flatpak info` matches system + user.)
  if flatpak info <pkg> succeeds:
    return skipped

  # 2. System install preferred (shared, survives user deletion, polkit-friendly).
  if detect::flatpak_can_system_install:
    flatpak install -y --system flathub <pkg>
    return system

  # 3. Fallback: per-user install (no sudo, no polkit required).
  flatpak install -y --user flathub <pkg>
  return user
```

Where:

```
detect::flatpak_can_system_install:
  # Either: the polkit rule is deployed AND the user is in sudo/wheel
  #     (→ flatpak install --system works password-free over SSH per the rule),
  # OR:     the user has passwordless sudo generally
  #     (→ we can sudo flatpak install --system directly).
  return 0 if:
    (test -f /usr/local/share/polkit-1/rules.d/90-flatpak-ssh.rules
       AND detect::sudo_group in (sudo|wheel))
    OR detect::can_sudo_nopasswd
```

Rationale for the ordering:

- **Dedup first** via `flatpak info` — if the app is already system-installed, a per-user install would waste disk and create confusing double-copies. This also makes the install step idempotent across multiple users on one machine: once one sudoer installs it system-wide, every other user (sudoer or not) sees it and skips.
- **System install second** — shared scope is the project's current convention and what the polkit rule was set up for. Keep the default.
- **User install as fallback only** — not a regression from status quo (status quo did nothing for non-sudoers); a new safety net.

**New probes added to the library:**

```bash
detect::has_flatpak_polkit_rule    # 0 if /usr/local/share/polkit-1/rules.d/90-flatpak-ssh.rules exists
detect::flatpak_can_system_install # composite probe per above
detect::flatpak_scope_of <pkg>     # echoes system|user|none — which scope already has it
```

All unprivileged (file existence check, group membership from `getent`, `flatpak info` as normal user). Fits the §5 constraint.

**Effect on the resolver report**: when a flatpak candidate resolves, the pre-flight log shows the dispatch decision:

```
flatpak:org.mozilla.firefox → install scope: system (polkit-rule present, user in 'sudo')
flatpak:org.videolan.VLC    → install scope: user (no polkit rule; not in sudo group)
flatpak:com.github.IsmaelMartinez.teams_for_linux → skipped (already installed system-wide)
```

User sees exactly what will happen and why before confirming.

#### 3.10.2 apt → snap transparent delegation (and similar shims)

On Ubuntu, several "apt packages" are thin transitional shims that actually invoke snap under the hood. Known cases:

| Package | Shim behavior |
|---|---|
| `lxd` | `apt install lxd` installs a deb that calls `snap install lxd` |
| `chromium-browser` | deb depends on snap; actual install is via snap |
| `firefox` (Ubuntu 22.04+) | same pattern |
| `core-tools`-style meta-pkgs | variable per release |

From the library's perspective, `apt-cache show lxd` returns a valid package; `pkg_avail apt lxd` returns true; then `apt install lxd` triggers snap. The resolver has **no reliable way** to detect this pre-install:

- `apt-cache show <pkg> | grep -E 'snapd|snap install'` catches some but not all shims — the snap invocation can be buried in `postinst` scripts, which aren't inspected by apt-cache.
- Ubuntu deliberately makes the delegation seamless; there's no `Delegated: snap` metadata field.
- Version reported by apt may be the shim's version, not the snap's.

**Design decision**: don't try to detect shims automatically. Instead:

1. **Maintain a known-shim list** in `detect-packages.sh`:
   ```bash
   APT_SNAP_SHIMS="lxd chromium-browser firefox"
   ```
2. `pkg_avail apt X` — if X is in the shim list, emit a diagnostic note in the resolver report: `apt:lxd (delegates to snap; consider snap:lxd explicitly)`.
3. Candidate lists for affected capabilities can **skip the apt entry deliberately** and list `snap:lxd` directly, making the indirection visible:
   ```bash
   CANDIDATES[lxd]="
     snap:lxd       # canonical path on Ubuntu — apt entry delegates anyway
     dnf:lxd        # Fedora native
     pacman:lxd     # Arch native
   "
   ```
4. If a user adds a new capability and we later discover it's a shim case, updating `APT_SNAP_SHIMS` + the candidate list is a one-line PR. No code change.

Rationale: detection heuristics for shim packages are fragile and go stale as Ubuntu's policy shifts (firefox moved to snap in 22.04, may move back; lxd spun off to Canonical's LXD fork with different packaging story). A hand-maintained list of ~5-10 known cases is more reliable than any heuristic we'd write.

#### 3.10.3 macOS is special — brew is the only leveragable manager

macOS has no package manager the library can use as a native primary. Apple's own tooling:

- **`softwareupdate`** — OS security updates only, not general apps. Not a programmable install surface.
- **Mac App Store** — requires GUI, Apple ID authentication, interactive purchase acceptance. Non-starter for scripted installs.
- **`pkgutil`** — manages `.pkg` receipts; doesn't resolve names or fetch.
- **MacPorts / Fink** — niche, not how the user's existing dotfiles run.
- **`sudo softwareupdate --install-rosetta` etc.** — single-purpose, not a general mechanism.

**Design decision: on Darwin, `DETECTED_PKGMGR=brew` and brew is treated as the native manager, not a secondary.** Consequence: the rank-order rules in §3.4 collapse — "native first" and "brew as universal secondary" become the same thing.

**Derived Darwin-specific behaviors:**

| Probe | Darwin behavior |
|---|---|
| `detect::pkgmgr` | `brew` (not `unknown`). If brew isn't installed yet, the bootstrap's `--from-jot` / initial setup path installs it first — same as today's flow. |
| `detect::sudo_group` | `admin` (Mac's default sudoer group). The `sudo_group` exit table in §9 now explicitly expects `admin` as a valid return value. |
| `detect::init_system` | `launchd`. All `is_container`/systemd-unit decision rules (§3.8) route to Darwin-specific no-op paths. |
| `detect::is_immutable` | **false**. macOS's SIP makes `/System` and `/usr` read-only, but brew installs under `/opt/homebrew` (Apple Silicon) or `/usr/local` (Intel) — both writable user-space targets. The immutable-FS probe only triggers for Linux ostree/transactional cases; Darwin returns false unconditionally. |
| `detect::has_flatpak` / `has_snap` | **always false on Darwin**. Flatpak is Linux-only by design; snap's macOS port was abandoned. Neither is probed further on `uname_s=Darwin`. |
| Flatpak polkit dispatch (§3.10.1.1) | **skipped entirely** — polkit doesn't exist on macOS. The `detect::has_flatpak_polkit_rule` probe returns false without checking `/usr/local/share/polkit-1/` (which is Linux-only anyway). |
| `detect::pkg_install` family | always resolves to brew's install/query syntax. No fallback needed. |
| Cross-family candidate entries | `apt:*`, `dnf:*`, `snap:*`, `flatpak:*` entries in candidate tables are silently unreachable on Darwin — resolver skips them as "manager not available" with no warning (it's not a user-relevant event). |
| `DETECTED_FAMILY` | `darwin`. Decision rules (§3.8) can test `family_contains darwin` to branch on Mac-only paths — e.g., the brew Bundle format for bulk installs differs from Linux brew. |

**Consequence for candidate tables**: every capability needs at least one `brew:*` entry to be resolvable on Darwin. This is already the case in the §3.4 examples (`c_toolchain`, `tmux`, `micro_editor`, `git_lfs`) and should be a candidate-table-author guideline — listed explicitly in the table authoring docs.

**Consequence for secondary managers**: `cargo`, `go-install`, `pipx` — all work on Darwin and retain their candidate-table positions. `npm-global` and `pip-user` stay excluded for the same version-switcher reasons as on Linux (nvm and pyenv are commonly used on macOS too).

**Consequence for "system-wide vs user-scope"**: brew is **shared-install, single-writer** (see §3.10.3.1) — its prefix is user-owned but readable/executable by every user on the machine. The flatpak-style system-vs-user dispatch (§3.10.1.1) doesn't apply; there is no `--user` fallback for a non-owner. Install commands never need sudo; the prefix is user-owned by design.

**Consequence for the privilege model (§5)**: on Darwin, sudo is only needed when the library extends into things brew can't do — e.g., system extensions, loginitems, `/etc/*` edits. The bootstrap path for dotfiles proper doesn't hit any of those, so Mac bootstrap is effectively sudo-free end-to-end.

#### 3.10.3.1 Brew — shared install, single-writer (Mac and Linux)

Brew is the one manager that doesn't fit cleanly into "system-scope" or "user-scope." Its actual model:

| Aspect | Behavior |
|---|---|
| Prefix | Linux: `/home/linuxbrew/.linuxbrew` (or `linuxbrew` system user on the multi-user install). Apple Silicon: `/opt/homebrew`. Intel Mac: `/usr/local`. |
| Ownership | **First user to install** becomes the owner of the entire prefix tree (Cellar, bin, var, etc.). No automatic re-sharing. |
| Readers | **All users** — the prefix is 755 / executable. Any user on the machine can run binaries and libraries installed there. |
| Writers | **Only the owner.** A second user running `brew install X` will get permission-denied on `Cellar/` writes — or worse, `sudo brew install` which brew actively refuses ("never run brew as root"). |
| Per-user fallback | `$HOME/.linuxbrew` on Linux is technically installable but officially unsupported — bottles are prefix-baked, so a non-default prefix forces source builds for everything. Not viable as an automatic fallback. |

**Implications for the resolver:**

1. **Dedup works naturally.** `brew list --formula X` (bulk-capable per §3.6.1) tells us if X is already installed. If yes, a second user's `brew install X` is a trivial no-op — brew checks Cellar, finds X, does nothing. Safe even for a non-owner.
2. **Installing something new requires write access.** If X isn't installed and the current user isn't the prefix owner, the install fails hard. This is the case the library must catch pre-install.
3. **No user-scope fallback.** Unlike flatpak's `--user`, brew has nowhere else to put it within reasonable constraints (source builds are too slow for bootstrap). A non-owner on a shared machine simply can't install new packages via brew.

**New probes:**

```bash
detect::brew_prefix               # echoes /home/linuxbrew/.linuxbrew or /opt/homebrew or /usr/local
detect::brew_prefix_owner         # echoes username that owns the prefix, or empty if not writable by anyone sane
detect::brew_can_install          # 0 if current user can `brew install` (write-test the prefix)
                                  # implementation: test -w "$(brew --prefix)/Cellar" &&
                                  #                 test -w "$(brew --prefix)/var/homebrew"
```

All unprivileged (file stat + write-test on user-owned paths). Satisfies §5.

**Resolver logic — brew candidates:**

```
resolve brew:X:
  1. If pkg_has brew X (from bulk cache §3.6.1) → already installed, all users benefit, SKIP.
  2. Else if detect::brew_can_install → install will succeed, QUEUE for batch (§3.6.3).
  3. Else → fall through to next candidate in the list; emit a diagnostic:
     "brew:X unresolvable for this user — prefix owned by <owner>.
      Ask the owner to run `brew install X`, or fall back to <next candidate>."
```

**Candidate-table implication:** every `brew:*` entry should have a follow-up candidate (native pkg mgr or scripted install) whenever possible, so non-owner users on shared machines still get a resolution. In practice this is already true — the §3.4 examples all list native first, brew second or last.

**Surfaced in the pre-flight report:**

```
Homebrew status:
  prefix: /home/linuxbrew/.linuxbrew
  owner:  alice (you are bob — cannot install new packages)
  fallback: capabilities resolving to brew will prefer alternate candidates
```

User sees the constraint before install, not after.

**Shared-writer multi-user setup** (outside the scope of this design, but documented for completeness): if a team wants multiple users to install via brew on a Linux box, the canonical setup is to create a `linuxbrew` group, `chgrp -R linuxbrew $(brew --prefix) && chmod -R g+w $(brew --prefix)`, and add target users to that group. That's a manual admin action, not something bootstrap should attempt. The library only *detects* whether the current user can install; it doesn't try to change prefix permissions.

#### 3.10.4 Language package managers and version switchers

`npm i -g`, `pip install --user`, `pipx`, `uv tool`, `cargo install`, `go install` — each of these *could* serve as a fallback manager for CLI tools packaged in their ecosystem (e.g., `tldr` via npm, `httpie` via pipx, `bat`/`ripgrep` via cargo, `lazygit` via go install). In practice they carry a **class of failure mode the resolver can't compensate for**: orphaning by version switchers.

**The problem, concrete cases:**

| Combo | What happens on version bump |
|---|---|
| `nvm` + `npm i -g X` | globals live under `$NVM_DIR/versions/node/vX.Y.Z/lib/node_modules`. Switching to a new node version means the globals are gone. `nvm install --reinstall-packages-from=prev` exists but is best-effort, fragile with native modules, and silently skips packages that fail to rebuild. |
| `pyenv` + `pip install --user` | `~/.local/lib/python3.X/site-packages` — version-specific directory. `python3.12 -> python3.13` orphans everything installed under 3.12. |
| `uv venv` (project-local) | not the issue — project-scoped. But `uv tool install` persists to `~/.local/share/uv/tools` with an embedded python; if `uv` rebuilds its toolchain, tools may need reinstall. Less bad than pip but not free. |
| `pipx` | uses per-tool venvs; pipx pins each tool's python independently. **Survives** system python version changes, unlike pip --user. |
| `rustup` + `cargo install` | binaries go to `$CARGO_HOME/bin` (stable across toolchain switches by default). **Safe.** |
| `go install` | binaries go to `$GOBIN` (stable across Go version switches). **Safe.** |

User's explicit experience, verified against the failure modes: `nvm`-managed node orphans `npm -g` globals on upgrade. Personal policy is to avoid `npm i -g`, prefer system pkg managers or per-project dev-dependency installs. Design should reflect this.

**Design decisions:**

1. **Default candidate tables never list `npm:` or `pip-user:` as fallbacks for CLI tools.** If a tool is only available via npm or pip, the library reports it as unresolvable rather than silently installing into a version-managed home that will be orphaned.

2. **`pipx:`, `cargo:`, `go:` ARE acceptable secondary candidates** — they install into stable, version-switcher-agnostic locations. Listed when they're the best option (e.g., `pipx:httpie`, `cargo:bat` as a last-resort universal fallback below `brew:bat`).

3. **`uv-tool:` treated like pipx** — stable enough for default candidate lists; verified empirically 2026-04-14 (see below).

4. **Manager registration flags** — each manager registration carries a `volatility` flag:
   ```bash
   MGR_VOLATILITY[npm-global]="version-managed"   # orphaned by nvm switch
   MGR_VOLATILITY[pip-user]="version-managed"     # orphaned by python version switch
   MGR_VOLATILITY[pipx]="stable"
   MGR_VOLATILITY[uv-tool]="stable"               # verified 2026-04-14
   MGR_VOLATILITY[cargo]="stable"
   MGR_VOLATILITY[go-install]="stable"
   MGR_VOLATILITY[brew]="stable"
   MGR_VOLATILITY[apt]="stable"
   # etc.
   ```
   Users opting in to a volatile manager (e.g., `DETECT_ALLOW_NPM_GLOBAL=1`) get a visible warning in the resolver output: `npm-global:tldr:volatile (orphaned on nvm switch)`.

5. **uv-tool volatility verification (2026-04-14).** Empirical test with `uv 0.11.6` on Linux: `uv tool install httpie`, probe venv layout, simulate python removal via rename + `uv python uninstall`, confirm recovery path. See [[logs/2026-04-14-uv-tool-volatility-test]]. Key findings:

   - **Venvs hard-pin a python home path in `pyvenv.cfg`.** Default target is the system/brew python (e.g. `/home/linuxbrew/.linuxbrew/opt/python@3.14/bin`); `uv tool install --python 3.13` anchors to the uv-managed major.minor symlink `~/.local/share/uv/python/cpython-3.13-linux-x86_64-gnu/bin`, which is the resilience-enabling detail — patch updates within a minor presumably flip the symlink rather than break the path.
   - **Brew's `python@X.Y/opt` path is stable** until explicit `brew uninstall python@X.Y` or post-major-upgrade `brew autoremove` with no other consumers. `brew upgrade python` creates a new `python@X.(Y+1)` and leaves `python@X.Y` untouched.
   - **`uv self update` is refused** on package-manager installs (brew/apt/dnf/pip) with a pointer to the package-manager's own upgrade path — correct behavior, not a volatility risk.
   - **Breakage is gated on explicit user action.** `uv python uninstall X.Y` silently orphans any tool pinned to that version (no dep check, no warning). Brew-anchored tools break only under `brew uninstall python@X.Y` or autoremove, both of which are explicit.
   - **Recovery footgun worth documenting.** Post-breakage, `uv tool upgrade --reinstall <tool>` fails with "not installed"; `uv tool install --reinstall <tool>` (or plain `uv tool install <tool>`) is the working recovery. Mention this in `Bootstrap-Detection.md` under the uv-tool manager entry.

   **Library behavior implications:** when the library installs via `uv-tool`, prefer `--python <major.minor>` with a uv-managed python for resilience over the default system-python anchor. The major.minor symlink pattern is the stability primitive.

The framing generalizes: **a secondary manager is safe to default-list only if its install location is stable across the version-switcher tooling in common use for that ecosystem.** Homebrew, apt, dnf, cargo, go, pipx all meet this bar. npm -g, pip --user don't.

#### 3.10.4.1 User opt-out — explicit blacklist

Beyond the default exclusions, users have their own preferences (some avoid snap on principle, some avoid brew on servers, some want to refuse all language-scoped managers). Expose a blacklist:

**CLI**: `bootstrap-dotfiles --opt-out npm,pip,uv,snap` (comma-separated manager tokens).
**Env var**: `DETECT_OPT_OUT="npm pip uv snap"` (space-separated; consumed by the library directly; works for chezmoi template contexts and non-interactive runs).
**Config file**: `~/.config/dotfiles/detect.conf` with `opt_out=npm,pip,uv` — picked up when the flag and env var are unset.

Resolution order: CLI flag > env var > config file > library defaults.

**What can be blacklisted:**

| Category | Example tokens | Blacklistable? |
|---|---|---|
| Native system pkg mgrs | apt, dnf, yum, microdnf, zypper, pacman, apk, xbps, emerge, eopkg, rpm-ostree, transactional-update, pkg (BSD) | **No — hard-refuse with an error.** Blacklisting the only native manager on a distro would leave nothing functional. |
| Universal secondary | brew | Yes |
| Sandboxed / app-store | flatpak, snap | Yes |
| Language-scoped | npm-global, pip-user, pipx, uv-tool, cargo, go-install, gem | Yes |
| Scripted installers | script | Yes (forces fail-early instead of auto-running `install-artifact` etc.) |

`detect::_assert_opt_out_valid` runs at library init: if the user tries to opt out of a native manager, the library exits with:

```
detect[error]: cannot opt out of native package manager 'apt' — this is the only manager that can install base prerequisites on this system. Remove 'apt' from --opt-out.
```

Aliases accepted for convenience: `--opt-out npm` matches `npm-global`; `--opt-out pip` matches `pip-user`; `--opt-out uv` matches `uv-tool`. Full alias map, rationale for each manager's default inclusion/exclusion, and worked examples live in the wiki page `Bootstrap-Detection.md` (URL referenced from `--help`, not inlined). See §3.12 for the help-text policy.

**Effect on the resolver**: opted-out managers are removed from `available_managers` at the top of `resolve()`, so candidates referencing them are skipped. If a capability has *no* viable candidate after opt-outs, the resolver emits:

```
detect[warn]: capability 'tldr' unresolvable under current opt-outs (--opt-out npm)
             Available candidates were: npm-global:tldr
             Consider: install via alternative channel, or remove 'npm' from --opt-out.
```

Bootstrap decides whether unresolvable items are fatal (required capability) or skippable (optional capability) — that's a per-capability flag in the candidate table, separate from opt-out.

**Surfaced in the pre-flight report** — report lists opted-out managers explicitly so the user sees exactly what's being excluded before the install phase starts.


#### 3.10.5 Implication for the resolver output

`detect::pkg_resolve` and `pkg_resolve_all` both emit a third field when a candidate has known quirks:

```
# Format: mgr:name:[flag,flag,...]
apt:lxd:shim-to-snap
flatpak:org.mozilla.firefox:sandboxed,gui
snap:lxd:auto-refresh
```

Consumers (bootstrap, dry-run report) surface these flags in their output so the user sees what they're getting before confirming install.

### 3.12 `--help` terseness — long docs belong in the wiki

Help output is what users read under pressure (something didn't work, they need to know what flag does what). Long help scrolls off and gets skimmed or ignored. **The library and any consuming CLI follow a terseness rule:**

1. **One line per flag, max ~80 chars** — enough to jog memory, not enough to teach.
2. **No exhaustive tables, alias maps, policy rationale, or worked examples inlined.**
3. **A single `See: <URL>` line at the bottom of `--help`** pointing to the canonical wiki page for deep detail.
4. **Wiki page is the single source of truth** for alias maps (`npm → npm-global`), default-inclusion/exclusion rationale per manager, opt-out semantics, worked examples, override env vars, decision tables. `--help` never grows to absorb them.

Example target `--help` shape for `bootstrap-dotfiles`:

```
Usage: bootstrap-dotfiles [options] [<host>]

  --from-jot             Self-bootstrap from an existing jot manifest.
  --opt-out <mgrs>       Comma-separated list of package managers to exclude.
                         Aliases: npm, pip, uv, snap, brew. Cannot opt out of
                         native system managers.
  --offline              Skip metadata refresh; query only cached state.
  --refresh              Force metadata refresh even if cache is fresh.
  --quiet / -q           Suppress pre-flight summary.
  --dry-run              Report what would happen; do not install.
  -v, --version          Print version and exit.
  -h, --help             This help.

See: https://github.com/uhop/dotfiles/wiki/Bootstrap-Detection
```

Nothing about which distros resolve to which pkg manager, why snap is opt-in, how the polkit rule interacts with non-sudoers, etc. — all of that lives in `Bootstrap-Detection.md` and is one URL away.

This matches the project convention already in play elsewhere (see `Msmtp.md`, `Dcm.md`, `Jot.md` wiki pages that absorbed detail out of their respective `--help`s), and is consistent with the queue discipline and wiki discipline in [[topics/project-wiki-convention]].

## 4. Integration points

### 4.1 `bootstrap-dotfiles`

- Pre-flight gains a `detect::summary` print (unless `--quiet`) and the existing report-mode shows `detect::report_json`.
- Generated install heredoc gets `detect-distro.sh` inlined at the top; subsequent package-install calls switch to `detect::pkg_install_if_missing`.
- `--from-jot` path already does local identity detection — refactored to source the same lib.

### 4.2 `.chezmoi.toml.tmpl`

- Today's inline parsing of `/etc/os-release` replaced by invoking the library (via `output` template function) and parsing its JSON summary.
- Adds new chezmoi data keys: `.distroFamily`, `.isImmutable`, `.initSystem`, `.sudoGroup` — available to all templates.

### 4.3 `run_onchange_before_install-packages.sh.tmpl`

- Current `{{ if eq .pkgManager "apt" }}` branches stay (they consume chezmoi data set by 4.2), but the SOURCE of that data is now the shared lib.
- Optionally: use `detect::pkg_install_if_missing` so re-runs are quieter.

## 5. Privilege model — sniffing must be unprivileged

**Hard constraint: every probe in the library must work without `sudo`.** Sniffing runs in the SSH session as the logged-in user, before any privileged step. Installs that follow are the only privileged actions — they prompt for sudo at the TTY, exactly as today's bootstrap flow already does.

This constraint rules out some "obvious" probe implementations and shapes a few design decisions:

### 5.1 Probe audit — what's safe without sudo

All of these read world-readable state or query user-scoped tools:

| Probe | Command | sudo? | Notes |
|---|---|---|---|
| `/etc/os-release` | `. /etc/os-release` | no | world-readable |
| `has_cmd` | `command -v X` | no | |
| `arch` / `uname_s` | `uname -m` / `uname -s` | no | |
| `init_system` | `ps -p 1 -o comm=` or `readlink /sbin/init` | no | |
| `has_ipv6` | `ip -6 route get 2606:4700:4700::1111` | no | `ip route get` is unprivileged |
| `can_reach` | `curl --max-time 5 -sI <url>` | no | **not** ping (needs CAP_NET_RAW) |
| `is_container` | `systemd-detect-virt -c`, `test -f /.dockerenv`, `$container` env | no | |
| `is_wsl` | `$WSL_DISTRO_NAME`, `test -d /run/WSL` | no | |
| `sudo_group` | `getent group wheel sudo admin` | no | user DB is world-readable |
| `can_sudo_nopasswd` | `sudo -n true 2>/dev/null` | no | tests without using |
| `locale` | `locale` | no | |
| `getenforce` | `getenforce` | no | reads `/sys/fs/selinux/enforce`, world-readable |
| `pkgmgr` | `command -v apt-get dnf ...` | no | |

Package-manager **queries** (availability, version) are all unprivileged on modern distros:

| Query | Command | sudo? |
|---|---|---|
| `pkg_avail` on apt | `apt-cache show X` / `apt-cache policy X` | no |
| `pkg_avail` on dnf | `dnf info X` | no — uses user cache or system cache if readable |
| `pkg_avail` on zypper | `zypper info X` / `zypper search X` | no |
| `pkg_avail` on pacman | `pacman -Si X` | no |
| `pkg_avail` on apk | `apk info X`, `apk search X` | no |
| `pkg_avail` on brew | `brew info --json=v2 X` | no (brew refuses sudo by design) |
| `pkg_avail` on flatpak | `flatpak remote-info flathub X` | no |
| `pkg_avail` on snap | `snap info X` | no |
| `pkg_has` (installed?) | `dpkg -s`, `rpm -q`, `pacman -Q`, `apk info -e` | no |

### 5.2 Probes that must be reworked to avoid sudo

Three probes in the original design would have needed root. Revised approaches:

| Original approach | Problem | Revised |
|---|---|---|
| `is_immutable` via `touch /usr/.rwtest` | write to `/usr` needs root; fails silently on permission denial even on writable systems (unprivileged user) | Use **read-only signals**: `findmnt -no OPTIONS /usr \| grep -qw ro` OR `detect::has_cmd rpm-ostree` OR `detect::has_cmd transactional-update` OR `test -f /run/ostree-booted`. Unprivileged, deterministic. |
| `aa-status --json` | needs root on Ubuntu to read profile list | Best-effort: check `/sys/module/apparmor/parameters/enabled` (world-readable `Y`/`N`). Skip profile enumeration; we don't need it. |
| `ip link` / interface probing | some fields need root | Not needed — `ip -6 route get` gives the reachability answer we actually want. Don't enumerate interfaces. |

### 5.3 Metadata refresh — moved out of the probe phase

Some pkg managers need `sudo` to refresh cached package metadata:

| Manager | Refresh command | sudo? | Query without refresh? |
|---|---|---|---|
| apt | `apt-get update` | yes | yes — stale cache still answers `apt-cache show` |
| dnf | `dnf makecache` | yes | yes — uses user-level cache fallback; may warn |
| zypper | `zypper refresh` | yes | yes |
| pacman | `pacman -Sy` | yes | yes — stale sync DB still answers `pacman -Si` |
| apk | `apk update` | yes | yes on Alpine images (they ship with a usable cache) |
| brew | `brew update` | no | yes |
| flatpak | `flatpak update --appstream` | no (--user) | yes |
| snap | none needed | — | yes |

**Rule**: the detection library **never runs a refresh**. It queries whatever cache is present. If the cache is empty (fresh container image), a probe may return "unknown"; the resolver treats that as "candidate not viable" and falls through.

**The refresh is folded into the install step itself** — `apt-get update && apt-get install ...` runs in one sudo-elevated invocation, exactly as bootstrap already does today. No behavior change there.

### 5.4 Implications for the design

- **Probe phase is 100% user-space.** Can run over plain SSH without a TTY, without sudo cached, without any privilege elevation. The operator can redirect its output to a log without surprises.
- **The user-run flow is unchanged**: SSH in, run bootstrap, hit a single sudo prompt when install kicks off. Sudo credential stays cached long enough for all subsequent installs in the same run (normal sudoers default 5-15 min; bootstrap completes in under that window on every distro tested).
- **Fully unattended bootstrap remains feasible**, but the privilege model isn't the blocker — the chezmoi `/dev/tty` quirk is (see [[projects/dotfiles/queue]], open research item).
- **Cross-check in the test matrix**: add an assertion that running `detect::summary` and `detect::report_json` as an unprivileged user (no sudo, no sudoers entry) completes without a single permission-denied error. If any probe violates this, CI fails.

### 5.5 Falsifiability

The simplest way to enforce "no sudo during sniffing" is mechanical:

```bash
# Inside the library header
detect::_assert_no_sudo() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    return 0  # running as root is FINE (e.g., container bootstrap); just skip the guard
  fi
  if [[ "${SUDO_USER:-}" ]]; then
    echo "detect[error]: library must not be invoked via sudo during sniffing phase" >&2
    return 1
  fi
}
```

And a CI test: `sudo -n -u nobody bash -c 'source detect-distro.sh && detect::summary'` — if that fails, we've regressed.

## 6. Error and fallback semantics

- Every probe has a **timeout** (default 3s for network, 1s for command probes) and returns a **safe default on failure** (e.g. `has_ipv6` → false on timeout).
- Every probe is **non-fatal**. The library never `exit`s. Consumers decide whether missing capability is blocking.
- A probe failure logs one line to stderr prefixed `detect[warn]:` so it's visible in the test-matrix logs.
- Memoization via associative arrays keyed by probe name. `detect::reset` clears the cache (for tests).

## 7. Testing

- **Unit tests** (on the author's machine): mock `/etc/os-release` via `OS_RELEASE_PATH` override env var; stub `command -v` via a `detect::_which` internal that tests can monkey-patch. Covers all family/variant combinations without needing real containers.
- **Integration tests** (LXC matrix, reuse [[projects/dotfiles/design/multi-distro-test-plan]]): run `detect::summary` on each target distro, snapshot the output, commit snapshots. CI compares on each run — any change is a conscious update.
- **Silverblue/MicroOS smoke**: new LXC images added to the matrix specifically to exercise immutable-FS path. This is the first variant the matrix hasn't already covered.
- **Minimal-image smoke**: `debian:slim` and `alpine:edge` containers to exercise missing-prereqs path.

## 8. Migration strategy

Strictly non-breaking, delivered in three PRs:

1. **PR 1 — Library, no callers changed.** Add `.chezmoitemplates/detect-distro.sh` + tests. Export vars exist but aren't used. Zero risk.
2. **PR 2 — `.chezmoi.toml.tmpl` and `run_onchange_*` adopt the library.** Same behavior, same chezmoi data keys, different source. Verify via matrix that generated files are byte-identical.
3. **PR 3 — `bootstrap-dotfiles` adopts the library and decision table.** New behavior surfaces only on variant cases (immutable FS, container, IPv6). Existing 11 distros pass unchanged.

Each PR has its own matrix run. Rollback is per-PR.

## 9. Open questions

- **Where does the lib live in the user's home after install?** Proposal: `~/.local/lib/dotfiles/detect-distro.sh` + `~/.local/lib/dotfiles/detect-packages.sh`, managed by chezmoi via `{{ template "detect-distro.sh" . }}`. One canonical copy each.
- **Should chezmoi data keys be namespaced (`.detect.*`) or flat (`.distroFamily`)?** Leaning namespaced. Breaks existing `.pkgManager` references; fix call sites in PR 2.
- **Does `detect::pkg_install` honor `DRY_RUN=1`?** Yes — uniformly. Report mode prints `would install: mgr:name` per resolved capability.
- **macOS path.** Covered fully in §3.10.3. Brew is the *only* leveragable manager (Apple's tooling isn't a general install surface); it's treated as native, not secondary. Darwin-specific probe returns: `pkgmgr=brew`, `sudo_group=admin`, `init_system=launchd`, `is_immutable=false`, `has_flatpak=false`, `has_snap=false`. Bootstrap on Mac is effectively sudo-free.
- **Candidate-list maintenance.** Where do new capabilities get added? Proposal: `detect-packages.sh` is the authoritative table; test-matrix runs include a `detect::pkg_resolve` diagnostic pass that lists resolved-vs-unresolved capabilities per distro, caught in PR review.
- **Snap/flatpak scope.** Flatpak is GUI-only in default candidate tables (§3.10.1). Snap is mixed — listed in default CLI tables when it's the canonical source (`lxd`, `kubectl`, `multipass`, `yq`, etc.), gated behind `DETECT_ALLOW_SNAP=1` opt-in because auto-refresh is polarizing. For GUI capabilities users extend with, flatpak defaults on and snap stays opt-in.
- **Shim list maintenance.** `APT_SNAP_SHIMS` lives in `detect-packages.sh` (§3.10.2). Needs occasional updates as Ubuntu repackages — catch via matrix run (install a canary shim pkg and check the warning fires) rather than auto-detection.
- **`uv tool` volatility — verified 2026-04-14.** Classified `stable`. Breakage requires explicit user action (`uv python uninstall X.Y` or `brew uninstall python@X.Y`); uv refuses `self update` on package-manager installs and points at the pkg manager. Recovery footgun: `uv tool upgrade --reinstall` fails on a broken venv with a misleading "not installed" error — `uv tool install --reinstall` works. Full findings: [[logs/2026-04-14-uv-tool-volatility-test]]; design updates in §3.10.4.
- **pyenv interaction.** We don't currently use pyenv, but if adopted later the `has_pip_user` probe must detect the pyenv shim and treat the manager as `version-managed` (same as nvm+npm). No change needed now; flagged so future pyenv adoption doesn't silently break the resolver.
- **Version normalization across managers.** apt versions (`2.0.11-1`), brew versions (`2.0.13`), flatpak versions (arbitrary format). The `pkg_meets` comparator needs a normalizer that strips packaging suffixes before semver compare.
- **Metadata-refresh cost on first bootstrap.** `dnf makecache` can be 30 s+ on fresh installs. Accept as pre-flight cost; show a progress line so the user knows what's happening.

## 10. Success criteria

- All 11 currently-green distros still green after PR 3.
- Fedora Silverblue (or a Silverblue-equivalent LXC image) runs `bootstrap-dotfiles` to completion without dnf-on-immutable-FS errors.
- `debian:slim` runs bootstrap; missing prereqs get installed; no "command not found" errors.
- `/etc/os-release` parsing exists in exactly one file in the repo.
- Pre-flight report mentions IPv6 reachability, GHCR reachability, sudo posture.
- Every installed package in the bootstrap path goes through `detect::pkg_ensure <capability>`; no direct `apt install` / `dnf install` calls remain in `bootstrap-dotfiles` or `run_onchange_*` scripts.
- Candidate table covers at minimum: `c_toolchain`, `tar`, `xz`, `curl`, `git`, `tmux`, `vim`, `micro`, `bat`, `jq`, `fzf`, `ripgrep`, `tpm-prereqs`.
- **Full `detect::summary` + `detect::report_json` + every `pkg_resolve` call completes as an unprivileged user with zero permission-denied errors on every distro in the test matrix** (enforced by CI).

## 11. Next step

Write the implementation plan: `[[projects/dotfiles/plans/bootstrap-detection-plan]]` — task breakdown for PRs 1-3, file list per PR, test checklist per PR.
