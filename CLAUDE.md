# CLAUDE.md — homelab-k8s

## Non-Negotiables

- **Never commit plaintext secrets** — no exceptions.
- **`HOMELAB_ALLOW_LATEST` and `HOMELAB_ALLOW_MAIN`** are for the human operator only. Claude must never set them.
- **Never use `git commit --amend`** — it rewrites the commit hash, causing merge conflicts. Always create a normal commit.
- **Pre-commit hook setup** (one-time per clone):
  ```bash
  ln -sf ../../.githooks/pre-commit .git/hooks/pre-commit
  ```

## Navigation

At the start of every session, read `.mex/ROUTER.md` before doing anything else. Its routing table entries are mandatory pre-action reads — before implementing any change, load the relevant context file.

docs/solutions/  # documented solutions to past problems (bugs, best practices, workflow patterns), organized by category with YAML frontmatter (module, tags, problem_type)
CONCEPTS.md  # shared domain vocabulary (entities, named processes, status concepts) — relevant when orienting to the codebase or discussing domain concepts

## Reference

The original 752-line CLAUDE.md is preserved at `CLAUDE.md.pre-mex` during the mex migration period. Delete it after the migration is verified and stable.
