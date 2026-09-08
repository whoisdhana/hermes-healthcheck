#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

RAM_WARN_PERCENT=${RAM_WARN_PERCENT:-80}
RAM_CRIT_PERCENT=${RAM_CRIT_PERCENT:-90}
DISK_WARN_PERCENT=${DISK_WARN_PERCENT:-80}
DISK_CRIT_PERCENT=${DISK_CRIT_PERCENT:-90}
HEALTH_UNIT_DIRS_USER=${HEALTH_UNIT_DIRS_USER:-$HOME/.config/systemd/user}
HEALTH_UNIT_DIRS_SYSTEM=${HEALTH_UNIT_DIRS_SYSTEM:-/etc/systemd/system:/usr/local/lib/systemd/system:/usr/lib/systemd/system:/lib/systemd/system}

for threshold_name in RAM_WARN_PERCENT RAM_CRIT_PERCENT DISK_WARN_PERCENT DISK_CRIT_PERCENT; do
  threshold=${!threshold_name}
  if [[ ! $threshold =~ ^[0-9]+$ ]] || (( threshold < 0 || threshold > 100 )); then
    printf 'Invalid %s=%q; expected an integer from 0 to 100.\n' "$threshold_name" "$threshold" >&2
    exit 2
  fi
done
if (( RAM_WARN_PERCENT > RAM_CRIT_PERCENT || DISK_WARN_PERCENT > DISK_CRIT_PERCENT )); then
  printf 'Warning thresholds must not exceed critical thresholds.\n' >&2
  exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/fleet-health.XXXXXX")
trap 'rm -rf -- "$tmp_dir"' EXIT HUP INT TERM

severity=0
raise_severity() {
  local candidate=$1
  (( candidate > severity )) && severity=$candidate
  return 0
}
format_bytes() {
  local bytes=$1
  awk -v bytes="$bytes" 'BEGIN {
    split("B KiB MiB GiB TiB", unit, " "); n = bytes + 0; i = 1;
    while (n >= 1024 && i < 5) { n /= 1024; i++ }
    if (i == 1) printf "%d %s", n, unit[i]; else printf "%.2f %s", n, unit[i]
  }'
}
format_gib() {
  awk -v bytes="$1" 'BEGIN { printf "%.2f GiB", (bytes + 0) / 1073741824 }'
}
classify_percent() {
  local percent=$1 warn=$2 crit=$3
  if (( percent >= crit )); then raise_severity 2
  elif (( percent >= warn )); then raise_severity 1
  fi
}

discover_scope() {
  local scope=$1 dirs=$2 output=$3
  local -a ctl=()
  [[ $scope == user ]] && ctl+=(--user)
  : >"$output"

  systemctl "${ctl[@]}" list-unit-files --type=service --no-legend --no-pager 2>/dev/null |
    while IFS=' ' read -r unit _; do
      [[ $unit == *hermes*gateway*.service || $unit == *gateway*hermes*.service ]] && printf '%s\n' "$unit"
    done >>"$output" || true
  systemctl "${ctl[@]}" list-units --all --type=service --no-legend --no-pager 2>/dev/null |
    while IFS=' ' read -r unit _; do
      [[ $unit == *hermes*gateway*.service || $unit == *gateway*hermes*.service ]] && printf '%s\n' "$unit"
    done >>"$output" || true

  local old_ifs=$IFS dir file unit_name unit_name_lower
  IFS=:
  shopt -s nullglob
  for dir in $dirs; do
    [[ -d $dir ]] || continue
    for file in "$dir"/*.service; do
      [[ -f $file || -L $file ]] || continue
      unit_name=${file##*/}
      unit_name_lower=${unit_name,,}
      [[ $unit_name_lower == *hermes*gateway*.service || $unit_name_lower == *gateway*hermes*.service ]] && printf '%s\n' "$unit_name"
    done
  done >>"$output"
  shopt -u nullglob
  IFS=$old_ifs
  sort -u -o "$output" "$output"
}

user_units="$tmp_dir/user-units"
system_units="$tmp_dir/system-units"
discover_scope user "$HEALTH_UNIT_DIRS_USER" "$user_units"
discover_scope system "$HEALTH_UNIT_DIRS_SYSTEM" "$system_units"

timestamp=$(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S %Z')
host=$(hostname)
uptime_text=$(uptime -p 2>/dev/null || uptime)
uptime_text=${uptime_text#up }

IFS=' ' read -r mem_total mem_used < <(free -b | awk '$1 == "Mem:" { print $2, $3 }')
IFS=' ' read -r swap_total swap_used < <(free -b | awk '$1 == "Swap:" { print $2, $3 }')
mem_percent=$(( mem_total > 0 ? (mem_used * 100 + mem_total / 2) / mem_total : 0 ))
swap_percent=$(( swap_total > 0 ? (swap_used * 100 + swap_total / 2) / swap_total : 0 ))
classify_percent "$mem_percent" "$RAM_WARN_PERCENT" "$RAM_CRIT_PERCENT"

printf 'Fleet health — %s\n' "$timestamp"
printf 'Host: %s | Uptime: %s\n' "$host" "$uptime_text"
printf 'RAM: %s / %s (%d%%) | Swap: %s / %s (%d%%)\n' \
  "$(format_gib "$mem_used")" "$(format_gib "$mem_total")" "$mem_percent" \
  "$(format_gib "$swap_used")" "$(format_gib "$swap_total")" "$swap_percent"
printf 'Filesystems:\n'
while IFS=' ' read -r filesystem total used available percent mountpoint; do
  [[ $filesystem == Filesystem ]] && continue
  percent=${percent%%%}
  [[ $percent =~ ^[0-9]+$ ]] || continue
  classify_percent "$percent" "$DISK_WARN_PERCENT" "$DISK_CRIT_PERCENT"
  printf '  %s %s / %s (%d%%)\n' "$mountpoint" "$(format_bytes "$used")" "$(format_bytes "$total")" "$percent"
done < <(df -P -B1 -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null)

printf 'Gateways:\n'
service_count=0
report_scope() {
  local scope=$1 file=$2 unit load active sub display
  local -a ctl=()
  [[ $scope == user ]] && ctl+=(--user)
  while IFS= read -r unit; do
    [[ -n $unit ]] || continue
    service_count=$((service_count + 1))
    mapfile -t states < <(systemctl "${ctl[@]}" show "$unit" --property=LoadState --property=ActiveState --property=SubState --value 2>/dev/null || true)
    load=${states[0]:-not-found}
    active=${states[1]:-inactive}
    sub=${states[2]:-dead}
    if [[ $load == not-found || $load == error || $load == bad-setting ]]; then
      display=missing
      raise_severity 2
    else
      case $active in
        active) display="active ($sub)" ;;
        failed) display="failed ($sub)"; raise_severity 2 ;;
        activating) display="activating ($sub)"; raise_severity 1 ;;
        inactive|deactivating|reloading) display="$active ($sub)"; raise_severity 1 ;;
        *) display="$active ($sub)"; raise_severity 1 ;;
      esac
    fi
    printf '  %s/%s: %s\n' "$scope" "$unit" "$display"
  done <"$file"
}
report_scope user "$user_units"
report_scope system "$system_units"
if (( service_count == 0 )); then
  printf '  none discovered\n'
  raise_severity 1
fi

case $severity in
  0) printf 'Overall: HEALTHY\n' ;;
  1) printf 'Overall: WARNING\n' ;;
  *) printf 'Overall: CRITICAL\n' ;;
esac
exit "$severity"
