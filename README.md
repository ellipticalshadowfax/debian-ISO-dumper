# debian-ISO-dumper

> Snapshot your Debian system. Burn it to an installer. Hand it to anyone.

`debian-ISO-dumper` remasters a standard Debian netinst ISO to replay the exact package state of your running machine on a fresh install — while keeping the normal Debian Installer flows for partitioning, users, locale, and everything else. No custom repos, no PXE server, no Ansible. One script, one ISO.
## NOTICE
This is AI generated code! Yes, I'm a sell out....
---

## How it works

1. **Snapshot** — reads your installed package list via `dpkg-query`
2. **Optionally embed** — downloads the `.deb` files into the ISO as a local apt repository for fully offline installs
3. **Optionally archive** — tarballs your settings from `/etc`, `/usr/local`, `/opt` (or custom paths) into the payload
4. **Remaster** — injects a `preseed.cfg` and `postinstall.sh` into a standard Debian netinst ISO
5. **Output** — a bootable hybrid ISO (BIOS + UEFI) that runs the normal installer, then silently replays your packages and settings in the late-command stage

---

## Requirements

- Debian-based host (must be run as root)
- `xorriso`, `rsync`, `tar`, `zstd`, `gzip`
- `dpkg-query`, `apt-get`, `apt-cache`
- `curl` or `wget` (for ISO download)
- `apt-ftparchive` — only if using `--download-packages`
- `whiptail` or `dialog` — for the interactive TUI (optional, falls back to plain prompts)

Install the build deps on Debian/Ubuntu:

```bash
sudo apt install xorriso rsync zstd curl whiptail apt-utils
```

---

## Quick start

```bash
# Clone and run — the TUI will guide you through everything
git clone https://github.com/you/debian-ISO-dumper
cd debian-ISO-dumper
sudo ./build-custom-installer.sh
```

The script will ask:
- Whether to include a settings snapshot
- Whether to build an offline package payload (with an interactive package picker)
- Confirm the plan before writing anything to disk

The finished ISO lands at `./custom-debian-installer.iso` by default.

---

## Usage

```
sudo ./build-custom-installer.sh [options]
```

### ISO source

| Flag | Description |
|---|---|
| `--base-iso PATH` | Use an existing netinst ISO instead of downloading |
| `--base-iso-url URL` | Override the download URL (default: Debian 12 amd64 netinst) |
| `--cache-dir DIR` | Where to cache the downloaded base ISO (default: `./.cache`) |

### Output

| Flag | Description |
|---|---|
| `--workdir DIR` | Build workspace (default: `./build`) |
| `--output PATH` | Output ISO path (default: `./custom-debian-installer.iso`) |
| `--hostname NAME` | Hostname to seed into the installer (default: current hostname) |

### Settings snapshot

| Flag | Description |
|---|---|
| `--include-settings` | Archive `/etc`, `/usr/local`, `/opt` into the ISO payload |
| `--snapshot-paths LIST` | Comma-separated paths to archive instead of the defaults |

Sensitive files are always excluded from the snapshot: `machine-id`, `fstab`, `mtab`, SSH host keys, and persistent udev net rules.

### Offline package payload

| Flag | Description |
|---|---|
| `--download-packages` | Download `.deb` files and build a local apt repo inside the ISO |
| `--offline-packages-file F` | Text file of package names (one per line) to embed; skips the TUI picker |
| `--selector-scope SCOPE` | `manual` (only manually-installed packages) or `all` (everything) — default: `manual` |

When `--download-packages` is set without `--offline-packages-file`, an interactive TUI picker appears. Dependencies are resolved and downloaded automatically.

### Flow control

| Flag | Description |
|---|---|
| `--resume` | Skip already-completed stages (useful after a failed build) |
| `--stop-after STAGE` | Stop after `plan`, `download`, `extract`, `payload`, or `build` |
| `--no-tui` | Disable all TUI widgets, use plain terminal prompts |
| `--help` | Show usage |

---

## Build stages

The script runs five sequential stages, each stamped in `<workdir>/state/` so `--resume` can skip them:

```
plan  →  download  →  extract  →  payload  →  build
```

| Stage | What happens |
|---|---|
| `plan` | Prompts confirmed, nothing written yet |
| `download` | Base ISO fetched (or verified from cache) |
| `extract` | ISO mounted, contents rsynced to `<workdir>/iso-root/` |
| `payload` | Package list, settings archive, and offline `.deb` repo assembled |
| `build` | `preseed.cfg` and `postinstall.sh` injected, final ISO built with `xorriso` |

---

## What goes on the ISO

```
iso-root/
├── preseed.cfg               ← seeds hostname, runs postinstall in late_command
└── custom/
    ├── postinstall.sh        ← reinstalls packages and restores settings
    ├── package-versions.tsv  ← full package list with pinned versions
    ├── package-names.txt     ← plain list of package names
    ├── system-config.tar.zst ← settings snapshot (if --include-settings)
    ├── offline-selected.txt  ← packages chosen for offline embed
    ├── offline-expanded.txt  ← selected + all resolved dependencies
    └── repo/
        ├── pool/             ← downloaded .deb files
        ├── Packages          ← apt repository index
        └── Packages.gz
```

The installer boots normally — you still choose your disk layout, user accounts, locale, and timezone. At the very end, `postinstall.sh` runs inside the new system via `in-target` to reinstall your packages and unpack the settings archive.

---

## The package selector TUI

When `--download-packages` is used without a package file, a full-screen interactive picker appears:

```
╔══════════════════════════════════════════╗
║         Offline package selector         ║
╠══════════════════════════════════════════╣
║  Select packages to embed offline.       ║
║  / to search                             ║
╠──────────────────────────────────────────╣
║  > [ ] bash                              ║
║    [x] curl                              ║
║    [ ] git                               ║
╠  v                                       ╣
║  [1/478]  spc=toggle  a=all  n=none ...  ║
╚══════════════════════════════════════════╝
```

| Key | Action |
|---|---|
| `↑` / `↓` or `j` / `k` | Move cursor |
| `PgUp` / `PgDn` | Jump a page |
| `Space` | Toggle selection |
| `a` | Select all |
| `n` | Deselect all |
| `/` | Filter by name (`Esc` to clear) |
| `Enter` | Confirm and continue |
| `q` | Abort |

The selector resizes automatically with the terminal window. Dependencies for all selected packages are resolved and included automatically — you only need to pick the top-level packages you care about.

---

## Examples

**Minimal — just package list, no offline debs, no settings:**
```bash
sudo ./build-custom-installer.sh --base-iso debian-12.10.0-amd64-netinst.iso
```

**Fully offline install with settings:**
```bash
sudo ./build-custom-installer.sh \
  --download-packages \
  --include-settings \
  --output my-workstation.iso
```

**Supply your own package list, skip the TUI picker:**
```bash
echo -e "vim\ntmux\ngit\nzsh" > my-packages.txt
sudo ./build-custom-installer.sh \
  --download-packages \
  --offline-packages-file my-packages.txt
```

**Resume a build that failed during the payload stage:**
```bash
sudo ./build-custom-installer.sh --resume
```

**Build only up through the payload stage, inspect, then finish:**
```bash
sudo ./build-custom-installer.sh --stop-after payload
# ... inspect ./build/iso-root/custom/ ...
sudo ./build-custom-installer.sh --resume
```

---

## Notes

- The script must run as root (required for `mount`, `apt-get download`, and `chown _apt`)
- The base ISO is cached in `./.cache/` and reused on subsequent runs — safe to keep around
- Package downloads run with `_apt` ownership on the pool directory to suppress sandbox warnings
- The generated ISO is a hybrid image — it can be written directly to USB with `dd` or `cp`
- Settings restore unpacks as root into `/` — review your snapshot paths before trusting this on a fresh machine

```bash
# Write to USB
sudo dd if=custom-debian-installer.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

---

## License

MIT
