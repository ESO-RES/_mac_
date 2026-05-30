#!/bin/bash
set -euo pipefail

# =========================
# Constants
# =========================
ANCHOR_NAME="com.local.harden_pf"
ANCHOR_PATH="/etc/pf.anchors/${ANCHOR_NAME}"
PF_CONF="/etc/pf.conf"
MANAGED_BEGIN="# BEGIN managed by mac-harden-pf"
MANAGED_END="# END managed by mac-harden-pf"
DAEMON_PLIST="/Library/LaunchDaemons/${ANCHOR_NAME}.plist"

MODE="install"
EXT_IF=""
LOGIN_USER=""

# =========================
# Argument parsing
# =========================
while [[ $# -gt 0 ]]; do
  case "$1" in
    install|uninstall)
      MODE="$1"
      shift
      ;;
    --ext-if)
      EXT_IF="$2"
      shift 2
      ;;
    --login-user)
      LOGIN_USER="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# =========================
# Privilege check
# =========================
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Must be run as root" >&2
  exit 1
fi

# =========================
# Helpers
# =========================
backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -p "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

remove_managed_block() {
  if grep -q "$MANAGED_BEGIN" "$PF_CONF"; then
    awk "
      \$0==\"$MANAGED_BEGIN\" {skip=1}
      \$0==\"$MANAGED_END\" {skip=0; next}
      !skip
    " "$PF_CONF" > "${PF_CONF}.tmp"
    mv "${PF_CONF}.tmp" "$PF_CONF"
  fi
}

insert_managed_block() {
  awk '
    BEGIN {
      block[1] = "'"$MANAGED_BEGIN"'"
      block[2] = "anchor \"'"$ANCHOR_NAME"'\""
      block[3] = "load anchor \"'"$ANCHOR_NAME"'\" from \"'"$ANCHOR_PATH"'\""
      block[4] = "'"$MANAGED_END"'"
    }

    /^[[:space:]]*(block|pass)/ && !done {
      for (i = 1; i <= 4; i++) print block[i]
      done = 1
    }

    { print }

    END {
      if (!done)
        for (i = 1; i <= 4; i++) print block[i]
    }
  ' "$PF_CONF" > "${PF_CONF}.tmp"

  mv "${PF_CONF}.tmp" "$PF_CONF"
}

# =========================
# Uninstall
# =========================
if [[ "$MODE" == "uninstall" ]]; then
  echo "Uninstalling PF hardening…"

  if [[ -f "$DAEMON_PLIST" ]]; then
    launchctl bootout system "$DAEMON_PLIST" 2>/dev/null || true
    rm -f "$DAEMON_PLIST"
  fi

  backup_file "$PF_CONF"
  remove_managed_block

  rm -f "$ANCHOR_PATH"

  /sbin/pfctl -nf "$PF_CONF"
  /sbin/pfctl -f "$PF_CONF" || true

  echo "Uninstall complete."
  exit 0
fi

# =========================
# Install
# =========================
echo "Installing PF hardening…"

# ---- Write anchor ----
cat > "${ANCHOR_PATH}.tmp" <<'EOF'
# macOS hardened baseline PF anchor
# ================================================================
#
# This anchor is managed by the mac-harden-pf installer.
#
# EXT_IF and LOGIN_USER are accepted as command-line options:
#   --ext-if      : external interface (e.g. en0, en1, utun*)
#   --login-user  : username of the logged-in console user
#
# They are currently optional for the basic “default-deny inbound,
# stateful outbound” policy, but you can easily extend the rules
# below to make them active:
#
#   • Scope rules to the external interface:
#       pass in  on $EXT_IF ...
#       pass out on $EXT_IF ...
#
#   • Restrict certain rules to the logged-in user only:
#       user "${LOGIN_USER}" ...
#       (useful for per-user VPN, file sharing, etc.)
#
#   • Example usage when calling the script:
#       sudo ./harden-pf.sh install --ext-if en0 --login-user user1
#
# ================================================================

set block-policy drop
set skip on lo0

scrub in all fragment reassemble

# Default deny inbound
block in all

# Allow DHCP
pass out quick proto udp from any to any port 67:68 keep state
pass in  quick proto udp from any to any port 67:68 keep state
pass out quick proto udp from any to any port 546:547 keep state
pass in  quick proto udp from any to any port 546:547 keep state

# Allow ICMP (v4)
pass inet proto icmp all keep state

# Allow ICMPv6 (ND / RA / PMTU)
pass inet6 proto icmp6 icmp6-type 1 keep state
pass inet6 proto icmp6 icmp6-type 2 keep state
pass inet6 proto icmp6 icmp6-type 3 keep state
pass inet6 proto icmp6 icmp6-type 4 keep state
pass inet6 proto icmp6 icmp6-type 133 keep state
pass inet6 proto icmp6 icmp6-type 134 keep state
pass inet6 proto icmp6 icmp6-type 135 keep state
pass inet6 proto icmp6 icmp6-type 136 keep state

# Optional QUIC block (UDP 443)
block out quick proto udp to any port 443

# Allow all outbound with state
pass out proto { tcp udp } from any to any keep state
EOF

install -o root -g wheel -m 600 "${ANCHOR_PATH}.tmp" "$ANCHOR_PATH"
rm -f "${ANCHOR_PATH}.tmp"

# ---- Validate anchor directly ----
/sbin/pfctl -n -f "$ANCHOR_PATH"

# ---- Update pf.conf ----
backup_file "$PF_CONF"
remove_managed_block
insert_managed_block

# ---- Validate full ruleset ----
/sbin/pfctl -nf "$PF_CONF"

# ---- Load PF ----
/sbin/pfctl -f "$PF_CONF"
/sbin/pfctl -E 2>/dev/null || true

# ---- Install LaunchDaemon ----
cat > "$DAEMON_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$ANCHOR_NAME</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>/sbin/pfctl -f $PF_CONF &amp;&amp; /sbin/pfctl -E 2&gt;/dev/null || true</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
EOF

chmod 644 "$DAEMON_PLIST"
chown root:wheel "$DAEMON_PLIST"
launchctl bootstrap system "$DAEMON_PLIST" || true

echo "Install complete."
