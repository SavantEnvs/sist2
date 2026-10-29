#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# sist2's full build (vcpkg: ffmpeg, mupdf, tesseract, ...) is network-heavy and irrelevant to the two
# self-contained units the in-tree libFuzzer targets exercise, so the fuzzed code is compiled
# straight from source: src/web/highlight.c and libscan/pst/rtf.c, with the sanitizers + DWARF 3.
# utf8h (rtf.c's only non-system header, a vcpkg port upstream) is vendored in mayhem/include.
INC=(-I"$SRC" -I"$SRC/mayhem/include")
OUT="$SRC"
BUILD="$SRC/build/mayhem"
mkdir -p "$BUILD"

# LeakSanitizer off at build time (SPEC §6.2 item 15)
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$BUILD/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"

# build_fuzzer <name> <harness.c> <unit sources...>
build_fuzzer() {
    local name="$1" harness="$2"; shift 2
    local objs=() src
    for src in "$@" "$harness"; do
        local obj="$BUILD/$name.$(basename "$src" .c).o"
        $CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 "${INC[@]}" -c "$src" -o "$obj"
        objs+=("$obj")
    done
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "${objs[@]}" "$BUILD/lsan_off.o" -o "$OUT/$name"
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS "${objs[@]}" "$BUILD/standalone_main.o" "$BUILD/lsan_off.o" -o "$OUT/$name-standalone"
}

build_fuzzer highlight_fuzz "$SRC/tests/fuzz/highlight_fuzz.c" "$SRC/src/web/highlight.c"
build_fuzzer rtf_fuzz "$SRC/tests/fuzz/rtf_fuzz.c" "$SRC/libscan/pst/rtf.c"

# 3) Upstream's own gtest specs for those two units, with the project's NORMAL flags. rtf.spec.cpp
#    includes tests/support/scan_fixture.h, which needs the full vcpkg closure; mayhem/shim provides a
#    gtest-only stand-in ahead of the real include path.
TEST_CC=(env -u SANITIZER_FLAGS -u DEBUG_FLAGS "${CC}")
TEST_CXX=(env -u SANITIZER_FLAGS -u DEBUG_FLAGS "${CXX}")
GTEST_LIBS=(-lgtest -lgtest_main -lpthread)
"${TEST_CC[@]}" -O2 -g "${INC[@]}" -c "$SRC/src/web/highlight.c" -o "$BUILD/t_highlight.o"
"${TEST_CC[@]}" -O2 -g "${INC[@]}" -c "$SRC/libscan/pst/rtf.c" -o "$BUILD/t_rtf.o"
"${TEST_CXX[@]}" -std=c++17 -O2 -g $COVERAGE_FLAGS "${INC[@]}" \
    "$SRC/src/web/highlight.spec.cpp" "$BUILD/t_highlight.o" "${GTEST_LIBS[@]}" -o "$BUILD/highlight_test"
"${TEST_CXX[@]}" -std=c++17 -O2 -g $COVERAGE_FLAGS -I"$SRC/mayhem/shim" "${INC[@]}" \
    "$SRC/libscan/pst/rtf.spec.cpp" "$BUILD/t_rtf.o" "${GTEST_LIBS[@]}" -o "$BUILD/rtf_test"
