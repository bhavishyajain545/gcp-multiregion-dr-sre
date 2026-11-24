#!/usr/bin/env bash
# Full teardown so nothing bills afterwards: Spanner is the only thing that costs money while idle.
#   ./teardown.sh   # terraform destroy -> LB leftovers -> buckets -> audit
set -uo pipefail
cd "$(dirname "$0")"
PROJECT_ID="$(grep -E '^project_id' terraform/terraform.tfvars | cut -d'"' -f2)"
g() { gcloud "$@" --project "$PROJECT_ID" --quiet; }

echo "== 1/4 terraform destroy"
terraform -chdir=terraform init -input=false >/dev/null 2>&1 || true
terraform -chdir=terraform destroy -input=false -auto-approve 2>&1 | grep -v 'Still destroying' | tail -8

echo "== 2/4 anything Terraform did not own"
for n in $(g spanner instances list --format='value(name)' 2>/dev/null); do echo "  delete spanner instance $n"; g spanner instances delete "$n" || true; done
for r in us-east4 us-east1; do
  for s in $(g run services list --region "$r" --format='value(metadata.name)' 2>/dev/null); do echo "  delete run service $s ($r)"; g run services delete "$s" --region "$r" || true; done
done
for b in $(gcloud storage ls --project "$PROJECT_ID" 2>/dev/null); do echo "  delete bucket $b"; gcloud storage rm -r "$b" --project "$PROJECT_ID" --quiet || true; done

echo "== 3/4 terraform destroy again (in case the LB blocked something)"
terraform -chdir=terraform destroy -input=false -auto-approve 2>&1 | tail -3

echo "== 4/4 what is left in $PROJECT_ID"
./audit-billing.sh "$PROJECT_ID"
echo "done. The WIF pool is soft-deleted for 30 days; an empty project costs nothing. Rebuild: ./reimport.sh then ./deploy.sh."
