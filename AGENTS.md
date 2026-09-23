# terp-core agent notes

Follow [CONTRIBUTING.md](CONTRIBUTING.md).

Zakura already enforces its own changelog. Do not add fragments, skills, or
agent rules inside `crates/zakura`.

## Changelog

When a pull request changes operator-visible behavior, add one
`changelog/unreleased/<PR-number>.md` after the draft PR exists. Categories
are `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, and `Security`.
Internal-only work uses `<!-- changelog: none -->` and a reason. Do not edit
`networks/upgrades/<plan>/RELEASE.md` in an ordinary PR.

Steps: `.grok/skills/changelog-fragment/SKILL.md`.
