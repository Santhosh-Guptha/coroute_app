#!/bin/bash
# Runs the rescue beacon lab (pure Dart, no Flutter). From the repository root:
#   tool/rescue_lab/run.sh [--trials N] [--quick]
# DART defaults to `dart` on PATH. The lab is copied to a temporary folder so `dart run` does not
# try to resolve the app's pubspec (no network needed); packages come from .dart_tool.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DART="${DART:-dart}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/tool/rescue_lab/rescue_lab.dart" "$WORK/rescue_lab.dart"
"$DART" run --packages="$ROOT/.dart_tool/package_config.json" "$WORK/rescue_lab.dart" "$@"
