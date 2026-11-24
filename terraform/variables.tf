variable "project_id" { type = string }

variable "regions" {
  description = "The two serving regions. They must be the read-write regions of spanner_config so each region writes to a local replica."
  type        = list(string)
  default     = ["us-east4", "us-east1"]
}

variable "spanner_config" {
  description = "Multi-region Spanner configuration. nam3 = Northern Virginia (us-east4, default leader) + South Carolina (us-east1) + a witness."
  type        = string
  default     = "nam3"
}

variable "spanner_processing_units" {
  description = "100 PU is the smallest multi-region instance (1/10 node); plenty for a demo, ~US$0.30/h on nam3."
  type        = number
  default     = 100
}

variable "default_leader" {
  description = "Region that hosts the Spanner leader replicas (write latency is lowest there). The leader drill moves it."
  type        = string
  default     = "us-east4"
}

variable "image_tag" {
  description = "ledger-api image tag in Artifact Registry (built by deploy.sh / CI before apply)."
  type        = string
  default     = "v1"
}

variable "github_repo" {
  description = "owner/repo allowed to assume the CI service account through Workload Identity Federation."
  type        = string
}

variable "alert_email" { type = string }

variable "app" {
  type    = string
  default = "ledger-api"
}
