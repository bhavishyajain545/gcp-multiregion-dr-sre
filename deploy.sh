#!/usr/bin/env bash
# Bring-up: Terraform (registry first) -> image v1 via Cloud Build -> Terraform (everything) -> seed -> smoke.
#   ./deploy.sh              # full bring-up (~12 min: Spanner ~2 min, LB ~5 min to serve)
#   ./deploy.sh image [TAG]  # build a new image and roll it to BOTH regions (what CI does keylessly)
set -euo pipefail
cd "$(dirname "$0")"
PROJECT_ID="$(grep -E '^project_id' terraform/terraform.tfvars | cut -d'"' -f2)"
REGION_A=us-east4; REGION_B=us-east1
IMAGE="${REGION_A}-docker.pkg.dev/${PROJECT_ID}/apps/ledger-api"
MODE="${1:-full}"
tf_out() { terraform -chdir=terraform output -raw "$1"; }

build() {  # TAG
  echo "== build ${IMAGE}:$1 (Cloud Build, sa-build)"
  gcloud builds submit --project "$PROJECT_ID" --region "$REGION_A" --config cloudbuild.yaml --substitutions="_TAG=$1,_REGION=${REGION_A}" . --quiet
}

case "$MODE" in
  image)
    TAG="${2:-v$(date -u +%m%d%H%M)}"; build "$TAG"
    for R in "$REGION_A" "$REGION_B"; do
      echo "== roll ${TAG} to ${R}"
      gcloud run services update ledger-api --project "$PROJECT_ID" --region "$R" --image "${IMAGE}:${TAG}" --quiet >/dev/null
    done
    ./smoke.sh; exit 0 ;;
esac

echo "== 1/5 terraform: APIs, registry, build SA"
terraform -chdir=terraform init -input=false >/dev/null
terraform -chdir=terraform apply -input=false -auto-approve \
  -target=google_project_service.apis -target=google_artifact_registry_repository.apps \
  -target=google_service_account.build -target=google_project_iam_member.build_roles >/dev/null
echo "== 2/5 first image"
build v1
echo "== 3/5 terraform: Spanner, Cloud Run x2, global LB, SLOs"
terraform -chdir=terraform apply -input=false -auto-approve
API="$(tf_out api)"
echo "== 4/5 wait for the load balancer to serve (first programming takes a few minutes)"
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$API/healthz" || true)"
  [[ "$code" == "200" ]] && break; sleep 10
done
echo "   edge: $code"
echo "== 5/5 seed 20 accounts x 1000"
curl -s -X POST "$API/seed?n=20&balance=1000"; echo
./smoke.sh
echo
echo "api:        $API"
echo "dashboard:  $(tf_out dashboard_url)"
echo "next:       drills/region-outage.sh ; drills/leader.sh ; drills/time-travel.sh ; python3 loadgen/load.py $API"
