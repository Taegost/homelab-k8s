# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Agent Memory

### mex
An agent memory system that manages persistent context for AI agents working in a repository. Creates a structured `.mex/` scaffold with routing tables, conventions, design documents, and a decisions log. The tool provides drift checking to validate scaffold integrity.

### drift checker
A validation component that scans `.mex/` markdown files to detect missing or broken references. Reports a score (0-100) based on findings. The checker's assumptions about what backtick-wrapped strings represent may not hold for all repository types (see `docs/solutions/tooling-decisions/mex-checkpaths-false-positives.md`).

### scaffold
The structured set of files and directories that mex creates in `.mex/` to organize agent memory. Includes context files, routing tables, pattern templates, and event logs.

### context files
The markdown files in `.mex/context/` that hold domain knowledge — architecture, conventions, decisions, setup procedures, and technology stack. Each file has YAML frontmatter with triggers and edges for routing.
