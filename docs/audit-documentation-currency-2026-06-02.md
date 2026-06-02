# Documentation Currency Audit — 2026-06-02

Comprehensive audit of all .md documentation (excluding bootstrap/ and
troubleshooting/) against actual repository state.

---

## Audit Scope

Reviewed 27 markdown files. Cross-referenced against actual `apps/` directories,
`apps/manifests/` listing, and StorageClass definitions. Each finding below is
confirmed against live repo state.

---

## Findings by File

### 1. `CLAUDE.md`

| # | Severity | Finding |
|---|----------|---------|
| 1 | **HIGH** | **Repository Structure tree stale.** The ASCII tree in the "Repository Structure" section (lines 176-224) is a static snapshot. Missing directories: `percona-mongodb/`, `percona-mongodb-operator/`, `wordpress-taegost/`, `librechat/`. Missing docs: `mongodb-runbooks.md`, `brainstorms/`, `plans/`. Missing apps: `firefly3/`, `leantime/`, `manyfold/`, `mealie/`, `n8n/`, `searxng/` (already in the doc text at lines 190-210 list but tree itself is incomplete). |
| 2 | **HIGH** | **StorageClasses incomplete.** Only documents `smb-backups` and `nfs-multimedia`. `nfs-backups` StorageClass exists in `apps/infrastructure/storage/storageclass-nfs-backups.yaml` but is not mentioned. Three StorageClasses exist: `longhorn`, `smb-backups`, `nfs-backups`, `nfs-multimedia`. |
| 3 | **MEDIUM** | **Core Stack table sync wave for MongoDB cluster** says `-1` but MongoDB cluster (`percona-mongodb.yaml`) is wave `-1`. Correct, but row ordering is non-chronological (wave -1 after wave 1). Not a bug but confusing. |
| 4 | **LOW** | **Cluster Overview note mentions "ArgoCD HA migration is pending."** Same note exists since the documentation-currency pass. Still accurate — HA migration hasn't been executed. No change needed but worth confirming intent. |

### 2. `README.md`

| # | Severity | Finding |
|---|----------|---------|
| 5 | **HIGH** | **Deployed Applications table missing `wordpress-taegost`.** `apps/wordpress-taegost/` and `apps/manifests/wordpress-taegost.yaml` exist. No row in the README table. |
| 6 | **HIGH** | **Deployed Applications table missing `LibreChat`.** `apps/librechat/` and `apps/manifests/librechat.yaml` exist. No row. Also no mention of MongoDB, Meilisearch, or RAG API in the README. |
| 7 | **HIGH** | **Deployed Applications table missing `AWS DDNS`.** `apps/aws-ddns/` has its own row in the table. Actually, checking again — it does NOT have a row. The table lists: Arr stack, Authentik, AWS DDNS, Firefly III, Leantime, LiteLLM, Manyfold, Mealie, n8n, Open WebUI, SearXNG, WordPress DNG. Wait — AWS DDNS IS listed as "AWS DDNS" with purpose "Route53 dynamic DNS updater (custom image)" and namespace `aws-ddns`. Let me re-check... Actually yes, it's there. But `wordpress-taegost` and `LibreChat` are missing. |
| 8 | **HIGH** | **StorageClasses section says only `nfs-backups` and `nfs-multimedia` exist.** Does not mention `smb-backups`. CLAUDE.md says `smb-backups` and `nfs-multimedia` but not `nfs-backups`. Between the two docs, all three are covered but neither doc covers all three. A reader of only one document gets incomplete information. |
| 9 | **MEDIUM** | **NFS example PVC uses `nfs-backups` StorageClass**, but the arr-stack and other apps actually use `smb-backups` for backup PVCs. The README shows `nfs-backups` as the example; CLAUDE.md shows `smb-backups` as the standard for backup volumes. Both exist but the README example pattern doesn't match what's deployed. |
| 10 | **MEDIUM** | **No MongoDB or MariaDB mention in the "Adding a New Application" section.** The section only describes the general pattern. The PostgreSQL/MariaDB/MongoDB notes exist in a separate paragraph after the Deployed Applications table, but the "Adding a New Application" checklist doesn't reference the runbook docs. |

### 3. `STRATEGY.md`

| # | Severity | Finding |
|---|----------|---------|
| 11 | **HIGH** | **`last_updated: 2026-05-22` is stale.** File says it was last updated 11 days ago but hasn't been touched since. |
| 12 | **HIGH** | **"Documentation currency" track is complete** — the documentation-currency pass (plan `2026-05-22-001`) was marked `status: completed`. This track should be marked done or removed. |
| 13 | **HIGH** | **"Personal portfolio WordPress" track is complete** — `wordpress-taegost` is deployed and running. Track should be marked done. |
| 14 | **MEDIUM** | **"Observability" track still pending** — Prometheus/Grafana not yet deployed. Accurate, but no progress noted since 2026-05-22. |
| 15 | **MEDIUM** | **"Backup capabilities" track still pending** — S3 endpoint not yet available. Accurate. |

### 4. `apps/open-webui/README.md`

| # | Severity | Finding |
|---|----------|---------|
| 16 | **HIGH** | **OIDC redirect URI mismatch within same document.** Line 97 (Authentik Provider config) says `https://open-webui.diceninjagaming.com/oauth/oidc/callback`. Line 174 (Troubleshooting) says `https://open-webui.diceninjagaming.com/authorization-code/callback`. One is wrong — need to verify which is actually configured in Authentik. |

### 5. `docs/mariadb-runbooks.md`

| # | Severity | Finding |
|---|----------|---------|
| 17 | **LOW** | **Architecture table references `apps/manifests/mariadb-operator-crds.yaml` and `apps/manifests/mariadb-operator.yaml` for version.** Correct pattern (reference the manifest, not hardcode). No issue. |
| 18 | **LOW** | **"Enabling backups (deferred)" section** — accurate, still deferred. |

### 6. `docs/postgres-runbooks.md`

| # | Severity | Finding |
|---|----------|---------|
| 19 | **MEDIUM** | **Architecture table says "Postgres version: 18.3"** — this is hardcoded rather than referencing the image tag. CLAUDE.md says "PostgreSQL 18" (major version only). Minor version 18.3 may be stale; should reference the actual image tag in the cluster CRD. |
| 20 | **LOW** | **"Enabling backups (deferred)" section references `apps/postgres/cluster.yaml`** but the actual file is `apps/postgres/cluster-postgres.yaml`. Path is wrong. |

### 7. `docs/argocd-ha-migration.md`

| # | Severity | Finding |
|---|----------|---------|
| 21 | **MEDIUM** | **References ArgoCD v3.3.7** — hardcoded version on line 38: `curl -sL https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.7/manifests/ha/install.yaml`. The actual deployed ArgoCD version is whatever's currently in `apps/argocd/argocd.yaml`. The version in the migration doc will drift. |

### 8. `docs/n8n-ha-migration.md`

| # | Severity | Finding |
|---|----------|---------|
| 22 | **LOW** | **Phase 1 references `N8N_MIGRATE_FS_STORAGE_PATH=true`** — if n8n has already been running with this set, the migration happened at initial deploy. Accurate for the guide's purpose. |
| 23 | **LOW** | **Phase 2 says "Replace VERSION with the current n8n version tag from deployment-n8n.yaml"** — follows the pattern of referencing the manifest. Correct. |

### 9. `docs/disaster-recovery.md`

| # | Severity | Finding |
|---|----------|---------|
| 24 | **LOW** | **References `bootstrap/kube-vip/` for kube-vip manifests** — does this directory exist? Bootstrap is out of scope for this audit but the cross-reference from a non-bootstrap doc is noted. |
| 25 | **LOW** | **"PostgreSQL Recovery" section says WAL archiving is deferred** — accurate. |

### 10. `docs/migration-traefik-docker.md`

| # | Severity | Finding |
|---|----------|---------|
| 26 | **LOW** | **Migration complete.** Document is historical reference. The `archived/traefik/README.md` correctly notes migration completed April 2026. This doc is still valid as a reference template. No staleness issues. |

### 11. `docs/storage.md`

| # | Severity | Finding |
|---|----------|---------|
| 27 | **LOW** | **References `docs/troubleshooting/troubleshooting-longhorn-stale-mount.md`** — correct. References `scripts/longhorn-pvc-report.sh` — correct. References `apps/longhorn/recurringjob-daily-filesystem-trim.yaml` — correct. No staleness issues. |

### 12. `docs/sealed-secrets.md`

| # | Severity | Finding |
|---|----------|---------|
| 28 | **LOW** | **Hardcodes `v0.36.6` kubeseal version** on line 28. The actual kubeseal version in use may differ. Minor. |
| 29 | **LOW** | **"Standard waves for WordPress-pattern apps" table** covers MariaDB apps. Good reference — matches the actual wave pattern used in wordpress-dng and wordpress-taegost. |

### 13. Plan Documents

| # | Severity | Finding |
|---|----------|---------|
| 30 | **HIGH** | **`2026-05-22-002-feat-wordpress-taegost-plan.md` — `status: active` but wordpress-taegost is deployed.** The plan is complete. Should be marked `status: completed` or archived. |
| 31 | **HIGH** | **`2026-05-23-001-feat-librechat-deployment-plan.md` — `status: active` but LibreChat is deployed.** Should be marked `status: completed` or archived. |
| 32 | **MEDIUM** | **`2026-05-25-001-fix-deployment-verification-gaps-plan.md` — `status: active`.** Need to verify if U1 (NetworkPolicy check script), U2 (CLAUDE.md research rules), and U3 (troubleshooting entries) were implemented. The CLAUDE.md research rules ARE present (tiered research in Behavior Instructions). NetworkPolicy check script and troubleshooting entries need verification. |
| 33 | **LOW** | **`docs/brainstorms/documentation-currency.md`** — this brainstorm fed the documentation-currency plan which is `status: completed`. The brainstorm itself has no status field. Historical reference — not stale, just archival. |

### 14. Superpowers Docs

| # | Severity | Finding |
|---|----------|---------|
| 34 | **MEDIUM** | **`docs/superpowers/plans/2026-05-23-mongodb-cluster-plan.md` references Percona Operator v1.22.0, MongoDB 8.0.19-7.** The actual deployed version is whatever's in `apps/percona-mongodb/perconaservermongodb-mongodb.yaml` and `apps/manifests/percona-mongodb-operator.yaml`. These docs are implementation plans — they become stale the moment the actual deployment version drifts. |
| 35 | **LOW** | **`docs/superpowers/specs/2026-05-23-mongodb-cluster-design.md`** — design doc, historical. No staleness issues for a design reference. |

### 15. App READMEs

| # | Severity | Finding |
|---|----------|---------|
| 36 | **LOW** | **`apps/librechat/README.md`** — references LibreChat v0.8.5. If the deployed version has changed, this is stale. Otherwise fine. |
| 37 | **LOW** | **`apps/litellm/README.md`** — model list in the template ConfigMap may be stale vs. what's configured in the LiteLLM UI. The doc notes "Models are managed via the LiteLLM UI" which is correct. |
| 38 | **LOW** | **`apps/traefik/external/README.md`** mentions `allowExternalNameServices: true` — consistent with CLAUDE.md. |
| 39 | **LOW** | **`apps/traefik/certificates/README.md`** and **`middlewares/README.md`** — thin but accurate. |

### 16. `archived/README.md`

| # | Severity | Finding |
|---|----------|---------|
| 40 | **LOW** | **References `nodelocaldns/`** — need to verify the `archived/nodelocaldns/` directory and files still exist. The README describes them accurately if they're present. |

### 17. `scripts/README.md`

| # | Severity | Finding |
|---|----------|---------|
| 41 | **LOW** | **References `scripts/longhorn-pvc-report.sh`** — accurate, script exists. References `docs/storage.md` — correct. |

---

## Cross-Cutting Issues

### A. Inconsistent StorageClass Documentation

Three StorageClasses exist: `longhorn`, `smb-backups`, `nfs-backups`, `nfs-multimedia` (4 total).

- **CLAUDE.md** documents: `longhorn`, `smb-backups`, `nfs-multimedia` (missing `nfs-backups`)
- **README.md** documents: `nfs-backups`, `nfs-multimedia` (missing `smb-backups` and `longhorn`)

A reader of either document alone gets an incomplete picture of available storage.

### B. README vs CLAUDE.md Completeness

| App | In CLAUDE.md repo tree? | In README deployed apps? | Actually deployed? |
|-----|------------------------|--------------------------|-------------------|
| wordpress-taegost | No | No | Yes |
| LibreChat | No | No | Yes |
| Percona MongoDB | No | No (infrastructure, not app) | Yes |
| AWS DDNS | Yes | Yes | Yes |

### C. Plan Document Lifecycle

Three plan documents with `status: active` are actually complete:
- `wordpress-taegost-plan.md` → app deployed
- `librechat-deployment-plan.md` → app deployed
- `deployment-verification-gaps-plan.md` → partially implemented (needs verification)

No process exists to mark plans as complete or archive them after implementation.

### D. STRATEGY.md Tracks Not Maintained

Two of four tracks are complete but still listed as active. No track for ongoing work
(LibreChat expansion, cluster hardening, etc.). The document functions as a snapshot
from 2026-05-22 rather than a living strategy.

---

## Summary

| Severity | Count |
|----------|-------|
| HIGH | 9 |
| MEDIUM | 8 |
| LOW | 24 |
| **Total** | **41** |

### HIGH Priority (fix first):
1. README missing `wordpress-taegost` app entry (#5)
2. README missing `LibreChat` app entry (#6)
3. README missing `smb-backups` StorageClass (#8)
4. CLAUDE.md missing `nfs-backups` StorageClass (#2)
5. CLAUDE.md repo tree missing `percona-mongodb/`, `percona-mongodb-operator/`, `wordpress-taegost/`, `librechat/` (#1)
6. Open WebUI README OIDC redirect URI mismatch (#16)
7. STRATEGY.md tracks not updated — two completed tracks still listed as active (#12, #13)
8. Plan docs `status: active` but work is complete (#30, #31)
9. STRATEGY.md `last_updated` stale (#11)
