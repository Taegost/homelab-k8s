# Honcho Deployment Gotchas — Blog Post Notes

Raw material for a blog post on deploying Honcho (AI memory backend) into a
Kubernetes homelab. Each gotcha is a "this should have been simple but wasn't"
moment.

---

## Gotcha 1: CNPG password reconciliation

**What we expected:** Recreate the SealedSecret, CNPG picks up the new password.
**What happened:** CNPG didn't reconcile the role password after the secret was
recreated. Had to manually `ALTER ROLE honcho PASSWORD` on the primary pod.
**Time wasted:** ~20 minutes
**Lesson:** CNPG's password reconciliation isn't always automatic. Verify with
`psql -U postgres -c "\du"` after re-sealing.

---

## Gotcha 2: pgvector requires superuser

**What we expected:** `CREATE EXTENSION IF NOT EXISTS vector` works for any role.
**What happened:** The `honcho` role isn't a superuser (by design). Had to exec
into the Postgres primary as `postgres` superuser to create the extension.
**Time wasted:** ~10 minutes
**Lesson:** PostgreSQL extensions that modify system catalogs require superuser.
Pre-create them before the app starts.

---

## Gotcha 3: tiktoken downloads blocked by NetworkPolicy

**What we expected:** tiktoken works out of the box.
**What happened:** tiktoken downloads tokenizer files from Azure Blob Storage on
first use. NetworkPolicy blocks external HTTPS. Pod crashes on startup.
**Time wasted:** ~30 minutes
**Solution:** Pre-download tokenizer files into a Longhorn RWM PVC and set
`TIKTOKEN_CACHE_DIR`.

---

## Gotcha 4: tiktoken caches by SHA-1 hash, not filename

**What we expected:** Copy `o200k_base.tiktoken` into the cache, done.
**What happened:** tiktoken looks up files by SHA-1 hash of the download URL
(`fb374d419588a4632f3f557e76b4b70aebbca790`), not the original filename. The
file sat there unused.
**Time wasted:** ~15 minutes
**Lesson:** Always check the tiktoken source code for the cache key format.

---

## Gotcha 5: pgvector HNSW 2000-dimension limit

**What we expected:** Use `text-embedding-3-large` (3072 dimensions) for best
quality.
**What happened:** pgvector's HNSW index has a hard 2000-dimension limit for the
`vector` type. The 3072-dimension embedding failed at index creation.
**Time wasted:** ~45 minutes (including trying `configure_embeddings.py` which
partially failed)
**Solution:** Switched to `text-embedding-3-small` (1536 dimensions). Documented
the limitation and alternatives (halfvec, sequential scan, MRL truncation).

---

## Gotcha 6: JWT uses custom claims, not standard sub/iat/exp

**What we expected:** Standard JWT claims (`sub`, `iat`, `exp`) work for Honcho
auth.
**What happened:** Honcho uses custom claims (`ad`, `t`, `w`, `p`, `s`).
Including `exp` causes a catch-22: PyJWT validates it as a Unix timestamp, but
Honcho's `parse_datetime_iso` expects ISO 8601. No single format works.
**Time wasted:** ~45 minutes across 5 iterations
**Solution:** Use Honcho's built-in `scripts/generate_jwt.py` script. It was in
the README the whole time.

---

## Gotcha 7: Hand-rolling JWTs when an official script exists

**What we expected:** We can generate a JWT with Python's `jwt.encode()`.
**What happened:** Manual base64url encoding produced different JSON serialization
(spaces after colons) than PyJWT's compact JSON, causing signature mismatches.
Five iterations of "fix one thing, break another."
**Time wasted:** ~30 minutes
**Lesson:** Check the project's README for CLI tools before hand-rolling
anything. This became a documented best practice:
`docs/solutions/best-practices/research-official-tools-before-implementing.md`

---

## Gotcha 8: Dialectic model config is separate from LLM config

**What we expected:** `LLM_OPENAI_MODEL` controls all LLM calls.
**What happened:** Honcho's dialectic feature (dream, deduction, induction) has
its own model config per level (minimal, low, medium, high, max), hardcoded to
`gpt-5.4-mini` hitting OpenAI directly. NetworkPolicy blocks that.
**Time wasted:** ~15 minutes
**Solution:** Override all five levels via `DIALECTIC_LEVELS__<level>__MODEL_CONFIG__*`
env vars to route through LiteLLM.

---

## Gotcha 9: openai/ prefix breaks tiktoken model lookup

**What we expected:** Setting `EMBEDDING_MODEL_CONFIG__MODEL: "openai/text-embedding-3-small"`
works because that's the LiteLLM model name.
**What happened:** Honcho passes the model name directly to tiktoken for
tokenization. tiktoken doesn't understand the `openai/` prefix and throws
`KeyError: 'Could not automatically map openai/text-embedding-3-small to a tokeniser.'`
**Time wasted:** ~10 minutes
**Solution:** Use `text-embedding-3-small` (without prefix) for the embedding
model. The `openai/` prefix is a LiteLLM routing convention, not a model name.

---

## Gotcha 10: Two tokenizer files needed, not one

**What we expected:** Cache `o200k_base.tiktoken` and we're done.
**What happened:** `text-embedding-3-small` uses `cl100k_base.tiktoken`, not
`o200k_base.tiktoken`. We only cached the wrong one.
**Time wasted:** ~5 minutes
**Lesson:** Check which tokenizer each model uses. Different models, different
files.

---

## Gotcha 11: MetalLB L2 hairpin breaks egress to LoadBalancer services

**What we expected:** NetworkPolicy egress rule allowing traffic to the MetalLB
IP (`192.168.5.202/32:443`) lets Honcho reach LiteLLM via the external domain.
**What happened:** `ECONNREFUSED` — the pod can't hairpin back to a LoadBalancer
IP on the same node. MetalLB L2 mode bypasses kube-proxy's iptables chains,
so the egress rule is never evaluated.
**Time wasted:** ~20 minutes
**Solution:** Replace `ipBlock` with `namespaceSelector` targeting the `traefik`
namespace. kube-proxy routes internally via ClusterIP, bypassing the hairpin.

---

## Summary stats

| Metric | Value |
|---|---|
| Total troubleshooting time | ~4 hours |
| Gotchas that could have been avoided by reading docs first | 4 (6, 7, 8, 9) |
| Gotchas that are genuine Kubernetes/NetworkPolicy edge cases | 5 (3, 4, 5, 10, 11) |
| Gotchas that are operator bugs | 1 (1) |
| Gotchas that are PostgreSQL limitations | 1 (2) |

The punchline: almost half the time was spent on problems the project's own
documentation already solved.
