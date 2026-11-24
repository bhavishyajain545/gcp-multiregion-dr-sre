#!/usr/bin/env bash
# Prove both regions serve the same ledger through one IP.
set -uo pipefail
cd "$(dirname "$0")"
PROJECT_ID="$(grep -E '^project_id' terraform/terraform.tfvars | cut -d'"' -f2)"
API="${API:-$(terraform -chdir=terraform output -raw api)}"
c() { curl -s --max-time 15 "$@"; }
echo "== edge $API"
echo "-- version: $(c $API/version)"
echo "-- served-by over 10 requests:"; for i in $(seq 1 10); do c -o /dev/null -D - "$API/healthz" | grep -i x-served-by-region | tr -d '\r'; done | sort | uniq -c
echo "-- summary: $(c $API/ledger/summary)"
echo "== each region directly (Cloud Run URLs)"
for R in us-east4 us-east1; do
  URL="$(terraform -chdir=terraform output -json run_urls | python3 -c "import sys,json; print(json.load(sys.stdin)['$R'])")"
  echo "-- $R $(c -w ' (%{time_total}s)' $URL/version)"
done
echo "== a transfer + its idempotent retry"
KEY="smoke-$(date +%s)"
c -X POST "$API/transfers" -H 'content-type: application/json' -d "{\"key\":\"$KEY\",\"from\":\"acc-000\",\"to\":\"acc-001\",\"amount\":1}"; echo
c -X POST "$API/transfers" -H 'content-type: application/json' -d "{\"key\":\"$KEY\",\"from\":\"acc-000\",\"to\":\"acc-001\",\"amount\":1}"; echo
echo "== spanner"
gcloud spanner databases execute-sql ledger --instance ledger --project "$PROJECT_ID" --sql "SELECT OPTION_VALUE AS default_leader FROM INFORMATION_SCHEMA.DATABASE_OPTIONS WHERE OPTION_NAME='default_leader'" 2>/dev/null
