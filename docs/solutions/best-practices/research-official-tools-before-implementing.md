---
module: general
tags: [process, research, integration, cli]
problem_type: best-practice
---

# Research official tools before implementing

## Problem

When integrating with a third-party tool, it's tempting to read the source code
and reverse-engineer the expected format. This leads to iterative troubleshooting
that wastes time on problems the project already solved.

## What happened

Integrating Hermes with Honcho required generating a JWT for API authentication.
Instead of checking Honcho's documentation first, the implementation:

1. Guessed standard JWT claims (`sub`, `iat`, `exp`) would work — wrong
2. Changed `exp` to ISO 8601 format — wrong
3. Switched to custom claims (`ad`, `t`) with manual base64 encoding — wrong
4. Switched to PyJWT's `jwt.encode()` — still wrong (JSON serialization mismatch)
5. Only found the answer after checking the repo README

Five iterations across an hour. The answer was in the README the whole time:
Honcho ships `scripts/generate_jwt.py` in the container that handles everything.

## Root cause

The project's CLAUDE.md says "Research before suggesting" and "Always check
latest docs before writing any manifest, CRD, or Helm values." Both were
skipped. The implementation was treated as something to figure out from source
code rather than something to look up in documentation.

## Solution

**Before implementing any integration with a third-party tool:**

1. **Check the project's README** — most projects document CLI scripts,
   configuration guides, and recommended workflows
2. **Check for CLI tools or scripts** — look for `scripts/`, `bin/`, or
   `--help` output in the container image before hand-rolling solutions
3. **Check the official docs site** — READMEs are often incomplete; the docs
   site may have dedicated pages for the feature you need
4. **Only read source code as a last resort** — when docs are silent or
   ambiguous, source code fills gaps. But docs-first catches pre-built tools
   that source code alone won't surface

## Verification

Before starting implementation, ask: "Does this project already have a tool
or documented process for this?" If the answer is yes, use it. If uncertain,
check before writing code.

## References

- This pattern was identified during Hermes-Honcho JWT integration
  (2026-06-24). The Honcho GitHub README documents `scripts/generate_jwt.py`
  under "Minting JWT Tokens".
