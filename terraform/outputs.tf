output "lb_ip" { value = google_compute_global_address.lb.address }
output "api" { value = "http://${google_compute_global_address.lb.address}" }
output "run_urls" { value = { for r, s in google_cloud_run_v2_service.ledger : r => s.uri } }
output "image" { value = local.image }
output "spanner_instance" { value = google_spanner_instance.ledger.name }
output "spanner_database" { value = "projects/${var.project_id}/instances/${google_spanner_instance.ledger.name}/databases/${google_spanner_database.ledger.name}" }
output "spanner_config" { value = var.spanner_config }
output "ci_service_account" { value = google_service_account.ci.email }
output "workload_identity_provider" { value = google_iam_workload_identity_pool_provider.github.name }
output "admin_token" {
  value     = random_password.admin_token.result
  sensitive = true
}
output "dashboard_url" {
  value = "https://console.cloud.google.com/monitoring/dashboards/builder/${element(split("/", google_monitoring_dashboard.dr.id), length(split("/", google_monitoring_dashboard.dr.id)) - 1)}?project=${var.project_id}"
}
output "slo_url" {
  value = "https://console.cloud.google.com/monitoring/services/${data.google_project.this.number}/${google_monitoring_custom_service.ledger.service_id}?project=${var.project_id}"
}
output "spanner_url" {
  value = "https://console.cloud.google.com/spanner/instances/${google_spanner_instance.ledger.name}/databases/${google_spanner_database.ledger.name}/details/tables?project=${var.project_id}"
}
output "run_url_console" {
  value = "https://console.cloud.google.com/run?project=${var.project_id}"
}
