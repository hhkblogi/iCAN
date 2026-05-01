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
    # Migrate: add APPSTORE_IDENTITY if missing (added in v0.2)
    if ! grep -Eq '^[[:space:]]*APPSTORE_IDENTITY[[:space:]]*=' team_config.bzl; then
        printf '\n# Apple Distribution signing identity for App Store builds (leave empty to skip).\nAPPSTORE_IDENTITY = ""\n' >> team_config.bzl
        echo "Added APPSTORE_IDENTITY to existing team_config.bzl (defaults to empty)."
    else
        echo "team_config.bzl already exists, skipping."
    fi
fi

# --- device_config.bzl ---
if [ ! -f device_config.bzl ]; then
    cp device_config.bzl.template device_config.bzl
    echo "Created device_config.bzl from template."
    echo "  -> Optional: set ICAN_DEVICE to your local development device."
else
    echo "device_config.bzl already exists, skipping."
fi

# --- git hooks ---
git config core.hooksPath .githooks
echo "Activated pre-commit hook (.githooks/)."

echo ""
echo "Setup complete. Next steps:"
echo "  1. Edit team_config.bzl with your Team ID"
echo "  2. Optional: edit device_config.bzl with your local device"
echo "  3. bazel run //:xcodeproj"
