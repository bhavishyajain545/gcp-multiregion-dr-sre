# Rebuild from zero

Terraform owns every cloud resource; `deploy.sh` builds the first image and applies everything; GitHub Actions
rolls new digests to both regions keylessly afterwards. ~12 minutes to a serving edge (Spanner ~2 min, Cloud Run
~1 min, the global LB needs ~5 min before the first request succeeds). Cost while up: ~US$0.5/hour, almost all
Spanner. Tear it down after the demo.

## 0. Prerequisites

| Need | Notes |
|---|---|
| Billing-linked GCP account | A billing account allows 5 linked projects by default; unlink a finished one if `billing projects link` says "quota exceeded". |
| `gcloud` >= 590, `terraform` >= 1.6, Go 1.24, Python 3 | `go test ./...` in `app/`; the drills use `python3` for JSON. |
| A GitHub repo at `github_repo` (tfvars) | CI auth is bound to exactly this `owner/repo` by the WIF attribute condition. |

Organisation constraints (domain-restricted sharing blocks `allUsers` on Cloud Run and Google-managed principals):

```bash
export PROJECT_ID=bj-multiregion-dr
gcloud services enable orgpolicy.googleapis.com --project "$PROJECT_ID"
cat > /tmp/drs.yaml <<EOF
name: projects/$PROJECT_ID/policies/iam.allowedPolicyMemberDomains
spec:
  rules:
  - allowAll: true
EOF
gcloud org-policies set-policy /tmp/drs.yaml --project "$PROJECT_ID" --billing-project "$PROJECT_ID"
```

## 1. Project

```bash
gcloud projects create "$PROJECT_ID" --name "Multi-region DR SRE" --organization <ORG_ID>
gcloud billing projects link "$PROJECT_ID" --billing-account <BILLING_ACCOUNT_ID>
gcloud auth application-default set-quota-project "$PROJECT_ID"
```

## 2. Configure

```bash
git clone https://github.com/bhavishyajain545/gcp-multiregion-dr-sre && cd gcp-multiregion-dr-sre
$EDITOR terraform/terraform.tfvars        # project_id, github_repo, alert_email (regions/spanner_config have defaults)
```

If you change `project_id`, also change it in `.github/workflows/release.yml` (env block).

## 3. Bring-up

```bash
./deploy.sh      # 1 terraform (APIs, registry, build SA)  2 Cloud Build image v1  3 terraform (everything)
                 # 4 wait for the edge  5 seed 20 accounts x 1000 + smoke
```

## 4. CI secret (once)

```bash
terraform -chdir=terraform output -raw workload_identity_provider   # -> repo secret GCP_WORKLOAD_IDENTITY_PROVIDER
```

Push to `main` (paths `app/**`) and the workflow tests, builds, pushes by digest and rolls us-east1 then us-east4.

## 5. Drills

```bash
python3 loadgen/load.py "$(terraform -chdir=terraform output -raw api)" --workers 20 --seconds 30
drills/region-outage.sh          # ~2 min: RTO / RPO at the edge
drills/leader.sh                 # move the leader, compare write latency per region
drills/time-travel.sh            # bad DML -> AS OF read -> restore
drills/leader.sh us-east4        # move it back
```

## 6. Demo

`demo/scenes.py` drives a signed-in Chrome (`--remote-debugging-port=9222`) and WSL for commands; narration via
Google Cloud TTS; `python -u demo/scenes.py` writes `demo/demo.mp4`, captions and transcript. Every command is
captured before its scene and replayed over the narration.

## 7. Tear down (stop all cost)

```bash
./teardown.sh        # terraform destroy -> Spanner/Run/bucket leftovers -> destroy again -> audit
```

Rebuilding later: `./reimport.sh` first (the WIF pool/provider survive soft-deleted and 409 on create), then
`./deploy.sh`.

## Gotchas met while building

- Serverless NEGs have **no health checks**; failover between regions is **outlier detection** on the backend
  service (needs `load_balancing_scheme = EXTERNAL_MANAGED`). The eviction parameters *are* the RTO.
- `default_leader` needs the Spanner **Enterprise** edition; `ALTER DATABASE ... SET OPTIONS (default_leader=...)`
  can be part of the create DDL.
- `ReadWriteTransaction` in the Go client returns the commit timestamp directly; reads inside it use `tx.Read`
  (`ReadUsingIndex` returns only an iterator).
- Terraform `ignore_changes` on the Cloud Run image/env: the outage drill and CI create revisions by hand, and
  Terraform must not roll them back on the next apply.
- A billing account links at most 5 projects by default; `UREQ_PROJECT_BILLING_NOT_FOUND` on `services enable`
  means the link silently failed.
