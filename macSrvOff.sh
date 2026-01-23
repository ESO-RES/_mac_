#!/bin/bash
# mac_harden_services.sh — macOS services/sharing hardening (no PF)
# - Disables common Sharing services and related advertising toggles
# - Writes a per-run CHANGELOG.txt and UNDO.sh with best-effort rollback commands
# - Supports plan (dry-run) mode
#
# NOTE: This script intentionally does NOT touch PF (/etc/pf.conf, anchors, pfctl, or PF LaunchDaemons).

set -euo pipefail

SCRIPT_NAME="mac_harden_services"
STATE_DIR="/var/db/${SCRIPT_NAME}"
LOG_DIR="/var/log/${SCRIPT_NAME}"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"

# Compatibility reporting
REPORT_FILE=""       # set per-backup unless overridden by --report
REPORT_OVERRIDE=""   # user-specified path
OS_VERSION=""
OS_MAJOR=""
OS_SUPPORTED=1
STRICT_OS=0
STOP_NOW=0
SUPPORTED_OS_MAJORS="14 15"  # Sonoma=14, Sequoia=15

DO_SHARING=1
BACKUP_ID=""
MODE="${1:-}"

# Per-backup artifacts
CHANGELOG_FILE=""
UNDO_FILE=""

# Dry-run mode (plan-only or apply --dry-run)
DRY_RUN=0
VERIFY=0

# Current run context (set during plan/apply)
CURRENT_BDIR=""
BACKUP_MARKS=""  # newline-delimited markers to avoid duplicate backups

mkdir -p "${STATE_DIR}" "${LOG_DIR}"
touch "${LOG_FILE}"
chmod 600 "${LOG_FILE}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${LOG_FILE}" >/dev/null; }
die() { log "ERROR: $*"; exit 1; }
need_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)."; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

get_console_user() {
  local u
  u="$(stat -f%Su /dev/console 2>/dev/null || true)"
  if [[ -z "${u}" || "${u}" == "root" || "${u}" == "loginwindow" ]]; then
    echo ""
  else
    echo "${u}"
  fi
}

get_console_home() {
  local u="$1"
  if [[ -z "${u}" ]]; then echo ""; return 0; fi
  dscl . -read "/Users/${u}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' | head -n 1
}

run_as_console_user() {
  local u="$1"
  shift
  [[ -n "${u}" ]] || return 0
  sudo -H -u "${u}" "$@"
}

# -----------------------------
# Change log + undo helpers
# -----------------------------
init_changelog_for_backup() {
  local bdir="$1"
  CURRENT_BDIR="${bdir}"
  BACKUP_MARKS=""
  CHANGELOG_FILE="${bdir}/CHANGELOG.txt"
  UNDO_FILE="${bdir}/UNDO.sh"
  REPORT_FILE="${REPORT_OVERRIDE:-${bdir}/compatibility_report.tsv}"
  if [[ -n "${REPORT_OVERRIDE}" ]]; then
    mkdir -p "$(dirname "${REPORT_FILE}")"
  fi
  : > "${CHANGELOG_FILE}"
  : > "${UNDO_FILE}"
  : > "${REPORT_FILE}"
  chmod 600 "${CHANGELOG_FILE}" "${UNDO_FILE}"
  chmod 600 "${REPORT_FILE}" || true
  {
    echo "#!/bin/bash"
    echo "set -euo pipefail"
    echo ""
    echo "# NOTE: This undo script is best-effort. Run selectively."
    echo ""
  } >> "${UNDO_FILE}"

  # Report header (TSV)
  printf 'timestamp\tos_version\tos_major\tos_supported\tcategory\tstatus\trc\tcommand\n' >> "${REPORT_FILE}"
}

clog() {
  if [[ -n "${CHANGELOG_FILE}" ]]; then
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${CHANGELOG_FILE}" >/dev/null
  fi
}

append_undo() {
  [[ -n "${UNDO_FILE}" ]] || return 0
  echo "$*" >> "${UNDO_FILE}"
}

mark_backed_up() {
  # Usage: mark_backed_up "<marker>"
  BACKUP_MARKS+="${1}"$'\n'
}

is_backed_up() {
  # Usage: is_backed_up "<marker>"
  [[ -n "${1}" ]] || return 1
  printf '%s' "${BACKUP_MARKS}" | grep -Fxq -- "${1}"
}

safe_mkdir() { mkdir -p "$1" 2>/dev/null || true; }

# -----------------------------
# Preference backup/restore helpers (production-grade)
# -----------------------------
backup_user_domain_once() {
  # Usage: backup_user_domain_once "<user>" "<domain>"
  local user="$1" domain="$2"
  [[ -n "${CURRENT_BDIR}" ]] || return 0
  [[ -n "${user}" && -n "${domain}" ]] || return 0

  local marker="user:${user}|domain:${domain}"
  if is_backed_up "${marker}"; then return 0; fi
  mark_backed_up "${marker}"

  local udir="${CURRENT_BDIR}/prefs/user-${user}"
  safe_mkdir "${udir}"

  if run_as_console_user "${user}" defaults read "${domain}" >/dev/null 2>&1; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      record_attempt "prefs-backup" "sudo -H -u ${user} defaults export ${domain} ${udir}/defaults_${domain}.plist" 0 "" "PLANNED"
      append_undo "sudo -H -u ${user} defaults import ${domain} \"${udir}/defaults_${domain}.plist\" >/dev/null 2>&1 || true"
      append_undo "killall cfprefsd >/dev/null 2>&1 || true"
      return 0
    fi

    set +e
    run_as_console_user "${user}" defaults export "${domain}" "${udir}/defaults_${domain}.plist" >/dev/null 2>&1
    local rc=$?
    set -e
    record_attempt "prefs-backup" "sudo -H -u ${user} defaults export ${domain} ${udir}/defaults_${domain}.plist" "${rc}" ""
    if [[ "${rc}" -eq 0 ]]; then
      append_undo "sudo -H -u ${user} defaults import ${domain} \"${udir}/defaults_${domain}.plist\" >/dev/null 2>&1 || true"
      append_undo "killall cfprefsd >/dev/null 2>&1 || true"
    fi
  else
    # Domain did not exist: undo should delete it if we end up creating keys in it.
    append_undo "sudo -H -u ${user} defaults delete ${domain} >/dev/null 2>&1 || true"
    append_undo "killall cfprefsd >/dev/null 2>&1 || true"
    record_attempt "prefs-backup" "defaults read ${domain} (user=${user})" 0 "" "SKIPPED"
  fi
}

normalize_plist_path() {
  local target="$1"
  if [[ "${target}" == /* ]]; then
    if [[ "${target}" == *.plist ]]; then
      echo "${target}"
    else
      echo "${target}.plist"
    fi
  else
    echo "${target}"
  fi
}

backup_system_target_once() {
  # Usage: backup_system_target_once "<target>"
  # target may be a domain (e.g. com.apple.foo) or a plist path (e.g. /Library/Preferences/com.apple.foo.plist)
  local target="$1"
  [[ -n "${CURRENT_BDIR}" ]] || return 0
  [[ -n "${target}" ]] || return 0

  local marker="system:${target}"
  if is_backed_up "${marker}"; then return 0; fi
  mark_backed_up "${marker}"

  local sdir="${CURRENT_BDIR}/prefs/system"
  safe_mkdir "${sdir}"

  if [[ "${target}" == /* ]]; then
    local plist; plist="$(normalize_plist_path "${target}")"
    local base; base="$(basename "${plist}")"
    if [[ -f "${plist}" ]]; then
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        record_attempt "prefs-backup" "cp -a \"${plist}\" \"${sdir}/${base}\"" 0 "" "PLANNED"
        append_undo "cp -a \"${sdir}/${base}\" \"${plist}\" >/dev/null 2>&1 || true"
        append_undo "killall cfprefsd >/dev/null 2>&1 || true"
        return 0
      fi
      set +e
      cp -a "${plist}" "${sdir}/${base}" >/dev/null 2>&1
      local rc=$?
      set -e
      record_attempt "prefs-backup" "cp -a \"${plist}\" \"${sdir}/${base}\"" "${rc}" ""
      if [[ "${rc}" -eq 0 ]]; then
        append_undo "cp -a \"${sdir}/${base}\" \"${plist}\" >/dev/null 2>&1 || true"
        append_undo "killall cfprefsd >/dev/null 2>&1 || true"
      fi
    else
      # File missing: undo will remove if created later.
      append_undo "rm -f \"${plist}\" >/dev/null 2>&1 || true"
      append_undo "killall cfprefsd >/dev/null 2>&1 || true"
      record_attempt "prefs-backup" "test -f \"${plist}\"" 0 "" "SKIPPED"
    fi
  else
    # Domain backup via defaults export
    if defaults read "${target}" >/dev/null 2>&1; then
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        record_attempt "prefs-backup" "defaults export ${target} ${sdir}/defaults_${target}.plist" 0 "" "PLANNED"
        append_undo "defaults import ${target} \"${sdir}/defaults_${target}.plist\" >/dev/null 2>&1 || true"
        append_undo "killall cfprefsd >/dev/null 2>&1 || true"
        return 0
      fi
      set +e
      defaults export "${target}" "${sdir}/defaults_${target}.plist" >/dev/null 2>&1
      local rc=$?
      set -e
      record_attempt "prefs-backup" "defaults export ${target} ${sdir}/defaults_${target}.plist" "${rc}" ""
      if [[ "${rc}" -eq 0 ]]; then
        append_undo "defaults import ${target} \"${sdir}/defaults_${target}.plist\" >/dev/null 2>&1 || true"
        append_undo "killall cfprefsd >/dev/null 2>&1 || true"
      fi
    else
      append_undo "defaults delete ${target} >/dev/null 2>&1 || true"
      append_undo "killall cfprefsd >/dev/null 2>&1 || true"
      record_attempt "prefs-backup" "defaults read ${target}" 0 "" "SKIPPED"
    fi
  fi
}

maybe_killall_track() {
  # Usage: maybe_killall_track "<proc>" "<reason>"
  local proc="$1" reason="${2:-}"
  [[ -n "${proc}" ]] || return 0
  if ! have_cmd pgrep || ! have_cmd killall; then
    record_attempt "killall-${proc}" "killall ${proc}" 0 "" "SKIPPED"
    return 0
  fi
  if ! pgrep -x "${proc}" >/dev/null 2>&1; then
    record_attempt "killall-${proc}" "killall ${proc}" 0 "" "SKIPPED"
    return 0
  fi
  run_cmd_track "killall-${proc}${reason:+ (${reason})}" "" killall "${proc}"
}

record_attempt() {
  # Usage: record_attempt "<category>" "<cmd string>" <exit_code> "<undo cmd>" ["<status_override>"]
  local category="$1" cmd="$2" rc="$3" undo="${4:-}" status_override="${5:-}"

  local status=""
  if [[ -n "${status_override}" ]]; then
    status="${status_override}"
  elif [[ "${rc}" -eq 0 ]]; then
    status="OK"
  else
    status="FAIL"
  fi

  if [[ "${status}" == "FAIL" ]]; then
    clog "${category}: FAIL rc=${rc} cmd=${cmd}"
    [[ -n "${undo}" ]] && clog "         UNDO (best-effort, if needed): ${undo}"
  else
    clog "${category}: ${status} cmd=${cmd}"
    [[ -n "${undo}" ]] && clog "         UNDO (best-effort): ${undo}"
  fi

  # Append to compatibility report (best-effort).
  if [[ -n "${REPORT_FILE}" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" \
      "${OS_VERSION}" "${OS_MAJOR}" "${OS_SUPPORTED}" \
      "${category}" "${status}" "${rc}" "${cmd}" \
      >> "${REPORT_FILE}" 2>/dev/null || true
  fi
}

get_os_version() {
  OS_VERSION="$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)"
  OS_MAJOR="${OS_VERSION%%.*}"
  [[ -n "${OS_MAJOR}" ]] || OS_MAJOR="unknown"
}

os_version_gate() {
  get_os_version
  OS_SUPPORTED=0
  for m in ${SUPPORTED_OS_MAJORS}; do
    if [[ "${OS_MAJOR}" == "${m}" ]]; then OS_SUPPORTED=1; break; fi
  done

  if [[ "${OS_SUPPORTED}" -eq 1 ]]; then
    log "INFO: Detected macOS ${OS_VERSION} (major=${OS_MAJOR}) — within supported set: ${SUPPORTED_OS_MAJORS}"
  else
    log "WARN: Detected macOS ${OS_VERSION} (major=${OS_MAJOR}) — outside supported set: ${SUPPORTED_OS_MAJORS}"
    log "WARN: Proceeding best-effort. Use --strict-os to fail closed on unsupported versions."
    if [[ "${STRICT_OS}" -eq 1 ]]; then
      die "Unsupported macOS major version: ${OS_MAJOR} (version ${OS_VERSION})."
    fi
  fi
}

print_compat_report_summary() {
  [[ -n "${REPORT_FILE}" && -f "${REPORT_FILE}" ]] || return 0

  # Summarize statuses from the report (excluding header).
  local ok fail skipped planned warn total
  ok=$(awk -F'\t' 'NR>1 && $6=="OK" {c++} END{print c+0}' "${REPORT_FILE}" 2>/dev/null || echo 0)
  fail=$(awk -F'\t' 'NR>1 && $6=="FAIL" {c++} END{print c+0}' "${REPORT_FILE}" 2>/dev/null || echo 0)
  skipped=$(awk -F'\t' 'NR>1 && $6=="SKIPPED" {c++} END{print c+0}' "${REPORT_FILE}" 2>/dev/null || echo 0)
  planned=$(awk -F'\t' 'NR>1 && $6=="PLANNED" {c++} END{print c+0}' "${REPORT_FILE}" 2>/dev/null || echo 0)
  warn=$(awk -F'\t' 'NR>1 && $6=="WARN" {c++} END{print c+0}' "${REPORT_FILE}" 2>/dev/null || echo 0)
  total=$(awk 'END{print NR-1}' "${REPORT_FILE}" 2>/dev/null || echo 0)

  log "INFO: Compatibility report: ${REPORT_FILE}"
  log "INFO: Report summary: total=${total} ok=${ok} fail=${fail} skipped=${skipped} planned=${planned} warn=${warn}"
}

run_cmd_track() {
  # Usage: run_cmd_track "<category>" "<undo_cmd_or_empty>" <command...>
  local category="$1"
  local undo_cmd="$2"
  shift 2

  local cmd_str
  cmd_str="$(printf '%q ' "$@")"
  cmd_str="${cmd_str% }"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    record_attempt "${category}" "${cmd_str}" 0 "${undo_cmd}" "PLANNED"
    [[ -n "${undo_cmd}" ]] && append_undo "${undo_cmd}"
    return 0
  fi

  set +e
  "$@"
  local rc=$?
  set -e
  record_attempt "${category}" "${cmd_str}" "${rc}" "${undo_cmd}"
  if [[ "${rc}" -eq 0 && -n "${undo_cmd}" ]]; then
    append_undo "${undo_cmd}"
  fi
  return 0
}


launchctl_get_pid() {
  # Usage: launchctl_get_pid "system/<label>"
  # Returns PID if launchd reports one; empty otherwise.
  local domain="$1"
  launchctl print "${domain}" 2>/dev/null | awk '/\bpid = [0-9]+/ {print $3; exit}'
}

launchctl_is_running() {
  local domain="$1"
  local pid
  pid="$(launchctl_get_pid "${domain}")"
  [[ -n "${pid}" ]]
}

launchctl_disable_track() {
  # Usage: launchctl_disable_track "<label>"
  # Missing labels are treated as SKIPPED.
  local label="$1"
  local domain="system/${label}"

  local cmd_str
  cmd_str="$(printf "%q " launchctl disable "${domain}")"
  cmd_str="${cmd_str% }"

  local undo1="launchctl enable ${domain} || true"
  local undo2="launchctl kickstart -k ${domain} || true"
  local undo_for_log="${undo1}; ${undo2}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    record_attempt "launchctl-disable label=${label}" "${cmd_str}" 0 "${undo_for_log}" "PLANNED"
    append_undo "${undo1}"
    append_undo "${undo2}"
    return 0
  fi

  if ! launchctl print "${domain}" >/dev/null 2>&1; then
    record_attempt "launchctl-disable label=${label}" "${cmd_str}" 0 "" "SKIPPED"
    return 0
  fi

  set +e
  launchctl disable "${domain}"
  local rc=$?
  set -e

  record_attempt "launchctl-disable label=${label}" "${cmd_str}" "${rc}" "${undo_for_log}"
  if [[ "${rc}" -eq 0 ]]; then
    append_undo "${undo1}"
    append_undo "${undo2}"

    if [[ "${STOP_NOW}" -eq 1 ]]; then
      local pid_before pid_after
      pid_before="$(launchctl_get_pid "${domain}")"

      if [[ -n "${pid_before}" ]]; then
        local stop_cmd
        stop_cmd="$(printf "%q " launchctl kill SIGTERM "${domain}")"; stop_cmd="${stop_cmd% }"
        set +e
        launchctl kill SIGTERM "${domain}"
        local stop_rc=$?
        set -e

        sleep 1
        pid_after="$(launchctl_get_pid "${domain}")"
        if [[ "${stop_rc}" -eq 0 && -z "${pid_after}" ]]; then
          record_attempt "launchctl-stop-now label=${label}" "${stop_cmd}" 0 "" "OK"
        else
          # rc=1 for reporting if still running or kill failed
          record_attempt "launchctl-stop-now label=${label}" "${stop_cmd}" 1 "" "FAIL"
        fi
      else
        record_attempt "launchctl-stop-now label=${label}" "effective-check (not running)" 0 "" "OK"
      fi
    fi
  fi
  return 0
}

defaults_write_user_track() {
  # Usage: defaults_write_user_track "<user>" "<domain>" "<key>" <args...>
  local user="$1" domain="$2" key="$3"
  shift 3

  backup_user_domain_once "${user}" "${domain}"

  local new_val
  new_val="$(printf '%q ' "$@")"; new_val="${new_val% }"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    clog "defaults-write PLANNED user=${user} domain=${domain} key=${key} new=${new_val}"
    return 0
  fi

  set +e
  run_as_console_user "${user}" defaults write "${domain}" "${key}" "$@"
  local rc=$?
  set -e

  if [[ "${rc}" -eq 0 ]]; then
    clog "defaults-write OK user=${user} domain=${domain} key=${key} new=${new_val}"
  else
    clog "defaults-write FAIL rc=${rc} user=${user} domain=${domain} key=${key} new=${new_val}"
  fi
  return 0
}

defaults_write_system_track() {
  # Usage: defaults_write_system_track "<plist_or_domain_path>" "<key>" <args...>
  local target="$1" key="$2"
  shift 2

  backup_system_target_once "${target}"

  local new_val
  new_val="$(printf '%q ' "$@")"; new_val="${new_val% }"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    clog "defaults-write PLANNED system target=${target} key=${key} new=${new_val}"
    return 0
  fi

  set +e
  defaults write "${target}" "${key}" "$@"
  local rc=$?
  set -e

  if [[ "${rc}" -eq 0 ]]; then
    clog "defaults-write OK system target=${target} key=${key} new=${new_val}"
  else
    clog "defaults-write FAIL rc=${rc} system target=${target} key=${key} new=${new_val}"
  fi
  return 0
}

parse_args() {
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-sharing) DO_SHARING=0; shift;;
      --id) BACKUP_ID="${2:-}"; shift 2;;
      --dry-run) DRY_RUN=1; shift;;
      --verify) VERIFY=1; shift;;
      --report) REPORT_OVERRIDE="${2:-}"; shift 2;;
      --strict-os) STRICT_OS=1; shift;;
      --stop-now) STOP_NOW=1; shift;;
      *) die "Unknown arg: $1";;
    esac
  done
}

ensure_dirs_perms() {
  chmod 700 "${STATE_DIR}"
  chmod 700 "${LOG_DIR}"
}

# -----------------------------
# Backup framework (for artifacts/logging)
# -----------------------------
new_backup_id() { date '+%Y%m%d%H%M%S'; }
backup_path() { echo "${STATE_DIR}/backup-$1"; }

save_backup() {
  local id="$1"
  local bdir; bdir="$(backup_path "$id")"
  mkdir -p "$bdir"

  launchctl print-disabled system 2>/dev/null > "${bdir}/launchctl_disabled_system.txt" || true

  local cu ch
  cu="$(get_console_user)"
  ch="$(get_console_home "${cu}")"
  if [[ -n "${cu}" ]]; then
    run_as_console_user "${cu}" defaults read com.apple.NetworkBrowser 2>/dev/null > "${bdir}/defaults_NetworkBrowser.${cu}.txt" || true
    if [[ -n "${ch}" ]]; then
      plutil -p "${ch}/Library/Preferences/com.apple.coreservices.useractivityd.plist" \
        > "${bdir}/useractivityd.${cu}.plist.txt" 2>/dev/null || true
    fi
  fi

  log "Backup saved: ${bdir}"
}

pick_latest_backup_id() {
  ls -1 "${STATE_DIR}" 2>/dev/null | grep -E '^backup-[0-9]{14}$' | sort | tail -n 1 | sed 's/^backup-//'
}

# -----------------------------
# Sharing/services hardening (tracked)
# -----------------------------
disable_sharing_services() {
  [[ "${DO_SHARING}" -eq 1 ]] || return 0

  local cu ch
  cu="$(get_console_user)"
  ch="$(get_console_home "${cu}")"

  # AirDrop UI disable (per-user)
  if [[ -n "${cu}" ]]; then
    defaults_write_user_track "${cu}" com.apple.NetworkBrowser DisableAirDrop -bool true
    maybe_killall_track "Finder" "apply AirDrop UI change"
  fi

  # Printer sharing / CUPS
  if have_cmd cupsctl; then
    run_cmd_track "cupsctl" "cupsctl --share-printers >/dev/null 2>&1 || true" cupsctl --no-share-printers
  fi
  launchctl_disable_track "org.cups.cupsd"

  # Remote Login (SSH)
  if have_cmd systemsetup; then
    run_cmd_track "systemsetup-ssh" "systemsetup -setremotelogin on >/dev/null 2>&1 || true" systemsetup -setremotelogin off
  fi

  # Remote Management (ARD)
  if [[ -x /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart ]]; then
    local cmd="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart -deactivate -stop"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      record_attempt "ard-kickstart" "${cmd}" 0 ""
      clog "         NOTE: Undo for ARD is environment-specific; use System Settings > Sharing or ARD kickstart docs."
    else
      set +e
      /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart -deactivate -stop >/dev/null 2>&1
      local rc=$?
      set -e
      record_attempt "ard-kickstart" "${cmd}" "${rc}" ""
      if [[ "${rc}" -eq 0 ]]; then
        clog "         NOTE: Undo for ARD is environment-specific; use System Settings > Sharing or ARD kickstart docs."
      fi
    fi
  fi

  # Screen Sharing / SMB / NetBIOS / AFP / Internet Sharing
  launchctl_disable_track "com.apple.screensharing"
  launchctl_disable_track "com.apple.smbd"
  launchctl_disable_track "com.apple.netbiosd"
  launchctl_disable_track "com.apple.AppleFileServer"
  launchctl_disable_track "com.apple.InternetSharing"

  # Bluetooth PAN/services (system-wide preferences)
  defaults_write_system_track "/Library/Preferences/com.apple.Bluetooth.plist" PrefKeyServicesEnabled -bool false
  defaults_write_system_track "/Library/Preferences/com.apple.Bluetooth.plist" PrefKeyPANServices -bool false
  maybe_killall_track "bluetoothd" "apply Bluetooth prefs"

  # AirPlay receiver (system-wide)
  defaults_write_system_track "/Library/Preferences/com.apple.airplayreceiver.plist" AirPlayReceiverEnabled -bool false

  # mDNS multicast advertisements (system-wide)
  defaults_write_system_track "/Library/Preferences/com.apple.mDNSResponder.plist" NoMulticastAdvertisements -bool true
  maybe_killall_track "mDNSResponder" "apply mDNS prefs"

  # Handoff/continuity advertising (per-user)
  if [[ -n "${cu}" && -n "${ch}" ]]; then
    defaults_write_user_track "${cu}" com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool false
    defaults_write_user_track "${cu}" com.apple.coreservices.useractivityd ActivityReceivingAllowed -bool false
  fi
}

# -----------------------------
# Verification
# -----------------------------
verify_state() {
  need_root
  ensure_dirs_perms

  local cu; cu="$(get_console_user)"
  local disabled; disabled="$(launchctl print-disabled system 2>/dev/null || true)"

  clog ""
  clog "VERIFY START"

  if [[ -n "${cu}" ]]; then
    if run_as_console_user "${cu}" defaults read com.apple.NetworkBrowser DisableAirDrop >/dev/null 2>&1; then
      local v; v="$(run_as_console_user "${cu}" defaults read com.apple.NetworkBrowser DisableAirDrop 2>/dev/null | tr -d '\n' || true)"
      if [[ "${v}" == "1" || "${v}" == "true" ]]; then
        clog "VERIFY PASS: AirDrop UI disabled for user=${cu}"
      else
        clog "VERIFY FAIL: AirDrop UI value unexpected for user=${cu} (DisableAirDrop=${v})"
      fi
    else
      clog "VERIFY WARN: Could not read AirDrop setting for user=${cu}"
    fi
  else
    clog "VERIFY WARN: No console user detected; skipped per-user checks"
  fi

  if have_cmd systemsetup; then
    local ssh; ssh="$(systemsetup -getremotelogin 2>/dev/null || true)"
    if printf '%s' "${ssh}" | grep -qi "off"; then
      clog "VERIFY PASS: Remote Login (SSH) appears OFF (${ssh})"
    else
      clog "VERIFY FAIL: Remote Login (SSH) not confirmed OFF (${ssh})"
    fi
  else
    clog "VERIFY WARN: systemsetup not available; skipped SSH check"
  fi

  if have_cmd cupsctl; then
    local cups; cups="$(cupsctl 2>/dev/null || true)"
    if printf '%s' "${cups}" | grep -Eq '(_share_printers=0|share_printers=0)'; then
      clog "VERIFY PASS: CUPS printer sharing appears disabled"
    else
      clog "VERIFY WARN: Could not confirm CUPS printer sharing disabled (cupsctl output may vary)"
    fi
  else
    clog "VERIFY WARN: cupsctl not available; skipped CUPS check"
  fi

  # launchd disables (best-effort checks; labels vary by OS)
  for label in org.cups.cupsd com.apple.screensharing com.apple.smbd com.apple.netbiosd com.apple.AppleFileServer com.apple.InternetSharing; do
    if printf '%s\n' "${disabled}" | grep -q "\"${label}\" => true"; then
      clog "VERIFY PASS: launchd disabled system/${label}"
    else
      clog "VERIFY WARN: launchd disable not confirmed for system/${label} (may be absent/renamed/protected)"
    fi
  done

  # System preferences checks
  for pair in \
    "/Library/Preferences/com.apple.Bluetooth.plist:PrefKeyServicesEnabled" \
    "/Library/Preferences/com.apple.Bluetooth.plist:PrefKeyPANServices" \
    "/Library/Preferences/com.apple.airplayreceiver.plist:AirPlayReceiverEnabled" \
    "/Library/Preferences/com.apple.mDNSResponder.plist:NoMulticastAdvertisements"
  do
    local p="${pair%%:*}"
    local k="${pair##*:}"
    if defaults read "${p}" "${k}" >/dev/null 2>&1; then
      local v; v="$(defaults read "${p}" "${k}" 2>/dev/null | tr -d '\n' || true)"
      clog "VERIFY INFO: ${p} ${k}=${v}"
    else
      clog "VERIFY WARN: Could not read ${p} ${k}"
    fi
  done

  if [[ -n "${cu}" ]]; then
    for k in ActivityAdvertisingAllowed ActivityReceivingAllowed; do
      if run_as_console_user "${cu}" defaults read com.apple.coreservices.useractivityd "${k}" >/dev/null 2>&1; then
        local v; v="$(run_as_console_user "${cu}" defaults read com.apple.coreservices.useractivityd "${k}" 2>/dev/null | tr -d '\n' || true)"
        clog "VERIFY INFO: user=${cu} com.apple.coreservices.useractivityd ${k}=${v}"
      else
        clog "VERIFY WARN: Could not read user=${cu} com.apple.coreservices.useractivityd ${k}"
      fi
    done
  fi

  clog "VERIFY END"
}

# -----------------------------
# Apply / Plan / Rollback
# -----------------------------
apply_all() {
  need_root
  ensure_dirs_perms

  os_version_gate

  local id; id="$(new_backup_id)"
  save_backup "${id}"

  local bdir; bdir="$(backup_path "$id")"
  init_changelog_for_backup "${bdir}"
  clog "MODE=apply dry_run=${DRY_RUN} backup_id=${id}"
  clog "This log records attempted changes + best-effort undo commands."
  clog ""

  echo "${id}" > "${STATE_DIR}/last_backup_id"

  log "Applying sharing/services hardening (backup id: ${id})"
  clog "Applying sharing/services hardening (backup id: ${id})"

  disable_sharing_services

  if [[ "${VERIFY}" -eq 1 && "${DRY_RUN}" -eq 0 ]]; then
    log "Verifying end state..."
    verify_state
  fi

  print_compat_report_summary

  log "Apply complete."
  log "Change log: ${bdir}/CHANGELOG.txt"
  log "Undo script: ${bdir}/UNDO.sh"
}

plan_all() {
  need_root
  ensure_dirs_perms

  os_version_gate

  DRY_RUN=1
  local id; id="$(new_backup_id)"
  local bdir; bdir="$(backup_path "$id")"
  mkdir -p "${bdir}"
  init_changelog_for_backup "${bdir}"
  clog "MODE=plan dry_run=1 backup_id=${id}"
  clog "No changes are applied in plan mode; this is a preview."
  clog ""

  log "Planning (dry run) with plan id: ${id}"
  log "Plan log: ${bdir}/CHANGELOG.txt"
  log "Undo script (preview): ${bdir}/UNDO.sh"

  disable_sharing_services

  if [[ "${VERIFY}" -eq 1 ]]; then
    log "Verification reads (no changes) ..."
    verify_state
  fi

  print_compat_report_summary

  log "Plan complete."
}

rollback_all() {
  need_root
  ensure_dirs_perms

  os_version_gate

  local id="${BACKUP_ID}"
  if [[ -z "${id}" ]]; then
    id="$(cat "${STATE_DIR}/last_backup_id" 2>/dev/null || true)"
  fi
  if [[ -z "${id}" ]]; then
    id="$(pick_latest_backup_id || true)"
  fi
  [[ -n "${id}" ]] || die "No backup id available. Provide: rollback --id <backup_id>"

  local bdir; bdir="$(backup_path "${id}")"
  [[ -d "${bdir}" ]] || die "Backup not found: ${bdir}"
  [[ -f "${bdir}/UNDO.sh" ]] || die "Undo script missing: ${bdir}/UNDO.sh"

  log "Rolling back (best-effort) using backup id: ${id}"
  chmod 700 "${bdir}/UNDO.sh" 2>/dev/null || true

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "Dry-run rollback requested; would run: ${bdir}/UNDO.sh"
    exit 0
  fi

  set +e
  /bin/bash "${bdir}/UNDO.sh"
  local rc=$?
  set -e

  if [[ "${rc}" -eq 0 ]]; then
    log "Rollback complete (UNDO.sh executed successfully)."
  else
    log "Rollback completed with warnings/errors (UNDO.sh exit code: ${rc}). Review:"
  fi
  log "  ${bdir}/CHANGELOG.txt"
  log "  ${bdir}/UNDO.sh"
}

# -----------------------------
# Main
# -----------------------------
case "${MODE}" in
  apply)
    parse_args "$@"
    apply_all
    ;;
  plan)
    parse_args "$@"
    plan_all
    ;;
  rollback)
    parse_args "$@"
    rollback_all
    ;;
  *)
    cat <<EOF
Usage:
  sudo $0 apply [options]
  sudo $0 plan [options]           # dry-run preview with CHANGELOG + UNDO script
  sudo $0 rollback [--id <id>]     # executes the per-run UNDO.sh (best-effort)

Options:
  --no-sharing             Skip sharing/service disables
  --id <backup_id>         Backup id for rollback (optional)
  --dry-run                Log/undo only; do not execute changes (apply/rollback)
  --verify                 After apply (or during plan), read back key settings and log PASS/FAIL
  --report <path>           Write compatibility report TSV to this path (default: per-backup directory)
  --strict-os               Fail closed if macOS major is not in supported set (${SUPPORTED_OS_MAJORS})
EOF
    exit 1
    ;;
esac
