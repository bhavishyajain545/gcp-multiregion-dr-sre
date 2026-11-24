#!/usr/bin/env bash
# Drill 1: a whole region goes dark. We flip OUTAGE=1 on the us-east4 revision (every request there -> 503),
# watch the edge, and measure:
#   RTO  = seconds between the first 5xx at the edge and the last one (outlier detection evicting the region)
#   RPO  = transfers written during the drill that are missing afterwards (must be 0: one Spanner database)
# Then we heal the region and watch traffic return.
#   drills/region-outage.sh [region=us-east4] [probe_seconds=90]
set -uo pipefail
cd "$(dirname "$0")/.."
PROJECT_ID="$(grep -E '^project_id' terraform/terraform.tfvars | cut -d'"' -f2)"
REGION="${1:-us-east4}"; SECS="${2:-90}"
API="$(terraform -chdir=terraform output -raw api)"
LOG="${DRILL_LOG:-/tmp/outage-$(date +%H%M%S).log}"

before="$(curl -s "$API/ledger/summary" | python3 -c 'import sys,json; s=json.load(sys.stdin)["summary"]; print(s["transfers"], s["total_balance"])')"
echo "before: transfers/total = $before"
echo "== probe running ($SECS s) -> $LOG"
drills/probe.sh "$API" "$SECS" 4 > "$LOG" 2>&1 &
PROBE=$!
sleep 8
echo "== $(date +%T) writer loop starts (1 transfer/s, keyed; retries are idempotent)"
( i=0; END=$(( $(date +%s) + SECS - 12 )); while [ "$(date +%s)" -lt "$END" ]; do
    i=$((i+1)); curl -s --max-time 5 -o /dev/null -X POST "$API/transfers" -H 'content-type: application/json' \
      -d "{\"key\":\"drill-$$-$i\",\"from\":\"acc-$(printf %03d $((i%20)))\",\"to\":\"acc-$(printf %03d $(((i+1)%20)))\",\"amount\":1}" \
      || curl -s --max-time 5 -o /dev/null -X POST "$API/transfers" -H 'content-type: application/json' \
      -d "{\"key\":\"drill-$$-$i\",\"from\":\"acc-$(printf %03d $((i%20)))\",\"to\":\"acc-$(printf %03d $(((i+1)%20)))\",\"amount\":1}"
    sleep 1; done; echo "$i" > /tmp/outage-writes-$$ ) &
WRITER=$!
sleep 4
echo "== $(date +%T) OUTAGE=1 on $REGION (new revision; every request there answers 503)"
gcloud run services update ledger-api --project "$PROJECT_ID" --region "$REGION" --update-env-vars OUTAGE=1 --quiet >/dev/null
echo "   $(date +%T) revision live"
sleep 35
echo "== $(date +%T) heal $REGION (remove OUTAGE)"
gcloud run services update ledger-api --project "$PROJECT_ID" --region "$REGION" --remove-env-vars OUTAGE --quiet >/dev/null
echo "   $(date +%T) healthy revision live"
wait $WRITER $PROBE 2>/dev/null || true
writes="$(cat /tmp/outage-writes-$$ 2>/dev/null || echo 0)"
after="$(curl -s "$API/ledger/summary" | python3 -c 'import sys,json; s=json.load(sys.stdin)["summary"]; print(s["transfers"], s["total_balance"])')"
echo
echo "== edge timeline (one line per second)"; cat "$LOG"
echo
first="$(grep -m1 -E 'err=[1-9]' "$LOG" | cut -c1-8 || true)"; last="$(grep -E 'err=[1-9]' "$LOG" | tail -1 | cut -c1-8 || true)"
errs="$(awk -F'err=' '{split($2,a," "); s+=a[1]} END{print s+0}' "$LOG")"
echo "RTO (first 5xx -> last 5xx at the edge): ${first:-none} -> ${last:-none}   failed probes: $errs"
echo "RPO: writes attempted=$writes  transfers before/after=$(echo $before | cut -d' ' -f1)/$(echo $after | cut -d' ' -f1)  total_balance before/after=$(echo $before | cut -d' ' -f2)/$(echo $after | cut -d' ' -f2)  (invariant must hold, every keyed write must be there exactly once)"
