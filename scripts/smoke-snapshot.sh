#!/usr/bin/env bash
# Smoke-test a LINKED d8/r8 snapshot over the real tracing corpus.
#
# The corpus is the same Compose app bytecode the image was traced on, so
# this is the end-to-end answer to "does the snapshot do real work": dex the
# app's classes with the native D8, shrink them with the native R8, and check
# the flag variants the trace exercised.
#
# Primary runs (dex the corpus, shrink the corpus, --version) are fatal: a
# snapshot that cannot do those is not shippable. Variant runs are reported
# instead: a variant that regresses is a reachability gap in the image, and
# the gap list travels with the artifact in <tool>-smoke-report.txt.
#
# Env: TOOL (d8|r8), WORK, OUT (directory holding <tool>-snapshot).
set -euo pipefail

TOOL="${TOOL:?set TOOL}"
WORK="${WORK:?set WORK}"
OUT="${OUT:?set OUT}"
CORPUS="$WORK/corpus"
BIN="$OUT/$TOOL-snapshot"
SMOKE="$WORK/smoke-$TOOL"
REPORT="$OUT/$TOOL-smoke-report.txt"

[ -x "$BIN" ] || { echo "missing snapshot binary: $BIN" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CORPUS/env.txt"
mapfile -t PROGS_ALL < <(grep -v -e 'broken.jar' "$CORPUS/programs.txt" || true)
mapfile -t PROGS_SAMPLES < <(grep -v -e 'broken.jar' "$CORPUS/samples.txt" || true)
mapfile -t CP_ENTRIES < "$CORPUS/classpath.txt"
CP_ARGS=()
for e in ${CP_ENTRIES[@]+"${CP_ENTRIES[@]}"}; do
  [ -n "$e" ] && CP_ARGS+=(--classpath "$e")
done
LIB_ARGS=(--lib "$ANDROID_LIB")
[ -n "${ANDROID_LIB2:-}" ] && [ "$ANDROID_LIB2" != "$ANDROID_LIB" ] && \
  LIB_ARGS+=(--lib "$ANDROID_LIB2")
rm -rf "$SMOKE"; mkdir -p "$SMOKE"
: > "$REPORT"

# The Proguard files come from corpus.sh. A missing one used to surface as an
# opaque "Error in <path>" from R8, so check them up front.
for pro in base prints noopt noshrink target11 flatten missing; do
  [ -f "$WORK/rules/$pro.pro" ] || { echo "missing rules file: $WORK/rules/$pro.pro" >&2; exit 1; }
done

PRIMARY_FAILED=0
DEGRADED=()
smoke() { # smoke <label> <ok|fail|any> <primary|variant> <args...>
  local label="$1" expect="$2" kind="$3"; shift 3
  local log="$SMOKE/$label.txt" rc=0
  "$BIN" "$@" > "$log" 2>&1 || rc=$?
  local verdict
  if [ "$expect" = any ]; then
    verdict="ok"
  elif { [ "$expect" = ok ] && [ "$rc" = 0 ]; } || { [ "$expect" = fail ] && [ "$rc" != 0 ]; }; then
    verdict="ok"
  else
    verdict="degraded"
    DEGRADED+=("$label")
    if [ "$kind" = primary ]; then
      PRIMARY_FAILED=1
      verdict="FAILED"
    fi
    {
      echo "--- $label: rc=$rc"
      grep -m 8 -A 4 -E 'Error|error:|Exception|Caused by' "$log" | cut -c1-160
    } >> "$REPORT"
  fi
  # Print the first error-ish lines on stdout too: the per-run log files live in
  # the work dir and are not always around when a CI failure is being read.
  local why
  why="$(grep -m 3 -E 'Error|error:|Exception' "$log" | cut -c1-120 | tr '\n' '|')"
  printf '%-9s %-18s %s\n' "$verdict" "$label" "$why"
}

echo "=== smoke $TOOL snapshot over $(wc -l < "$CORPUS/programs.txt") program inputs ==="
"$BIN" --version | head -1

if [ "$TOOL" = d8 ]; then
  mkdir -p "$SMOKE/dex24"
  smoke dex-corpus ok primary --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --output "$SMOKE/dex24" "${PROGS_ALL[@]}"
  echo "  dex files: $(ls "$SMOKE/dex24" | tr '\n' ' ')"
  mkdir -p "$SMOKE/dex19"
  smoke dex-min19 ok variant --release --min-api 19 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --output "$SMOKE/dex19" "${PROGS_SAMPLES[@]}"
  # --no-desugaring rejects desugar-dependent shapes (see corpus.sh), so
  # this one runs against the plain Java 8 sample.
  mkdir -p "$SMOKE/nodesug"
  smoke dex-nodesug ok variant --min-api 21 --no-desugaring "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --output "$SMOKE/nodesug" "$CORPUS/samples/java8.jar"
  mkdir -p "$SMOKE/classfile"
  smoke dex-classfile ok variant --release --lib "$ANDROID_LIB" --classfile "${CP_ARGS[@]}" \
    --output "$SMOKE/classfile" "${PROGS_SAMPLES[@]}"
  mkdir -p "$SMOKE/perclass"
  smoke dex-per-class ok variant --release --min-api 24 "${LIB_ARGS[@]}" --file-per-class \
    --globals-output "$SMOKE/perclass-globals.zip" \
    --output "$SMOKE/perclass" "${PROGS_SAMPLES[@]}"
  # dex round trip: the snapshot dexing its own output
  DEX_IN="$(ls "$SMOKE/dex24"/classes*.dex 2>/dev/null | head -1 || true)"
  if [ -n "$DEX_IN" ]; then
    mkdir -p "$SMOKE/dexin"
    smoke dex-from-dex ok variant --release --min-api 34 "${LIB_ARGS[@]}" \
      --output "$SMOKE/dexin" "$DEX_IN"
  fi
  mkdir -p "$SMOKE/broken"
  # a dangling type reference is a warning for both compilers, not a failure
  smoke dex-broken-input any variant --release --min-api 24 "${LIB_ARGS[@]}" \
    --output "$SMOKE/broken" "$CORPUS/samples/broken.jar"
else
  smoke version ok primary --version
  smoke shrink-corpus ok primary --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --pg-conf "$WORK/rules/base.pro" --output "$SMOKE/full.jar" "${PROGS_ALL[@]}"
  ls -la "$SMOKE/full.jar" 2>/dev/null | sed 's/^/  /'
  smoke shrink-prints ok variant --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --pg-conf "$WORK/rules/prints.pro" --output "$SMOKE/prints.jar" "${PROGS_SAMPLES[@]}"
  smoke shrink-noopt ok variant --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --pg-conf "$WORK/rules/noopt.pro" --output "$SMOKE/noopt.jar" "${PROGS_SAMPLES[@]}"
  smoke shrink-noshrink ok variant --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --pg-conf "$WORK/rules/noshrink.pro" --output "$SMOKE/noshrink.jar" "${PROGS_SAMPLES[@]}"
  smoke shrink-target11 ok variant --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --pg-conf "$WORK/rules/target11.pro" --output "$SMOKE/t11.jar" "${PROGS_SAMPLES[@]}"
  mkdir -p "$SMOKE/classfile"
  smoke shrink-classfile ok variant --release --lib "$ANDROID_LIB" --classfile "${CP_ARGS[@]}" \
    --pg-conf "$WORK/rules/base.pro" --output "$SMOKE/classfile" "${PROGS_SAMPLES[@]}"
  smoke shrink-flatten ok variant --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --pg-conf "$WORK/rules/flatten.pro" --output "$SMOKE/flatten.jar" "${PROGS_SAMPLES[@]}"
  rm -f "$SMOKE/broken.jar"
  smoke shrink-broken-input any variant --release --min-api 24 "${LIB_ARGS[@]}" \
    --pg-conf "$WORK/rules/missing.pro" --output "$SMOKE/broken.jar" \
    "$CORPUS/samples/broken.jar"
fi

if [ "${#DEGRADED[@]}" -gt 0 ]; then
  echo "=== smoke: ${#DEGRADED[@]} degraded variant(s): ${DEGRADED[*]} ==="
  echo "degraded variants: ${DEGRADED[*]}" >> "$REPORT"
else
  echo "=== smoke: all variants ok ==="
fi
[ "$PRIMARY_FAILED" = 0 ] || { echo "PRIMARY smoke run failed" >&2; exit 1; }
echo "=== smoke $TOOL OK ==="