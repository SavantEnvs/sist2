#!/usr/bin/env bash
#
# mayhem/test.sh — RUN upstream's own gtest specs for the units the fuzz targets cover
# (src/web/highlight.spec.cpp, libscan/pst/rtf.spec.cpp), as built by mayhem/build.sh. They assert
# exact outputs (highlight markup, extracted RTF text), so a neutered program fails them.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

passed=0 failed=0 skipped=0
for bin in highlight_test rtf_test; do
  exe="$SRC/build/mayhem/$bin"
  if [ ! -x "$exe" ]; then echo "missing $exe (mayhem/build.sh should have built it)" >&2; failed=$((failed+1)); continue; fi
  out="$("$exe" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  ran=$(printf '%s\n' "$out" | sed -n 's/^\[==========\] \([0-9]\+\) tests\? from .* ran\..*/\1/p' | tail -1)
  p=$(printf '%s\n' "$out" | sed -n 's/^\[  PASSED  \] \([0-9]\+\) tests\?\..*/\1/p' | tail -1)
  f=$(printf '%s\n' "$out" | sed -n 's/^\[  FAILED  \] \([0-9]\+\) tests\?, listed below:.*/\1/p' | tail -1)
  s=$(printf '%s\n' "$out" | sed -n 's/^\[  SKIPPED \] \([0-9]\+\) tests\?, listed below:.*/\1/p' | tail -1)
  # No summary line means the runner did not really run (crashed, or was neutered into exiting 0)
  if [ -z "$ran" ] || [ "$ran" -lt 1 ]; then echo "$bin: no gtest summary (rc=$rc)" >&2; failed=$((failed+1)); continue; fi
  passed=$((passed + ${p:-0})); failed=$((failed + ${f:-0})); skipped=$((skipped + ${s:-0}))
  [ "$rc" -eq 0 ] || [ "${f:-0}" -gt 0 ] || failed=$((failed+1))
done

emit_ctrf "gtest" "$passed" "$failed" "$skipped"
