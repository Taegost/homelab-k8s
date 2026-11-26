---
title: "feat: Enforce iocharset=utf8 on all SMB persistent volumes"
type: feat
date: 2026-11-25
---

# feat: Enforce iocharset=utf8 on all SMB persistent volumes

## Summary

Add `iocharset=utf8` to every place SMB mount options are defined in git — the `smb-backups` StorageClass and the two static SMB PVs (`manyfold-libraries`, `arr-stack-multimedia`) — enforce the option with a new pre-commit check and document it as a repo standard. The static PV mounts pick the option up when nodes reboot for routine maintenance; dynamically provisioned PVs inherit it at future provisioning time. No live-cluster mutation commands.

---

## Problem Frame

The operator directed that every SMB persistent volume must mount with `iocharset=utf8`, as a standing repo standard. Mount options are defined in exactly three git-managed places (the StorageClass and two static PVs). The static PVs are git-managed, so ArgoCD updates them in place; a node reboot then restages their mounts with the new options. Dynamically provisioned PVs carry options baked at CSI `NodeStageVolume` time, do not retroactively inherit StorageClass changes, and are outside this change's live scope (Problem Frame.D2). The change has a git half and an enforcement half; the remount rides routine maintenance.

#### Problem Frame.D1. No charset rationale in the plan, manifests, or docs
**Decision:** The option is required by operator directive; no kernel-charset rationale (nls_default, iso8859-1, filename mangling) appears in the plan, manifest comments, or docs.
**Why:** The operator stated the justification is "because I said so" and directed removal of all references to the researched rationale.
**Source:** user, 2026-11-25 plan review menu

#### Problem Frame.D2. Dynamic PVs excluded from live migration; reboot applies the change
**Decision:** The live remount covers only the two static PVs, delivered by node reboots during routine maintenance; the seven Bound dynamic SMB PVs keep their current options until naturally reprovisioned.
**Why:** The operator scoped the dynamic volumes out — they receive the standard as a forward-looking convention, and any downstream risk from their old options is explicitly accepted.
**Source:** user, 2026-11-25 "the dynamic ones aren't a problem... they do not need to be recreated as part of this. I am fine with any risks down the road coming from this decision"

---

## Requirements

**Manifests**

- R1. `apps/infrastructure/storage/storageclass-smb-backups.yaml` includes `iocharset=utf8` in its top-level `mountOptions` (StorageClass field, not under `spec`); `apps/manyfold/persistentvolume-manyfold-libraries.yaml` and `apps/arr-stack/persistentvolume-arr-stack-multimedia.yaml` include it in `spec.mountOptions`.
- R2. Every future dynamically provisioned SMB PV inherits `iocharset=utf8` from its StorageClass (consequence of R1, no separate manifest).

**Enforcement**

- R3. A new pre-commit check blocks any commit staging an SMB StorageClass (`provisioner: smb.csi.k8s.io`) or SMB PV (`csi.driver: smb.csi.k8s.io`) that lacks `iocharset=utf8` in its mount options; non-SMB storage manifests are not flagged.
- R4. `CLAUDE.md` (pre-commit table, conditional-check list, Storage section) and `docs/storage.md` document the standard; `docs/solutions/tooling-decisions/pre-commit-validation-suite.md` reflects 12 checks instead of 11; `.claude/skills/homelab-validate/SKILL.md` documents every check with name-keyed sections and no check counts or ordinals (per U3.D3).

#### Requirements.D1. R4 names SKILL.md as a documentation target
**Decision:** R4's documentation file list includes `.claude/skills/homelab-validate/SKILL.md` (every check documented, name-keyed sections, no counts or ordinals).
**Why:** U3's Files list includes SKILL.md per U3.D1/U3.D3, but R4 named only three docs — the unit's fourth file had no covering requirement, breaking requirement-to-unit traceability.
**Source:** review agent Coherence, 2026-11-25 auto-applied (round 2 safe_auto pass)

**Live cluster**

- R5. After a full round of node reboots, every workload mounting a static SMB PV (arr-stack: bazarr, radarr, sonarr, whisparr on `multimedia`; manyfold on `manyfold-libraries`) shows `iocharset=utf8` in `/proc/mounts` inside the container.
- R6. No manual cluster mutation: the migration is a git merge, ArgoCD sync, and the operator's routine node reboots; verification is read-only (`kubectl get pv`, `kubectl exec` reading `/proc/mounts`) (user-directed: GitOps repo — no kubectl patching, no scale-to-zero).

---

## Key Technical Decisions

- **Set the option at the definition sites, not in the driver.** The csi-driver-smb Helm chart exposes no global `mountOptions` default; the StorageClass (dynamic provisioning) and the two static PV specs are the only authoritative surfaces. Mirrors how `noserverino` and the uid/gid options are already managed.
- **Apply existing static volumes via ArgoCD sync + node reboot** (amended by KTD.D1 — GitOps-only migration). Mount options are baked at CSI `NodeStageVolume` time; a StorageClass edit or `rollout restart` alone can reuse the cached staging, and ArgoCD triggers no rollouts for PV-object changes. A node reboot clears every staged mount on that node, so pods restage reading the PV's current mountOptions — the two git-managed static PVs pick up `iocharset=utf8` from the synced git state with zero manual commands. Dynamic PVs are out of live scope (Problem Frame.D2).
- **Enforcement as conditional pre-commit check #12** (`smb-iocharset-check.sh`), firing when `storageclass` or `persistentvolume` files are staged — same pattern as the Longhorn fsGroup and NetworkPolicy checks. User chose pre-commit check *and* doc standard. Bound by Problem Frame.D1 (no charset rationale anywhere, user constraint).

#### KTD.D1. Migration is GitOps-only: sync plus node reboot
**Decision:** The migration mechanism is a git merge, ArgoCD sync of the StorageClass and the two static PVs, and node reboots during routine maintenance — replacing the earlier patch-and-scale-to-zero design; no kubectl patching and no scale-to-zero.
**Why:** The operator directed that a GitOps repo follows GitOps practices end to end. Verified research (ArgoCD auto-sync docs; Kubernetes Deployment and PersistentVolume docs) showed ArgoCD applies git↔live diffs only to tracked resources, restarts no pods for PV-object changes, cannot reach dynamic PVs, and its self-heal reverts live drift within ~5 seconds — while a reboot restages all mounts natively.
**Source:** user, 2026-11-25 "We are NOT doing any manual patching, and scaling down to zero is not acceptable. This is a gitops repo and everything should follow those practices"

---

## Scope Boundaries

- NFS classes (`nfs-backups` and its mount options) are untouched — user scoped this to SMB.
- csi-driver-smb Helm values are untouched (no global default exists there anyway).
- No data migration: the option changes mount behavior only; Unraid-side data is untouched.
- The seven Bound dynamic SMB PVs are excluded from live migration — they keep their current options until naturally reprovisioned (Problem Frame.D2).
- seerr, manyfold-redis, neutarr, prowlarr, and mealie mount no static SMB PV and are excluded from the verification set — neutarr's, prowlarr's, and mealie's only SMB volumes are dynamic (Problem Frame.D2).

---

## Implementation Units

### U1. Add `iocharset=utf8` to the three git definitions

**Goal:** Every git-managed SMB mount surface sets `iocharset=utf8`.
**Requirements:** R1, R2
**Files:**
- `apps/infrastructure/storage/storageclass-smb-backups.yaml`
- `apps/manyfold/persistentvolume-manyfold-libraries.yaml`
- `apps/arr-stack/persistentvolume-arr-stack-multimedia.yaml`
**Approach:** Append `iocharset=utf8` to each file's mount options — top-level `mountOptions` on the StorageClass, `spec.mountOptions` on the two PVs (U1.D1) — no rationale comment (bound by Problem Frame.D1). New PVCs against `smb-backups` then inherit the option at provision time.
**Test scenarios:** none — pure manifest addition with no behavioral surface testable in the repo; correctness is verified in U4 (live mount check) and guarded by U2.
**Verification:** `grep -rn "iocharset=utf8" apps/infrastructure/storage/ apps/manyfold/ apps/arr-stack/persistentvolume-arr-stack-multimedia.yaml` returns three hits; a fresh `smb-backups` PVC would provision with the option.

#### U1.D1. Field path corrected per object kind
**Decision:** R1 and U1 name the mount-options field path per object — top-level `mountOptions` on the StorageClass, `spec.mountOptions` on the two PVs.
**Why:** On a StorageClass the field is top-level; the earlier blanket "spec.mountOptions" wording would lead an implementer to nest it under `spec`, where it silently does nothing.
**Source:** user, 2026-11-25 approved review agent Feasibility's proposal

### U2. Pre-commit check #12: `smb-iocharset-check.sh`

**Goal:** Commits cannot introduce or modify an SMB StorageClass/PV missing `iocharset=utf8`.
**Requirements:** R3
**Dependencies:** U1 (the three definitions must pass the new check when staged together).
**Files:**
- `.claude/skills/homelab-validate/scripts/smb-iocharset-check.sh` (new)
- `.githooks/pre-commit` (wire in as check 12, renumber the `[N/11]` labels to `[N/12]`)
**Approach:** Mirror the staged-file grep style of `longhorn-fsgroup-check.sh`: scan staged YAML for `provisioner: smb.csi.k8s.io` or `driver: smb.csi.k8s.io`; for each hit, require `iocharset=utf8` within the kind-correct mount-options block — top-level `mountOptions` for a StorageClass, `spec.mountOptions` for a PV (U1.D1). Fire conditionally when staged filenames match `storageclass` or `persistentvolume` (covers `.git/hooks` gating the same way checks 4/5/8 do). Non-SMB storage manifests exit PASS without flagging.
**Patterns to follow:** `.claude/skills/homelab-validate/scripts/longhorn-fsgroup-check.sh` (staged-file selection, FAIL/PASS output, failure counter, process-substitution loop).
**Test scenarios:**
- Happy path: staged StorageClass with `smb.csi.k8s.io` and `iocharset=utf8` present → PASS.
- Failure: staged StorageClass or PV with `smb.csi.k8s.io` and no `iocharset=utf8` → FAIL naming the file.
- Negative match: staged `storageclass-nfs-backups.yaml` change → not flagged (no SMB driver match).
- Skip path: commit touching only Deployment/IngressRoute YAML → check reports SKIP (conditional gate).
- Placement failure (StorageClass): staged StorageClass with `iocharset=utf8` nested under `spec.mountOptions` instead of top-level → FAIL naming the file.
- Placement failure (PV): staged PV with `iocharset=utf8` at top level instead of `spec.mountOptions` → FAIL naming the file.
**Verification:** Stage a deliberate no-iocharset copy of the smb StorageClass and confirm the hook blocks the commit; unstage and confirm the real files commit cleanly.

#### U2.D1. Check enforces the kind-correct mount-options field path
**Decision:** The check requires `iocharset=utf8` within the kind-correct block — top-level `mountOptions` for a StorageClass, `spec.mountOptions` for a PV — and the test scenarios cover both misplacements.
**Why:** A blanket `mountOptions` match would pass a StorageClass with the option nested under `spec`, where it silently does nothing; U1.D1's field-path split only holds if the check enforces it.
**Source:** user, 2026-11-25 approved review agent Test-documentation's proposal

### U3. Document the standard

**Goal:** The repo's docs state the SMB `iocharset=utf8` standard and describe the 12th check.
**Requirements:** R4
**Dependencies:** U2 (check name/number must exist before documenting).
**Files:**
- `CLAUDE.md` — add table row `| SMB iocharset | smb-iocharset-check.sh | SMB StorageClass/PV missing iocharset=utf8 in mountOptions |`, extend the conditional-check sentence in Pre-Commit Verification, add a bullet under Storage → SMB CSI Driver.
- `docs/storage.md` — new "SMB mounts" section: the standard statement and the recipe for picking up new SMB mount options on git-managed static PVs (sync the git change, reboot the node, verify `/proc/mounts`), plus one sentence noting dynamically provisioned volumes pick up new mount options only at reprovision time (Problem Frame.D2). The exact current-cluster flow lives in U4; docs/storage.md gets the reusable general form. No charset rationale (bound by Problem Frame.D1).
- `docs/solutions/tooling-decisions/pre-commit-validation-suite.md` — retitle to 12 checks, add the row to the conditional table, add script to the manual-invocation list.
- `.claude/skills/homelab-validate/SKILL.md` — full alignment (U3.D3): document every check in the suite including `smb-iocharset-check.sh` (what it catches, conditional-fire note for staged `storageclass`/`persistentvolume` files), with name-keyed sections and no check counts or ordinals anywhere in the skill file.
**Test scenarios:** none — documentation only.
**Verification:** All four docs mention `iocharset=utf8`; the solutions doc's count claims now say 12 (title and "The 11 checks" section), and its conditional table gains the check-12 row.

#### U3.D1. SKILL.md added to U3 scope
**Decision:** U3 also updates `.claude/skills/homelab-validate/SKILL.md` (manual-invocation list + new check section).
**Why:** Without it, the `/homelab-validate` skill doc would still describe 10 checks while the solutions doc says 12 — doc drift the suite's learning doc exists to prevent.
**Source:** user, 2026-11-25 approved review agent Documentation's proposal

#### U3.D2. Verification criterion scoped to count claims
**Decision:** U3's verification targets suite-count claims (title, "The 11 checks" section, new table row) instead of "no '11' anywhere".
**Why:** The literal criterion could never pass — the conditional table legitimately retains row 11 (Env Injection), and renumbering stable check IDs would break the `[N/12]` hook labels.
**Source:** user, 2026-11-25 approved review agent Coherence's proposal

#### U3.D3. SKILL.md carries no check counts or ordinals
**Decision:** SKILL.md documents all checks with name-keyed sections — no numeric check count and no ordinal numbering anywhere in the skill file; the solutions doc keeps its count claims.
**Why:** The count changes with every added check and adds no value; a hard number would force a doc edit on every suite change.
**Source:** user, 2026-11-25 "leave the exact number of checks out of the skill. That is a number that will be constantly changing and it should not require a 'code change' because of a count that doesn't add any value"

#### U3.D4. storage.md recipe scoped to static PVs
**Decision:** The docs/storage.md recipe covers git-managed static PVs only, with one sentence stating dynamically provisioned volumes pick up new mount options only at reprovision time (Problem Frame.D2).
**Why:** A generic "pre-existing volumes" recipe would read as covering the seven Bound dynamic SMB PVs, whose options cannot change without reprovision — the doc would promise a flow that does not exist for them.
**Source:** user, 2026-11-25 approved review agent Coherence's proposal

### U4. Restage static SMB mounts via node reboot

**Goal:** The two static SMB PVs' mounts come back with `iocharset=utf8` after routine node reboots.
**Requirements:** R5, R6
**Dependencies:** U1 merged and ArgoCD synced first, so the live static PV objects already carry the option before any node reboots.
**Files:** none (git-side changes are U1; reboots are operator maintenance; the reusable general recipe lands in `docs/storage.md` via U3).
**Approach:** Merge U1 and confirm ArgoCD synced the StorageClass and both static PVs (read-only check below). From that point, each node that reboots — routine maintenance or otherwise — restages every SMB mount it hosts using the PV's current mountOptions. After all nodes have rebooted once, verify from inside each consuming workload. A pod that rescheduled onto a not-yet-rebooted node in the window shows old options until that node reboots; the final verification catches it.

```bash
# 1. After ArgoCD sync — both static PVs must list iocharset=utf8 (read-only).
kubectl get pv arr-stack-multimedia manyfold-libraries -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.mountOptions}{"\n"}{end}'

# 2. Reboot nodes during routine maintenance (operator-driven; the cadence is
#    the maintenance window's, not this plan's).

# 3. After all nodes have rebooted once — every line must print iocharset=utf8.
#    If a container lacks grep, swap in 'cat /proc/mounts'.
for d in bazarr radarr sonarr whisparr; do echo "== $d"; kubectl exec -n arr-stack deploy/$d -- grep cifs /proc/mounts | grep -o 'iocharset=[a-z0-9]*' | sort -u; done
echo "== manyfold"; kubectl exec -n manyfold deploy/manyfold -- grep cifs /proc/mounts | grep -o 'iocharset=[a-z0-9]*' | sort -u
```

**Test scenarios:** none — operational migration; step 3 is the pass/fail check.
**Verification:** Step 3 prints `iocharset=utf8` for all five workloads; pods Running with no CrashLoopBackOff.

#### U4.D1. Unit rewritten under GitOps-only migration
**Decision:** U4 is the sync-and-reboot flow above, replacing the earlier kubectl patch loop, scale-to-zero restage, and all-eight-workload verification.
**Why:** Bound by KTD.D1 (GitOps-only migration, user directive) — reboots deliver the restage; mealie leaves the verification set because its only SMB volume is dynamic (Problem Frame.D2).
**Source:** user, 2026-11-25 "We'll go with just the update and then rebooting the nodes for maintenance"

#### U4.D2. Verification set corrected to five workloads
**Decision:** The verification set is five workloads — bazarr, radarr, sonarr, whisparr on `multimedia`, plus manyfold on `manyfold-libraries`; neutarr and prowlarr join the excluded set.
**Why:** Repo grep shows exactly four deployments reference the `multimedia` PVC, and live `/proc/mounts` shows neutarr and prowlarr mount only their dynamic `smb-backups` volumes — the seven-workload loop could never pass step 3 for them.
**Source:** user, 2026-11-25 approved review agent Feasibility's proposal

---

## Risks & Dependencies

- **`nls_utf8` kernel module missing on a node** would fail the remount: if mounts fail after a reboot, check `modinfo nls_utf8` on that node (Ubuntu typically ships it built-in or autoloadable), then fix forward — there is no rollback path (Risks.D2).
- **Residual, accepted: dynamic SMB PVs keep their current options** until naturally reprovisioned — recorded and accepted in Problem Frame.D2.
- **Reboot-ordering window:** a pod that reschedules onto a not-yet-rebooted node after the ArgoCD sync mounts with the old options until that node reboots; U4 step 3 detects it.

#### ~~Risks.D1. Risk set rewritten under GitOps-only migration~~
**Status:** superseded by Risks.D2 — the rollback item is removed; the `nls_utf8`, dynamic-residual, and reboot-ordering items stand.
**Decision:** The patch-rejection, self-heal-race, unstage-race, and downtime-window risks are deleted (no patching, no scale-to-zero, a reboot is a full unstage); rollback, the `nls_utf8` check, the accepted dynamic-PV residual, and a reboot-ordering window replace them.
**Why:** The earlier bullets described the patch-and-restage design the operator rejected; this set covers the actual sync-and-reboot flow (KTD.D1).
**Source:** user, 2026-11-25 "We are NOT doing any manual patching, and scaling down to zero is not acceptable"

#### Risks.D2. No rollback path — fail-forward only
**Decision:** The plan carries no rollback procedure; the Rollback bullet is deleted and the `nls_utf8` risk closes with a fix-forward step instead. Any failure is handled by diagnosing, correcting in git, syncing, and rebooting again.
**Why:** The operator directed there is no rollback for this change, only fail-forward; reboots are routine maintenance, so a forward fix rides the same mechanism that applied the change.
**Source:** user, 2026-11-25 "There is no rollback for this, only fail-forward"

---

## Sources & Research

- `apps/infrastructure/storage/storageclass-smb-backups.yaml`, `apps/manyfold/persistentvolume-manyfold-libraries.yaml`, `apps/arr-stack/persistentvolume-arr-stack-multimedia.yaml` — current mount option sets.
- `.claude/skills/homelab-validate/scripts/longhorn-fsgroup-check.sh` and `.githooks/pre-commit` — check-script pattern and conditional wiring.
- `docs/solutions/tooling-decisions/pre-commit-validation-suite.md` — existing 11-check suite this extends.
- ArgoCD auto-sync and self-heal behavior — https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/ (verified 2026-11-25: automated sync applies git↔live diffs to tracked resources only; self-heal reverts live drift after a 5-second default timeout).
- Kubernetes PersistentVolume mount options — https://kubernetes.io/docs/concepts/storage/persistent-volumes/#mount-options and the PV API reference (verified 2026-11-25: mount options apply when the volume is mounted on a node; the API does not validate them).
