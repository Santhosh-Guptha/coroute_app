#!/bin/bash
# Runs PURE Dart tests (no widgets, no dart:ui) without the Flutter SDK, with the stand-in for
# flutter_test in shim.dart. Usage (from the repository root):
#   tool/pure_dart_test/run.sh test/avatar_crop_356_test.dart [more tests...]
# DART defaults to `dart` on PATH. Exit code 1 when a test fails.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DART="${DART:-dart}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/tool/pure_dart_test/shim.dart" "$WORK/shim.dart"
rc=0
for f in "$@"; do
  b="$(basename "$f" .dart)"
  python3 - "$ROOT/$f" "$WORK/$b.dart" "$f" <<'PY'
import sys
src, dst, name = sys.argv[1:4]
s = open(src).read()
s = s.replace("import 'package:flutter_test/flutter_test.dart';", "import 'shim.dart';")
s = s.replace("void main() {", "Future<void> main() async {\n  _main();\n  await report('" + name + "');\n}\n\nvoid _main() {", 1)
open(dst, "w").write(s)
PY
  "$DART" run --packages="$ROOT/.dart_tool/package_config.json" "$WORK/$b.dart" 2>&1 | tail -40
  [ "${PIPESTATUS[0]}" -ne 0 ] && rc=1
done
exit $rc
