---
name: changelog-fragment
description: >-
  Write the changelog fragment a terp-core pull request owns. Use when creating
  or updating a PR, when the user mentions changelogs, release notes, or
  fragments, or when a changelog check fails. Do not use this for the Zakura
  checkout; that repo already has its own rule.
---

# Changelog fragment (terp-core)

Zakura's team owns Zakura's fragments. This skill is for terp-core only.
Policy text: `CONTRIBUTING.md`, section Changelog.

## When

After the draft PR number exists:

- Operator-visible work (chain behavior, CLI, upgrade execution, configs
  operators read) gets one `changelog/unreleased/<PR-number>.md`.
- Internal work still gets that file, marked none.
- Do not add a fragment for a change that only touches `crates/zakura`.

## User-visible

```markdown
## Fixed

- Fixed the operator-visible behavior
  ([#123](https://github.com/terpnetwork/terp-core/pull/123)).
```

Categories: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.
Prefer `Fixed` when unsure. Start with a verb. Describe what an operator
sees, not the patch. Do not describe an undisclosed or unfixed vulnerability
under `Security`.

## Internal only

```markdown
<!-- changelog: none -->

This PR only changes tests and has no operator-visible effect.
```

Replace the second line with the real reason.

## Do not

- Edit `networks/upgrades/<plan>/RELEASE.md` in an ordinary PR. That file is
  the assembled note for a release cut.
- Edit Zakura's `CHANGELOG.md`, `docs/changelog/`, or `AGENTS.md`.
