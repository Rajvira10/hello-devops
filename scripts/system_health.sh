#!/usr/bin/env bash
#
# system_health.sh — point-in-time health check for Linux servers.
#
# Collects CPU, memory, disk (all real mounted filesystems), load average and
# the top 5 processes by memory; appends a timestamped entry to a log file
# (with size-based rotation); prints [WARNING]/[CRITICAL] lines when
# thresholds are exceeded; and exits with a monitoring-friendly code:
#
#   0  healthy     1  warning     2  critical     3  unknown (bad usage / error)
#
# Optional: set HEALTH_WEBHOOK_URL to a Slack or Discord incoming-webhook URL
# to be notified whenever the result is not healthy.

set -euo pipefail
# Also run the ERR trap inside functions, so any unexpected failure exits 3.
set -o errtrace

readonly SCRIPT_NAME="${0##*/}"
readonly VERSION="1.0.0"

readonly EXIT_OK=0 EXIT_WARN=1 EXIT_CRIT=2 EXIT_UNKNOWN=3

# ----------------------------------------------------------------- defaults --
CPU_WARN=90;  CPU_CRIT=95
MEM_WARN=85;  MEM_CRIT=95
DISK_WARN=80; DISK_CRIT=90
LOG_FILE="${HEALTH_LOG_FILE:-./health_log.txt}"
MAX_LOG_BYTES=$((1024 * 1024))   # rotate when the log exceeds 1 MiB
KEEP_LOGS=5                      # keep health_log.txt.1 … .5
CPU_SAMPLE_SECONDS=1
OUTPUT_JSON=false
QUIET=false

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Collect basic host health metrics, log them and report threshold breaches.

Thresholds (percent, integers 1-100):
  --cpu N          CPU usage warning threshold          (default: $CPU_WARN)
  --mem N          memory usage warning threshold       (default: $MEM_WARN)
  --disk N         disk usage warning threshold         (default: $DISK_WARN)
  --cpu-crit N     CPU usage critical threshold         (default: $CPU_CRIT)
  --mem-crit N     memory usage critical threshold      (default: $MEM_CRIT)
  --disk-crit N    disk usage critical threshold        (default: $DISK_CRIT)

Output:
  --json           print the report as a single JSON object (also logged as JSON)
  --log-file PATH  log file to append to   (default: \$HEALTH_LOG_FILE or ./health_log.txt)
  --max-size BYTES rotate the log when larger than this  (default: $MAX_LOG_BYTES)
  --keep N         number of rotated logs to keep        (default: $KEEP_LOGS)
  -q, --quiet      print only warnings/criticals (the log is still written)
  -h, --help       show this help and exit
  -V, --version    show version and exit

Environment:
  HEALTH_LOG_FILE      default log file path
  HEALTH_WEBHOOK_URL   Slack/Discord webhook; notified when status != healthy

Exit codes:
  0 healthy, 1 warning, 2 critical, 3 unknown (invalid arguments or error)

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME --disk 80 --cpu 90 --mem 85
  $SCRIPT_NAME --json --log-file /var/log/system_health/health_log.txt
EOF
}

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$EXIT_UNKNOWN"
}

# Any unexpected failure under `set -e` reports UNKNOWN, never a false "healthy".
trap 'printf "%s: unexpected error on line %s\n" "$SCRIPT_NAME" "$LINENO" >&2; exit $EXIT_UNKNOWN' ERR

is_percent() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 100 )); }
is_uint()    { [[ "$1" =~ ^[0-9]+$ ]]; }

# --------------------------------------------------------------- arguments --
parse_args() {
  while (($#)); do
    case "$1" in
      --cpu|--mem|--disk|--cpu-crit|--mem-crit|--disk-crit)
        (($# >= 2)) || die "$1 requires a value"
        is_percent "$2" || die "$1 must be an integer between 1 and 100 (got '$2')"
        case "$1" in
          --cpu) CPU_WARN=$2 ;;       --cpu-crit) CPU_CRIT=$2 ;;
          --mem) MEM_WARN=$2 ;;       --mem-crit) MEM_CRIT=$2 ;;
          --disk) DISK_WARN=$2 ;;     --disk-crit) DISK_CRIT=$2 ;;
        esac
        shift 2 ;;
      --log-file)
        (($# >= 2)) && [[ -n "$2" ]] || die "--log-file requires a path"
        LOG_FILE=$2; shift 2 ;;
      --max-size)
        if ! { (($# >= 2)) && is_uint "$2" && (($2 > 0)); }; then
          die "--max-size requires a positive integer"
        fi
        MAX_LOG_BYTES=$2; shift 2 ;;
      --keep)
        if ! { (($# >= 2)) && is_uint "$2" && (($2 >= 1)); }; then
          die "--keep requires an integer >= 1"
        fi
        KEEP_LOGS=$2; shift 2 ;;
      --json) OUTPUT_JSON=true; shift ;;
      -q|--quiet) QUIET=true; shift ;;
      -h|--help) usage; exit "$EXIT_OK" ;;
      -V|--version) printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; exit "$EXIT_OK" ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
  done

  # A critical threshold below its warning threshold is almost certainly a typo.
  ((CPU_CRIT  >= CPU_WARN))  || CPU_CRIT=$CPU_WARN
  ((MEM_CRIT  >= MEM_WARN))  || MEM_CRIT=$MEM_WARN
  ((DISK_CRIT >= DISK_WARN)) || DISK_CRIT=$DISK_WARN
}

check_dependencies() {
  local cmd missing=()
  for cmd in awk df ps date; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  ((${#missing[@]} == 0)) || die "missing required commands: ${missing[*]}"
  [[ -r /proc/stat && -r /proc/meminfo && -r /proc/loadavg ]] || die "/proc is not readable (Linux only)"
}

# ---------------------------------------------------------------- metrics --
# CPU usage over a short sample: 100 * (1 - Δidle/Δtotal) using /proc/stat.
cpu_usage() {
  local a b
  a=$(awk '/^cpu /{idle=$5+$6; t=0; for(i=2;i<=NF;i++) t+=$i; print idle, t}' /proc/stat)
  sleep "$CPU_SAMPLE_SECONDS"
  b=$(awk '/^cpu /{idle=$5+$6; t=0; for(i=2;i<=NF;i++) t+=$i; print idle, t}' /proc/stat)
  awk -v a="$a" -v b="$b" 'BEGIN {
    split(a, x, " "); split(b, y, " ")
    dt = y[2] - x[2]; di = y[1] - x[1]
    printf "%.1f", (dt > 0) ? 100 * (1 - di / dt) : 0
  }'
}

# Prints: used_percent total_kib available_kib
memory_usage() {
  awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2}
       END { if (t > 0) printf "%.1f %d %d", 100 * (t - a) / t, t, a; else print "0 0 0" }' /proc/meminfo
}

# Prints one line per real filesystem: mountpoint use_percent size_kib used_kib
# Pseudo filesystems are skipped, and a device mounted several times (bind
# mounts, btrfs subvolumes) is reported once, under its shortest mountpoint.
disk_usage() {
  df -P -k -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null \
    | awk 'NR > 1 && $2 > 0 { gsub("%", "", $5); print length($6), $1, $6, $5, $2, $3 }' \
    | sort -n | awk '!seen[$2]++ { print $3, $4, $5, $6 }' | sort -k1,1
}

load_average() { awk '{print $1, $2, $3}' /proc/loadavg; }

cpu_count() { getconf _NPROCESSORS_ONLN 2>/dev/null || grep -c '^processor' /proc/cpuinfo; }

# Prints: pid mem_percent rss_kib command
top_processes() {
  ps -eo pid=,pmem=,rss=,comm= --sort=-rss 2>/dev/null | head -n 5
}

# ------------------------------------------------------------------ output --
json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/\\r}
  printf '%s' "$s"
}

# Compare two decimals: returns 0 if $1 >= $2.
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }

STATUS=$EXIT_OK
ALERTS=()

evaluate() {   # evaluate <name> <value> <warn> <crit> [detail]
  local name=$1 value=$2 warn=$3 crit=$4 detail=${5:-}
  if ge "$value" "$crit"; then
    ALERTS+=("[CRITICAL] ${name} usage ${value}% >= ${crit}%${detail:+ ($detail)}")
    STATUS=$EXIT_CRIT
  elif ge "$value" "$warn"; then
    ALERTS+=("[WARNING] ${name} usage ${value}% >= ${warn}%${detail:+ ($detail)}")
    ((STATUS == EXIT_CRIT)) || STATUS=$EXIT_WARN
  fi
}

status_name() {
  case "$1" in 0) echo healthy ;; 1) echo warning ;; 2) echo critical ;; *) echo unknown ;; esac
}

rotate_log() {
  local file=$1 size i
  [[ -f "$file" ]] || return 0
  size=$(wc -c <"$file")
  ((size > MAX_LOG_BYTES)) || return 0
  rm -f -- "${file}.${KEEP_LOGS}"
  for ((i = KEEP_LOGS - 1; i >= 1; i--)); do
    [[ -f "${file}.${i}" ]] && mv -f -- "${file}.${i}" "${file}.$((i + 1))"
  done
  mv -f -- "$file" "${file}.1"
}

notify_webhook() {
  local text=$1 url=${HEALTH_WEBHOOK_URL:-}
  [[ -n "$url" ]] || return 0
  command -v curl >/dev/null 2>&1 || { echo "[INFO] curl not found; webhook skipped" >&2; return 0; }
  local escaped payload
  escaped=$(json_escape "$text")
  # "content" is read by Discord, "text" by Slack; each ignores the other.
  payload="{\"content\":\"${escaped}\",\"text\":\"${escaped}\"}"
  curl -fsS -m 10 -H 'Content-Type: application/json' -d "$payload" "$url" >/dev/null \
    || echo "[INFO] webhook notification failed" >&2
}

main() {
  parse_args "$@"
  check_dependencies

  local ts host cpu mem_pct mem_total mem_avail load1 load5 load15 ncpu
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  host=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname)
  cpu=$(cpu_usage)
  read -r mem_pct mem_total mem_avail <<<"$(memory_usage)"
  read -r load1 load5 load15 <<<"$(load_average)"
  ncpu=$(cpu_count)

  local -a disks procs
  mapfile -t disks < <(disk_usage)
  mapfile -t procs < <(top_processes)

  evaluate "CPU" "$cpu" "$CPU_WARN" "$CPU_CRIT"
  evaluate "Memory" "$mem_pct" "$MEM_WARN" "$MEM_CRIT"
  local line mp pct size used
  for line in "${disks[@]}"; do
    read -r mp pct size used <<<"$line"
    evaluate "Disk" "$pct" "$DISK_WARN" "$DISK_CRIT" "$mp"
  done

  local status_str report
  status_str=$(status_name "$STATUS")

  if [[ "$OUTPUT_JSON" == true ]]; then
    local disk_json="" proc_json="" alert_json="" sep="" pid pmem rss comm a
    for line in "${disks[@]}"; do
      read -r mp pct size used <<<"$line"
      disk_json+="${sep}{\"mount\":\"$(json_escape "$mp")\",\"used_percent\":${pct},\"size_kib\":${size},\"used_kib\":${used}}"
      sep=","
    done
    sep=""
    for line in "${procs[@]}"; do
      read -r pid pmem rss comm <<<"$line"
      proc_json+="${sep}{\"pid\":${pid},\"mem_percent\":${pmem},\"rss_kib\":${rss},\"command\":\"$(json_escape "$comm")\"}"
      sep=","
    done
    sep=""
    for a in "${ALERTS[@]+"${ALERTS[@]}"}"; do
      alert_json+="${sep}\"$(json_escape "$a")\""
      sep=","
    done
    report="{\"timestamp\":\"${ts}\",\"host\":\"$(json_escape "$host")\",\"status\":\"${status_str}\",\"exit_code\":${STATUS},"
    report+="\"cpu\":{\"used_percent\":${cpu},\"cores\":${ncpu}},"
    report+="\"memory\":{\"used_percent\":${mem_pct},\"total_kib\":${mem_total},\"available_kib\":${mem_avail}},"
    report+="\"load_average\":{\"1m\":${load1},\"5m\":${load5},\"15m\":${load15}},"
    report+="\"disks\":[${disk_json}],\"top_processes\":[${proc_json}],"
    report+="\"thresholds\":{\"cpu\":[${CPU_WARN},${CPU_CRIT}],\"memory\":[${MEM_WARN},${MEM_CRIT}],\"disk\":[${DISK_WARN},${DISK_CRIT}]},"
    report+="\"alerts\":[${alert_json}]}"
  else
    report="===== ${ts} ${host} status=${status_str} =====
CPU:     ${cpu}% (${ncpu} cores)
Memory:  ${mem_pct}% used ($((mem_avail / 1024)) MiB available of $((mem_total / 1024)) MiB)
Load:    ${load1} ${load5} ${load15} (1m 5m 15m)
Disks:"
    for line in "${disks[@]}"; do
      read -r mp pct size used <<<"$line"
      report+=$'\n'"$(printf '  %-30s %3s%%  (%s / %s MiB)' "$mp" "$pct" "$((used / 1024))" "$((size / 1024))")"
    done
    report+=$'\n'"Top 5 processes by memory:"
    report+=$'\n'"$(printf '  %-8s %-6s %-10s %s' PID %MEM RSS_MiB COMMAND)"
    local pid pmem rss comm
    for line in "${procs[@]}"; do
      read -r pid pmem rss comm <<<"$line"
      report+=$'\n'"$(printf '  %-8s %-6s %-10s %s' "$pid" "$pmem" "$((rss / 1024))" "$comm")"
    done
    if ((${#ALERTS[@]})); then
      report+=$'\n'"$(printf '%s\n' "${ALERTS[@]}")"
    fi
  fi

  # Log (rotate first so a single run never pushes the file far past the cap).
  local log_dir
  log_dir=$(dirname -- "$LOG_FILE")
  if mkdir -p -- "$log_dir" 2>/dev/null && touch -- "$LOG_FILE" 2>/dev/null; then
    rotate_log "$LOG_FILE"
    printf '%s\n' "$report" >>"$LOG_FILE"
  else
    echo "[INFO] cannot write log file $LOG_FILE; continuing without logging" >&2
  fi

  # Console output.
  if [[ "$QUIET" == true ]]; then
    ((${#ALERTS[@]} == 0)) || printf '%s\n' "${ALERTS[@]}"
  else
    printf '%s\n' "$report"
  fi

  if ((STATUS != EXIT_OK)); then
    notify_webhook "system_health on ${host}: ${status_str^^}"$'\n'"$(printf '%s\n' "${ALERTS[@]}")"
  fi

}

main "$@"
exit "$STATUS"
