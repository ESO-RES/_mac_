#!/bin/zsh
# ipRange.zsh — fast ping sweep for macOS (BSD ping) using zsh + xargs -P

set -u

usage() {
  cat <<'EOF'
Usage:
  ipRange.zsh <base> <start-end>
  ipRange.zsh <base> <start> <end>
  ipRange.zsh <ip>

Examples:
  ipRange.zsh 192.168.1 1-254
  ipRange.zsh 10.0.0 1 50
  ipRange.zsh 192.168.1.10

Options (env vars):
  IP_RANGE_PARALLEL   Parallel pings (default: 64)
  IP_RANGE_VERBOSE    1 to print up/down per host (default: 0)
  IP_RANGE_LIMIT      Max targets allowed (default: 4096). Set 0 to disable.
  IP_RANGE_SORT       1 to sort output (default: 1)
EOF
}

die() { print -r -- "Error: $*" >&2; exit 2; }
is_int() { [[ "${1:-}" == <-> ]]; }

# ---- Dependency check (NEW) ----
for cmd in ping xargs awk sed sort; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
done

# Defaults
PARALLEL="${IP_RANGE_PARALLEL:-64}"
VERBOSE="${IP_RANGE_VERBOSE:-0}"
LIMIT="${IP_RANGE_LIMIT:-4096}"
DO_SORT="${IP_RANGE_SORT:-1}"

is_int "$PARALLEL" || die "IP_RANGE_PARALLEL must be an integer"
is_int "$VERBOSE"  || die "IP_RANGE_VERBOSE must be 0 or 1"
is_int "$LIMIT"    || die "IP_RANGE_LIMIT must be an integer"
is_int "$DO_SORT"  || die "IP_RANGE_SORT must be 0 or 1"

# Help
if (( $# >= 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

ping_one() {
  ping -n -c 1 -o "$1" >/dev/null 2>&1
}

gen_targets() {
  local i
  for (( i=start; i<=end; i++ )); do
    print -r -- "${base}.${i}"
  done
}

ip_sort() {
  if (( DO_SORT == 1 )); then
    sort -n -t . -k 1,1 -k 2,2 -k 3,3 -k 4,4
  else
    cat
  fi
}

# ---- Argument parsing ----
if (( $# == 1 )); then
  ip="$1"
  [[ "$ip" == <->.<->.<->.<-> ]] || die "Invalid IP: $ip"
  ping_one "$ip" && { print -r -- "$ip"; exit 0; } || exit 1
fi

if (( $# != 2 && $# != 3 )); then
  usage >&2
  exit 2
fi

base="$1"
[[ "$base" == <->.<->.<-> ]] || die "Base must be like 192.168.1"

if (( $# == 2 )); then
  [[ "$2" == *-* ]] || die "Range must be start-end"
  start="${2%-*}"
  end="${2#*-}"
else
  start="$2"
  end="$3"
fi

is_int "$start" || die "Start must be integer"
is_int "$end"   || die "End must be integer"
(( start >= 0 && start <= 255 )) || die "Start out of range"
(( end   >= 0 && end   <= 255 )) || die "End out of range"
(( start <= end )) || die "Start must be <= end"

count=$(( end - start + 1 ))
(( LIMIT == 0 || count <= LIMIT )) || \
  die "Refusing to scan $count hosts (limit $LIMIT)"

# ---- Worker ----
worker='ip="$1";
if ping -n -c 1 -o "$ip" >/dev/null 2>&1; then
  if [ "'"$VERBOSE"'" = "1" ]; then echo "UP   $ip"; else echo "$ip"; fi
else
  if [ "'"$VERBOSE"'" = "1" ]; then echo "DOWN $ip"; fi
fi'

scan_out="$(
  gen_targets | xargs -n 1 -P "$PARALLEL" sh -c "$worker" _ || true
)"

# ---- Output ----
if (( VERBOSE == 1 )); then
  if [[ -n "$scan_out" ]]; then
    if (( DO_SORT == 1 )); then
      # Sort by IP field (field 2) but preserve full line (NEW)
      print -r -- "$scan_out" |
        sort -n -t . -k 2,2 -k 3,3 -k 4,4 -k 5,5
    else
      print -r -- "$scan_out"
    fi
  fi
  alive_count="$(print -r -- "$scan_out" | awk '$1=="UP"{c++} END{print c+0}')"
else
  alive_only="$(print -r -- "$scan_out" | sed '/^$/d')"
  if [[ -n "$alive_only" ]]; then
    print -r -- "$alive_only" | ip_sort
    alive_count="$(print -r -- "$alive_only" | wc -l | tr -d ' ')"
  else
    alive_count=0
  fi
fi

(( alive_count > 0 )) && exit 0 || exit 1
