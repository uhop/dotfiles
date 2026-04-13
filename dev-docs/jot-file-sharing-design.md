# Sharing sensitive files with jot

## Problem

Sensitive per-machine files — `~/.env`, `~/.msmtprc`, `~/.ssh/age.key`, SSL certificates, API tokens — need to travel between managed machines. They can't be committed to git or managed by chezmoi (secrets in a public repo). Two transfer paths exist today:

1. **`playbash put/get`** — works when the operator machine has direct SSH access to the target. Fast, secure (SSH transport), but requires connectivity.
2. **`scp` / manual copy** — same SSH requirement, no automation.

Neither works when machines can't reach each other directly — different networks, behind NAT, cloud instances, or simply "I'm setting up a laptop at a coffee shop and need my `.env` from the server at home."

A common scenario: a user travels with an already-configured laptop to a client's facility. Some settings are missing or need updating — VPN credentials, client-specific API tokens, an `.msmtprc` for the client's mail relay. If those files were uploaded to the S3 bucket beforehand (from the office or a home server), a single `jot get` pulls them down over any internet connection. No VPN back to the home network, no SSH tunnel, no asking a colleague to `scp` something.

Another scenario: a coworker has a file you need — a config, a certificate, a key. You call them and ask them to `jot put` it to the shared bucket. They encrypt and upload in one command; you `jot get` it minutes later. The file is encrypted at rest with a shared key, travels over HTTPS both ways, and neither person needs network access to the other's machine.

## Proposed solution

Use `jot` as a secure intermediary. It already provides:

- **Encrypted storage on S3** — files like `myfile.gz.age` are compressed and encrypted at rest.
- **`get` / `put` commands** — download (decrypt) and upload (encrypt) with a single command.
- **Extension-driven codec chain** — `.gz.age` means gzip then age-encrypt on upload, age-decrypt then gunzip on download. No flags to remember.
- **Prefix matching** — `jot get env` finds `env.gz.age` if it's the only match.

The workflow is already possible today with zero code changes:

```bash
# Machine A: upload a sensitive file
jot put ~/.env env.gz.age

# Machine B: download it
jot get env
mv env ~/.env
chmod 600 ~/.env
```

The gap is **documentation and conventions**, not code.

## What jot handles well

| Concern | Status |
|---|---|
| Encryption at rest | age via `~/.ssh/age.key` or SSH key pair |
| Encryption in transit | S3 over HTTPS |
| Compression | gzip, brotli, xz, zstd, bzip2 (extension-driven) |
| Upload / download | `jot put` / `jot get` |
| File listing | `jot list` with optional prefix filter |
| Cleanup | `jot delete` |
| Prefix ergonomics | `jot get env` finds `env.gz.age` |

## Conventions

### Naming

Use a `sys/` prefix in the S3 bucket to separate shared system files from personal notes:

```
sys/env.gz.age           # ~/.env
sys/msmtprc.gz.age       # ~/.msmtprc
sys/age-key.age          # ~/.ssh/age.key (no compression — tiny)
sys/ssh-config-d.tar.age # ~/.ssh/config.d/* bundled
```

`jot list sys/` shows only system files. Personal notes remain at the bucket root, uncluttered.

### Extension choice

- **`.gz.age`** — good default. Gzip is universal, age is the project's standard encryption.
- **`.age`** (no compression) — for files that are already tiny or binary-compressed (keys, certs).
- **`.tar.gz.age`** — for directories (e.g., `config.d/`). Jot auto-tars directories on `put` and auto-extracts on `get` (see [Directory support](#directory-support-in-jot)).

### Permissions

Jot does not preserve Unix permissions. After `jot get`, the user must set permissions explicitly:

```bash
jot get sys/msmtprc
mv msmtprc ~/.msmtprc
chmod 600 ~/.msmtprc
```

This is intentional — S3 has no concept of Unix modes, and silently setting 600 on everything would be wrong for non-secret files. The wiki workflow section should document the expected permissions for each file.

## Encryption key story

Jot encrypts with the first available key:

| Priority | Encrypt with | Decrypt with |
|---|---|---|
| 1 | `~/.ssh/age.key` | `~/.ssh/age.key` |
| 2 | `~/.ssh/id_rsa.pub` | `~/.ssh/id_rsa` |

### Same key on all machines (current model)

The wiki already documents distributing the same SSH key pair across machines (see [Setting Up a New Machine — Distributing keys across your own computers](https://github.com/uhop/dotfiles/wiki/Setting-Up-a-New-Machine#distributing-keys-across-your-own-computers)). If all machines share the same key, jot encryption/decryption works everywhere with no extra setup.

The age key (`~/.ssh/age.key`) can be distributed the same way — `scp` it to new machines during initial setup, or use jot itself once one key pair is in place (encrypt the age key with the SSH key, then decrypt on the target with the same SSH key).

### Different keys per machine

If machines have distinct key pairs, the current jot implementation encrypts to a single recipient. A file encrypted on machine A with A's key cannot be decrypted on machine B with B's key.

Two paths forward:

1. **Shared age key as the exchange key.** Distribute a single `age.key` to all machines (perhaps bootstrapped via SSH key encryption as described above). This is the simplest path and is already the natural outcome of the current setup.
2. **Multi-recipient age encryption.** `age` supports encrypting to multiple public keys. Jot will support a `--for` / `-f` flag to name recipients whose public keys are stored in `~/.config/jot/recipients/`. See [Multi-recipient encryption](#multi-recipient-encryption) for the full design.

## Bootstrap: chicken-and-egg

A brand-new machine has no age key and no AWS credentials. Getting the first secret onto it requires an out-of-band step:

1. **SSH access exists** (most common): `scp` or `playbash put` the age key and `~/.env` (which contains AWS credentials) directly.
2. **No SSH access**: manually copy the age key and `.env` via a USB drive, password manager export, or similar. This is unavoidable — you need at least one secret delivered out-of-band to unlock the rest.

Once `~/.env` (AWS creds) and `~/.ssh/age.key` are on the new machine, `jot get` unlocks everything else.

The bootstrap sequence:

```
out-of-band → ~/.env + age.key → jot get sys/msmtprc → jot get sys/... → done
```

## Workflow summary

### Uploading a sensitive file (any machine)

```bash
jot put ~/.msmtprc sys/msmtprc.gz.age
```

### Downloading to a new machine

```bash
jot get sys/msmtprc
mv msmtprc ~/.msmtprc
chmod 600 ~/.msmtprc
```

### Listing shared files

```bash
jot list sys/
```

### Updating a shared file

```bash
# Edit in-place (download, edit, re-upload)
jot edit sys/env

# Or replace entirely
jot put ~/.env sys/env.gz.age -y
```

### Bundling a directory

With directory support (see below), jot handles this automatically:

```bash
# Upload — jot detects a directory, auto-prepends tar
jot put ~/.ssh/config.d -a gz.age          # → config.d.tar.gz.age

# Download — prefix match, full decode + extract
jot get sys/ssh-config-d
```

## Directory support in jot

Jot currently handles flat files. Directories should be supported natively via `tar`.

### `put` a directory

When the local path is a directory, jot auto-tars it before encoding. The primary form uses `--as` / `-a` to specify the codec chain (tar is auto-prepended):

```bash
jot put ~/.ssh/config.d -a gz.age        # → ssh-config-d.tar.gz.age
jot put ~/certs/ sys/certs -a gz.age     # → sys/certs.tar.gz.age
```

Jot detects a directory, prepends `tar` to the codec chain (since tar produces the single file the other codecs need), creates a tar archive in the temp dir, then runs the remaining chain (`.gz` → `.age`) before uploading.

When the remote name already carries the full extension chain, `--as` is not needed:

```bash
jot put ~/.ssh/config.d sys/ssh-config-d.tar.gz.age
```

**Warning on missing `.tar`:** if the source is a directory but the resolved extension chain contains no `tar`, jot warns ("source is a directory but remote name has no .tar — the archive will be tarred but the name won't reflect it") and proceeds with the user-supplied name. This handles cases like `jot put ~/stuff/ backup.txt` where the user explicitly chose an unusual name.

### `--as` / `-a` flag for `put`

Specifies the codec chain to apply when uploading. This is the primary way to control encoding for both files and directories:

```bash
jot put ~/certs/ sys/certs -a gz.age        # directory → sys/certs.tar.gz.age
jot put ~/.env sys/env -a gz.age            # file → sys/env.gz.age
```

For directories, `tar` is auto-prepended to the chain. For files, the chain is used as-is.

The flag is only needed when the remote name doesn't already carry the desired extensions. When the remote name already has extensions (`sys/env.gz.age`), `--as` is unnecessary.

The value is parsed leniently: leading dots are stripped and multiple dots are collapsed, so `.gz.age`, `gz.age`, and `..gz..age.` all produce the same chain `["gz", "age"]`. This avoids any ambiguity about whether the value should start with a dot.

### `get` a tar — prefix disambiguation

The existing prefix-matching logic already provides the right behavior:

| Command | Matches | Result |
|---|---|---|
| `jot get sys/ssh-config-d` | `ssh-config-d.tar.gz.age` | decrypt → decompress → **extract tar** → directory `ssh-config-d/` |
| `jot get sys/ssh-config-d.tar` | `ssh-config-d.tar.gz.age` | decrypt → decompress → stop at `.tar` → file `ssh-config-d.tar` |
| `jot get sys/ssh-config-d.tar.gz` | `ssh-config-d.tar.gz.age` | decrypt → stop at `.tar.gz` → file `ssh-config-d.tar.gz` |

The codec chain already peels extensions one at a time and stops when it hits an unrecognized extension. Adding `.tar` as a recognized codec that extracts to a directory makes this work naturally. The "stop point" is wherever the user's prefix ends — longer prefixes peel fewer layers.

### Implementation notes

- `tar` becomes a new case in `do_command`: decode creates a directory, encode creates a `.tar` from a directory.
- On decode, `tar xf` into the working directory.
- On encode, `tar cf` from the source directory.
- The `edit` command refuses to operate on tar entries (no meaningful editor experience for a directory). A `--force` flag overrides this for edge cases where the user knows what they're doing.

## Multi-recipient encryption

`age` supports encrypting to multiple public keys. The default (single-key) path must stay zero-friction; multi-recipient is opt-in.

### CLI design

Default key — no flags, current behavior:

```bash
jot put ~/.env sys/env.gz.age
jot get sys/env
```

Named recipients — a comma-separated list specifies who can decrypt:

```bash
jot put -f bob,jim ~/certs/ sys/certs -a gz.age
```

When `-f` / `--for` is specified, jot encrypts to the listed recipients' public keys instead of the default key. Decryption still uses the caller's private key (which must match one of the recipients).

Options.bash stores one value per flag (associative array, last write wins), so repeated `-f bob -f jim` would lose `bob`. Comma-separated is the correct approach: `-f bob,jim`. Jot splits on commas to get the list.

### Recipient key storage

Recipients are named identities that map to public key files at `~/.config/jot/recipients/<name>.pub`. Each file contains one or more public keys in age format (one per line). The directory can be overridden with `JOT_RECIPIENTS_DIR`.

```
~/.config/jot/recipients/
├── bob.pub      # Bob's age public key(s)
├── jim.pub      # Jim's age public key(s)
└── team.pub     # composite — multiple keys for a group
```

When encrypting with `-f bob,jim`, jot reads `bob.pub` and `jim.pub` and passes both to `age --encrypt -R bob.pub -R jim.pub`. When no `-f` is specified, the default key (`~/.ssh/age.key` or SSH key pair) is used — zero-friction single-key path.

The recipients directory is managed by chezmoi (public keys are not secrets) and shared across the fleet the same way as any other config — via `chezmoi update`. This means all machines automatically know all named recipients.

## Bundle helpers: `jot-bundle` / `jot-deploy`

Two standalone scripts handle the "gather files → bundle → upload" and "download → unbundle → install" workflows. They are separate from jot — jot is a general-purpose encrypted S3 tool; these are specific to the dotfiles system-file workflow.

### Manifest

A manifest file describes which files to collect, their target paths, permissions, and ownership. Managed by chezmoi (contains no secrets — just paths and metadata):

```
# sys-files.manifest — one entry per line
# path                mode  [owner]
.env                  600
.msmtprc              600
.ssh/age.key          600
.ssh/config.d/        700
/etc/ssl/local.pem    644   root:root
```

- Paths without a leading `/` are relative to `$HOME`.
- Absolute paths are used as-is.
- `owner` is optional — when present, the helper uses `sudo` to read (on collect) or write (on deploy).
- Trailing `/` means a directory entry.

The manifest is embedded in the archive under a predefined non-colliding name (`.jot-manifest`). This makes archives self-describing.

### Missing files

Both helpers handle missing files gracefully:

- **Collect**: if a file listed in the manifest doesn't exist on this machine, skip it and warn. The archive contains only what was found. The embedded manifest records which entries were present and which were skipped, so the deploy side knows.
- **Deploy**: if the archive doesn't contain a file listed in the embedded manifest (marked as skipped during collect), skip it and warn. If the target directory for a file doesn't exist, create it with the appropriate permissions.

This makes both tools resilient — a manifest can be a superset of what any single machine has.

### Permissions and ownership

Permissions come from the static manifest, not from the source filesystem. The manifest is the source of truth for how files should be installed. This keeps behavior predictable — if a source file has wrong permissions, the archive still installs correctly.

The collect helper needs `sudo` to read files owned by root (e.g., `/etc/ssl/local.pem`). It checks ownership before reading and escalates only when necessary, following the same `sudo` pattern as `upd`/`cln` — sudoers rules from chezmoi's `/etc/sudoers.d/chezmoi` allow passwordless operation for maintenance commands.

### Bundle (upload) helper

Reads the manifest, gathers the listed files from the local machine, bundles them, and uploads via jot:

```bash
jot-bundle sys/myhost                      # uses default manifest
jot-bundle sys/myhost -m custom.manifest   # custom manifest
```

Internally:

1. Read the manifest (default: chezmoi-managed path, e.g., `~/.local/share/jot/sys-files.manifest`).
2. For each entry: check existence; if present, copy to a staging directory (using `sudo` if the manifest specifies an owner). If missing, record as skipped.
3. Write the resolved manifest (with skip annotations) as `.jot-manifest` in the staging directory.
4. `jot put <staging-dir> sys/myhost.tar.gz.age` — auto-tar, compress, encrypt.

### Deploy (download) helper

Downloads an archive, reads the embedded manifest, and installs files to their target locations:

```bash
jot-deploy sys/myhost                      # report what would change (dry-run)
jot-deploy sys/myhost --apply              # actually install files
jot-deploy sys/myhost -i                   # interactive: prompt per file
```

Internally:

1. `jot get sys/myhost` — decrypt, decompress, extract.
2. Read `.jot-manifest` from the extracted directory.
3. For each non-skipped entry: compare with target, copy if needed, set mode, set owner if specified (via `sudo`).
4. Report what was installed, what was skipped, and what was unchanged.

### Overwrite behavior

When the target file already exists, `jot-deploy` must decide what to do. Three strategies, controlled by a flag:

| Mode | Flag | Behavior |
|---|---|---|
| **Report** (default) | *(none)* | Compare each file; report which are missing, which differ, which match. Do not write anything. |
| **Overwrite** | `--apply` | Write all files from the archive, overwriting existing targets. Skip files that are already identical. |
| **Interactive** | `--interactive` / `-i` | For each differing file, show a diff and prompt: overwrite / skip / open in editor (merge). |

The default is **report** (dry-run by nature) — consistent with the project convention that destructive operations default to dry-run with `--apply` to actually execute. This means `jot-deploy sys/myhost` is always safe to run — it shows what *would* change without touching anything. `jot-deploy sys/myhost --apply` does the actual install.

For identical files (content matches), all modes skip the copy and report "unchanged".

For files that only exist in the archive (missing on the target machine), all modes install them — there's nothing to overwrite. Report mode still shows these as "would install".

### Archive naming

The S3 key can be host-specific (`sys/laptop.tar.gz.age`) or role-based (`sys/dev-workstation.tar.gz.age`). Multiple manifests or multiple archives can coexist — the user picks which to bundle/deploy.

## bootstrap-dotfiles jot path

`bootstrap-dotfiles` currently only works over SSH. It should offer a jot-based path for situations where SSH access to the operator machine isn't available (e.g., setting up a machine remotely without VPN). A `--from-jot` flag (or similar) would pull system files from S3 instead of copying them from the operator machine.

Prerequisites: the new machine needs AWS credentials (`~/.env`) and an encryption key (`~/.ssh/age.key`) before this path works — the bootstrap chicken-and-egg. These two files must arrive out-of-band (scp, USB, password manager). Once they're in place, `bootstrap-dotfiles --from-jot` can pull everything else.

This is confirmed as future work. Design TBD — it depends on the bundle helpers being implemented first.

## Versioning / history

S3 bucket versioning can keep old versions of shared files automatically. This is an S3-level setting (enable versioning on the bucket), not a jot concern. Worth documenting in the wiki as a recommendation for the bucket setup.

## What to document in the wiki

Add a "Sharing sensitive files" section to the [Jot wiki page](https://github.com/uhop/dotfiles/wiki/Jot) covering:

- The `sys/` naming convention
- Upload/download workflow with permission notes
- Directory support
- Pointer to Setting Up a New Machine for the bootstrap sequence

Add a brief mention + link in [Setting Up a New Machine](https://github.com/uhop/dotfiles/wiki/Setting-Up-a-New-Machine) under a "Sensitive files" heading, after the SSH key distribution section.
