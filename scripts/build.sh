#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

swift build --configuration release --package-path "$PROJECT_ROOT/apps/macos"
