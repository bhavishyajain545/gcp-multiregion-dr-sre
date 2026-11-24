#!/usr/bin/env bash
# Drill 2: where do writes commit? Spanner multi-region keeps the leader replicas in one region
# (default_leader). Writes from the other region pay a cross-region round trip. We measure write latency
# from each region's Cloud Run URL, move the leader with one DDL statement, and measure again.
#   drills/leader.sh [new_leader=us-east1]
set -uo pipefail
cd "$(dirname "$0")/.."
PROJECT_ID="$(grep -E '^project_id' terraform/terraform.tfvars | cut -d'"' -f2)"
NEW="${1:-us-east1}"
urls="$(terraform -chdir=terraform output -json run_urls)"
url() { echo "$urls" | python3 -c "import sys,json; print(json.load(sys.stdin)['$1'])"; }
leader() { gcloud spanner databases execute-sql ledger --instance ledger --project "$PROJECT_ID" --format='value(rows[0][0])' \
  --sql "SELECT OPTION_VALUE FROM INFORMATION_SCHEMA.DATABASE_OPTIONS WHERE OPTION_NAME='default_leader'" 2>/dev/null; }
measure() {  # region -> median write latency in ms over 8 keyed transfers
  local U; U="$(url "$1")"; local t=()
  for i in $(seq 1 8); do
    t+=("$(curl -s --max-time 10 -o /dev/null -w '%{time_total}' -X POST "$U/transfers" -H 'content-type: application/json' \
      -d "{\"key\":\"leader-$$-$1-$i\",\"from\":\"acc-002\",\"to\":\"acc-003\",\"amount\":1}")")
  done
  printf '%s\n' "${t[@]}" | sort -n | awk '{a[NR]=$1} END{printf "%d", a[int((NR+1)/2)]*1000}'
}
echo "default_leader now: $(leader)"
for R in us-east4 us-east1; do echo "  write p50 from $R: $(measure $R) ms"; done
echo "== ALTER DATABASE ledger SET OPTIONS (default_leader = '$NEW')"
gcloud spanner databases ddl update ledger --instance ledger --project "$PROJECT_ID" --ddl "ALTER DATABASE ledger SET OPTIONS (default_leader = '$NEW')" --quiet
sleep 20   # leader hand-off is quick, give the first measurement a clean slate
echo "default_leader now: $(leader)"
for R in us-east4 us-east1; do echo "  write p50 from $R: $(measure $R) ms"; done
