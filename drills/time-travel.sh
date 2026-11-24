#!/usr/bin/env bash
# Drill 3: an operator runs a bad DML in production and zeroes every balance. Replication faithfully copies
# the mistake to every region in milliseconds; multi-region does nothing for you here. Spanner's version
# history does: read the ledger AS OF a timestamp before the mistake, and write that state back.
#   drills/time-travel.sh
set -uo pipefail
cd "$(dirname "$0")/.."
PROJECT_ID="$(grep -E '^project_id' terraform/terraform.tfvars | cut -d'"' -f2)"
API="$(terraform -chdir=terraform output -raw api)"
TOKEN="$(terraform -chdir=terraform output -raw admin_token)"
summary() { python3 drills/summary.py "$API" "${1:-}"; }
echo "== healthy:        $(summary)"
T0="$(date -u +%Y-%m-%dT%H:%M:%S.%6NZ)"; sleep 2
echo "== T0 = $T0 (the last known-good moment)"
echo "== the mistake: UPDATE Accounts SET Balance = 0 WHERE TRUE   (run as the operator, straight at the database)"
gcloud spanner databases execute-sql ledger --instance ledger --project "$PROJECT_ID" --sql "UPDATE Accounts SET Balance = 0 WHERE TRUE" --quiet >/dev/null
echo "== now (strong):   $(summary)"
echo "== AS OF T0:       $(summary "?asof=$T0")"
echo "== recover: POST /ledger/restore?asof=T0 (reads every account AS OF T0, writes it back in one commit)"
curl -s -X POST -d "" "$API/ledger/restore?asof=$T0" -H "X-Admin-Token: $TOKEN"; echo
echo "== after restore:  $(summary)"
echo "== backups on the side: $(gcloud spanner backup-schedules list --instance ledger --database ledger --project "$PROJECT_ID" --format='value(name.basename(),spec.cronSpec.text,retentionDuration)' 2>/dev/null)"
