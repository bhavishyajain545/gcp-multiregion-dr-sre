# One ledger, three replicas, two continents' worth of nines. A multi-region
# instance keeps a synchronously replicated copy in each read-write region;
# losing one region loses no committed write (RPO 0) and the surviving region
# keeps serving reads and, after leader re-election (seconds), writes.
resource "google_spanner_instance" "ledger" {
  name             = "ledger"
  display_name     = "ledger (multi-region)"
  config           = var.spanner_config
  processing_units = var.spanner_processing_units
  edition          = "ENTERPRISE_PLUS" # multi-region configs (and default_leader) require Enterprise Plus on new instances
  labels           = { app = var.app }
  depends_on       = [google_project_service.apis]
}

resource "google_spanner_database" "ledger" {
  instance                 = google_spanner_instance.ledger.name
  name                     = "ledger"
  database_dialect         = "GOOGLE_STANDARD_SQL"
  version_retention_period = "4h" # how far back AS OF reads (time-travel recovery) can go; max 7d
  deletion_protection      = false
  ddl = [
    <<-EOT
    CREATE TABLE Accounts (
      AccountId STRING(64) NOT NULL,
      Owner     STRING(128),
      Balance   INT64 NOT NULL,
      UpdatedAt TIMESTAMP NOT NULL OPTIONS (allow_commit_timestamp = true)
    ) PRIMARY KEY (AccountId)
    EOT
    ,
    <<-EOT
    CREATE TABLE Transfers (
      IdempotencyKey STRING(64) NOT NULL,
      FromAccount    STRING(64) NOT NULL,
      ToAccount      STRING(64) NOT NULL,
      Amount         INT64 NOT NULL,
      Region         STRING(32),
      CommitTs       TIMESTAMP NOT NULL OPTIONS (allow_commit_timestamp = true)
    ) PRIMARY KEY (IdempotencyKey)
    EOT
    ,
    "CREATE INDEX TransfersByCommitTs ON Transfers(CommitTs DESC)",
    "ALTER DATABASE ledger SET OPTIONS (default_leader = '${var.default_leader}')",
  ]
}

# Belt and braces next to time travel: a daily full backup kept for two days.
resource "google_spanner_backup_schedule" "daily" {
  instance           = google_spanner_instance.ledger.name
  database           = google_spanner_database.ledger.name
  name               = "daily-full"
  retention_duration = "172800s"
  spec {
    cron_spec {
      text = "0 2 * * *"
    }
  }
  full_backup_spec {}
}
