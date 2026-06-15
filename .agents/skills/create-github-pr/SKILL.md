---
name: create-github-pr
description: Create GitHub pull requests using the gh CLI. Use when the user wants to create a new PR, submit code for review, or open a pull request. Trigger keywords - create PR, pull request, new PR, submit for review, code review, open PR.
---

# Create GitHub Pull Request

Create pull requests on GitHub using the `gh` CLI, following project conventions.

## Prerequisites

- The `gh` CLI must be authenticated (`gh auth status`).
- You must have commits on a branch that is pushed to the remote.
- All commits must be signed off for DCO compliance (`git commit --signoff`).

## Before Creating a PR

### Run Pre-PR Checks

```bash
make fmt
```

Verify no formatting drift:

```bash
git diff --exit-code
```

If formatting changes are needed, stage and commit them (with `--signoff`).

Run the test suite:

```bash
make test
```

All tests must pass before opening a PR.

### Verify Unit Test Coverage

- **Bug fixes must include a unit test** that reproduces the bug and verifies the fix.
- **New features must include unit tests** covering the main behavior and relevant edge cases.
- Place tests in `Tests/socktainerTests/` following the existing directory structure.
- When modifying existing behavior, update the corresponding tests to reflect the change.

### Verify Branch State

1. **Not on main** — never create PRs directly from main:

   ```bash
   git branch --show-current   # Should NOT be "main"
   ```

2. **Push your branch**:

   ```bash
   git push -u origin HEAD
   ```

### Verify DCO Sign-off

Every commit in the PR must have a `Signed-off-by` trailer. The [DCO Probot app](https://probot.github.io/apps/dco/) enforces this. Check with:

```bash
git log --format='%h %s | %b' origin/main..HEAD | grep -c 'Signed-off-by'
```

If any commits are missing sign-off, amend them:

```bash
git rebase --signoff origin/main
```

## PR Title Format

PR titles must follow the [Conventional Commits](https://www.conventionalcommits.org/) format:

```
<type>(<scope>): <description>
```

### Types

| Type | Meaning |
|---|---|
| `feat` | New feature or new API endpoint |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `refactor` | Code restructuring, no behavior change |
| `test` | Adding or updating tests |
| `chore` | Maintenance (CI, build, dependencies) |
| `perf` | Performance improvement |
| `deps` | Dependency updates |
| `build` | Build system changes |
| `ci` | CI/CD pipeline changes |

### Common Scopes

Scopes typically match the affected component: `routes`, `containers`, `images`, `healthcheck`, `dns`, `build`, `volumes`, `labels`, `stats`, `context`, `attach`, `app`, `archive`, `builder`.

### Examples

- `feat(healthcheck): implement Docker healthcheck support`
- `fix(attach): stream output for non-interactive docker run`
- `fix(labels): normalize label keys for Apple Container compatibility`
- `docs: update README with volume sync options`
- `refactor(routes): use native pull/push`
- `deps: bump apple/container to 1.0.0`

## PR Description Format

PR descriptions should follow the template in `.github/PULL_REQUEST_TEMPLATE.md`:

```markdown
## Summary
<!-- 1-3 sentences: what this PR does and why -->

## Related Issue
<!-- Fixes #NNN or Closes #NNN -->

## Changes
<!-- Bullet list of key changes -->

## Testing
- [ ] `make fmt` passes (no formatting drift)
- [ ] `make test` passes
- [ ] Unit tests added or updated (required for features and bug fixes)
- [ ] Manual testing performed (if applicable)

## Checklist
- [ ] Follows Conventional Commits
- [ ] All commits are signed off (DCO)
```

## Creating a PR

Basic command:

```bash
gh pr create --title "<title>" --body "<body>"
```

### Full Example

```bash
gh pr create \
  --title "feat(healthcheck): implement Docker healthcheck support" \
  --body "$(cat <<'EOF'
## Summary

Implement Docker healthcheck support so containers can define HEALTHCHECK
instructions and socktainer tracks their status. Closes #214

## Related Issue

Closes #214

## Changes

- Added `HealthCheckManager` to run periodic health probes inside containers
- Added `ClientHealthCheckService` for healthcheck state management
- Container inspect now returns `.State.Health` with current status and log
- Healthcheck loops resume automatically on socktainer restart

## Testing

- [x] `make fmt` passes (no formatting drift)
- [x] `make test` passes
- [x] Unit tests added for `HealthCheckManager` and `ClientHealthCheckService`
- [x] Manual testing with `docker run --health-cmd` verified

## Checklist

- [x] Follows Conventional Commits
- [x] All commits are signed off (DCO)
EOF
)"
```

### Link to an Issue

Use `Closes #<issue-number>` or `Fixes #<issue-number>` in the body to auto-close the issue when merged.

### Create as Draft

For work-in-progress that is not ready for review:

```bash
gh pr create --draft --title "feat(dns): add inter-container DNS"
```

### With Labels

```bash
gh pr create --title "Title" --label "bug"
```

### Target a Different Branch

Default target is `main`. To target a different branch:

```bash
gh pr create --base "1.0.x"
```

## Useful Options

| Option | Description |
|---|---|
| `--title, -t` | PR title (use conventional commit format) |
| `--body, -b` | PR description |
| `--reviewer, -r` | Request review from user |
| `--draft` | Create as draft (WIP) |
| `--label, -l` | Add label (can use multiple times) |
| `--base, -B` | Target branch (default: main) |
| `--head, -H` | Source branch (default: current) |
| `--web` | Open in browser after creation |

## After Creating

The command outputs the PR URL and number.

**Display the URL using markdown link syntax** so it's easily clickable:

```
Created PR [#123](https://github.com/socktainer/socktainer/pull/123)
```

### Monitor CI (Optional)

The PR CI runs formatting check, unit tests, release build, installer build, and integration tests:

```bash
gh run watch
```
