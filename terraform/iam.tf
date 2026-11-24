# CI identity (GitHub Actions via Workload Identity Federation): build, push, deploy both regions. No keys.
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"
  depends_on                = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }
  attribute_condition = "assertion.repository == \"${var.github_repo}\""
  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "ci" {
  account_id   = "sa-github-ci"
  display_name = "GitHub Actions CI (build, push, deploy)"
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "ci_roles" {
  for_each = toset(["roles/artifactregistry.writer", "roles/run.developer"])
  project  = var.project_id
  role     = each.value
  member   = google_service_account.ci.member
}

# deploying a revision requires actAs on the runtime service account
resource "google_service_account_iam_member" "ci_actas_run" {
  service_account_id = google_service_account.run.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.ci.member
}

resource "google_service_account_iam_member" "ci_wif" {
  service_account_id = google_service_account.ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}
