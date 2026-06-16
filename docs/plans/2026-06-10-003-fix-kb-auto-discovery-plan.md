---
type: fix
status: active
created: 2026-06-10
origin: docs/plans/2026-06-10-002-feat-image-audit-skill-plan.md
notes: "U1 (auto-discovery + valkey alias) complete. U2 (capability-check.sh reads from KB) blocked by docs/plans/2026-06-10-001-feat-pre-commit-validation-scripts-plan.md U2."
---

# fix: KB Auto-Discovery, Valkey Alias, and Single Capability Source

## Summary

Fix three deferred findings from the image-audit skill implementation: make the audit script auto-discover KB entries instead of hardcoding a TYPE_TO_KB map, add `--type valkey` as an alias for redis, and make `capability-check.sh` read capability requirements from `docs/solutions/` KB files instead of hardcoding them — establishing a single source of truth for image capability requirements.

## Problem Frame

The image-audit script hardcodes a TYPE_TO_KB map that must be manually updated when adding new KB entries. Adding a new image type requires editing two files (KB entry + script map). The KB files already contain machine-parseable "Image patterns" sections — the script should read them directly.

The `--type` flag accepts `redis` but not `valkey`, even though the KB covers both. Users trying `--type valkey` get an error.

The planned `capability-check.sh` (from the pre-commit validation scripts plan, not yet implemented) will hardcode capability requirements for nginx and RabbitMQ. If those hardcoded lists diverge from the KB entries, the audit script recommends one set and pre-commit enforces another. The KB should be the single source of truth that both tools read.

## Requirements

- **R1:** Audit script auto-discovers KB entries by scanning `docs/solutions/` and parsing each file's "Image patterns" section — no manual TYPE_TO_KB map
- **R2:** `--type valkey` maps to the same KB as `--type redis`
- **R3:** `capability-check.sh` reads required capabilities from KB files instead of hardcoding them
- **R4:** Adding a new image type is a single-file operation (write the KB entry, nothing else)

## Key Technical Decisions

### KTD-1: Parse KB markdown with grep, not Python3

The "Image patterns" section uses a simple bullet-list format (`- \`pattern\``). Grep extraction is sufficient:

```bash
grep -A20 "^## Image patterns" "$KB_FILE" | grep -oP '`\K[^`]+'
```

This avoids a Python3 dependency for a simple text-extraction task. Each pattern is a shell-compatible substring (no regex needed — the patterns already work with `grep -qE` in the current script).

### KTD-2: KB capability tables use a parseable format

For `capability-check.sh` to read capability requirements from KB files, the "Required capabilities" table must be parseable. The existing markdown table format works if we extract the first column:

```bash
# Section-aware extraction: read from table header to next blank line or heading
awk '/^\| Capability \| Why \|/{flag=1; next} /^$|^## /{flag=0} flag' "$KB_FILE" \
  | grep -oP '^\| `\K[^`]+'
```

This extracts capability names (CHOWN, SETGID, etc.) from the markdown table without Python3. The script compares the extracted list against the Deployment's `capabilities.add` list.

### KTD-3: Auto-discovery runs at script startup

The audit script scans `docs/solutions/` once at startup, builds the pattern map in memory, and uses it for both interactive and non-interactive modes. Startup cost is negligible (< 10ms for 4 files).

## Implementation Units

### U1. Auto-discover KB entries and add valkey alias

**Goal:** Remove the hardcoded TYPE_TO_KB map. The script scans `docs/solutions/` at startup, parses "Image patterns" from each file, and builds the pattern map dynamically. Add `valkey` as a recognized type alias for the redis KB entry.

**Requirements:** R1, R2, R4.

**Dependencies:** None.

**Files:**
- `.claude/skills/homelab-image-audit/audit.sh` (modify)

**Approach:**

1. Replace the static TYPE_TO_KB map with a startup scan function:
   ```bash
   # Scan KB directory and build pattern → filename map.
   # Skip base-images-root-generic.md — its patterns are generic fallbacks
   # that would overwrite specific patterns if processed in arbitrary order.
   for kb_file in "$KB_DIR"/base-images-*.md; do
     [[ "$kb_file" == *"root-generic"* ]] && continue
     # Extract type name from filename: base-images-<type>.md
     type_name=$(basename "$kb_file" .md | sed 's/^base-images-//')
     TYPE_TO_KB["$type_name"]="$(basename "$kb_file")"
     # Parse Image patterns section for match substrings.
     # Uses awk for section-aware extraction (reads until next ## heading or EOF,
     # not fixed line count) and process substitution to avoid pipeline subshell
     # (which would lose associative array assignments).
     # Patterns containing * are stripped (grep -qF treats * as literal).
     while read -r pattern; do
       IMAGE_PATTERNS["$pattern"]="$type_name"
     done < <(awk '/^## Image patterns/{flag=1; next} /^## /{flag=0} flag' "$kb_file" \
       | grep -oP '`\K[^`]+' | sed 's/\*//g')
   done
   ```

   Also add explicit `valkey` and `redis` aliases so `--type valkey` and
   `--type redis` both resolve to the canonical `redis-valkey` type. Before the
   non-interactive `--type` check, add:
   ```bash
   declare -A TYPE_ALIASES
   TYPE_ALIASES[redis]="redis-valkey"
   TYPE_ALIASES[valkey]="redis-valkey"
   # Resolve alias before looking up KB file
   [[ -n "${TYPE_ALIASES[$TYPE]:-}" ]] && TYPE="${TYPE_ALIASES[$TYPE]}"
   ```

2. For valkey support: add `valkey` and `valkey:` to the redis KB entry's "Image patterns" section (already covered — the patterns include `valkey, valkey:`). The auto-discovery picks them up automatically.

3. Update the usage line to list `nginx|rabbitmq|redis|valkey|other`.

**Test scenarios:**
1. Run `audit.sh --image valkey:9.0-alpine --type valkey` → outputs redis/valkey KB entry (no capabilities required)
2. Run `audit.sh --image valkey:9.0-alpine --type redis` → same output (both types map to same KB)
3. Add a new KB file `base-images-postgres.md` with `## Image patterns` section → script picks it up at next run without any script changes
4. Interactive mode: enter `valkey:9.0-alpine` as image name → auto-detects as redis type

### U2. Make capability-check.sh read from KB

**Goal:** The planned `capability-check.sh` reads required capabilities from `docs/solutions/` KB files instead of hardcoding them.

**Requirements:** R3.

**Dependencies:** U1 (auto-discovery must work before capability-check can rely on it).

**Files:**
- `.claude/skills/homelab-validate/scripts/capability-check.sh` (modify the planned implementation — the script does not yet exist on disk, so this unit updates the plan in `docs/plans/2026-06-10-001-feat-pre-commit-validation-scripts-plan.md` to reference KB-based capability lookup)
- `docs/plans/2026-06-10-001-feat-pre-commit-validation-scripts-plan.md` (modify — update U2 capability-check.sh approach to reference KB)

**Approach:** Update the origin plan's U2 (capability-check.sh) approach to include KB-based capability lookup:

1. At startup, scan `docs/solutions/` for KB entries
2. For each Deployment, match the image against KB pattern lists (same auto-discovery as U1)
3. If matched, extract the required capabilities from the KB table using the grep pattern from KTD-2
4. Compare against the Deployment's `capabilities.add` list
5. If the KB file has no capability table (prose-only "None." like redis-valkey), required capabilities are an empty set — PASS if the deployment has no `capabilities.add` entries (or only the required set is empty)
6. FAIL if required capabilities are missing, PASS if all present

The KB becomes the single source of truth. The capability-check script no longer hardcodes nginx needs SETGID+SETUID+CHOWN — it reads it from `base-images-nginx.md`.

**Test scenarios:**
1. `capability-check.sh` run against `deployment-plane-admin.yaml` (has CHOWN, SETGID, SETUID) → PASS (matches nginx KB requirements)
2. Temporarily remove SETGID from plane-admin → FAIL (KB requires SETGID, deployment is missing it)
3. `capability-check.sh` run against `deployment-valkey.yaml` (drop: [ALL], no capabilities added) → PASS (KB has no capability table — empty required set, deployment correctly has no adds)
4. Add a new KB entry for PostgreSQL → `capability-check.sh` picks it up without code changes
5. KB entry missing "Required capabilities" section → script logs warning and skips that image type (no false FAIL)

## Verification

1. Run `audit.sh --image valkey:9.0-alpine --type valkey` → outputs redis/valkey KB
2. Add a test KB file, run `audit.sh` → script discovers it without modification
3. Read updated origin plan → capability-check.sh approach references KB-based lookup
4. Count hardcoded capability lists in the origin plan → zero (all moved to KB)
