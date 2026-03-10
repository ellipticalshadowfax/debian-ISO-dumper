#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: sudo ./build-custom-installer.sh [options]

Build a Debian installer ISO that replays package state from the running machine
while still using regular Debian Installer flows (partitioning, users, locale,
etc.). You can optionally include settings snapshot data and optional offline
package payloads.

Options:
  --base-iso PATH            Existing Debian netinst ISO to remaster.
  --base-iso-url URL         URL to download netinst ISO if --base-iso omitted.
  --workdir DIR              Build workspace (default: ./build)
  --output PATH              Output ISO path (default: ./custom-debian-installer.iso)
  --hostname NAME            Hostname to seed in installer (default: current host)

  --include-settings         Include settings snapshot archive in payload (off by default).
  --snapshot-paths LIST      Comma-separated paths to archive when settings are enabled
                             (default: /etc,/usr/local,/opt)

  --download-packages        Download package .debs into ISO for offline installs.
  --offline-packages-file F  File with package names (one per line) for offline payload.
                             If omitted with --download-packages, a TUI selector is shown.
  --selector-scope SCOPE     Package list source for TUI: manual|all (default: manual)

  --help                     Show this help.

Examples:
  sudo ./build-custom-installer.sh --output ./my.iso
  sudo ./build-custom-installer.sh --include-settings --download-packages
USAGE
}

require_bin() {
  local bin="$1"
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing required command: $bin" >&2; exit 1; }
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

[[ ${EUID} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

BASE_ISO=""
BASE_ISO_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12-netinst.iso"
WORKDIR="$(pwd)/build"
OUTPUT_ISO="$(pwd)/custom-debian-installer.iso"
HOSTNAME_VALUE="$(hostname -s)"
INCLUDE_SETTINGS=0
SNAPSHOT_PATHS="/etc,/usr/local,/opt"
DOWNLOAD_PACKAGES=0
OFFLINE_PACKAGES_FILE=""
SELECTOR_SCOPE="manual"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-iso) BASE_ISO="$2"; shift 2 ;;
    --base-iso-url) BASE_ISO_URL="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --output) OUTPUT_ISO="$2"; shift 2 ;;
    --hostname) HOSTNAME_VALUE="$2"; shift 2 ;;
    --include-settings) INCLUDE_SETTINGS=1; shift ;;
    --snapshot-paths) SNAPSHOT_PATHS="$2"; shift 2 ;;
    --download-packages) DOWNLOAD_PACKAGES=1; shift ;;
    --offline-packages-file) OFFLINE_PACKAGES_FILE="$2"; shift 2 ;;
    --selector-scope) SELECTOR_SCOPE="$2"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[[ "$SELECTOR_SCOPE" == "manual" || "$SELECTOR_SCOPE" == "all" ]] || {
  echo "--selector-scope must be manual or all" >&2
  exit 1
}

for c in dpkg-query apt-get apt-cache rsync xorriso tar zstd awk sed mount umount; do require_bin "$c"; done
[[ $DOWNLOAD_PACKAGES -eq 0 ]] || require_bin apt-ftparchive

mkdir -p "$WORKDIR"
if [[ -z "$BASE_ISO" ]]; then
  BASE_ISO="$WORKDIR/base-netinst.iso"
  echo "Downloading base installer ISO from: $BASE_ISO_URL"
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail -o "$BASE_ISO" "$BASE_ISO_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$BASE_ISO" "$BASE_ISO_URL"
  else
    echo "Need curl or wget to download base ISO." >&2
    exit 1
  fi
fi
[[ -f "$BASE_ISO" ]] || { echo "Base ISO not found: $BASE_ISO" >&2; exit 1; }

ISO_ROOT="$WORKDIR/iso-root"
MNT_BASE="$WORKDIR/mnt-base"
CUSTOM_DIR="$ISO_ROOT/custom"
PAYLOAD_DIR="$WORKDIR/payload"
REPO_DIR="$CUSTOM_DIR/repo"

rm -rf "$ISO_ROOT" "$MNT_BASE" "$PAYLOAD_DIR"
mkdir -p "$ISO_ROOT" "$MNT_BASE" "$CUSTOM_DIR" "$PAYLOAD_DIR"

cleanup() { mountpoint -q "$MNT_BASE" && umount "$MNT_BASE" || true; }
trap cleanup EXIT

echo "Collecting package inventory..."
dpkg-query -W -f='${binary:Package}\t${Version}\n' | sort > "$PAYLOAD_DIR/package-versions.tsv"
cut -f1 "$PAYLOAD_DIR/package-versions.tsv" > "$PAYLOAD_DIR/package-names.txt"
cp "$PAYLOAD_DIR/package-versions.tsv" "$CUSTOM_DIR/"
cp "$PAYLOAD_DIR/package-names.txt" "$CUSTOM_DIR/"

if [[ $INCLUDE_SETTINGS -eq 1 ]]; then
  echo "Creating settings snapshot..."
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
  echo "Skipping settings snapshot (enable with --include-settings)."
fi

echo "Copying base ISO filesystem..."
mount -o loop,ro "$BASE_ISO" "$MNT_BASE"
rsync -a --delete "$MNT_BASE/" "$ISO_ROOT/"
umount "$MNT_BASE"

if [[ $DOWNLOAD_PACKAGES -eq 1 ]]; then
  echo "Preparing offline package selection..."

  OFFLINE_SELECTED_FILE="$PAYLOAD_DIR/offline-selected.txt"
  if [[ -n "$OFFLINE_PACKAGES_FILE" ]]; then
    awk 'NF && $1 !~ /^#/' "$OFFLINE_PACKAGES_FILE" | sort -u > "$OFFLINE_SELECTED_FILE"
  else
    CANDIDATE_FILE="$PAYLOAD_DIR/candidates.txt"
    if [[ "$SELECTOR_SCOPE" == "manual" ]]; then
      apt-mark showmanual | sort -u > "$CANDIDATE_FILE"
    else
      cp "$PAYLOAD_DIR/package-names.txt" "$CANDIDATE_FILE"
    fi

    mapfile -t CANDIDATES < "$CANDIDATE_FILE"
    if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
      echo "No candidate packages available for selection." >&2
      exit 1
    fi

    CHECKLIST_ITEMS=()
    for pkg in "${CANDIDATES[@]}"; do
      CHECKLIST_ITEMS+=("$pkg" "" "OFF")
    done

    CHOICE_RAW="$(show_checklist \
      "Offline package selector" \
      "Select packages to embed offline. Dependencies are auto-included." \
      "${CHECKLIST_ITEMS[@]}")" || {
      echo "No package selection made; aborting offline payload build." >&2
      exit 1
    }

    printf '%s\n' "$CHOICE_RAW" | tr ' ' '\n' | tr -d '"' | sed '/^$/d' | sort -u > "$OFFLINE_SELECTED_FILE"
  fi

  if [[ ! -s "$OFFLINE_SELECTED_FILE" ]]; then
    echo "No offline packages selected; skipping package download payload."
  else
    echo "Resolving dependencies for selected packages..."
    mapfile -t SELECTED_PKGS < "$OFFLINE_SELECTED_FILE"
    resolve_dependencies "${SELECTED_PKGS[@]}" > "$PAYLOAD_DIR/offline-expanded.txt"

    echo "Building offline repository (this can take a while)..."
    mkdir -p "$REPO_DIR/pool"
    apt-get update

    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue
      version="$(awk -F '\t' -v p="$pkg" '$1==p {print $2; exit}' "$PAYLOAD_DIR/package-versions.tsv")"
      if [[ -n "$version" ]]; then
        if apt-get -y download "${pkg}=${version}"; then
          mv ./*.deb "$REPO_DIR/pool/" 2>/dev/null || true
          continue
        fi
      fi

      if apt-get -y download "$pkg"; then
        mv ./*.deb "$REPO_DIR/pool/" 2>/dev/null || true
      else
        echo "Warning: could not download $pkg"
      fi
    done < "$PAYLOAD_DIR/offline-expanded.txt"

    (cd "$REPO_DIR" && apt-ftparchive packages pool > Packages && gzip -9c Packages > Packages.gz)
    cp "$PAYLOAD_DIR/offline-selected.txt" "$CUSTOM_DIR/"
    cp "$PAYLOAD_DIR/offline-expanded.txt" "$CUSTOM_DIR/"
  fi
fi

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

if [[ -f "$ISO_ROOT/isolinux/txt.cfg" ]]; then
  cat >> "$ISO_ROOT/isolinux/txt.cfg" <<'ISOLINUX'

label custom-install
  menu label ^Install customized Debian from this ISO
  menu default
  kernel /install.amd/vmlinuz
  append vga=788 initrd=/install.amd/initrd.gz preseed/file=/cdrom/preseed.cfg --- quiet
ISOLINUX
fi

if [[ -f "$ISO_ROOT/boot/grub/grub.cfg" ]]; then
  cat >> "$ISO_ROOT/boot/grub/grub.cfg" <<'GRUB'
menuentry 'Install customized Debian from this ISO' {
    linux    /install.amd/vmlinuz preseed/file=/cdrom/preseed.cfg --- quiet
    initrd   /install.amd/initrd.gz
}
GRUB
fi

ISOHYBRID_MBR="/usr/lib/ISOLINUX/isohdpfx.bin"
XORRISO_ARGS=(
  -as mkisofs -r -J -joliet-long
  -V "Custom Debian Installer"
  -o "$OUTPUT_ISO"
  -b isolinux/isolinux.bin -c isolinux/boot.cat
  -no-emul-boot -boot-load-size 4 -boot-info-table
  -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot
)
[[ -f "$ISOHYBRID_MBR" ]] && XORRISO_ARGS+=( -isohybrid-mbr "$ISOHYBRID_MBR" )

xorriso "${XORRISO_ARGS[@]}" "$ISO_ROOT"

echo "Done: $OUTPUT_ISO"
