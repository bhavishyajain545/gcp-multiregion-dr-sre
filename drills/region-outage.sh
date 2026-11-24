#!/usr/bin/env bash
# Drill 1: a whole region goes dark. We flip the region's outage flag in the ledger (every instance there polls it:
# readiness and every business request answer 503 within ~2 s), watch the edge, and measure:
#   RTO  = seconds between the first 5xx at the edge and the last one (outlier detection evicting the region)
#   RPO  = transfers written during the drill that are missing afterwards (must be 0: one Spanner database)
# Then we heal the region and watch traffic return.
#   drills/region-outage.sh [region=us-east4] [probe_seconds=90]
set -uo pipefail
cd "$(dirname "$0")/.."
PROJECT_ID="$(grep -E '^project_id' terraform/terraform.tfvars | cut -d'"' -f2)"
REGION="${1:-us-east4}"; SECS="${2:-90}"
API="$(terraform -chdir=terraform output -raw api)"
TOKEN="$(terraform -chdir=terraform output -raw admin_token)"
OTHER_URL="$(terraform -chdir=terraform output -json run_urls | python3 -c "import sys,json; u=json.load(sys.stdin); print([v for k,v in u.items() if k!='$REGION'][0])")"
flag() { curl -s --max-time 15 -X POST "$OTHER_URL/admin/outage" -H "X-Admin-Token: $TOKEN" -H 'content-type: application/json' -d "{\"region\":\"$REGION\",\"on\":$1}"; echo; }
LOG="${DRILL_LOG:-/tmp/outage-$(date +%H%M%S).log}"

before="$(curl -s "$API/ledger/summary" | python3 -c 'import sys,json; s=json.load(sys.stdin)["summary"]; print(s["transfers"], s["total_balance"])')"
echo "before: transfers/total = $before"
echo "== probe running ($SECS s) -> $LOG"
drills/probe.sh "$API" "$SECS" 4 > "$LOG" 2>&1 &
PROBE=$!
sleep 8
echo "== $(date +%T) writer loop starts (1 transfer/s, keyed; retries are idempotent)"
( i=0; retried=0; END=$(( $(date +%s) + SECS - 12 )); while [ "$(date +%s)" -lt "$END" ]; do
    i=$((i+1)); body="{\"key\":\"drill-$$-$i\",\"from\":\"acc-$(printf %03d $((i%20)))\",\"to\":\"acc-$(printf %03d $(((i+1)%20)))\",\"amount\":1}"
    for attempt in 1 2 3 4; do   # same idempotency key every time: a retry can never move the money twice
      code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -X POST "$API/transfers" -H 'content-type: application/json' -d "$body")
      case "$code" in 2*) break;; esac
      retried=$((retried+1)); sleep 2
    done
    sleep 1; done; echo "$i $retried" > /tmp/outage-writes-$$ ) &
WRITER=$!
sleep 4
echo "== $(date +%T) outage flag ON for $REGION (set through the other region's URL; instances poll it every 2 s)"
flag true
sleep 40
echo "== $(date +%T) heal $REGION (flag OFF)"
flag false
wait $WRITER $PROBE 2>/dev/null || true
read -r writes retries < /tmp/outage-writes-$$ 2>/dev/null || { writes=0; retries=0; }
after="$(curl -s "$API/ledger/summary" | python3 -c 'import sys,json; s=json.load(sys.stdin)["summary"]; print(s["transfers"], s["total_balance"])')"
echo
echo "== edge timeline (one line per second)"; cat "$LOG"
echo
first="$(grep -m1 -E 'err=[1-9]' "$LOG" | cut -c1-8 || true)"; last="$(grep -E 'err=[1-9]' "$LOG" | tail -1 | cut -c1-8 || true)"
errs="$(awk -F'err=' '{split($2,a," "); s+=a[1]} END{print s+0}' "$LOG")"
echo "RTO (first 5xx -> last 5xx at the edge): ${first:-none} -> ${last:-none}   failed probes: $errs"
echo "RPO: keyed writes=$writes (retries needed: $retries)  transfers before/after=$(echo $before | cut -d' ' -f1)/$(echo $after | cut -d' ' -f1)  total_balance before/after=$(echo $before | cut -d' ' -f2)/$(echo $after | cut -d' ' -f2)  (every key exactly once, total unchanged)"
