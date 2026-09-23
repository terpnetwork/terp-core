# Contributing to terp-core

This is the workspace standard. Read it before adding CI, a second copy of a
dependency, or a new document.

## Maintainability — Anti-Entropy Rules

## Working Style

- Push back on genuinely bad ideas, with reasoning. Point out bugs, misleading names,
  and better approaches when you see them. Direct but collaborative.
- If requirements are ambiguous or a design decision could reasonably go multiple ways,
  ask rather than guess. A quick question is cheaper than reworking a wrong assumption.
- **If a prompt looks damaged or wrong, STOP and say so** — truncated mid-sentence,
  duplicated blocks, garbled copy/paste, references to context that doesn't exist, or
  instructions that contradict prior decisions without acknowledging they do. Do not
  execute a best-guess reconstruction. A mangled prompt executed faithfully is worse
  than a delay.
- **Decisions live in the repo, not in chat.** When a ruling or plan change arrives
  mid-session, write it into the durable work file (progress notes, this file, the
  relevant spec) and commit before executing it. If the session ended the moment
  after the message was read, the repo alone must be enough to act on it.


A codebase built fast rots in predictable ways. These rules stop each one.

**One way to do each thing.**
- Before writing any function, component, or pattern, search for an existing one that
  does the job. Extend or reuse it; never write a parallel implementation.
- Finding two near-duplicates makes unifying them part of the current task, not a
  someday-cleanup.
- One canonical name per domain concept, everywhere. Never introduce a synonym for an
  existing concept; a new concept gets a named type in the core layer first.
- Constants and magic values have one home. Repeating a literal is a bug waiting to
  desynchronize.
- The same goes for every shared surface, not just literals: option lists, validation
  bounds, schemas, vocabularies. Define once; every consumer imports or composes it.
  A second dialog, boundary, or validator must never restate its own copy — even a
  copy that looks locally complete will silently drift.

**Delete, don't deprecate.**
- When a project has no external consumers of an interface, changing it means
  updating every call site in the same commit — no compatibility shims, re-export
  layers, or deprecation markers.
- Replaced code is removed in the commit that replaces it. No commented-out blocks,
  no unused exports, no `-old`/`-v2` files. Version control history is the archive.

**No premature abstraction.**
- Write the concrete version first. Extract an abstraction only when the second real
  use exists — not when you predict one. Interfaces with one implementation,
  factories, managers, and generic parameters "for flexibility" are slop.
- No configuration options, feature flags, or fallback paths nothing uses. Every
  branch must be reachable by a real requirement.

**Type honesty.**
- Escape hatches that silence the type system (`any`, unchecked casts, non-null
  assertions, `unsafe`) are forbidden or require a comment stating why they're safe.
  Prefer type guards and schema-validated parsing at boundaries. Silencing the
  checker is hiding a bug.

**Comments.**
- Comments state invariants, constraints, and non-obvious *why* — never *what* the
  next line does, never narration, never history (that's the commit message). Most
  code should need no comments because the names carry the meaning.

**Files and structure.**
- When a file grows past a few hundred lines, look for the module boundary trying to
  get out — but don't shatter code into fragments either; a file holds one coherent
  concern.
- Respect the project's dependency direction (e.g. UI depends on core, never the
  reverse; core stays free of platform concerns).
- Import from the defining module; avoid barrel/re-export layers that hide structure
  and breed cycles.
- No ad-hoc documentation litter: durable docs live in the designated docs location,
  working state in the designated progress file. No scratch SUMMARY/NOTES/PLAN files.

**Consistency beats local taste.**
- Before writing in any area, read the neighboring code and match its patterns. If a
  pattern deserves changing, change it everywhere in a dedicated refactor commit —
  never fork a second style alongside the first.

**Gardening is part of every milestone.**
- A milestone isn't done until: no dead code, no known duplicated logic, no lint
  suppressions without justification, sane file sizes, dependency rules passing.
  Entropy is removed on the spot, not logged for later.

## Style

- **Naming**: clear, descriptive names that read as plain English —
  `remainingAttempts` over `rem`, `decodeStemFile()` over `procF()`. Abbreviations
  only when universally understood (`id`, `url`, `config`).
- **Functional style**: prefer map/filter/reduce or iterator chains over manual loops
  with mutable accumulators when they make intent clearer. Don't force it when a loop
  reads better (hot paths often should be plain loops with no per-iteration
  allocation).
- **No incomplete code**: no TODO stubs or placeholder implementations. Every piece
  of code ships complete and functional. If a task is too large, discuss scope
  reduction rather than writing skeleton code.

## Commits

Make clear, atomic commits for every logical unit of work. Don't batch unrelated
changes.

- Start the message with a verb: Add, Fix, Update, Remove, Refactor.
- Be concise but specific: `Add onset envelope to modulation sources`, not
  `Update code`.
- Commit before moving on to the next task.
- Never stage blindly: no `git add -A` / `git add .`. Stage explicit paths for
  exactly the files the commit is about, and read `git status` before committing.
  The user's working files must never enter commits, gitignored or not.

## Changelog

Same shape as the Zakura fragment standard. This repo is the consumer: do not
edit Zakura's changelog or agent files.

- After a draft PR exists, a change operators can see owns exactly one
  `changelog/unreleased/<PR-number>.md`. The filename is the PR number.
- Categories: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.
  Prefer `Fixed` when unsure. Write the observable effect, start with a verb,
  and link the PR.
- Internal work (tests, refactors, CI) still gets that file, with
  `<!-- changelog: none -->` and a one-line reason.
- Do not edit an assembled release note in an ordinary PR. Upgrade cuts live in
  `networks/upgrades/<plan>/RELEASE.md` and are written when that release is cut.
- `docs/` is gitignored here, so fragments are not under `docs/changelog/`.

Procedure: `.grok/skills/changelog-fragment/SKILL.md`.

## Issue and Task Management

- Never mark an issue or task completed without explicit user verification. Resolve
  individual points, but closure requires the user's confirmation.
- Always test changes before claiming they work; describe expected behavior and ask
  the user to verify.
