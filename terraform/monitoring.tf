# SLOs are measured at the edge (load balancer metrics), because that is what a
# user sees during a regional failover: the region label on each request tells
# the story of where traffic went.
resource "google_monitoring_notification_channel" "email" {
  display_name = "${var.app} SLO alerts"
  type         = "email"
  labels       = { email_address = var.alert_email }
  depends_on   = [google_project_service.apis]
}

resource "google_monitoring_custom_service" "ledger" {
  service_id   = "${var.app}-global"
  display_name = "${var.app} (global, both regions)"
  depends_on   = [google_project_service.apis]
}

locals {
  lb_filter    = "resource.type=\"https_lb_rule\" resource.labels.url_map_name=\"${google_compute_url_map.ledger.name}\""
  requests_cnt = "metric.type=\"loadbalancing.googleapis.com/https/request_count\" ${local.lb_filter}"
  requests_ok  = "${local.requests_cnt} metric.labels.response_code_class!=500"
  latency_dist = "metric.type=\"loadbalancing.googleapis.com/https/backend_latencies\" ${local.lb_filter}"
}

resource "google_monitoring_slo" "availability" {
  service             = google_monitoring_custom_service.ledger.service_id
  slo_id              = "ledger-availability"
  display_name        = "99.9% of requests non-5xx at the edge"
  goal                = 0.999
  rolling_period_days = 28
  request_based_sli {
    good_total_ratio {
      good_service_filter  = local.requests_ok
      total_service_filter = local.requests_cnt
    }
  }
}

resource "google_monitoring_slo" "latency" {
  service             = google_monitoring_custom_service.ledger.service_id
  slo_id              = "ledger-latency-p95-500ms"
  display_name        = "95% of requests under 500 ms backend latency"
  goal                = 0.95
  rolling_period_days = 28
  request_based_sli {
    distribution_cut {
      distribution_filter = local.latency_dist
      range {
        min = 0
        max = 500
      }
    }
  }
}

resource "google_monitoring_alert_policy" "burn" {
  for_each = {
    availability = google_monitoring_slo.availability.name
    latency      = google_monitoring_slo.latency.name
  }
  display_name = "${var.app} ${each.key} SLO burn rate"
  combiner     = "OR"
  conditions {
    display_name = "fast burn (1h > 14.4x)"
    condition_threshold {
      filter          = "select_slo_burn_rate(\"${each.value}\", \"3600s\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 14.4
      duration        = "0s"
    }
  }
  conditions {
    display_name = "slow burn (6h > 6x)"
    condition_threshold {
      filter          = "select_slo_burn_rate(\"${each.value}\", \"21600s\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 6
      duration        = "0s"
    }
  }
  notification_channels = [google_monitoring_notification_channel.email.id]
  documentation {
    content   = "${var.app} ${each.key} SLO is burning budget. Check which region the LB is sending to (X-Served-By-Region), Cloud Run revisions (OUTAGE env?), Spanner CPU and the default leader. Drills: drills/*.sh."
    mime_type = "text/markdown"
  }
}

# A probe from outside, every minute, from several Google regions.
resource "google_monitoring_uptime_check_config" "edge" {
  display_name = "${var.app} edge /healthz"
  timeout      = "10s"
  period       = "60s"
  http_check {
    path         = "/healthz"
    port         = 80
    use_ssl      = false
    request_method = "GET"
  }
  monitored_resource {
    type   = "uptime_url"
    labels = { project_id = var.project_id, host = google_compute_global_address.lb.address }
  }
  depends_on = [google_project_service.apis]
}

locals {
  dash_tiles = [
    {
      title  = "Requests/s by serving region (edge)"
      filter = "metric.type=\"loadbalancing.googleapis.com/https/request_count\" resource.type=\"https_lb_rule\""
      group  = ["metric.label.backend_scope"]
      align  = "ALIGN_RATE"
      red    = "REDUCE_SUM"
      type   = "STACKED_AREA"
    },
    {
      title  = "5xx/s by serving region (edge)"
      filter = "metric.type=\"loadbalancing.googleapis.com/https/request_count\" resource.type=\"https_lb_rule\" metric.label.response_code_class=\"500\""
      group  = ["metric.label.backend_scope"]
      align  = "ALIGN_RATE"
      red    = "REDUCE_SUM"
      type   = "STACKED_AREA"
    },
    {
      title  = "p95 backend latency by region (ms)"
      filter = "metric.type=\"loadbalancing.googleapis.com/https/backend_latencies\" resource.type=\"https_lb_rule\""
      group  = ["metric.label.backend_scope"]
      align  = "ALIGN_PERCENTILE_95"
      red    = "REDUCE_MEAN"
      type   = "LINE"
    },
    {
      title  = "Cloud Run instances by region"
      filter = "metric.type=\"run.googleapis.com/container/instance_count\" resource.type=\"cloud_run_revision\""
      group  = ["resource.label.location"]
      align  = "ALIGN_MAX"
      red    = "REDUCE_SUM"
      type   = "LINE"
    },
    {
      title  = "Spanner CPU utilization (%)"
      filter = "metric.type=\"spanner.googleapis.com/instance/cpu/utilization\" resource.type=\"spanner_instance\""
      group  = ["resource.label.instance_id"]
      align  = "ALIGN_MEAN"
      red    = "REDUCE_MEAN"
      type   = "LINE"
    },
    {
      title  = "Spanner API p99 latency by method (ms)"
      filter = "metric.type=\"spanner.googleapis.com/api/request_latencies\" resource.type=\"spanner_instance\""
      group  = ["metric.label.method"]
      align  = "ALIGN_PERCENTILE_99"
      red    = "REDUCE_MEAN"
      type   = "LINE"
    },
  ]
}

resource "google_monitoring_dashboard" "dr" {
  dashboard_json = jsonencode({
    displayName = "${var.app} multi-region DR"
    mosaicLayout = {
      columns = 12
      tiles = [
        for i, t in local.dash_tiles : {
          xPos   = (i % 3) * 4
          yPos   = floor(i / 3) * 4
          width  = 4
          height = 4
          widget = {
            title = t.title
            xyChart = {
              dataSets = [{
                plotType = t.type
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = t.filter
                    aggregation = {
                      alignmentPeriod    = "60s"
                      perSeriesAligner   = t.align
                      crossSeriesReducer = t.red
                      groupByFields      = t.group
                    }
                  }
                }
              }]
            }
          }
        }
      ]
    }
  })
}
