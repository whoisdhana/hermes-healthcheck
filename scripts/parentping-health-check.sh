#!/usr/bin/env bash
# ParentPing public health check for cron/systemd monitoring.
# Example cron (output only; alert routing belongs outside this script):
#   */5 * * * * /home/youruser/.hermes/work/parentping-health-check.sh
# Example systemd ExecStart:
#   ExecStart=/home/youruser/.hermes/work/parentping-health-check.sh
# Exit codes: 0=healthy, 1=warning, 2=critical.
set -Eeuo pipefail

readonly DEFAULT_URL='https://example.com/healthz'
URL=${PARENTPING_HEALTH_URL:-$DEFAULT_URL}
CONNECT_TIMEOUT_SECONDS=${PARENTPING_CONNECT_TIMEOUT:-5}
TOTAL_TIMEOUT_SECONDS=${PARENTPING_TOTAL_TIMEOUT:-15}
RETRIES=${PARENTPING_RETRIES:-2}
WARN_LATENCY_SECONDS=${PARENTPING_WARN_LATENCY:-5}
WARN_TLS_DAYS=${PARENTPING_WARN_TLS_DAYS:-14}

usage() {
  cat <<'EOF'
Usage: parentping-health-check.sh [--help]

Read-only health check for ParentPing's public endpoint.

Environment:
  PARENTPING_HEALTH_URL       URL to check (default: https://example.com/healthz)
  PARENTPING_CONNECT_TIMEOUT  curl connect timeout in seconds (default: 5)
  PARENTPING_TOTAL_TIMEOUT    curl total timeout in seconds (default: 15)
  PARENTPING_RETRIES          curl retry count (default: 2)
  PARENTPING_WARN_LATENCY     warning threshold in seconds (default: 5)
  PARENTPING_WARN_TLS_DAYS    TLS-expiry warning threshold in days (default: 14)

Output is exactly one concise status line. Exit codes: 0 OK, 1 WARN, 2 CRITICAL.
The check performs only HTTPS GET/TLS reads; it sends no credentials or alerts.
EOF
}

case ${1:-} in
  --help|-h) usage; exit 0 ;;
  '') ;;
  *) printf 'CRITICAL reason=unknown_argument argument=%q\n' "$1"; exit 2 ;;
esac

for command in curl openssl date mktemp timeout tr awk; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'CRITICAL url=%s reason=missing_dependency dependency=%s\n' "$URL" "$command"
    exit 2
  fi
done

# Keep response data off stdout and guarantee cleanup on normal exit and signals.
tmp_body=$(mktemp "${TMPDIR:-/tmp}/parentping-health.XXXXXX") || {
  printf 'CRITICAL url=%s reason=tempfile_creation_failed\n' "$URL"
  exit 2
}
tmp_error=$(mktemp "${TMPDIR:-/tmp}/parentping-health-error.XXXXXX") || {
  rm -f -- "$tmp_body"
  printf 'CRITICAL url=%s reason=tempfile_creation_failed\n' "$URL"
  exit 2
}
cleanup() { rm -f -- "$tmp_body" "$tmp_error"; }
trap cleanup EXIT
# Convert termination signals into a normal exit so the EXIT trap performs cleanup once.
trap 'exit 2' HUP INT TERM

# Only HTTPS is accepted because TLS expiry is part of the health contract.
if [[ $URL =~ ^https://([^/:?#]+)(:([0-9]+))?(/[^[:space:]]*)?$ ]]; then
  tls_host=${BASH_REMATCH[1]}
  tls_port=${BASH_REMATCH[3]:-443}
else
  printf 'CRITICAL url=%s reason=invalid_https_url\n' "$URL"
  exit 2
fi

curl_format=$'%{http_code}\n%{time_total}\n'
set +e
curl_result=$(curl --silent --show-error --location \
  --connect-timeout "$CONNECT_TIMEOUT_SECONDS" \
  --max-time "$TOTAL_TIMEOUT_SECONDS" \
  --retry "$RETRIES" --retry-delay 1 --retry-max-time "$TOTAL_TIMEOUT_SECONDS" \
  --retry-all-errors --max-filesize 1048576 \
  --output "$tmp_body" --write-out "$curl_format" -- "$URL" 2>"$tmp_error")
curl_rc=$?
set -e

if ((curl_rc != 0)); then
  curl_error=$(<"$tmp_error")
  curl_error=${curl_error//$'\n'/ }
  curl_error=${curl_error// /_}
  printf 'CRITICAL url=%s reason=curl_failed curl_rc=%d detail=%.160s\n' \
    "$URL" "$curl_rc" "${curl_error:-unknown}"
  exit 2
fi

mapfile -t curl_metrics <<<"$curl_result"
http_status=${curl_metrics[0]:-}
latency=${curl_metrics[1]:-}
if [[ ! $http_status =~ ^[0-9]{3}$ || ! $latency =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'CRITICAL url=%s reason=invalid_curl_metrics\n' "$URL"
  exit 2
fi

# Validate common healthy text and JSON forms without jq. Reject explicit failure words first.
body=$(LC_ALL=C tr '[:upper:]' '[:lower:]' <"$tmp_body" | tr -d '\r\n\t ')
body_ok=0
if [[ $body != *unhealthy* && $body != *degraded* && $body != *"\"error\""* && $body != *failed* ]]; then
  if [[ $body =~ ^(ok|healthy)$ ]] ||
     [[ $body =~ \"status\":\"(ok|healthy|up|pass|passing)\" ]] ||
     [[ $body =~ \"healthy\":true ]] ||
     [[ $body =~ \"ok\":true ]]; then
    body_ok=1
  fi
fi

# Read the leaf certificate and normalize its expiry to UTC. Failure is a warning if HTTP is healthy.
tls_expiry='unknown'
tls_days='unknown'
tls_problem=''
set +e
tls_enddate=$(timeout "$TOTAL_TIMEOUT_SECONDS" openssl s_client -servername "$tls_host" -connect "${tls_host}:${tls_port}" </dev/null 2>/dev/null \
  | openssl x509 -noout -enddate 2>/dev/null)
tls_rc=$?
set -e
if ((tls_rc == 0)) && [[ $tls_enddate == notAfter=* ]]; then
  tls_raw=${tls_enddate#notAfter=}
  if expiry_epoch=$(date -u -d "$tls_raw" +%s 2>/dev/null); then
    now_epoch=$(date -u +%s)
    tls_days=$(( (expiry_epoch - now_epoch) / 86400 ))
    tls_expiry=$(date -u -d "@$expiry_epoch" +%Y-%m-%dT%H:%M:%SZ)
    if ((tls_days < 0)); then
      tls_problem='certificate_expired'
    elif ((tls_days < WARN_TLS_DAYS)); then
      tls_problem='certificate_expiring'
    fi
  else
    tls_problem='certificate_date_invalid'
  fi
else
  tls_problem='certificate_check_failed'
fi

if [[ ! $http_status =~ ^2[0-9]{2}$ ]]; then
  printf 'CRITICAL url=%s http=%s latency=%ss tls_days=%s tls_expiry=%s reason=http_status\n' \
    "$URL" "$http_status" "$latency" "$tls_days" "$tls_expiry"
  exit 2
fi
if ((body_ok == 0)); then
  printf 'CRITICAL url=%s http=%s latency=%ss tls_days=%s tls_expiry=%s reason=unhealthy_body\n' \
    "$URL" "$http_status" "$latency" "$tls_days" "$tls_expiry"
  exit 2
fi
if [[ $tls_problem == certificate_expired ]]; then
  printf 'CRITICAL url=%s http=%s latency=%ss tls_days=%s tls_expiry=%s reason=%s\n' \
    "$URL" "$http_status" "$latency" "$tls_days" "$tls_expiry" "$tls_problem"
  exit 2
fi

latency_warn=0
if ! latency_warn=$(LC_ALL=C awk -v actual="$latency" -v limit="$WARN_LATENCY_SECONDS" 'BEGIN { print (actual > limit) ? 1 : 0 }'); then
  latency_warn=1
fi
if [[ -n $tls_problem ]] || ((latency_warn == 1)); then
  reason=${tls_problem:-high_latency}
  printf 'WARN url=%s http=%s latency=%ss tls_days=%s tls_expiry=%s reason=%s\n' \
    "$URL" "$http_status" "$latency" "$tls_days" "$tls_expiry" "$reason"
  exit 1
fi

printf 'OK url=%s http=%s latency=%ss tls_days=%s tls_expiry=%s body=healthy\n' \
  "$URL" "$http_status" "$latency" "$tls_days" "$tls_expiry"
exit 0
