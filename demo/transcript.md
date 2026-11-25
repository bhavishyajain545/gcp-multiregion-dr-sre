# Demo transcript: demo

## 00:00  Architecture

This project is about losing a region on purpose and measuring what it costs. The same Go service, a small money-transfer ledger, runs in two regions on Cloud Run, Northern Virginia and South Carolina, behind one anycast IP on the global load balancer. Underneath there is one multi-region Cloud Spanner database: both regions hold a synchronously committed read-write replica and a witness in a third region breaks ties. So a regional outage changes where requests are served, never what the ledger says: the recovery point is zero by construction, and the recovery time is the load balancer's outlier detection evicting the dead region, which we measure rather than estimate. Transfers are serializable Spanner transactions keyed by a client idempotency key, reads come strong, stale or as of a past timestamp, and everything is Terraform with a keyless pipeline that rolls one region at a time.

## 00:55  One IP two regions

One IP, two regions, one ledger. Every response carries the region that served it; from where I am, the load balancer picks the nearest healthy one, and both regions answer the same question with the same numbers. Calling each region's Cloud Run URL directly shows the two deployments are identical, down to the revision, and the ledger summary is the invariant we will keep checking: twenty accounts, twenty thousand in total.

## 01:21  Concurrency

Consistency under concurrency. Twenty workers fire keyed transfers through the edge for twenty seconds; some land in one region, some in the other, and all of them are serializable transactions on the same database. Afterwards the total balance is exactly what it was and the transfer count grew by exactly the number of successful requests. Money moved, none was created, none was lost, with two regions writing at once.

## 01:48  Reads and idempotency

Three ways to read, and one way to retry. A strong read goes to the leader and returns the freshest value. A bounded-stale read is allowed to be up to fifteen seconds old and is served by the nearest replica, which is what a dashboard should use. And a transfer retried with the same idempotency key, say after a failover cut the first response off, comes back as a duplicate: nothing moves twice.

## 02:13  Spanner

The database in the console: instance configuration nam3, Enterprise Plus, a hundred processing units, which is a tenth of a node and plenty for this. Two read-write replicas, one per serving region, plus the witness. The default leader sits in Northern Virginia; we will move it later with a single statement.

## 02:34  Region outage drill

Drill one: a region goes dark. A probe hits the edge four times a second and a writer commits one keyed transfer per second. Then I flip the outage switch on Northern Virginia, so every request there answers five-oh-three. The edge fails for a few seconds, outlier detection ejects the region, and South Carolina takes all of it. That window is the measured recovery time. Then the region heals and traffic flows back. The recovery point: every keyed write is in the ledger exactly once and the total balance did not move. That is what one database under two regions buys you.

## 03:10  Leader drill

Drill two: where do writes commit? Spanner keeps the leader replicas in one region, and a write from the other region pays a cross-region round trip. Write latency from each region, then one DDL statement moves the default leader to South Carolina, and the numbers swap. In a real failover Spanner elects a new leader on its own within seconds; this is the dial for when you want to choose.

## 03:34  Time travel drill

Drill three is the one replication cannot save you from. An operator runs an update that zeroes every balance, and the replicas faithfully copy the mistake in milliseconds. Spanner's version history does what replication cannot: a read as of a timestamp before the mistake still shows the right ledger, and the restore endpoint writes that state back in a single commit. Seconds, not a backup restore; the daily backup schedule stays as the second line.

## 04:01  Dashboard and SLOs

The dashboard splits the edge by serving region: requests and five-hundreds per region, p95 per region, Cloud Run instances, Spanner CPU and API latency. The outage shows up as a short burst of errors in one region and the other region's line taking the load. The SLOs are measured at the edge, the way a user would: ninety-nine point nine percent non-five-hundred, and ninety-five percent under five hundred milliseconds, each with burn-rate alerts and an uptime check from three continents.

## 04:31  Keyless CI

Delivery is keyless and region-aware: GitHub Actions tests, builds, pushes by digest, and rolls that digest to South Carolina first, then Northern Virginia, one at a time, so a bad build can never take both regions down in the same minute. Terraform owns everything around the revisions and deliberately ignores the image and the outage knob.

## 04:52  Wrap-up

Everything shown is in the repository: the Go service with its three read modes and idempotent transfers, Terraform for Spanner, Cloud Run, the global load balancer with its eviction policy, SLOs, alerts and dashboard, the three drill scripts, the load generator and the keyless workflow. The only idle cost is the Spanner instance, and the teardown script removes it all. Thanks for watching.
