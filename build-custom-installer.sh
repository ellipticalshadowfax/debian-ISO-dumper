#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: sudo ./build-custom-installer.sh [options]

Build a Debian installer ISO that replays package state from the running machine
while still using regular Debian Installer flows (partitioning, users, locale,
etc.). By default, a TUI is used for status/prompts when available.

Options:
  --base-iso PATH            Existing Debian netinst ISO to remaster.
  --base-iso-url URL         URL to download netinst ISO if --base-iso omitted.
  --cache-dir DIR            Download cache directory (default: <script-dir>/.cache)
  --workdir DIR              Build workspace (default: <script-dir>/build)
  --output PATH              Output ISO path (default: <script-dir>/custom-debian-installer.iso)
  --hostname NAME            Hostname to seed in installer (default: current host)

  --include-settings         Include settings snapshot archive in payload.
  --snapshot-paths LIST      Comma-separated paths for settings snapshot
                             (default: /etc,/usr/local,/opt)

  --download-packages        Download package .debs into ISO for offline installs.
  --offline-packages-file F  File with package names (one per line) for offline payload.
                             If omitted with --download-packages, a TUI selector is shown.
  --selector-scope SCOPE     TUI package source: manual|all (default: manual)

  --resume                   Resume from completed stages in workdir.
  --stop-after STAGE         Stop after stage: plan|download|extract|payload|build

  --no-tui                   Disable TUI prompts/status and use plain stdout.
  --help                     Show this help.
USAGE
}

require_bin() {
  local bin="$1"
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing required command: $bin" >&2; exit 1; }
}

has_tui() {
  command -v whiptail >/dev/null 2>&1 || command -v dialog >/dev/null 2>&1
}

can_use_tui() {
  [[ $USE_TUI -eq 1 ]] && [[ -t 0 ]] && [[ -t 1 ]] && [[ -n "${TERM:-}" ]] && [[ "${TERM:-}" != "dumb" ]] && has_tui
}

cli_yesno() {
  local prompt="$1"
  local reply=""
  while true; do
    read -r -p "$prompt [y/N]: " reply
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no|"") return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

tui_msg() {
  local msg="$1"
  if can_use_tui; then
    if command -v whiptail >/dev/null 2>&1; then
      whiptail --title "debian-ISO-dumper" --infobox "$msg" 9 78
    else
      dialog --title "debian-ISO-dumper" --infobox "$msg" 9 78
    fi
  fi
  echo "$msg"
}

tui_yesno() {
  local prompt="$1"
  if can_use_tui; then
    if command -v whiptail >/dev/null 2>&1; then
      whiptail --title "debian-ISO-dumper" --yesno "$prompt" 12 90
    else
      dialog --title "debian-ISO-dumper" --yesno "$prompt" 12 90
    fi
  else
    cli_yesno "$prompt"
  fi
}

show_checklist() {
  local title="$1"
  local prompt="$2"
  shift 2

  if command -v whiptail >/dev/null 2>&1; then
    whiptail --title "$title" --checklist "$prompt" 22 100 14 "$@" 3>&1 1>&2 2>&3
  elif command -v dialog >/dev/null 2>&1; then
    dialog --stdout --title "$title" --checklist "$prompt" 22 100 14 "$@"
  else
    echo "Error: need whiptail or dialog for interactive package selection." >&2
    return 1
  fi
}

resolve_dependencies() {
  local -a initial=("$@")
  local -A seen=()
  local -a queue=("${initial[@]}")

  while [[ ${#queue[@]} -gt 0 ]]; do
    local pkg="${queue[0]}"
    queue=("${queue[@]:1}")
    [[ -n "$pkg" ]] || continue
    [[ -n "${seen[$pkg]:-}" ]] && continue
    seen["$pkg"]=1

    while IFS= read -r dep; do
      dep="${dep%%:*}"
      dep="${dep// /}"
      dep="${dep%%|*}"
      [[ -z "$dep" ]] && continue
      [[ "$dep" == \<*\> ]] && continue
      [[ -n "${seen[$dep]:-}" ]] && continue
      queue+=("$dep")
    done < <(apt-cache depends "$pkg" 2>/dev/null | awk '/PreDepends:|Depends:/ {print $2}')
  done

  printf '%s\n' "${!seen[@]}" | sort
}

mark_stage_done() {
  local stage="$1"
  mkdir -p "$STATE_DIR"
  : > "$STATE_DIR/${stage}.done"
}

is_stage_done() {
  local stage="$1"
  [[ -f "$STATE_DIR/${stage}.done" ]]
}

maybe_stop_after() {
  local stage="$1"
  if [[ "$STOP_AFTER" == "$stage" ]]; then
    tui_msg "Stopping after stage '$stage' as requested. Re-run with --resume to continue."
    exit 0
  fi
}

[[ ${EUID} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

BASE_ISO=""
BASE_ISO_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.10.0-amd64-netinst.iso"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$SCRIPT_DIR/build"
CACHE_DIR=""
OUTPUT_ISO="$SCRIPT_DIR/custom-debian-installer.iso"
HOSTNAME_VALUE="$(hostname -s)"
INCLUDE_SETTINGS=0
INCLUDE_SETTINGS_SET=0
SNAPSHOT_PATHS="/etc,/usr/local,/opt"
DOWNLOAD_PACKAGES=0
DOWNLOAD_PACKAGES_SET=0
OFFLINE_PACKAGES_FILE=""
SELECTOR_SCOPE="manual"
USE_TUI=1
RESUME=0
STOP_AFTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-iso) BASE_ISO="$2"; shift 2 ;;
    --base-iso-url) BASE_ISO_URL="$2"; shift 2 ;;
    --cache-dir) CACHE_DIR="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --output) OUTPUT_ISO="$2"; shift 2 ;;
    --hostname) HOSTNAME_VALUE="$2"; shift 2 ;;
    --include-settings) INCLUDE_SETTINGS=1; INCLUDE_SETTINGS_SET=1; shift ;;
    --snapshot-paths) SNAPSHOT_PATHS="$2"; shift 2 ;;
    --download-packages) DOWNLOAD_PACKAGES=1; DOWNLOAD_PACKAGES_SET=1; shift ;;
    --offline-packages-file) OFFLINE_PACKAGES_FILE="$2"; shift 2 ;;
    --selector-scope) SELECTOR_SCOPE="$2"; shift 2 ;;
    --resume) RESUME=1; shift ;;
    --stop-after) STOP_AFTER="$2"; shift 2 ;;
    --no-tui) USE_TUI=0; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[[ "$SELECTOR_SCOPE" == "manual" || "$SELECTOR_SCOPE" == "all" ]] || {
  echo "--selector-scope must be manual or all" >&2
  exit 1
}
[[ -z "$STOP_AFTER" || "$STOP_AFTER" =~ ^(plan|download|extract|payload|build)$ ]] || {
  echo "--stop-after must be one of: plan|download|extract|payload|build" >&2
  exit 1
}

for c in dpkg-query apt-get apt-cache rsync xorriso tar zstd awk sed mount umount; do require_bin "$c"; done


if [[ $USE_TUI -eq 1 ]] && ! can_use_tui; then
  echo "Notice: TUI requested but unavailable (missing whiptail/dialog, no TTY, or invalid TERM). Falling back to plain terminal prompts." >&2
fi

if [[ $INCLUDE_SETTINGS_SET -eq 0 ]] && tui_yesno "Include system settings snapshot in the ISO payload?"; then
  INCLUDE_SETTINGS=1
fi
if [[ $DOWNLOAD_PACKAGES_SET -eq 0 ]] && tui_yesno "Build offline package payload (.deb repository) in the ISO?"; then
  DOWNLOAD_PACKAGES=1
fi
[[ $DOWNLOAD_PACKAGES -eq 0 ]] || require_bin apt-ftparchive


ISO_ROOT="$WORKDIR/iso-root"
MNT_BASE="$WORKDIR/mnt-base"
CUSTOM_DIR="$ISO_ROOT/custom"
PAYLOAD_DIR="$WORKDIR/payload"
STATE_DIR="$WORKDIR/state"
CACHE_DIR="${CACHE_DIR:-$SCRIPT_DIR/.cache}"

BASE_ISO_CACHE="$CACHE_DIR/base-netinst.iso"
if [[ -z "$BASE_ISO" ]]; then
  BASE_ISO="$BASE_ISO_CACHE"
fi

cleanup() { mountpoint -q "$MNT_BASE" && umount "$MNT_BASE" || true; }
trap cleanup EXIT

# PRE-PLAN / PREVIEW (no writes/downloads yet)
PRESELECTED_OFFLINE=""
if [[ $DOWNLOAD_PACKAGES -eq 1 ]]; then
  if [[ -n "$OFFLINE_PACKAGES_FILE" ]]; then
    PRESELECTED_OFFLINE="$(awk 'NF && $1 !~ /^#/' "$OFFLINE_PACKAGES_FILE" | sort -u | tr '\n' ' ')"
  elif can_use_tui; then
    tui_msg "Collecting package candidates for offline selector..."
    mapfile -t CANDIDATES < <(if [[ "$SELECTOR_SCOPE" == "manual" ]]; then apt-mark showmanual | sort -u; else dpkg-query -W -f='${binary:Package}\n' | sort -u; fi)
    [[ ${#CANDIDATES[@]} -gt 0 ]] || { echo "No candidate packages available for selection." >&2; exit 1; }
    CHECKLIST_ITEMS=()
    for pkg in "${CANDIDATES[@]}"; do CHECKLIST_ITEMS+=("$pkg" "" "OFF"); done
    CHOICE_RAW="$(show_checklist "Offline package selector" "Select packages to embed offline. Dependencies are auto-included." "${CHECKLIST_ITEMS[@]}")" || {
      echo "No package selection made; aborting offline payload build." >&2
      exit 1
    }
    PRESELECTED_OFFLINE="$(printf '%s\n' "$CHOICE_RAW" | tr -d '"' | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')"
  fi
fi

PLAN_MSG="Ready to run with:\n\n"
PLAN_MSG+="Workdir: $WORKDIR\nCache dir: $CACHE_DIR\n"
PLAN_MSG+="Base ISO: $BASE_ISO\nBase URL: $BASE_ISO_URL\n"
PLAN_MSG+="Output ISO: $OUTPUT_ISO\nHostname seed: $HOSTNAME_VALUE\n"
PLAN_MSG+="Include settings: $INCLUDE_SETTINGS\nDownload packages: $DOWNLOAD_PACKAGES\n"
if [[ $DOWNLOAD_PACKAGES -eq 1 ]]; then
  PLAN_MSG+="Selector scope: $SELECTOR_SCOPE\n"
  [[ -n "$OFFLINE_PACKAGES_FILE" ]] && PLAN_MSG+="Offline package file: $OFFLINE_PACKAGES_FILE\n"
  [[ -n "$PRESELECTED_OFFLINE" ]] && PLAN_MSG+="Preselected packages count: $(wc -w <<<"$PRESELECTED_OFFLINE")\n"
fi
PLAN_MSG+="Resume mode: $RESUME\n"
[[ -n "$STOP_AFTER" ]] && PLAN_MSG+="Stop after: $STOP_AFTER\n"
PLAN_MSG+="\nProceed?"

if ! tui_yesno "$PLAN_MSG"; then
  echo "Aborted before making changes."
  exit 0
fi

# Writes/downloads begin here
mkdir -p "$WORKDIR" "$CACHE_DIR" "$STATE_DIR" "$MNT_BASE" "$PAYLOAD_DIR"
mark_stage_done "plan"
maybe_stop_after "plan"
if [[ $RESUME -eq 0 ]]; then
  rm -rf "$ISO_ROOT" "$PAYLOAD_DIR" "$WORKDIR/tmp-offline-selected.txt"
  mkdir -p "$PAYLOAD_DIR"
fi

# Persist preselected package choices after confirmation
if [[ -n "$PRESELECTED_OFFLINE" ]]; then
  printf '%s\n' $PRESELECTED_OFFLINE | sed '/^$/d' | sort -u > "$WORKDIR/tmp-offline-selected.txt"
fi

if ! is_stage_done download || [[ ! -f "$BASE_ISO" ]]; then
  [[ -f "$BASE_ISO" ]] || {
    tui_msg "Downloading base Debian netinst ISO to persistent cache..."
    if command -v curl >/dev/null 2>&1; then
      curl -L --fail -o "$BASE_ISO" "$BASE_ISO_URL"
    elif command -v wget >/dev/null 2>&1; then
      wget -O "$BASE_ISO" "$BASE_ISO_URL"
    else
      echo "Need curl or wget to download base ISO." >&2
      exit 1
    fi
  }
  mark_stage_done download
else
  tui_msg "Stage 'download' already complete; using cached base ISO."
fi
[[ -f "$BASE_ISO" ]] || { echo "Base ISO not found: $BASE_ISO" >&2; exit 1; }
maybe_stop_after "download"

if ! is_stage_done extract || [[ $RESUME -eq 0 ]]; then
  tui_msg "Extracting base ISO filesystem..."
  rm -rf "$ISO_ROOT"
  mkdir -p "$ISO_ROOT"
  mount -o loop,ro "$BASE_ISO" "$MNT_BASE"
  rsync -a --delete "$MNT_BASE/" "$ISO_ROOT/"
  umount "$MNT_BASE"
  mark_stage_done extract
else
  tui_msg "Stage 'extract' already complete; reusing extracted ISO tree."
fi
maybe_stop_after "extract"

if ! is_stage_done payload || [[ $RESUME -eq 0 ]]; then
  mkdir -p "$CUSTOM_DIR" "$PAYLOAD_DIR"

  tui_msg "Collecting package inventory from current system..."
  dpkg-query -W -f='${binary:Package}\t${Version}\n' | sort > "$PAYLOAD_DIR/package-versions.tsv"
  cut -f1 "$PAYLOAD_DIR/package-versions.tsv" > "$PAYLOAD_DIR/package-names.txt"
  cp "$PAYLOAD_DIR/package-versions.tsv" "$CUSTOM_DIR/"
  cp "$PAYLOAD_DIR/package-names.txt" "$CUSTOM_DIR/"

  if [[ $INCLUDE_SETTINGS -eq 1 ]]; then
    tui_msg "Creating settings snapshot archive..."
    printf '%s' "$SNAPSHOT_PATHS" | tr ',' '\n' > "$PAYLOAD_DIR/snapshot-paths.txt"
    TAR_ARGS=(--acls --xattrs --numeric-owner --zstd -cpf "$CUSTOM_DIR/system-config.tar.zst")
    while IFS= read -r path; do
      [[ -z "$path" ]] && continue
      [[ -e "$path" ]] && TAR_ARGS+=("$path") || echo "Skipping missing snapshot path: $path"
    done < "$PAYLOAD_DIR/snapshot-paths.txt"

    tar "${TAR_ARGS[@]}" \
      --exclude=/etc/machine-id \
      --exclude=/etc/fstab \
      --exclude=/etc/mtab \
      --exclude=/etc/ssh/ssh_host_* \
      --exclude=/etc/udev/rules.d/70-persistent-net.rules
  else
    tui_msg "Skipping settings snapshot."
  fi

  if [[ $DOWNLOAD_PACKAGES -eq 1 ]]; then
    tui_msg "Preparing offline package selection..."
    OFFLINE_SELECTED_FILE="$PAYLOAD_DIR/offline-selected.txt"

    if [[ -n "$OFFLINE_PACKAGES_FILE" ]]; then
      awk 'NF && $1 !~ /^#/' "$OFFLINE_PACKAGES_FILE" | sort -u > "$OFFLINE_SELECTED_FILE"
    elif [[ -f "$WORKDIR/tmp-offline-selected.txt" ]]; then
      cp "$WORKDIR/tmp-offline-selected.txt" "$OFFLINE_SELECTED_FILE"
    else
      echo "Offline package selection is required for --download-packages." >&2
      exit 1
    fi

    if [[ ! -s "$OFFLINE_SELECTED_FILE" ]]; then
      tui_msg "No offline packages selected; skipping offline payload."
    else
      tui_msg "Resolving dependencies for selected packages..."
      mapfile -t SELECTED_PKGS < "$OFFLINE_SELECTED_FILE"
      resolve_dependencies "${SELECTED_PKGS[@]}" > "$PAYLOAD_DIR/offline-expanded.txt"

      tui_msg "Downloading packages and building offline repository..."
      REPO_DIR="$CUSTOM_DIR/repo"
      mkdir -p "$REPO_DIR/pool"
      apt-get update

      while IFS= read -r pkg; do
        [[ -n "$pkg" ]] || continue
        version="$(awk -F '\t' -v p="$pkg" '$1==p {print $2; exit}' "$PAYLOAD_DIR/package-versions.tsv")"
        if [[ -n "$version" ]] && (cd "$REPO_DIR/pool" && apt-get -y download "${pkg}=${version}"); then
          continue
        fi
        if ! (cd "$REPO_DIR/pool" && apt-get -y download "$pkg"); then
          echo "Warning: could not download $pkg"
        fi
      done < "$PAYLOAD_DIR/offline-expanded.txt"

      (cd "$REPO_DIR" && apt-ftparchive packages pool > Packages && gzip -9c Packages > Packages.gz)
      cp "$PAYLOAD_DIR/offline-selected.txt" "$CUSTOM_DIR/"
      cp "$PAYLOAD_DIR/offline-expanded.txt" "$CUSTOM_DIR/"
    fi
  fi

  mark_stage_done payload
else
  tui_msg "Stage 'payload' already complete; reusing payload/custom files."
fi
maybe_stop_after "payload"

if ! is_stage_done build || [[ $RESUME -eq 0 ]]; then
  tui_msg "Injecting installer replay scripts..."
  mkdir -p "$CUSTOM_DIR"
  cat > "$CUSTOM_DIR/postinstall.sh" <<'POST'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [[ -d /root/custom/repo/pool ]]; then
  cat > /etc/apt/sources.list.d/local-custom.list <<'SRC'
deb [trusted=yes] file:/root/custom/repo ./
SRC
  apt-get update || true
fi

if [[ -f /root/custom/package-versions.tsv ]]; then
  while IFS=$'\t' read -r pkg ver; do
    apt-get -y --allow-downgrades install "${pkg}=${ver}" || apt-get -y install "$pkg" || true
  done < /root/custom/package-versions.tsv
fi

if [[ -f /root/custom/system-config.tar.zst ]]; then
  tar --zstd -xpf /root/custom/system-config.tar.zst -C /
fi

systemctl preset-all >/dev/null 2>&1 || true
POST
  chmod +x "$CUSTOM_DIR/postinstall.sh"

  cat > "$ISO_ROOT/preseed.cfg" <<PRESEED
### Installer remains interactive by default.

d-i netcfg/get_hostname string ${HOSTNAME_VALUE}
d-i preseed/late_command string \
  mkdir -p /target/root/custom; \
  cp -a /cdrom/custom/. /target/root/custom/; \
  in-target chmod +x /root/custom/postinstall.sh; \
  in-target /bin/bash /root/custom/postinstall.sh
PRESEED

  if [[ -f "$ISO_ROOT/isolinux/txt.cfg" ]] && ! grep -q "customized Debian from this ISO" "$ISO_ROOT/isolinux/txt.cfg"; then
    cat >> "$ISO_ROOT/isolinux/txt.cfg" <<'ISOLINUX'

label custom-install
  menu label ^Install customized Debian from this ISO
  menu default
  kernel /install.amd/vmlinuz
  append vga=788 initrd=/install.amd/initrd.gz preseed/file=/cdrom/preseed.cfg --- quiet
ISOLINUX
  fi

  if [[ -f "$ISO_ROOT/boot/grub/grub.cfg" ]] && ! grep -q "customized Debian from this ISO" "$ISO_ROOT/boot/grub/grub.cfg"; then
    cat >> "$ISO_ROOT/boot/grub/grub.cfg" <<'GRUB'
menuentry 'Install customized Debian from this ISO' {
    linux    /install.amd/vmlinuz preseed/file=/cdrom/preseed.cfg --- quiet
    initrd   /install.amd/initrd.gz
}
GRUB
  fi

  ISOHYBRID_MBR="/usr/lib/ISOLINUX/isohdpfx.bin"
  XORRISO_ARGS=(
    -as mkisofs -r
    -V "CUST_DEBIAN12"
    -o "$OUTPUT_ISO"
    -b isolinux/isolinux.bin -c isolinux/boot.cat
    -no-emul-boot -boot-load-size 4 -boot-info-table
    -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot
  )
  [[ -f "$ISOHYBRID_MBR" ]] && XORRISO_ARGS+=( -isohybrid-mbr "$ISOHYBRID_MBR" )

  tui_msg "Building final custom ISO image..."
  xorriso "${XORRISO_ARGS[@]}" "$ISO_ROOT"

  mark_stage_done build
else
  tui_msg "Stage 'build' already complete; output should already exist."
fi
maybe_stop_after "build"

tui_msg "Done: $OUTPUT_ISO"
echo "Done: $OUTPUT_ISO"
