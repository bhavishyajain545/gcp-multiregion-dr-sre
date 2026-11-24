#!/usr/bin/env bash
# Edge probe: N requests/s against the global IP (a cheap bounded-stale read, i.e. real user traffic, not a health
# endpoint); prints one line per second:
#   HH:MM:SS  ok=<2xx> err=<5xx> other=<n>  regions: us-east4=<n> us-east1=<n>  p50=<ms>
# Used by the outage drill to measure how long the edge keeps failing before the other region takes over.
#   drills/probe.sh <api> <seconds> [rps]
set -uo pipefail
API="$1"; SECS="${2:-60}"; RPS="${3:-4}"
END=$(( $(date +%s) + SECS ))
while [ "$(date +%s)" -lt "$END" ]; do
  T=$(date +%T); declare -A R=(); ok=0; err=0; other=0; lat=()
  for _ in $(seq 1 "$RPS"); do
    out=$(curl -s --max-time 5 -o /dev/null -D /dev/stderr -w '%{http_code} %{time_total}' "$API/accounts/acc-000?staleness=15s" 2>&1 \
          | awk 'BEGIN{IGNORECASE=1} /^x-served-by-region:/{gsub(/\r/,"");reg=$2} /^[0-9]{3} /{code=$1;t=$2} END{print code, t, (reg==""?"-":reg)}')
    read -r code t reg <<<"$out"
    case "$code" in 2*) ok=$((ok+1));; 5*) err=$((err+1));; *) other=$((other+1));; esac
    R[$reg]=$(( ${R[$reg]:-0} + 1 )); lat+=("$t")
    sleep "$(awk "BEGIN{print 1/$RPS}")"
  done
  p50=$(printf '%s\n' "${lat[@]}" | sort -n | awk '{a[NR]=$1} END{printf "%d", a[int((NR+1)/2)]*1000}')
  regs=""; for k in "${!R[@]}"; do regs+="$k=${R[$k]} "; done
  printf '%s  ok=%d err=%d other=%d  regions: %s p50=%sms\n' "$T" "$ok" "$err" "$other" "$regs" "$p50"
done
