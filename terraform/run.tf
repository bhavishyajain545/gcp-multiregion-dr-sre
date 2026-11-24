# The same image in both regions, each talking to the Spanner replica next to it.
locals {
  image = "${var.regions[0]}-docker.pkg.dev/${var.project_id}/apps/${var.app}:${var.image_tag}"
}

resource "google_service_account" "run" {
  account_id   = "sa-ledger"
  display_name = "ledger-api runtime"
  depends_on   = [google_project_service.apis]
}

resource "google_spanner_database_iam_member" "run_db_user" {
  instance = google_spanner_instance.ledger.name
  database = google_spanner_database.ledger.name
  role     = "roles/spanner.databaseUser"
  member   = google_service_account.run.member
}

resource "google_project_iam_member" "run_roles" {
  for_each = toset(["roles/cloudtrace.agent", "roles/logging.logWriter", "roles/monitoring.metricWriter"])
  project  = var.project_id
  role     = each.value
  member   = google_service_account.run.member
}

resource "random_password" "admin_token" {
  length  = 32
  special = false
}

resource "google_cloud_run_v2_service" "ledger" {
  for_each = toset(var.regions)
  name     = var.app
  location = each.value
  ingress  = "INGRESS_TRAFFIC_ALL" # the LB is the front door; direct URLs stay reachable for the per-region latency drill
  deletion_protection = false

  template {
    service_account = google_service_account.run.email
    scaling {
      min_instance_count = 1 # no cold start in the failover measurement
      max_instance_count = 10
    }
    containers {
      image = local.image
      ports { container_port = 8080 }
      env {
        name  = "REGION"
        value = each.value
      }
      env {
        name  = "SPANNER_DATABASE"
        value = "projects/${var.project_id}/instances/${google_spanner_instance.ledger.name}/databases/${google_spanner_database.ledger.name}" # the resource id is only instance/database
      }
      env {
        name  = "ADMIN_TOKEN"
        value = random_password.admin_token.result
      }
      resources {
        limits            = { cpu = "1", memory = "512Mi" }
        cpu_idle          = true
        startup_cpu_boost = true
      }
      startup_probe {
        http_get { path = "/healthz" }
        period_seconds    = 2
        failure_threshold = 10
      }
      # Service health: the global LB fails a region over when < 60% of its instances pass this
      # readiness probe (serverless NEGs have no health checks of their own). The outage drill
      # makes /readyz answer 503, so this probe IS the failover signal.
      readiness_probe {
        http_get { path = "/readyz" }
        period_seconds    = 5
        timeout_seconds   = 3
        failure_threshold = 2
      }
    }
    max_instance_request_concurrency = 80
  }
  labels = { app = var.app, region = each.value }

  lifecycle {
    # the outage drill and CI roll new revisions by hand; Terraform must not fight them. Before an apply that
    # changes the template, run `terraform apply -refresh-only` so the new revision keeps the live image.
    ignore_changes = [template[0].containers[0].image, template[0].containers[0].env, client, client_version]
  }
  depends_on = [google_spanner_database_iam_member.run_db_user]
}

resource "google_cloud_run_v2_service_iam_member" "public" {
  for_each = google_cloud_run_v2_service.ledger
  name     = each.value.name
  location = each.value.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}
