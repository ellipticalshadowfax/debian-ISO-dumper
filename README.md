# debian-ISO-dumper

Build a custom Debian installer ISO from a running Debian machine.

## What this does

`build-custom-installer.sh` captures package state from the current system and remasters a Debian netinst ISO with a replay payload.

The resulting ISO still uses normal Debian Installer flows (including partitioning), but adds a custom install menu entry that runs a late-stage replay script.

## Highlights

- Interactive Debian install process is preserved.
- TUI mode is enabled by default (whiptail/dialog) for prompts and progress visibility.
- If TUI tools are unavailable or terminal capabilities are missing, the script falls back to plain terminal prompts.
- Optional settings snapshot (`--include-settings`) so config copy is not forced.
- Optional offline package payload (`--download-packages`) with terminal checklist selection.
- Preflight planning/confirmation now happens before downloads or workspace writes.
- Base ISO download is cached persistently in `./.cache` (next to the script) to avoid re-downloading after failed runs or launches from different directories.
- Resumable staged workflow with `--resume` and `--stop-after`.
- Offline package selection auto-expands dependencies for a more complete offline install set.
- Default base ISO URL now targets Debian 13.3.0 netinst.

## Quick start

```bash
sudo ./build-custom-installer.sh --output ./my-custom-debian.iso
```

## Common examples

### Include settings from this machine

```bash
sudo ./build-custom-installer.sh --include-settings --snapshot-paths /etc,/usr/local,/opt
```

### Build offline payload with TUI package selector

```bash
sudo ./build-custom-installer.sh --download-packages
```

### Non-interactive offline package list

```bash
printf 'vim\ncurl\n' > offline-list.txt
sudo ./build-custom-installer.sh --download-packages --offline-packages-file offline-list.txt
```

### Stop after a stage and resume later

```bash
# Configure + download only, then stop
sudo ./build-custom-installer.sh --download-packages --stop-after download

# Resume later from completed stages
sudo ./build-custom-installer.sh --download-packages --resume
```

### Disable TUI

```bash
sudo ./build-custom-installer.sh --no-tui
```

## Notes and limitations

- Run this on the exact Debian install you want to replicate.
- Personal files are intentionally not included.
- Without `--download-packages`, install replay pulls packages from Debian mirrors.
- Settings replay only happens if `--include-settings` is enabled (or chosen in TUI prompt).
- Hardware-specific artifacts like `machine-id`, `fstab`, and SSH host keys are excluded from settings snapshot.
- Always test the generated ISO in a VM before using it on real systems.
- ISO volume label was changed to an ISO9660/Joliet-safe value to avoid xorriso volume-id warnings.
- Joliet output is disabled to avoid noisy symlink warnings inherited from Debian ISO content.
