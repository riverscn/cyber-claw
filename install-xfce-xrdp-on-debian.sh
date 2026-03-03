#!/usr/bin/env bash
set -euo pipefail

# =========================
# Debian + XFCE + XRDP automated setup (before installing OpenClaw)
# =========================

log() { printf "\n\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m[!] %s\033[0m\n" "$*"; }
err() { printf "\n\033[1;31m[✗] %s\033[0m\n" "$*"; exit 1; }
SESSION_DISPLAY=""
SESSION_DBUS=""

latest_xrdp_display() {
  run_as_user "$TARGET_USER" xrdp-sesadmin -c=list 2>/dev/null | awk -v u="$TARGET_USER" '
    $1=="Display:" {d=$2}
    $1=="User:" && $2==u {last=d}
    END {print last}
  '
}

find_session_context() {
  local uid p env_display env_bus bus_path
  uid="$(id -u "$TARGET_USER")"

  SESSION_DBUS=""

  # User session bus path is usually stable even when XFCE processes are not up yet.
  bus_path="/run/user/${uid}/bus"
  if [[ -S "$bus_path" ]]; then
    SESSION_DBUS="unix:path=$bus_path"
  fi

  # Prefer XRDP display when available for this target user.
  SESSION_DISPLAY="$(latest_xrdp_display)"

  # Fallback: sniff any DISPLAY from user's session-related processes.
  if [[ -z "${SESSION_DISPLAY:-}" ]]; then
    for p in $(pgrep -u "$uid" -f 'dbus-daemon|dbus-broker|xfce4-session|xfconfd|xfce4-panel|Xorg|Xwayland' 2>/dev/null || true); do
      [[ -r "/proc/$p/environ" ]] || continue
      env_display="$(tr '\0' '\n' < "/proc/$p/environ" | sed -n 's/^DISPLAY=//p' | head -n1)"
      [[ -n "${env_display:-}" ]] || continue
      SESSION_DISPLAY="$env_display"
      break
    done
  fi

  # If bus wasn't from /run/user/<uid>/bus, try extracting from process env.
  if [[ -z "${SESSION_DBUS:-}" ]]; then
    for p in $(pgrep -u "$uid" -f 'dbus-daemon|dbus-broker|xfce4-session|xfconfd|xfce4-panel' 2>/dev/null || true); do
      [[ -r "/proc/$p/environ" ]] || continue
      env_bus="$(tr '\0' '\n' < "/proc/$p/environ" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' | head -n1)"
      [[ -n "${env_bus:-}" ]] || continue
      SESSION_DBUS="$env_bus"
      break
    done
  fi

  [[ -n "${SESSION_DISPLAY:-}" ]]
}

ensure_session_context() {
  local out disp uid runtime_dir

  if [[ -n "${SESSION_DISPLAY:-}" ]]; then
    return 0
  fi

  uid="$(id -u "$TARGET_USER")"
  runtime_dir="/run/user/${uid}"

  # First, try to reuse an existing graphical session context (physical or XRDP).
  log "Detecting existing graphical session context (DISPLAY + DBUS)..."
  if find_session_context; then
    log "Found existing session context: DISPLAY=$SESSION_DISPLAY"
    return 0
  fi

  # If no session context exists, start XRDP session then detect its context.
  log "No session context found. Starting XRDP session and re-detecting context..."
  out="$(run_as_user "$TARGET_USER" xrdp-sesrun 2>&1 || true)"
  disp="$(echo "$out" | grep -Eo 'display=:[0-9]+' | head -n1 | cut -d= -f2)"
  if [[ -n "${disp:-}" ]]; then
    SESSION_DISPLAY="$disp"
  fi

  if find_session_context; then
    log "XRDP session context ready: DISPLAY=$SESSION_DISPLAY"
    return 0
  fi

  log "Waiting for XRDP session context to become ready (up to 90s)..."
  for _ in {1..90}; do
    sleep 1
    if find_session_context; then
      log "XRDP session context ready after wait: DISPLAY=$SESSION_DISPLAY"
      return 0
    fi
  done

  warn "Cannot determine graphical session context for $TARGET_USER. xrdp-sesrun output was:"
  printf '  %s\n' "$out"
  warn "Debug: uid=$uid runtime_dir=$runtime_dir"
  if [[ -d "$runtime_dir" ]]; then
    warn "Debug: runtime dir exists; bus socket present? $( [[ -S "$runtime_dir/bus" ]] && echo yes || echo no )"
  else
    warn "Debug: runtime dir is missing"
  fi
  warn "Debug: latest_xrdp_display=$(latest_xrdp_display || true)"
  if command -v loginctl >/dev/null 2>&1; then
    warn "Debug: loginctl user-status $TARGET_USER (tail)"
    loginctl user-status "$TARGET_USER" 2>/dev/null | tail -n 20 || true
  fi
  return 1
}

run_in_session_context() {
  ensure_session_context

  if [[ -n "${SESSION_DBUS:-}" ]]; then
    log "Using DISPLAY=$SESSION_DISPLAY DBUS_SESSION_BUS_ADDRESS=$SESSION_DBUS for xfconf/xfce4-panel operations"
    run_as_user "$TARGET_USER" env DISPLAY="$SESSION_DISPLAY" DBUS_SESSION_BUS_ADDRESS="$SESSION_DBUS" "$@"
  else
    warn "DBUS session bus not detected; using dbus-run-session fallback on DISPLAY=$SESSION_DISPLAY"
    if [[ "$1" == "xfce4-panel" && "${2:-}" == "-r" ]]; then
      run_as_user "$TARGET_USER" env DISPLAY="$SESSION_DISPLAY" timeout 12s dbus-run-session -- "$@" >/dev/null 2>&1 || true
    else
      run_as_user "$TARGET_USER" env DISPLAY="$SESSION_DISPLAY" dbus-run-session -- "$@" >/dev/null 2>&1
    fi
  fi
}

# Optional flags
APT_QUIET=0
if [[ $# -gt 0 ]]; then
  case "$1" in
    --quiet)
      APT_QUIET=1
      ;;
    -h|--help)
      echo "Usage: $0 [--quiet]"
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      ;;
  esac
fi

# Target user (the one whose ~/.config will be written)
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d "$TARGET_HOME" ]] || err "Cannot determine HOME directory for user: $TARGET_USER"

SUDO="sudo"
if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=""
else
  command -v sudo >/dev/null 2>&1 || err "sudo is required when not running as root"
fi

run_as_user() {
  local user="$1"
  shift
  if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "$user" -- "$@"
  else
    sudo -u "$user" "$@"
  fi
}

log "Target user: $TARGET_USER"
log "Target HOME: $TARGET_HOME"

apt_run() {
  if [[ "$APT_QUIET" == "1" ]]; then
    if [[ -n "$SUDO" ]]; then
      $SUDO env DEBIAN_FRONTEND=noninteractive \
        apt-get -q -y \
          -o Dpkg::Use-Pty=0 \
          -o Dpkg::Progress-Fancy=0 \
          "$@"
    else
      DEBIAN_FRONTEND=noninteractive \
        apt-get -q -y \
          -o Dpkg::Use-Pty=0 \
          -o Dpkg::Progress-Fancy=0 \
          "$@"
    fi
  else
    $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get "$@"
  fi
}

log "apt-get update"
apt_run update

# -------------------------
# XFCE / XRDP
# -------------------------
log "Install XFCE / XRDP / fonts"
apt_run install -y \
  xfce4 xfce4-goodies \
  xrdp xorgxrdp xclip xserver-xorg-input-libinput \
  pipewire-audio pipewire-module-xrdp \
  fonts-noto fonts-noto-cjk fonts-noto-color-emoji

$SUDO systemctl enable --now xrdp
$SUDO systemctl disable lightdm

# -------------------------
# fcitx5 + Chinese addons
# -------------------------
log "Install fcitx5 + chinese addons"
apt_run install -y --install-recommends fcitx5 fcitx5-chinese-addons

log "Configure fcitx5 profile: ensure pinyin exists (EN system; do NOT change DefaultIM / ordering)"

FCITX_DIR="$TARGET_HOME/.config/fcitx5"
PROFILE="$FCITX_DIR/profile"

run_as_user "$TARGET_USER" mkdir -p "$FCITX_DIR"
pkill -x fcitx5 2>/dev/null || true

if [[ ! -f "$PROFILE" ]]; then
  cat > /tmp/fcitx5-profile <<'EOF'
[Groups/0]
Name=Default
Default Layout=us

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=pinyin
Layout=

[GroupOrder]
0=Default
EOF
  $SUDO install -o "$TARGET_USER" -g "$TARGET_USER" -m 0644 /tmp/fcitx5-profile "$PROFILE"
  rm -f /tmp/fcitx5-profile
else
  if ! grep -q '^Name=pinyin$' "$PROFILE"; then
    max="$(grep -Eo '^\[Groups/0/Items/[0-9]+\]$' "$PROFILE" \
      | sed -E 's#.*/([0-9]+)\]#\1#' \
      | sort -n | tail -1)"
    [[ -z "${max:-}" ]] && max=0
    new=$((max + 1))

    cat >> "$PROFILE" <<EOF

[Groups/0/Items/$new]
Name=pinyin
Layout=
EOF
  fi
fi

fcitx5 -rd 2>/dev/null || true

# -------------------------
# Desktop polish
# -------------------------
log "Install Papirus icon theme / global menu / LibreOffice / Chromium"
apt_run install -y papirus-icon-theme xfce4-appmenu-plugin libreoffice libreoffice-gtk3 chromium

# Set Papirus as the default icon theme (XFCE)
log "Set default icon theme to Papirus"
run_in_session_context xfconf-query -c xsettings -p /Net/IconThemeName -s Papirus

# -------------------------
# plank-reloaded
# -------------------------
log "Install plank-reloaded"
$SUDO mkdir -p /usr/share/keyrings
curl -fsSL https://zquestz.github.io/ppa/debian/KEY.gpg \
  | $SUDO gpg --dearmor -o /usr/share/keyrings/zquestz-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/zquestz-archive-keyring.gpg] https://zquestz.github.io/ppa/debian ./" \
  | $SUDO tee /etc/apt/sources.list.d/zquestz.list >/dev/null

apt_run update
apt_run install -y plank-reloaded

AUTOSTART="$TARGET_HOME/.config/autostart"
run_as_user "$TARGET_USER" mkdir -p "$AUTOSTART"

log "Configure XFCE panel (remove panel-2, set appmenu as plugin-2, apply settings)"

# 1) delete panel-2 by keeping only panel-1
run_in_session_context xfconf-query --create -c xfce4-panel -p /panels -t int -s 1 -a

# 2) force plugin-2 to be appmenu (NOTE: your system stores type at /plugins/plugin-2)
run_in_session_context xfconf-query --create -c xfce4-panel -p /plugins/plugin-2 -t string -s appmenu

# 3) appmenu settings
run_in_session_context xfconf-query --create -c xfce4-panel -p /plugins/plugin-2/plugins/plugin-2/bold-application-name -t bool -s true
run_in_session_context xfconf-query --create -c xfce4-panel -p /plugins/plugin-2/plugins/plugin-2/compact-mode -t bool -s false
run_in_session_context xfconf-query --create -c xfce4-panel -p /plugins/plugin-2/plugins/plugin-2/expand -t bool -s false
run_in_session_context xfconf-query --create -c xfce4-panel -p /plugins/plugin-1/button-icon -t string -s xfce4_xicon2
run_in_session_context xfconf-query --create -c xfce4-panel -p /plugins/plugin-1/show-button-title -t bool -s false
run_in_session_context xfce4-panel -r || true

# 4) apply dock changes now
run_in_session_context plank >/dev/null 2>&1 &
# -------------------------
# openclaw-gateway + xrdp session binding
# -------------------------
log "Configure openclaw-gateway systemd user override"

OVR_DIR="$TARGET_HOME/.config/systemd/user/openclaw-gateway.service.d"
run_as_user "$TARGET_USER" mkdir -p "$OVR_DIR"

cat > /tmp/10-xrdp.conf <<EOF
[Service]
ExecStartPre=/usr/bin/bash -c "xrdp-sesadmin -c=list 2>/dev/null | awk -v u='$TARGET_USER' '\$1==\"Display:\" {d=\$2} \$1==\"User:\" && \$2==u {last=d} END {if (last!="") exit 0; exit 1}' || xrdp-sesrun"
EOF

$SUDO install -o "$TARGET_USER" -g "$TARGET_USER" -m 0644 \
  /tmp/10-xrdp.conf "$OVR_DIR/10-xrdp.conf"
rm -f /tmp/10-xrdp.conf

$SUDO systemctl daemon-reload

log "Configure XFCE autostart: restart openclaw-gateway after login"

cat > "$AUTOSTART/restart-openclaw-gateway.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Restart OpenClaw Gateway
Exec=/usr/bin/bash -lc "xrdp-sesadmin -c=list 2>/dev/null | awk -v u='$TARGET_USER' '\$1==\"Display:\" {d=\$2} \$1==\"User:\" && \$2==u {last=d} END {if (last!="") exit 0; exit 1}' && openclaw gateway restart || true"
X-GNOME-Autostart-enabled=true
EOF
$SUDO chown "$TARGET_USER:$TARGET_USER" "$AUTOSTART/restart-openclaw-gateway.desktop"
$SUDO chmod 0644 "$AUTOSTART/restart-openclaw-gateway.desktop"

cat > "$AUTOSTART/plank-reloaded.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Plank
Exec=plank
OnlyShowIn=XFCE;
EOF
$SUDO chown "$TARGET_USER:$TARGET_USER" "$AUTOSTART/plank-reloaded.desktop"
$SUDO chmod 0644 "$AUTOSTART/plank-reloaded.desktop"

run_as_user "$TARGET_USER" test -s "$AUTOSTART/restart-openclaw-gateway.desktop" || err "restart-openclaw-gateway.desktop is empty"
run_as_user "$TARGET_USER" test -s "$AUTOSTART/plank-reloaded.desktop" || err "plank autostart desktop file is empty at finish"

# logout step disabled
# if [[ -n "$(latest_xrdp_display)" ]]; then
#   log "Logging out current desktop session(s) for $TARGET_USER"
#
#   # Find loginctl session id that belongs to this user and XRDP display.
#   sid=""
#   for candidate in $(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$TARGET_USER" '$3==u {print $1}'); do
#     display="$(loginctl show-session "$candidate" -p Display --value 2>/dev/null || true)"
#     if [[ "$display" == "$(latest_xrdp_display)" ]]; then
#       sid="$candidate"
#       break
#     fi
#   done
#
#   if [[ -n "${sid:-}" ]]; then
#     loginctl terminate-session "$sid" || true
#   else
#     warn "No matching loginctl XRDP session found for DISPLAY=$(latest_xrdp_display); skip logout step."
#   fi
# else
#   warn "No XRDP session found for $TARGET_USER; skip logout step."
# fi

warn "Setup finished. Please connect again via your XRDP client / remote desktop tool to enter the configured XFCE session."
warn "Then install OpenClaw manually: curl -fsSL https://openclaw.ai/install.sh | bash"
