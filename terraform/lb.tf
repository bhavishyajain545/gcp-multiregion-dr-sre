# One anycast IP in front of both regions. The global external Application
# Load Balancer sends each client to the nearest healthy region; serverless
# NEGs have no health checks, so "healthy" is decided by outlier detection:
# a backend that keeps answering 5xx is ejected and traffic flows to the other
# region. That eviction time IS the recovery time objective of this design.
resource "google_compute_global_address" "lb" {
  name       = "${var.app}-ip"
  depends_on = [google_project_service.apis]
}

resource "google_compute_region_network_endpoint_group" "run" {
  for_each              = google_cloud_run_v2_service.ledger
  name                  = "${var.app}-${each.key}"
  region                = each.key
  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = each.value.name
  }
}

resource "google_compute_security_policy" "edge" {
  name        = "${var.app}-edge"
  description = "per-client rate limit at the edge"
  rule {
    priority = 1000
    action   = "throttle"
    match {
      versioned_expr = "SRC_IPS_V1"
      config { src_ip_ranges = ["*"] }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 600
        interval_sec = 60
      }
    }
  }
  rule {
    priority = 2147483647
    action   = "allow"
    match {
      versioned_expr = "SRC_IPS_V1"
      config { src_ip_ranges = ["*"] }
    }
  }
}

resource "google_compute_backend_service" "ledger" {
  name                  = var.app
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 30
  security_policy       = google_compute_security_policy.edge.id
  custom_response_headers = ["X-Client-Region: {client_region}"] # the app itself adds X-Served-By-Region

  dynamic "backend" {
    for_each = google_compute_region_network_endpoint_group.run
    content {
      group = backend.value.id
    }
  }

  # The failover policy, in numbers: 3 consecutive 5xx within a 1 s window
  # ejects the region for 30 s (then it is retried); up to 100% of a backend
  # may be ejected because the other region can take the whole load.
  outlier_detection {
    consecutive_errors                    = 3
    interval { seconds = 1 }
    base_ejection_time { seconds = 30 }
    max_ejection_percent                  = 100
    enforcing_consecutive_errors          = 100
    consecutive_gateway_failure           = 3
    enforcing_consecutive_gateway_failure = 100
    enforcing_success_rate                = 0
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_url_map" "ledger" {
  name            = var.app
  default_service = google_compute_backend_service.ledger.id
}

resource "google_compute_target_http_proxy" "ledger" {
  name    = var.app
  url_map = google_compute_url_map.ledger.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "${var.app}-http"
  target                = google_compute_target_http_proxy.ledger.id
  port_range            = "80"
  ip_address            = google_compute_global_address.lb.address
  load_balancing_scheme = "EXTERNAL_MANAGED"
}
