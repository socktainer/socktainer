#!/usr/bin/env bash

set -euo pipefail

action=uninstall
products="dory,orbstack"
apply=false

usage() {
    cat <<'EOF'
Usage: scripts/benchmark-tools.sh [options]

Manage external benchmark applications without changing the benchmark run cleanup.

Options:
  --action ACTION       install or uninstall (default: uninstall)
  --products LIST       dory,orbstack, or docker-desktop
  --apply               Execute the plan (default: print a dry-run plan)
  --help                Show this help

Docker Desktop is refused when an EasyLink container is present in any Docker
context. This script never removes Docker volumes or application data.
EOF
}

die() {
    echo "benchmark-tools: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --action)
            action="${2:-}"
            shift 2
            ;;
        --products)
            products="${2:-}"
            shift 2
            ;;
        --apply)
            apply=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown option: $1"
            ;;
    esac
done

case "$action" in
    install|uninstall) ;;
    *) die "--action must be install or uninstall" ;;
esac

command -v brew >/dev/null 2>&1 || die "Homebrew is required"

IFS=',' read -r -a requested <<< "$products"
(( ${#requested[@]} > 0 )) || die "--products cannot be empty"

casks=()
for product in "${requested[@]}"; do
    case "$product" in
        dory|orbstack)
            casks+=("$product")
            ;;
        docker|docker-desktop)
            casks+=(docker-desktop)
            ;;
        *)
            die "unsupported product: $product (choose dory, orbstack, or docker-desktop)"
            ;;
    esac
done

contains_easylink_container() {
    command -v docker >/dev/null 2>&1 || return 1

    local context names
    while IFS= read -r context; do
        [[ -n "$context" ]] || continue
        names="$(DOCKER_CONTEXT="$context" docker ps -a --format '{{.Names}}' 2>/dev/null || true)"
        if printf '%s\n' "$names" | grep -Eiq '(^|[-_])easylink([-_]|$)'; then
            echo "EasyLink container detected in Docker context '$context'." >&2
            return 0
        fi
    done < <(docker context ls --format '{{.Name}}' 2>/dev/null || true)
    return 1
}

if printf '%s\n' "${casks[@]}" | grep -qx docker-desktop && contains_easylink_container; then
    die "refusing Docker Desktop removal; stop using Docker for EasyLink before retrying"
fi

for cask in "${casks[@]}"; do
    if [[ "$action" == install ]]; then
        command=(brew install --cask "$cask")
    else
        command=(brew uninstall --cask "$cask")
    fi
    printf '%q ' "${command[@]}"
    printf '\n'
    if [[ "$apply" == true ]]; then
        "${command[@]}"
    fi
done

if [[ "$apply" != true ]]; then
    echo "Dry run only. Add --apply to execute the plan."
fi
