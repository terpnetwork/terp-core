---
name: git
description: >-
  Best practices for git usage, commits, branches, tags, pull requests, and
  GitHub Actions hygiene. Use when the user mentions git, commit, push, branch,
  tag, pull request, PR, merge, rebase, staging, signing, authentication, or CI
  workflow audits.
---

# Git

Respect existing style first. Before writing a commit message or opening a PR,
inspect recent history and match the repo's conventions:

```bash
git log --oneline -20
gh pr list --state merged --limit 10
```

The Conventional Commits format below is a default. If the repo uses a
different consistent style, follow that instead.

## Workflow

1. Pull latest changes before starting work.
2. Make small, focused commits: one logical change per commit.
3. Stage explicit paths, never blindly. Review staged changes before
   committing:

```bash
git add <path>...
git diff --staged
```

4. Run linters and tests locally before pushing.
5. Never push to upstream unless explicitly asked to do so.
6. Audit GitHub Actions workflows with
   [zizmor](https://docs.zizmor.sh/audits/) whenever `.github/` changes:

```bash
zizmor .github/workflows/
```

Fix findings rather than suppressing them.

## Commit messages

Default format (Conventional Commits):

```text
<type>[optional scope]: <description>

[optional body]
```

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `perf`, `style`,
`ci`, `build`.

Rules:

- Write in imperative mood: "add feature", not "added feature".
- Keep the subject line to 50 characters or less.
- Do not end the subject line with a period.
- Separate subject from body with a blank line.
- Use the body to explain what and why, not how.
- Never mention an AI assistant in commit messages, PRs, or issues. No
  `Co-Authored-By` AI lines, no "Generated with ..." footers.

## Branches

- Use descriptive names: `fix/null-pointer-login`, `feat/oauth2-flow`.
- Delete branches after merging.
- Keep branches short-lived and focused on a single concern.

## Amending and history

- Amend only unpushed commits: `git commit --amend`.
- Never force-push to shared branches (main, master, develop).
- Use `git rebase -i` to clean up local history before pushing.

## Tags

Use annotated tags for releases:

```bash
git tag -a v1.2.3 -m "Release v1.2.3"
```

## Pull requests

- Title: one concise line in the repo's commit-subject style.
- Body: a brief summary of what changed and why. A few sentences or a short
  bullet list is plenty. Do not pad with boilerplate sections.
- Do not add a "Test Plan" checkbox section unless the repo's existing PRs
  clearly use that convention.
- Never represent an unrun check as passing. If compilation or tests cannot
  run, state the blocker.

## Signing and authentication

- Never skip commit signing unless the user explicitly asks. If signing fails
  because a hardware key is unavailable, stop and wait for the user. Do not
  fall back to an unsigned commit or disable signing.
- Never work around an authentication failure. If a push, fetch, or `gh` call
  fails to authenticate, stop and surface the error. Do not switch remotes
  between SSH and HTTPS, substitute tokens from the environment or config
  files, generate new keys, disable host key verification, or edit
  `~/.ssh/config`, `~/.gitconfig`, or credential helpers. Retry once after
  the user confirms the key is available.

## Terp-core notes

- Commit subjects start with a verb (`Add`, `Fix`, `Update`, `Remove`,
  `Refactor`), not Conventional Commits types. See `CONTRIBUTING.md`.
- Ask before `git tag`, `git push`, S3 upload, or `cargo publish`. See
  `AGENTS.md`.
- Submodules are gitlinks. Committing inside a submodule plus a gitlink bump
  is two commits in two repos; the submodule commit must be pushed before CI
  can fetch it.
- Linked worktrees resolve `.git` to a file pointing outside the worktree.
  Anything that bind-mounts the worktree (act `--bind`) cannot see git
  inside; use a full clone for that.
- `act` needs a `GITHUB_TOKEN` to download actions. Pass it via
  `--secret-file` pointing outside the repo. Never commit the secret file.
- A PR that changes operator-visible behavior owns exactly one
  `changelog/unreleased/<PR-number>.md` after the draft PR exists. See the
  `changelog-fragment` skill.
