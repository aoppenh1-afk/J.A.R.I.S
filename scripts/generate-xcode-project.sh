#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS_ROOT="$PROJECT_ROOT/apps/macos"

if ! command -v xcodegen >/dev/null 2>&1; then
  printf 'XcodeGen is required to regenerate the project. Install it with: brew install xcodegen\n' >&2
  exit 1
fi

xcodegen generate \
  --spec "$MACOS_ROOT/project.yml" \
  --project "$MACOS_ROOT"

printf 'Generated %s\n' "$MACOS_ROOT/JarvisMac.xcodeproj"
