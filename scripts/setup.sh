#!/bin/bash
# Bootstrap script for new clones.
# Run once after cloning:  ./scripts/setup.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# --- team_config.bzl ---
if [ ! -f team_config.bzl ]; then
    cp team_config.bzl.template team_config.bzl
    echo "Created team_config.bzl from template."
    echo "  → Edit it and set TEAM_ID to your Apple Developer Team ID."
else
    echo "team_config.bzl already exists, skipping."
fi

# --- git hooks ---
git config core.hooksPath .githooks
echo "Activated pre-commit hook (.githooks/)."

echo ""
echo "Setup complete. Next steps:"
echo "  1. Edit team_config.bzl with your Team ID"
echo "  2. bazel run //:xcodeproj"
