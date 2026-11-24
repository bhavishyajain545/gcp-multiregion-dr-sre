resource "google_artifact_registry_repository" "apps" {
  location      = var.regions[0]
  repository_id = "apps"
  format        = "DOCKER"
  depends_on    = [google_project_service.apis]
}

# Cloud Build identity for deploy.sh (org disables the default SA grants)
resource "google_service_account" "build" {
  account_id   = "sa-build"
  display_name = "Cloud Build (test, build, push)"
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "build_roles" {
  for_each = toset(["roles/artifactregistry.writer", "roles/logging.logWriter", "roles/storage.objectViewer"])
  project  = var.project_id
  role     = each.value
  member   = google_service_account.build.member
}
