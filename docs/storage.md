# Storage

## Longhorn 

### Checking current PVC utilisation

Run `scripts/longhorn-pvc-report.sh` to get a cluster-wide usage report sorted by % used:

```bash
./scripts/longhorn-pvc-report.sh
```

This queries the Prometheus metrics endpoint on each `longhorn-manager` pod directly, so no monitoring stack is required. See `scripts/README.md` for details.

Bear in mind that reported usage reflects block-layer writes, not filesystem usage — volumes that haven't been trimmed recently will appear larger than their actual data. Run the report after the daily trim job has had a chance to complete for the most accurate picture.

### Trim vs. "Actual Size"

Longhorn's "Actual Size" column in the Volumes UI reflects block-level usage, not filesystem usage. After a trim job runs, "Actual Size" will drop to match what `du` reports inside the container. If they still diverge significantly after a trim, the volume may have snapshot data consuming the difference — check the volume's snapshot chain in the Longhorn UI.

#### filesystem trim

Longhorn operates at the block device layer and has no visibility into filesystem-level deletions. When files are deleted inside a volume, the filesystem marks those blocks as free, but Longhorn still counts them as used — causing "Actual Size" in the UI to overstate real data consumption, sometimes significantly.

The `RecurringJob` at `apps/longhorn/recurringjob-daily-filesystem-trim.yaml` runs a daily `fstrim` across all volumes to reclaim those blocks and keep Longhorn's reported sizes accurate.

The job is assigned to the `default` group, which means Longhorn automatically applies it to any volume that has no other recurring job labels. No per-volume configuration is needed.

#### Adjusting the schedule

The current schedule is daily at 3am. This is appropriate for this cluster because:

- Volumes are small (config databases, application data)
- Nodes are SSD-backed (trim is cheap on flash storage)
- Workloads have low write throughput (SQLite, not high-concurrency Postgres)

You would want to reduce to weekly (or less) if:

- **Many large, heavily-written volumes** — trim is a write-like operation. Running it nightly across dozens of large volumes creates sustained storage load. The `concurrency: 2` setting serializes it, but the total window grows with volume count.
- **Databases with high write throughput** — trim on an active high-write database can cause latency spikes while the storage layer processes UNMAP commands alongside application writes. For a busy Postgres instance, weekly or monthly is more appropriate. The arr-stack SQLite databases do not have this problem.
- **Snapshot-heavy volumes** — trim must account for blocks still referenced by older snapshots before releasing them. More snapshots means a more expensive trim operation. If snapshot jobs are added later, re-evaluate the trim frequency on those volumes.
- **HDD-backed storage** — UNMAP/DISCARD on spinning disks is significantly more expensive than on SSDs due to seek times. Weekly at most on HDDs.
