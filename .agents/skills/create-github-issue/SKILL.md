---
name: create-github-issue
description: Create GitHub issues using the gh CLI. Use when the user wants to create a new issue, report a bug, request a feature, or create a task in GitHub. Trigger keywords - create issue, new issue, file bug, report bug, feature request, github issue.
---

# Create GitHub Issue

Create issues on GitHub using the `gh` CLI, following project conventions and issue templates.

## Prerequisites

The `gh` CLI must be authenticated (`gh auth status`).

## Issue Templates

This project uses YAML form issue templates (`.github/ISSUE_TEMPLATE/`). When creating issues, match the template structure so the output aligns with what GitHub renders.

### Bug Reports

Title format: `bug: <concise description>`

Apply the `bug` label only when the user explicitly asks to. When in doubt, omit labels and let maintainers triage.

```bash
gh issue create \
  --title "bug: <concise description>" \
  --body "$(cat <<'EOF'
## Description

**Actual behavior:** <what happened>

**Expected behavior:** <what should happen>

## Reproduction Steps

1. <step>
2. <step>

## Environment

- macOS: <version>
- socktainer: <version>
- Docker CLI: <version>
- Apple Container: <version, if known>

## Logs

```
<relevant output>
```
EOF
)"
```

### Feature Requests

Title format: `feat: <concise description>`

Apply the `enhancement` label only when the user explicitly asks to.

```bash
gh issue create \
  --title "feat: <concise description>" \
  --body "$(cat <<'EOF'
## Problem Statement

<What problem does this solve? Why does it matter?>

## Proposed Design

<How should this work? Describe the system behavior, components involved,
and user-facing interface changes.>

## Alternatives Considered

<What other approaches were evaluated? Why is this design better?>

## Docker API Reference

<If this relates to Docker API compatibility, link to the relevant
Docker Engine API endpoint or documentation.>
EOF
)"
```

### Tasks

For internal tasks that don't fit bug/feature templates (refactoring, CI, dependencies, docs):

```bash
gh issue create \
  --title "<type>: <description>" \
  --body "$(cat <<'EOF'
## Description

<Clear description of the work>

## Context

<Any dependencies, related issues, or background>

## Definition of Done

- [ ] <criterion>
EOF
)"
```

Title types should match conventional commit types: `chore`, `refactor`, `docs`, `ci`, `deps`, `build`, `test`, `perf`.

## Available Labels

| Label | When to apply |
|---|---|
| `bug` | Confirmed bugs |
| `enhancement` | Feature requests and improvements |
| `documentation` | Documentation-only issues |
| `good first issue` | Issues suitable for newcomers |
| `help wanted` | Issues where community help is welcome |
| `question` | Questions about the project |

Only apply labels when clearly applicable. When in doubt, omit labels and let maintainers triage.

## Useful Options

| Option | Description |
|---|---|
| `--title, -t` | Issue title (required) |
| `--body, -b` | Issue description |
| `--label, -l` | Add label (can use multiple times) |
| `--milestone, -m` | Add to milestone |
| `--project, -p` | Add to project |
| `--web` | Open in browser after creation |

## After Creating

The command outputs the issue URL and number.

**Display the URL using markdown link syntax** so it's easily clickable:

```
Created issue [#123](https://github.com/socktainer/socktainer/issues/123)
```

Use the issue number to:

- Reference in commits: `git commit --signoff -m "fix(containers): resolve crash on stop (fixes #123)"`
- Link from pull requests: `Closes #123` in the PR body
