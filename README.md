# debian-ISO-dumper

Build a custom Debian installer ISO from a running Debian machine.

## What this does

`build-custom-installer.sh` captures package state from the current system and remasters a Debian netinst ISO with a replay payload.

The resulting ISO still uses normal Debian Installer flows (including partitioning), but adds a **custom install menu entry** that runs a late-stage replay script.

## Highlights

- Interactive Debian install process is preserved.
- Optional settings snapshot (`--include-settings`) so config copy is not forced.
- Optional offline package payload (`--download-packages`) with a terminal checklist selector (whiptail/dialog style).
- Offline selection can auto-expand dependencies for a complete offline install set.

## Quick start

```bash
sudo ./build-custom-installer.sh --output ./my-custom-debian.iso
```

### Include settings from this machine

```bash
sudo ./build-custom-installer.sh --include-settings --snapshot-paths /etc,/usr/local,/opt
```

### Build offline payload with TUI package selector

```bash
sudo ./build-custom-installer.sh --download-packages
```

### Non-interactive offline selection

```bash
printf 'vim\ncurl\n' > offline-list.txt
sudo ./build-custom-installer.sh --download-packages --offline-packages-file offline-list.txt
```

## Notes and limitations

- Run this on the exact Debian install you want to replicate.
- Personal files are intentionally not included.
- Without `--download-packages`, install replay pulls packages from Debian mirrors.
- Settings replay only happens if `--include-settings` is used.
- Hardware-specific artifacts like `machine-id`, `fstab`, and SSH host keys are excluded from settings snapshot.
- Always test the generated ISO in a VM before using it on real systems.
