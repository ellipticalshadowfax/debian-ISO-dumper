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

# ---------------------------------------------------------------------------
# Input validation helpers
# ---------------------------------------------------------------------------

# Valid Debian package name: lowercase alphanum, plus . + - ~, no leading -
validate_pkg_name() {
  local pkg="$1"
  [[ "$pkg" =~ ^[a-z0-9][a-z0-9.+\-]*$ ]] || {
    echo "Invalid package name rejected: $(printf '%q' "$pkg")" >&2
    return 1
  }
}

# Valid Debian package version: alphanum and . + - ~ :
validate_pkg_version() {
  local ver="$1"
  [[ "$ver" =~ ^[a-zA-Z0-9.+\-~:]+$ ]] || {
    echo "Invalid package version rejected: $(printf '%q' "$ver")" >&2
    return 1
  }
}

# Hostname: RFC-952/1123 — labels of [a-zA-Z0-9-], max 63 chars each, no leading/trailing -
validate_hostname() {
  local h="$1"
  # strip to single label (short hostname)
  [[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$ ]] || {
    echo "Invalid hostname: $(printf '%q' "$h") — must be alphanumeric/hyphens only, no leading or trailing hyphen" >&2
    return 1
  }
}

# Snapshot path: must be absolute, no null bytes, no newlines, no shell metacharacters,
# must not start with - (would become a tar flag)
validate_snapshot_path() {
  local p="$1"
  [[ "$p" == /* ]] || { echo "Snapshot path must be absolute: $(printf '%q' "$p")" >&2; return 1; }
  [[ "$p" =~ [[:cntrl:]] ]] && { echo "Snapshot path contains control characters: $(printf '%q' "$p")" >&2; return 1; }
  [[ "$p" =~ ['`$\\!;|&<>'] ]] && { echo "Snapshot path contains shell metacharacters: $(printf '%q' "$p")" >&2; return 1; }
}

# URL: must start with https:// or http:// only
validate_url() {
  local url="$1"
  [[ "$url" =~ ^https?:// ]] || {
    echo "Base ISO URL must start with http:// or https://: $(printf '%q' "$url")" >&2
    return 1
  }
}

# Safe filesystem path: no null bytes, no newlines
validate_path() {
  local p="$1" label="$2"
  [[ -z "$p" ]] && { echo "${label} path must not be empty" >&2; return 1; }
  [[ "$p" =~ [[:cntrl:]] ]] && { echo "${label} path contains control characters: $(printf '%q' "$p")" >&2; return 1; }
  return 0
}

# Expand ~ and return an absolute path while tolerating missing segments
normalize_path() {
  local p="$1"
  [[ -z "$p" ]] && { echo ""; return; }
  case "$p" in
    "~"|"~/*") p="${p/#~/$HOME}" ;;
  esac
  if command -v realpath >/dev/null 2>&1; then
    realpath -m -- "$p"
  else
    [[ "$p" == /* ]] && { echo "$p"; return; }
    echo "$PWD/$p"
  fi
}

has_tui() {
  command -v whiptail >/dev/null 2>&1 || command -v dialog >/dev/null 2>&1
}

can_use_tui() {
  [[ $USE_TUI -eq 1 ]] && [[ -t 0 ]] && [[ -t 1 ]] && [[ -n "${TERM:-}" ]] && [[ "${TERM:-}" != "dumb" ]] && has_tui
}

# ---------------------------------------------------------------------------
# TUI theme: monochrome base, red/orange accents
# whiptail reads NEWT_COLORS; dialog reads DIALOGRC (we write a tmpfile).
# ---------------------------------------------------------------------------
setup_tui_theme() {
  local -; set +e
  # whiptail / newt colour string
  # format: element=foreground,background
  export NEWT_COLORS='
root=white,black
border=white,black
window=white,black
shadow=black,black
title=brightred,black
button=black,red
actbutton=white,brightred
checkbox=white,black
actcheckbox=brightred,black
entry=white,black
label=white,black
listbox=white,black
actlistbox=white,red
sellistbox=white,red
actsellistbox=white,brightred
listitem=white,black
actlistitem=white,red
textbox=white,black
acttextbox=brightred,black
compactbutton=white,black
emptyscale=white,black
fullscale=red,black
helpline=black,white
roottext=white,black
'

  # dialog: write a minimal rc to a tempfile and export DIALOGRC
  local _drc
  _drc="$(mktemp /tmp/debian-iso-dumper-dialogrc.XXXXXX)"
  cat > "$_drc" <<'DIALOGRC_EOF'
# debian-ISO-dumper dialog theme — monochrome + red/orange accents
use_colors = ON
screen_color = (WHITE,BLACK,OFF)
shadow_color = (BLACK,BLACK,ON)
dialog_color = (WHITE,BLACK,OFF)
title_color = (RED,BLACK,ON)
border_color = (WHITE,BLACK,OFF)
button_active_color = (WHITE,RED,ON)
button_inactive_color = (WHITE,BLACK,OFF)
button_key_active_color = (WHITE,RED,ON)
button_key_inactive_color = (RED,BLACK,OFF)
button_label_active_color = (WHITE,RED,ON)
button_label_inactive_color = (WHITE,BLACK,OFF)
inputbox_color = (WHITE,BLACK,OFF)
inputbox_border_color = (WHITE,BLACK,OFF)
searchbox_color = (WHITE,BLACK,OFF)
searchbox_title_color = (RED,BLACK,ON)
searchbox_border_color = (WHITE,BLACK,OFF)
position_indicator_color = (RED,BLACK,ON)
menubox_color = (WHITE,BLACK,OFF)
menubox_border_color = (WHITE,BLACK,OFF)
item_color = (WHITE,BLACK,OFF)
item_selected_color = (WHITE,RED,ON)
tag_color = (RED,BLACK,OFF)
tag_selected_color = (WHITE,RED,ON)
tag_key_color = (RED,BLACK,OFF)
tag_key_selected_color = (WHITE,RED,ON)
check_color = (WHITE,BLACK,OFF)
check_selected_color = (WHITE,RED,ON)
uarrow_color = (RED,BLACK,ON)
darrow_color = (RED,BLACK,ON)
form_active_text_color = (WHITE,RED,ON)
form_text_color = (WHITE,BLACK,OFF)
form_item_readonly_color = (WHITE,BLACK,ON)
gauge_color = (WHITE,BLACK,OFF)
border2_color = (WHITE,BLACK,OFF)
inputbox_border2_color = (WHITE,BLACK,OFF)
searchbox_border2_color = (WHITE,BLACK,OFF)
menubox_border2_color = (WHITE,BLACK,OFF)
DIALOGRC_EOF
  export DIALOGRC="$_drc"
  # clean up tempfile on exit (append to any existing trap)
  trap "rm -f '$_drc'; $(trap -p EXIT | sed "s/trap -- '//;s/' EXIT//")" EXIT
}

cli_yesno() {
  local -; set +e
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

# Return terminal dimensions clamped to requested maximums.
# Usage: read -r h w < <(tui_dims MAX_H MAX_W)
tui_dims() {
  local -; set +e
  local max_h="${1:-9}" max_w="${2:-78}"
  local term_h term_w
  term_h="$(tput lines  2>/dev/null || echo 24)"
  term_w="$(tput cols   2>/dev/null || echo 80)"
  local h=$(( max_h < term_h - 2 ? max_h : term_h - 2 ))
  local w=$(( max_w < term_w - 2 ? max_w : term_w - 2 ))
  [[ $h -lt 3 ]] && h=3
  [[ $w -lt 20 ]] && w=20
  echo "$h $w"
}

tui_msg() {
  local -; set +e
  local msg="$1"
  if can_use_tui; then
    local h w; read -r h w < <(tui_dims 9 78)
    if command -v whiptail >/dev/null 2>&1; then
      whiptail --title "debian-ISO-dumper" --infobox "$msg" "$h" "$w"
    else
      dialog --title "debian-ISO-dumper" --infobox "$msg" "$h" "$w"
    fi
  fi
  echo "$msg"
}

tui_yesno() {
  local -; set +e
  local prompt="$1"
  if can_use_tui; then
    local h w; read -r h w < <(tui_dims 12 80)
    if command -v whiptail >/dev/null 2>&1; then
      whiptail --title "debian-ISO-dumper" --yesno "$prompt" "$h" "$w"
    else
      dialog --title "debian-ISO-dumper" --yesno "$prompt" "$h" "$w"
    fi
  else
    cli_yesno "$prompt"
  fi
}

# ---------------------------------------------------------------------------
# tui_configure — full-screen interactive configuration form.
# Reads/writes the global option variables directly.
# Called once after arg-parsing; only prompts for values not already set
# via CLI flags (tracked by the *_SET variables).
# ---------------------------------------------------------------------------
tui_configure() {
  local -; set +e
  # ── ANSI / layout helpers (same palette as show_checklist) ────────────────
  local ESC=$'\033' NL=$'\n'
  local RED="${ESC}[31m" BRED="${ESC}[1;31m" DIM="${ESC}[2m" RST="${ESC}[0m"

  _rep() { local ch="$1" n="$2" r=""; local j; for((j=0;j<n;j++)); do r+="$ch"; done; printf '%s' "$r"; }

  local box_h box_w inner_w need_resize=0
  _recalc() {
    local th tw
    th="$(tput lines 2>/dev/null||echo 24)"
    tw="$(tput cols  2>/dev/null||echo 80)"
    box_h=$((th-2)); [[ $box_h -lt 20 ]] && box_h=20
    box_w=$((tw-2)); [[ $box_w -lt 60 ]] && box_w=60
    inner_w=$((box_w-2))
  }

  # ── Field definitions ─────────────────────────────────────────────────────
  # Each field: name | label | type (text|bool|choice|readonly) | choices (pipe-sep) | description
  local -a F_NAME F_LABEL F_TYPE F_CHOICES F_DESC F_VAL F_LOCKED
  _deffield() {
    F_NAME+=("$1"); F_LABEL+=("$2"); F_TYPE+=("$3")
    F_CHOICES+=("$4"); F_DESC+=("$5"); F_VAL+=("$6"); F_LOCKED+=("$7")
  }

  # locked=1 means the value was supplied via CLI and cannot be changed in TUI
  _deffield output       "Output ISO"         text    "" \
    "Path for the finished ISO file." \
    "$OUTPUT_ISO"        "0"
  _deffield hostname     "Hostname seed"      text    "" \
    "Hostname baked into the installer preseed." \
    "$HOSTNAME_VALUE"    "0"
  _deffield cache_dir    "Cache directory"    text    "" \
    "Where the base ISO is cached between runs." \
    "${CACHE_DIR:-$SCRIPT_DIR/.cache}" "0"
  _deffield base_iso_url "Base ISO URL"       text    "" \
    "URL to download the netinst ISO (used when no local ISO is given)." \
    "$BASE_ISO_URL"      "0"
  _deffield base_iso     "Local base ISO"     text    "" \
    "Path to an existing netinst ISO; leave blank to download." \
    "$BASE_ISO"          "0"
  _deffield inc_settings "Include settings"   bool    "" \
    "Snapshot your config dirs and restore them on the new machine." \
    "$INCLUDE_SETTINGS"  "$INCLUDE_SETTINGS_SET"
  # Per-path checkboxes — only relevant when inc_settings=1; shown always so
  # user can pre-select before toggling include settings on.
  _deffield snap_etc     "  [snap] /etc"           snapbool "" \
    "System-wide config files. Sensitive files (ssh keys, fstab) are always excluded." \
    "1"  "0"
  _deffield snap_local   "  [snap] /usr/local"     snapbool "" \
    "Locally compiled/installed software and admin scripts." \
    "1"  "0"
  _deffield snap_opt     "  [snap] /opt"           snapbool "" \
    "Third-party application bundles (e.g. JetBrains, Chrome)." \
    "1"  "0"
  _deffield snap_home    "  [snap] /home"          snapbool "" \
    "User home directories. Can be very large — enable with care." \
    "0"  "0"
  _deffield snap_custom  "  [snap] custom path"    text     "" \
    "Extra path to include in the snapshot (leave blank to skip)." \
    ""   "0"
  _deffield dl_packages  "Offline packages"   bool    "" \
    "Download .deb files and embed a local apt repo in the ISO." \
    "$DOWNLOAD_PACKAGES" "$DOWNLOAD_PACKAGES_SET"
  _deffield resume       "Resume build"       bool    "" \
    "Skip already-completed stages from a previous run." \
    "$RESUME"            "0"

  local nfields=${#F_NAME[@]}
  local cursor=0

  # ── inline text editor ────────────────────────────────────────────────────
  _edit_field() {
    # Opens a small whiptail/dialog inputbox, or falls back to readline read.
    local idx=$1 cur_val="${F_VAL[$1]}"
    if can_use_tui; then
      local h w; read -r h w < <(tui_dims 10 70)
      local new_val
      if command -v whiptail >/dev/null 2>&1; then
        new_val="$(whiptail --title "debian-ISO-dumper" \
          --inputbox "${F_DESC[$idx]}" "$h" "$w" "$cur_val" 3>&1 1>&2 2>&3)" || return
      else
        new_val="$(dialog --stdout --title "debian-ISO-dumper" \
          --inputbox "${F_DESC[$idx]}" "$h" "$w" "$cur_val")" || return
      fi
      # Strip CR and any embedded newlines whiptail/dialog may append.
      # Then trim leading/trailing whitespace.  Use [^[:space:]] so the
      # glob correctly handles all whitespace variants.
      new_val="${new_val//$'\r'/}"
      new_val="${new_val//$'\n'/}"
      new_val="${new_val#"${new_val%%[^[:space:]]*}"}"   # ltrim
      new_val="${new_val%"${new_val##*[^[:space:]]}"}"   # rtrim
      F_VAL[$idx]="$new_val"
    else
      printf '\n%s\n[%s]: ' "${F_DESC[$idx]}" "$cur_val" > /dev/tty
      local reply; IFS= read -r reply < /dev/tty
      reply="${reply//$'\r'/}"
      [[ -n "$reply" ]] && F_VAL[$idx]="$reply"
    fi
  }

  # ── cycle choice field ────────────────────────────────────────────────────
  _cycle_choice() {
    local idx=$1
    local IFS='|'; read -ra opts <<< "${F_CHOICES[$idx]}"
    local cur="${F_VAL[$idx]}" next="" found=0
    local o
    for o in "${opts[@]}"; do
      if [[ $found -eq 1 ]]; then next="$o"; found=2; break; fi
      [[ "$o" == "$cur" ]] && found=1
    done
    [[ $found -ne 2 ]] && next="${opts[0]}"
    F_VAL[$idx]="$next"
  }

  # ── draw ──────────────────────────────────────────────────────────────────
  _draw() {
    [[ $need_resize -eq 1 ]] && { _recalc; need_resize=0; }

    local out="${ESC}[2J${ESC}[H"
    local title="debian-ISO-dumper — configuration"
    local tlen=${#title}
    local tlpad=$(( (inner_w - tlen) / 2 ))
    local trpad=$(( inner_w - tlen - tlpad ))

    out+="${BRED}╔$(_rep '═' "$inner_w")╗${RST}${NL}"
    out+="${BRED}║${RST}$(_rep ' ' "$tlpad")${BRED}${title}${RST}$(_rep ' ' "$trpad")${BRED}║${RST}${NL}"
    out+="${BRED}╠$(_rep '═' "$inner_w")╣${RST}${NL}"

    # header hint
    local hint="  arrows=move  enter/space=edit  tab=toggle  s=save & continue  q=quit"
    local hpad=$(( inner_w - ${#hint} )); [[ $hpad -lt 0 ]] && hpad=0
    out+="${BRED}║${RST}${DIM}${hint}$(_rep ' ' "$hpad")${RST}${BRED}║${RST}${NL}"
    out+="${BRED}╠$(_rep '─' "$inner_w")╣${RST}${NL}"

    local label_w=20
    local val_w=$(( inner_w - label_w - 5 ))  # 1(space) + 1(>) + 1(space) + val + 1(space) = inner_w

    local i
    for (( i=0; i<nfields; i++ )); do
      local is_cur=0; [[ $i -eq $cursor ]] && is_cur=1
      local locked="${F_LOCKED[$i]}"
      local label="${F_LABEL[$i]}"
      local val="${F_VAL[$i]}"
      local ftype="${F_TYPE[$i]}"

      # snapbool fields dim out when inc_settings is off
      local snap_active=0
      local _si; for (( _si=0; _si<nfields; _si++ )); do
        [[ "${F_NAME[$_si]}" == "inc_settings" && "${F_VAL[$_si]}" == "1" ]] && snap_active=1
      done

      # Format value display (plain version for width math, ansi version for output)
      local val_disp val_plain
      case "$ftype" in
        bool|snapbool)
          if [[ "$val" == "1" ]]; then
            val_plain="[on] "
            if [[ "$ftype" == "snapbool" && $snap_active -eq 0 ]]; then
              val_disp="${DIM}[on] ${RST}"
            else
              val_disp="${BRED}[on] ${RST}"
            fi
          else
            val_plain="[off]"
            val_disp="${DIM}[off]${RST}"
          fi
          ;;
        choice)
          val_plain="${val:-<none>}"
          val_disp="${RED}${val_plain}${RST}"
          ;;
        text)
          val_plain="${val:-(blank)}"
          local maxv=$(( val_w - 2 ))
          [[ ${#val_plain} -gt $maxv ]] && val_plain="${val_plain:0:$(( maxv - 1 ))}…"
          val_disp="${val_plain}"
          ;;
      esac

      # Arrow indicator
      local arrow="  "
      [[ $is_cur -eq 1 ]] && arrow="${BRED}> ${RST}"

      # Lock indicator
      local lock_marker="" lock_plain=""
      [[ "$locked" == "1" ]] && { lock_marker="${DIM} (cli)${RST}"; lock_plain=" (cli)"; }

      # Label, padded to label_w; dim snapbool rows when settings is off
      local label_trunc="${label:0:$label_w}"
      local lpad=$(( label_w - ${#label_trunc} ))
      local label_out="${label_trunc}"
      [[ "$ftype" == "snapbool" && $snap_active -eq 0 ]] && label_out="${DIM}${label_trunc}${RST}"

      # compute trailing pad using plain lengths
      local used=$(( 1 + 2 + label_w + 1 + ${#val_plain} + ${#lock_plain} + 1 ))
      local rpad=$(( inner_w - used )); [[ $rpad -lt 0 ]] && rpad=0

      out+="${BRED}║${RST} ${arrow}${label_out}$(_rep ' ' "$lpad") ${val_disp}${lock_marker}$(_rep ' ' "$rpad") ${BRED}║${RST}${NL}"
    done

    out+="${BRED}╠$(_rep '─' "$inner_w")╣${RST}${NL}"

    # description of current field
    local desc="${F_DESC[$cursor]}"
    local desc_trunc="${desc:0:$inner_w}"
    local dpad=$(( inner_w - ${#desc_trunc} )); [[ $dpad -lt 0 ]] && dpad=0
    out+="${BRED}║${RST} ${DIM}${desc_trunc}$(_rep ' ' "$(( dpad - 1 ))")${RST}${BRED}║${RST}${NL}"

    out+="${BRED}╚$(_rep '═' "$inner_w")╝${RST}${NL}"

    printf '%s' "$out" > /dev/tty
  }

  # ── main loop ─────────────────────────────────────────────────────────────
  trap 'need_resize=1' WINCH
  local old_stty; old_stty="$(stty -g 2>/dev/null||true)"
  tput smcup > /dev/tty 2>/dev/null||true
  tput civis > /dev/tty 2>/dev/null||true
  stty -echo -icanon min 1 time 0 2>/dev/null||true

  _recalc
  _draw

  while true; do
    local key=""
    IFS= read -r -s -n1 -t 0.15 key 2>/dev/null </dev/tty || true

    [[ $need_resize -eq 1 ]] && { _draw; continue; }

    # Escape sequence: read up to 4 more bytes with a generous timeout
    if [[ "$key" == $'\x1b' ]]; then
      local s1="" s2="" s3="" s4=""
      IFS= read -r -s -n1 -t 0.15 s1 </dev/tty || true
      IFS= read -r -s -n1 -t 0.15 s2 </dev/tty || true
      # handle longer sequences like PgUp/PgDn (\x1b[5~ = 4 bytes)
      [[ "$s2" != "~" && -n "$s2" ]] && { IFS= read -r -s -n1 -t 0.10 s3 </dev/tty || true; }
      key="${key}${s1}${s2}${s3}"
    fi

    local ftype="${F_TYPE[$cursor]}"
    local locked="${F_LOCKED[$cursor]}"

    case "$key" in
      $'\x1b[A'|k)  # up
        if [[ $cursor -gt 0 ]]; then cursor=$(( cursor - 1 )); fi
        ;;
      $'\x1b[B'|j)  # down
        if [[ $cursor -lt $(( nfields - 1 )) ]]; then cursor=$(( cursor + 1 )); fi
        ;;
      $'\t')  # tab — toggle bool or cycle choice without enter
        if [[ "$locked" != "1" ]]; then
          case "$ftype" in
            bool|snapbool) F_VAL[$cursor]=$(( 1 - ${F_VAL[$cursor]} )) ;;
            choice)        _cycle_choice "$cursor" ;;
          esac
        fi
        ;;
      $'\n'|' ')  # enter/space — edit
        if [[ "$locked" != "1" ]]; then
          case "$ftype" in
            text)
              # Leave alternate screen so whiptail draws cleanly, then return
              tput rmcup > /dev/tty 2>/dev/null || true
              stty "$old_stty" 2>/dev/null || true
              tput cnorm > /dev/tty 2>/dev/null || true
              _edit_field "$cursor"
              tput smcup > /dev/tty 2>/dev/null || true
              tput civis > /dev/tty 2>/dev/null || true
              stty -echo -icanon min 1 time 0 2>/dev/null || true
              # Drain buffered input (e.g. the Enter that closed whiptail)
              while IFS= read -r -s -n1 -t 0.05 _drain </dev/tty 2>/dev/null; do :; done
              ;;
            bool|snapbool) F_VAL[$cursor]=$(( 1 - ${F_VAL[$cursor]} )) ;;
            choice)        _cycle_choice "$cursor" ;;
          esac
        fi
        ;;
      s|S)
        # Save and continue
        break
        ;;
      q|Q)
        # Quit the whole script — user changed their mind
        trap - WINCH
        stty "$old_stty"       2>/dev/null || true
        tput cnorm > /dev/tty  2>/dev/null || true
        tput rmcup > /dev/tty  2>/dev/null || true
        echo "Aborted." >&2
        exit 0
        ;;
    esac
    _draw
  done

  trap - WINCH
  stty "$old_stty"       2>/dev/null||true
  tput cnorm > /dev/tty  2>/dev/null||true
  tput rmcup > /dev/tty  2>/dev/null||true

  # ── Write values back to globals ──────────────────────────────────────────
  # For text fields, only overwrite the global if the TUI returned a non-empty
  # value — an empty result means the user cleared the field or the TUI widget
  # swallowed the value (e.g. whiptail dropping a space-containing path), and
  # we should keep whatever was there before.
  local i
  for (( i=0; i<nfields; i++ )); do
    local _v="${F_VAL[$i]}"
    case "${F_NAME[$i]}" in
      output)       [[ -n "$_v" ]] && OUTPUT_ISO="$_v" ;;
      hostname)     [[ -n "$_v" ]] && HOSTNAME_VALUE="$_v" ;;
      cache_dir)    [[ -n "$_v" ]] && CACHE_DIR="$_v" ;;
      base_iso_url) [[ -n "$_v" ]] && BASE_ISO_URL="$_v" ;;
      base_iso)     BASE_ISO="$_v" ;;  # blank is valid (triggers download)
      inc_settings) INCLUDE_SETTINGS="$_v"; INCLUDE_SETTINGS_SET=1 ;;
      dl_packages)  DOWNLOAD_PACKAGES="$_v"; DOWNLOAD_PACKAGES_SET=1 ;;
      resume)       RESUME="$_v" ;;
    esac
  done

  # Build SNAPSHOT_PATHS from the individual snap checkboxes + optional custom
  local _sp=""
  local _idx
  for (( _idx=0; _idx<nfields; _idx++ )); do
    case "${F_NAME[$_idx]}" in
      snap_etc)    [[ "${F_VAL[$_idx]}" == "1" ]] && _sp+="/etc," ;;
      snap_local)  [[ "${F_VAL[$_idx]}" == "1" ]] && _sp+="/usr/local," ;;
      snap_opt)    [[ "${F_VAL[$_idx]}" == "1" ]] && _sp+="/opt," ;;
      snap_home)   [[ "${F_VAL[$_idx]}" == "1" ]] && _sp+="/home," ;;
      snap_custom) [[ -n "${F_VAL[$_idx]}" ]]     && _sp+="${F_VAL[$_idx]}," ;;
    esac
  done
  SNAPSHOT_PATHS="${_sp%,}"   # strip trailing comma
}

# show_checklist TITLE PROMPT item [item ...]
# Items are the package names (the "tag" fields from the old whiptail triplets).
# Prints selected package names to stdout, one per line.
# Controls: arrows / j/k = move, space = toggle, a = select all,
#           n = deselect all, / = search, enter = confirm, q/esc = abort.
show_checklist() {
  local -; set +e
  local title="$1"
  local prompt="$2"
  shift 2

  # Collect package names from whiptail-style triplets (tag desc state)
  local -a items=()
  while [[ $# -ge 3 ]]; do
    items+=("$1")   # tag
    shift 3         # skip desc + state
  done
  [[ ${#items[@]} -eq 0 ]] && { echo "No items to display." >&2; return 1; }

  local -a checked=()
  local i; for (( i=0; i<${#items[@]}; i++ )); do checked+=( 0 ); done

  # Terminal / layout
  local term_h term_w
  term_h="$(tput lines 2>/dev/null || echo 24)"
  term_w="$(tput cols  2>/dev/null || echo 80)"
  local box_h=$(( term_h - 4 ))
  local box_w=$(( term_w - 4 ))
  [[ $box_h -lt 8  ]] && box_h=8
  [[ $box_w -lt 30 ]] && box_w=30
  # inner list area: border(1) + title(1) + prompt(1) + blank(1) = 4 top
  #                  blank(1) + status(1) + border(1)             = 3 bottom
  local list_h=$(( box_h - 7 ))
  [[ $list_h -lt 3 ]] && list_h=3
  local list_w=$(( box_w - 6 ))   # border(1) + arrow(2) + check(4) + pad(1) each side

  local cursor=0 scroll=0 query="" search_mode=0
  # filtered index → real index
  local -a view=()

  _rebuild_view() {
    view=()
    local idx
    for (( idx=0; idx<${#items[@]}; idx++ )); do
      if [[ -z "$query" ]] || [[ "${items[$idx]}" == *"$query"* ]]; then
        view+=( "$idx" )
      fi
    done
    # clamp cursor
    [[ ${#view[@]} -eq 0 ]] && { cursor=0; scroll=0; return; }
    [[ $cursor -ge ${#view[@]} ]] && cursor=$(( ${#view[@]} - 1 ))
    [[ $cursor -lt 0 ]] && cursor=0
    # clamp scroll
    if [[ $cursor -lt $scroll ]]; then scroll=$cursor; fi
    if [[ $cursor -ge $(( scroll + list_h )) ]]; then scroll=$(( cursor - list_h + 1 )); fi
  }

  # ANSI helpers (write directly to /dev/tty)
  local ESC=$'\033'
  local RED="${ESC}[31m"
  local BRED="${ESC}[1;31m"
  local DIM="${ESC}[2m"
  local BOLD="${ESC}[1m"
  local RST="${ESC}[0m"
  local CLS="${ESC}[2J"
  local HOME="${ESC}[H"

  _draw() {
    _rebuild_view

    # Build frame lines into a buffer, then flush in one write
    local out=""
    out+="${CLS}${HOME}"

    local sel_count=0
    local ci; for ci in "${checked[@]}"; do (( sel_count += ci )); done

    # top border + title
    local inner_w=$(( box_w - 2 ))
    local title_pad=$(( (inner_w - ${#title}) / 2 ))
    (( title_pad < 0 )) && title_pad=0
    out+="${BRED}"
    out+="╔"; local bi; for (( bi=0; bi<inner_w; bi++ )); do out+="═"; done; out+="╗\n"
    out+="║${RST}"
    printf -v _pad '%*s' "$title_pad" ''; out+="$_pad"
    out+="${BRED}${title:0:$inner_w}${RST}"
    local right_pad=$(( inner_w - title_pad - ${#title} ))
    (( right_pad < 0 )) && right_pad=0
    printf -v _pad '%*s' "$right_pad" ''; out+="$_pad"
    out+="${BRED}║${RST}\n"
    out+="${BRED}╠"; for (( bi=0; bi<inner_w; bi++ )); do out+="═"; done; out+="╣${RST}\n"

    # prompt line
    local ptext="  ${prompt}"
    ptext="${ptext:0:$inner_w}"
    printf -v _pad '%-*s' "$inner_w" "$ptext"; out+="${BRED}║${RST}${_pad}${BRED}║${RST}\n"

    # search line
    local stext
    if [[ $search_mode -eq 1 ]]; then
      stext="  ${BRED}/${RST} ${query}_"
    else
      stext="  ${DIM}/ to search${RST}"
      [[ -n "$query" ]] && stext="  ${RED}filter: ${query}${RST}  (/ to clear)"
    fi
    # strip ansi for length calc
    local stext_plain; stext_plain="$(printf '%s' "$stext" | sed 's/\x1b\[[0-9;]*m//g')"
    local spad=$(( inner_w - ${#stext_plain} ))
    (( spad < 0 )) && spad=0
    printf -v _pad '%-*s' "$spad" ''
    out+="${BRED}║${RST}${stext}${_pad}${BRED}║${RST}\n"

    out+="${BRED}╠"; for (( bi=0; bi<inner_w; bi++ )); do out+="─"; done; out+="╣${RST}\n"

    # list rows
    local row
    for (( row=0; row<list_h; row++ )); do
      local vi=$(( scroll + row ))
      if [[ $vi -ge ${#view[@]} ]]; then
        printf -v _pad '%-*s' "$inner_w" ''
        out+="${BRED}║${RST}${_pad}${BRED}║${RST}\n"
        continue
      fi
      local real_idx="${view[$vi]}"
      local pkg="${items[$real_idx]}"
      local is_checked="${checked[$real_idx]}"
      local is_cursor=0; [[ $vi -eq $cursor ]] && is_cursor=1

      # arrow column (2 chars)
      local arrow="  "
      [[ $is_cursor -eq 1 ]] && arrow="${BRED}► ${RST}"

      # checkbox (4 chars: space [ X ] space)
      local chk
      if [[ $is_checked -eq 1 ]]; then
        chk="${RED}[${BRED}✓${RST}${RED}]${RST} "
      else
        chk="${DIM}[ ] ${RST}"
      fi

      # package name, truncated
      local max_name=$(( inner_w - 8 ))  # 2(arrow) + 4(chk) + 2(border pad)
      local name_disp="${pkg:0:$max_name}"
      printf -v _pad '%-*s' "$(( max_name - ${#name_disp} ))" ''

      out+="${BRED}║${RST} ${arrow}${chk}${name_disp}${_pad} ${BRED}║${RST}\n"
    done

    # scroll indicators
    local scroll_info=""
    [[ $scroll -gt 0 ]] && scroll_info+="${RED}▲${RST} "
    [[ $(( scroll + list_h )) -lt ${#view[@]} ]] && scroll_info+="${RED}▼${RST}"
    local si_plain; si_plain="$(printf '%s' "$scroll_info" | sed 's/\x1b\[[0-9;]*m//g')"
    printf -v _pad '%-*s' "$(( inner_w - 2 - ${#si_plain} ))" ''
    out+="${BRED}╠${RST} ${scroll_info}${_pad}${BRED}╣${RST}\n"

    # status + keys
    local status_line="  ${BRED}[${sel_count} selected / ${#view[@]} shown]${RST}  spc=toggle  a=all  n=none  enter=ok  q=abort"
    local sl_plain; sl_plain="$(printf '%s' "$status_line" | sed 's/\x1b\[[0-9;]*m//g')"
    local trunc_w=$(( inner_w ))
    [[ ${#sl_plain} -gt $trunc_w ]] && status_line="${status_line:0:$trunc_w}"
    printf -v sl_plain '%-*s' "$trunc_w" "${sl_plain:0:$trunc_w}"
    # reprint with ansi preserved but padded
    local sl_ansi="${status_line}"
    local sl_ansi_plain; sl_ansi_plain="$(printf '%s' "$sl_ansi" | sed 's/\x1b\[[0-9;]*m//g')"
    local sl_pad=$(( trunc_w - ${#sl_ansi_plain} ))
    printf -v _pad '%-*s' "$sl_pad" ''
    out+="${BRED}║${RST}${sl_ansi}${_pad}${BRED}║${RST}\n"

    # bottom border
    out+="${BRED}╚"; for (( bi=0; bi<inner_w; bi++ )); do out+="═"; done; out+="╝${RST}\n"

    printf '%s' "$out" > /dev/tty
  }

  # Save/restore terminal state
  local old_stty; old_stty="$(stty -g 2>/dev/null || true)"
  tput smcup   > /dev/tty 2>/dev/null || true
  tput civis   > /dev/tty 2>/dev/null || true
  stty -echo -icanon min 1 time 0 2>/dev/null || true

  local result=1
  _rebuild_view
  _draw

  while true; do
    local key
    IFS= read -r -s -n1 key 2>/dev/null <>/dev/tty || true

    if [[ $search_mode -eq 1 ]]; then
      case "$key" in
        $'\x1b') search_mode=0; query=""; _rebuild_view ;;
        $'\x7f'|$'\b') query="${query%?}" ;;
        '') search_mode=0 ;;  # enter closes search
        *) query+="$key" ;;
      esac
      _draw; continue
    fi

    # handle escape sequences for arrows
    if [[ "$key" == $'\x1b' ]]; then
      local seq1 seq2
      IFS= read -r -s -n1 -t 0.1 seq1 <>/dev/tty || true
      IFS= read -r -s -n1 -t 0.1 seq2 <>/dev/tty || true
      key="${key}${seq1}${seq2}"
    fi

    case "$key" in
      $'\x1b[A'|k)  # up
        (( cursor > 0 )) && (( cursor-- ))
        if [[ $cursor -lt $scroll ]]; then (( scroll-- )); fi
        ;;
      $'\x1b[B'|j)  # down
        (( cursor < ${#view[@]} - 1 )) && (( cursor++ ))
        if [[ $cursor -ge $(( scroll + list_h )) ]]; then (( scroll++ )); fi
        ;;
      $'\x1b[5~')  # page up
        cursor=$(( cursor - list_h < 0 ? 0 : cursor - list_h ))
        scroll=$(( cursor < scroll ? cursor : scroll ))
        ;;
      $'\x1b[6~')  # page down
        local last=$(( ${#view[@]} - 1 ))
        cursor=$(( cursor + list_h > last ? last : cursor + list_h ))
        if [[ $cursor -ge $(( scroll + list_h )) ]]; then scroll=$(( cursor - list_h + 1 )); fi
        ;;
      ' ')  # toggle
        if [[ ${#view[@]} -gt 0 ]]; then
          local ri="${view[$cursor]}"
          checked[$ri]=$(( 1 - checked[$ri] ))
        fi
        ;;
      a)  for (( i=0; i<${#items[@]}; i++ )); do checked[$i]=1; done ;;
      n)  for (( i=0; i<${#items[@]}; i++ )); do checked[$i]=0; done ;;
      /)  search_mode=1 ;;
      $'\n')  # enter — confirm
        result=0; break ;;
      q|Q|$'\x1b\x1b')  # quit/abort
        result=1; break ;;
    esac
    _draw
  done

  # Restore terminal
  stty "$old_stty"            2>/dev/null || true
  tput cnorm  > /dev/tty      2>/dev/null || true
  tput rmcup  > /dev/tty      2>/dev/null || true

  if [[ $result -eq 0 ]]; then
    for (( i=0; i<${#items[@]}; i++ )); do
      [[ "${checked[$i]}" -eq 1 ]] && printf '%s\n' "${items[$i]}"
    done
  fi
  return $result
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

# Apply theme now that USE_TUI is finalised
[[ $USE_TUI -eq 1 ]] && setup_tui_theme


if [[ $USE_TUI -eq 1 ]] && ! can_use_tui; then
  echo "Notice: TUI requested but unavailable (missing whiptail/dialog, no TTY, or invalid TERM). Falling back to plain terminal prompts." >&2
fi

# Interactive configuration — covers every option the script supports.
# Only runs when TUI is available; CLI-supplied flags are shown as locked.
if can_use_tui; then
  tui_configure
  # Make it obvious that leaving the form continues the flow
  tui_msg "Configuration saved. Moving to package selection (if enabled)..."
else
  # Plain-terminal fallback for the two essential yes/no questions
  if [[ $INCLUDE_SETTINGS_SET -eq 0 ]] && cli_yesno "Include system settings snapshot in the ISO payload?"; then
    INCLUDE_SETTINGS=1
  fi
  if [[ $DOWNLOAD_PACKAGES_SET -eq 0 ]] && cli_yesno "Build offline package payload (.deb repository) in the ISO?"; then
    DOWNLOAD_PACKAGES=1
  fi
fi
[[ $DOWNLOAD_PACKAGES -eq 0 ]] || require_bin apt-ftparchive


CACHE_DIR="${CACHE_DIR:-$SCRIPT_DIR/.cache}"

# Expand user-provided paths so xorriso sees real, existing parent dirs
OUTPUT_ISO="$(normalize_path "$OUTPUT_ISO")"
WORKDIR="$(normalize_path "$WORKDIR")"
CACHE_DIR="$(normalize_path "$CACHE_DIR")"
BASE_ISO_CACHE="$CACHE_DIR/base-netinst.iso"
BASE_ISO="${BASE_ISO:-$BASE_ISO_CACHE}"
BASE_ISO="$(normalize_path "$BASE_ISO")"

ISO_ROOT="$WORKDIR/iso-root"
MNT_BASE="$WORKDIR/mnt-base"
CUSTOM_DIR="$ISO_ROOT/custom"
PAYLOAD_DIR="$WORKDIR/payload"
STATE_DIR="$WORKDIR/state"

# Validate all paths and URLs now that defaults have been applied
validate_path "$OUTPUT_ISO"  "Output ISO"   || { echo "Invalid Output ISO path. Aborting." >&2; exit 1; }
validate_path "$WORKDIR"     "Work directory" || { echo "Invalid work directory path. Aborting." >&2; exit 1; }
validate_path "$CACHE_DIR"   "Cache directory" || { echo "Invalid cache directory path. Aborting." >&2; exit 1; }
validate_path "$BASE_ISO"    "Base ISO"     || { echo "Invalid base ISO path. Aborting." >&2; exit 1; }
validate_url  "$BASE_ISO_URL"               || { echo "Invalid base ISO URL. Aborting." >&2; exit 1; }

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
      tui_msg "No package selection made; disabling offline package payload."
      DOWNLOAD_PACKAGES=0
    }
    if [[ $DOWNLOAD_PACKAGES -eq 1 ]]; then
      PRESELECTED_OFFLINE="$(printf '%s\n' "$CHOICE_RAW" | sed '/^$/d' | sort -u | tr '\n' ' ')"
    fi
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
  printf '%s\n' "$PRESELECTED_OFFLINE" | tr ' ' '\n' | sed '/^$/d' | sort -u > "$WORKDIR/tmp-offline-selected.txt"
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
  # Validate and filter the package list as we write it — reject any name or
  # version that wouldn't pass apt-get's own format, so postinstall can't be
  # handed a flag-shaped package name or a version with shell metacharacters.
  dpkg-query -W -f='${binary:Package}\t${Version}\n' | sort | \
    while IFS=$'\t' read -r _pkg _ver; do
      validate_pkg_name    "$_pkg" 2>/dev/null || continue
      validate_pkg_version "$_ver" 2>/dev/null || continue
      printf '%s\t%s\n' "$_pkg" "$_ver"
    done > "$PAYLOAD_DIR/package-versions.tsv"
  cut -f1 "$PAYLOAD_DIR/package-versions.tsv" > "$PAYLOAD_DIR/package-names.txt"
  cp "$PAYLOAD_DIR/package-versions.tsv" "$CUSTOM_DIR/"
  cp "$PAYLOAD_DIR/package-names.txt" "$CUSTOM_DIR/"

  if [[ $INCLUDE_SETTINGS -eq 1 ]]; then
    tui_msg "Creating settings snapshot archive..."
    printf '%s' "$SNAPSHOT_PATHS" | tr ',' '\n' > "$PAYLOAD_DIR/snapshot-paths.txt"
    TAR_ARGS=(--acls --xattrs --numeric-owner --zstd -cpf "$CUSTOM_DIR/system-config.tar.zst"
      --exclude=/etc/machine-id
      --exclude=/etc/fstab
      --exclude=/etc/mtab
      --exclude=/etc/ssh/ssh_host_*
      --exclude=/etc/udev/rules.d/70-persistent-net.rules
      --)
    while IFS= read -r path; do
      [[ -z "$path" ]] && continue
      if ! validate_snapshot_path "$path"; then
        printf 'Skipping invalid snapshot path: %q\n' "$path" >&2
        continue
      fi
      [[ -e "$path" ]] && TAR_ARGS+=("$path") || echo "Skipping missing snapshot path: $path"
    done < "$PAYLOAD_DIR/snapshot-paths.txt"

    if [[ ${#TAR_ARGS[@]} -le 9 ]]; then
      echo "Warning: no valid snapshot paths found; skipping settings archive." >&2
    else
      tar "${TAR_ARGS[@]}"
    fi
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
      chown _apt "$REPO_DIR/pool"
      apt-get update

      while IFS= read -r pkg; do
        [[ -n "$pkg" ]] || continue
        if ! validate_pkg_name "$pkg"; then continue; fi
        version="$(awk -F '\t' -v p="$pkg" '$1==p {print $2; exit}' "$PAYLOAD_DIR/package-versions.tsv")"
        if [[ -n "$version" ]] && validate_pkg_version "$version" && \
           (cd "$REPO_DIR/pool" && apt-get -y download "${pkg}=${version}"); then
          continue
        fi
        if ! (cd "$REPO_DIR/pool" && apt-get -y download -- "$pkg"); then
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
    # Reject anything that doesn't look like a valid package name/version
    [[ "$pkg" =~ ^[a-z0-9][a-z0-9.+\-]*$ ]]  || continue
    [[ "$ver" =~ ^[a-zA-Z0-9.+\-~:]+$ ]]      || continue
    apt-get -y --allow-downgrades install -- "${pkg}=${ver}" \
      || apt-get -y install -- "$pkg" \
      || true
  done < /root/custom/package-versions.tsv
fi

if [[ -f /root/custom/system-config.tar.zst ]]; then
  tar --zstd -xpf /root/custom/system-config.tar.zst -C /
fi

systemctl preset-all >/dev/null 2>&1 || true
POST
  chmod +x "$CUSTOM_DIR/postinstall.sh"

  cat > "$ISO_ROOT/preseed.cfg" <<'PRESEED_HEADER'
### Installer remains interactive by default.
PRESEED_HEADER
  # Write hostname line safely — validate first so no preseed injection is possible
  validate_hostname "$HOSTNAME_VALUE"
  printf 'd-i netcfg/get_hostname string %s\n' "$HOSTNAME_VALUE" >> "$ISO_ROOT/preseed.cfg"
  cat >> "$ISO_ROOT/preseed.cfg" <<'PRESEED_TAIL'
d-i preseed/late_command string \
  mkdir -p /target/root/custom; \
  cp -a /cdrom/custom/. /target/root/custom/; \
  in-target chmod +x /root/custom/postinstall.sh; \
  in-target /bin/bash /root/custom/postinstall.sh
PRESEED_TAIL

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
  # Pass the output path via xorriso native -outdev BEFORE -as mkisofs.
  # The mkisofs compat layer re-tokenises its argv on whitespace, so a path
  # containing spaces is silently split when given as mkisofs -o.  Using
  # -outdev at the native layer is not affected by this.
  XORRISO_ARGS=(
    -outdev "$OUTPUT_ISO"
    -as mkisofs -r
    -V "CUST_DEBIAN12"
    -b isolinux/isolinux.bin -c isolinux/boot.cat
    -no-emul-boot -boot-load-size 4 -boot-info-table
    -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot
  )
  [[ -f "$ISOHYBRID_MBR" ]] && XORRISO_ARGS+=( -isohybrid-mbr "$ISOHYBRID_MBR" )

  tui_msg "Building final custom ISO image..."
  # Ensure the output directory exists — xorriso errors with "invalid iso output
  # directory" if the parent path does not already exist.
  OUTPUT_ISO_DIR="$(dirname "$OUTPUT_ISO")"
  mkdir -p "$OUTPUT_ISO_DIR" || { echo "Cannot create output directory: $OUTPUT_ISO_DIR" >&2; exit 1; }
  xorriso "${XORRISO_ARGS[@]}" -- "$ISO_ROOT"

  mark_stage_done build
else
  tui_msg "Stage 'build' already complete; output should already exist."
fi
maybe_stop_after "build"

tui_msg "Done: $OUTPUT_ISO"
echo "Done: $OUTPUT_ISO"
