#!/bin/bash
# Scan staged additions for local usernames and host-specific absolute paths.

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: scripts/check_private_paths.sh [--cached|--stdin]

  --cached  Scan staged git additions. This is the default.
  --stdin   Read a unified diff from stdin. Intended for tests.

Set PRIVATE_PATH_EXTRA_NAMES to a comma- or space-separated list of additional
local names to block.
EOF
}

mode="${1:---cached}"
case "$mode" in
    --cached|--stdin)
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 2
        ;;
esac

escape_ere() {
    printf '%s' "$1" | sed -e 's/[][(){}.^$*+?|]/\\&/g'
}

patterns=()
descriptions=()

add_pattern() {
    descriptions+=("$1")
    patterns+=("$2")
}

add_private_name() {
    local name="$1"

    # Very short names are too noisy for prose and code identifiers.
    if [ "${#name}" -lt 3 ]; then
        return
    fi

    local escaped
    escaped="$(escape_ere "$name")"
    add_pattern "local username '${name}'" "(^|[^A-Za-z0-9])${escaped}($|[^A-Za-z0-9])"
}

# User-specific home directories should not be committed, even in comments or
# generated logs.
add_pattern "user home absolute path" "/(Users|home)/[A-Za-z0-9._-]+(/|$)"

# Apple logs and temporary tool output often include this host-specific path.
add_pattern "macOS per-user temporary path" "/(private/)?var/folders/[A-Za-z0-9._/-]+"

for candidate in "${USER:-}" "${LOGNAME:-}" "$(basename "${HOME:-}")"; do
    add_private_name "$candidate"
done

if [ -n "${PRIVATE_PATH_EXTRA_NAMES:-}" ]; then
    IFS=', ' read -r -a extra_names <<< "${PRIVATE_PATH_EXTRA_NAMES}"
    for candidate in "${extra_names[@]}"; do
        add_private_name "$candidate"
    done
fi

violations=0

check_text() {
    local location="$1"
    local text="$2"
    local i

    for i in "${!patterns[@]}"; do
        if [[ "$text" =~ ${patterns[$i]} ]]; then
            printf 'error: staged content contains %s in %s\n' "${descriptions[$i]}" "$location" >&2
            violations=$((violations + 1))
        fi
    done
}

check_staged_paths() {
    local path

    while IFS= read -r -d '' path; do
        check_text "path:${path}" "$path"
    done < <(git diff --cached --name-only -z --diff-filter=ACMR)
}

scan_diff() {
    local line
    local file="<unknown>"

    while IFS= read -r line; do
        case "$line" in
            '+++ b/'*)
                file="${line#+++ b/}"
                ;;
            '+++ '*)
                file="<unknown>"
                ;;
            '+'*)
                check_text "$file" "${line:1}"
                ;;
        esac
    done
}

if [ "$mode" = "--cached" ]; then
    check_staged_paths
    scan_diff < <(git diff --cached --unified=0 --no-ext-diff --diff-filter=ACMR --)
else
    scan_diff
fi

if [ "$violations" -ne 0 ]; then
    cat >&2 <<'EOF'
error: remove local absolute paths or usernames before committing.
       Use repo-relative paths, placeholders, or sanitized examples instead.
EOF
    exit 1
fi
