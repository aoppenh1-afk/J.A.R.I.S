#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARAKEET_MODEL_PATH="${JARVIS_PARAKEET_MODEL_PATH:-$HOME/Library/Caches/com.parakeet-tdt/hf-models/mweinbach1_parakeet-tdt-0.6b-v3-coreml}"
MODE="${1:---all}"
failures=0

pass() { printf '✓ %s\n' "$1"; }
fail() { printf '✗ %s\n' "$1" >&2; failures=$((failures + 1)); }

check_tool() {
  if command -v "$1" >/dev/null 2>&1; then
    pass "$1 is available"
  else
    fail "$1 is required"
  fi
}

check_build() {
  if [[ "$(uname -m)" == "arm64" ]]; then
    pass "host architecture is arm64"
  else
    fail "Apple Silicon arm64 host required (found $(uname -m))"
  fi

  check_tool swift
  check_tool python3
  check_tool xcodebuild
  check_tool codesign
  check_tool plutil
  check_tool xcrun
  check_tool ditto
  check_tool hdiutil

  if [[ -f "$PROJECT_ROOT/apps/macos/Vendor/ParakeetTDT/Sources/ParakeetTranscriber.swift" \
        && -f "$PROJECT_ROOT/apps/macos/Vendor/ParakeetTDT/LICENSE" ]]; then
    pass "pinned Parakeet Swift source and license are vendored"
  else
    fail "vendored Parakeet Swift source or license is missing"
  fi

  if [[ -f "$PROJECT_ROOT/apps/macos/project.yml" ]]; then
    pass "Xcode project specification is present"
  else
    fail "Xcode project specification is missing"
  fi

  if [[ -f "$PROJECT_ROOT/apps/macos/Packaging/Info.plist" ]]; then
    pass "application Info.plist is present"
  else
    fail "application Info.plist is missing"
  fi

  if [[ -f "$PROJECT_ROOT/apps/macos/Packaging/Jarvis.entitlements" ]]; then
    pass "application entitlements are present"
  else
    fail "application entitlements are missing"
  fi
}

check_runtime() {
  local hermes="${JARVIS_HERMES_EXECUTABLE:-}"
  local candidates=(
    "$hermes"
    "$HOME/.local/bin/hermes"
    "/opt/homebrew/bin/hermes"
    "/usr/local/bin/hermes"
  )
  local found_hermes=""
  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      found_hermes="$candidate"
      break
    fi
  done

  if [[ -n "$found_hermes" ]]; then
    pass "Hermes executable found at $found_hermes"
  else
    fail "Hermes executable not found in a supported packaged-app location"
  fi

  local required_model_files=(
    "encoder.mlpackage/Manifest.json"
    "encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel"
    "encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
    "decoder.mlpackage/Manifest.json"
    "decoder.mlpackage/Data/com.apple.CoreML/model.mlmodel"
    "decoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
    "joint.mlpackage/Manifest.json"
    "joint.mlpackage/Data/com.apple.CoreML/model.mlmodel"
    "joint.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
    "tokenizer.json"
  )
  local missing_model_file=0
  for relative_path in "${required_model_files[@]}"; do
    if [[ ! -f "$PARAKEET_MODEL_PATH/$relative_path" ]]; then
      fail "Parakeet model is missing $relative_path under $PARAKEET_MODEL_PATH"
      missing_model_file=1
    fi
  done
  if [[ "$missing_model_file" -eq 0 ]]; then
    pass "Parakeet model cache is complete at $PARAKEET_MODEL_PATH"
  fi
}

case "$MODE" in
  --build) check_build ;;
  --runtime) check_runtime ;;
  --all) check_build; check_runtime ;;
  *)
    printf 'Usage: %s [--build|--runtime|--all]\n' "$0" >&2
    exit 2
    ;;
esac

if [[ "$failures" -ne 0 ]]; then
  printf '\n%d prerequisite check(s) failed.\n' "$failures" >&2
  exit 1
fi

printf '\nAll requested prerequisites are available.\n'
