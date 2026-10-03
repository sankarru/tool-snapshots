#!/usr/bin/env bash
# Trace D8 or R8 with the native-image agent across a matrix of REAL
# invocations, then union every run's metadata into $META.
#
# Why a matrix: the agent only records what actually executes, so reachability
# of the finished image is the union of everything the traced runs touched.
# One dexing run over hello-world records a sliver of D8; the whole matrix
# over a Compose app's bytecode plus its androidx classpath records the dex
# writers, the desugaring passes, library resolution, shrinking/optimizing/
# obfuscating, dex layout, printing and the diagnostic paths.
#
# Every invocation is expected to be *runnable* (flags are validated against
# the R8 version in use), but a failure is not fatal: the run still traces the
# code it reached before dying, and the failure is reported. Two runs are
# deliberate failures (missing class, no --lib) whose only job is to trace the
# diagnostic/reporting code.
#
# Env: TOOL (d8|r8), WORK, R8JAR, JAVA_BIN, META. Reads $WORK/corpus/*.
set -euo pipefail

TOOL="${TOOL:?set TOOL}"
WORK="${WORK:?set WORK}"
R8JAR="${R8JAR:?set R8JAR}"
JAVA_BIN="${JAVA_BIN:-$JAVA_HOME/bin}"
META="${META:-$WORK/meta}"
CORPUS="$WORK/corpus"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULES="$WORK/rules"
OUTDIRS="$WORK/$TOOL-out"

MAIN="com.android.tools.r8.D8"
[ "$TOOL" = r8 ] && MAIN="com.android.tools.r8.R8"

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

mkdir -p "$RULES" "$OUTDIRS" "$META"
rm -rf "$META"; mkdir -p "$META"

RUNS=0
FAILED=0
declare -A RUN_META=()

# D8/R8 reject a --output directory that does not exist yet.
outdir() { local d="$1"; rm -rf "$d"; mkdir -p "$d"; echo "$d"; }

# run <label> <args...> : one invocation, one agent metadata directory.
run() {
  local label="$1"; shift
  local dir="$WORK/meta-$TOOL-$label"
  local log="$WORK/log-$TOOL-$label.txt"
  rm -rf "$dir"; mkdir -p "$dir"
  RUNS=$((RUNS + 1))
  echo "--- trace [$label]: $*"
  local rc=0
  "$JAVA_BIN/java" "-agentlib:native-image-agent=config-output-dir=$dir" \
    -cp "$R8JAR" "$MAIN" "$@" > "$log" 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then
    RUN_META[$label]="$dir"
    echo "    ok ($(wc -c < "$log") bytes of output)"
  else
    FAILED=$((FAILED + 1))
    RUN_META[$label]="$dir"   # partial trace is still a trace
    echo "    rc=$rc (traced anyway): $(grep -m1 -E 'Error|error:|Unknown|Illegal|Unsupported' "$log" | cut -c1-160)"
  fi
}

echo "=== trace matrix: tool=$TOOL r8=$(basename "$R8JAR") ==="
echo "    program inputs: ${#PROGS_ALL[@]}  sample inputs: ${#PROGS_SAMPLES[@]}  classpath: ${#CP_ENTRIES[@]}"

if [ "$TOOL" = d8 ]; then
  # Tier A: the whole corpus (app classes + samples), full androidx classpath.
  MDX="$(outdir "$OUTDIRS/mdx19")"
  run mdx19 --release --min-api 19 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --output "$MDX" "${PROGS_ALL[@]}"
  REL24="$(outdir "$OUTDIRS/rel24")"
  run rel24 --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --output "$REL24" "${PROGS_ALL[@]}"
  REL24_ZIP="$OUTDIRS/rel24.zip"; rm -f "$REL24_ZIP"
  run rel24-zip --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --output "$REL24_ZIP" "${PROGS_ALL[@]}"

  # Tier B: synthetic samples against the same classpath - the exotic flag
  # paths do not need the app to be interesting, only present.
  S=("${PROGS_SAMPLES[@]}")
  run debug19 --debug --min-api 19 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --output "$(outdir "$OUTDIRS/debug19")" "${S[@]}"
  # no-desugaring legitimately rejects shapes that need desugaring (static
  # interface methods, records); run against the plain Java 8 sample so the
  # pass itself is what gets traced.
  run nodesug --min-api 21 --no-desugaring "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --output "$(outdir "$OUTDIRS/nodesug")" "$CORPUS/samples/java8.jar"
  run minapi34 --release --min-api 34 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --output "$(outdir "$OUTDIRS/minapi34")" "${S[@]}"
  run one-lib --release --min-api 24 --lib "$ANDROID_LIB" "${CP_ARGS[@]}" \
    --output "$(outdir "$OUTDIRS/onelib")" "${S[@]}"
  # classfile output is the non-dex writer: no --min-api may be combined.
  run classfile --release --lib "$ANDROID_LIB" --classfile "${CP_ARGS[@]}" \
    --output "$(outdir "$OUTDIRS/classfile")" "${S[@]}"
  # file-per-class needs a globals consumer whenever a global synthetic (e.g.
  # record desugaring) shows up.
  run per-class --release --min-api 24 "${LIB_ARGS[@]}" --file-per-class \
    --globals-output "$OUTDIRS/perclass-globals.zip" \
    --output "$(outdir "$OUTDIRS/perclass")" "${S[@]}"
  run single-thread --release --min-api 24 "${LIB_ARGS[@]}" --thread-count 1 \
    --output "$(outdir "$OUTDIRS/one-thread")" "${S[@]}"
  # intermediate compilation + global synthetics round trip.
  GLOBALS="$OUTDIRS/globals.zip"; rm -f "$GLOBALS"
  run intermediate --release --min-api 24 "${LIB_ARGS[@]}" --intermediate \
    --globals-output "$GLOBALS" --output "$OUTDIRS/intermediate.zip" "${S[@]}"
  run merge-globals --release --min-api 24 "${LIB_ARGS[@]}" --globals "$GLOBALS" \
    --output "$OUTDIRS/merged.zip" "${S[@]}"
  # dex inputs: D8 reads its own dex back (R8 refuses), and only then is
  # --main-dex-list legal (deprecated for class inputs).
  DEX_IN="$(ls "$MDX"/classes.dex 2>/dev/null | head -1 || true)"
  if [ -n "$DEX_IN" ]; then
    printf 'com/example/reply/MainActivity.class\n' > "$OUTDIRS/main-dex-list.txt"
    run dex-in-maindex --release --min-api 21 "${LIB_ARGS[@]}" \
      --main-dex-list "$OUTDIRS/main-dex-list.txt" \
      --output "$(outdir "$OUTDIRS/dexin-maindex")" "$DEX_IN"
    run dex-in-nodesug --release --min-api 21 "${LIB_ARGS[@]}" --no-desugaring \
      --output "$(outdir "$OUTDIRS/dexin-nodesug")" "$DEX_IN"
    printf 'Lhello/Hello;->main([Ljava/lang/String;)V\n' > "$OUTDIRS/startup.prof"
    run dex-in-startup --release --min-api 21 "${LIB_ARGS[@]}" \
      --startup-profile "$OUTDIRS/startup.prof" \
      --output "$(outdir "$OUTDIRS/dexin-startup")" "$DEX_IN"
  else
    echo "    no dex output from mdx19, skipping dex-input runs"
  fi
  printf 'Lhello/Hello;->main([Ljava/lang/String;)V\n' > "$OUTDIRS/startup.prof"
  run startup-profile --release --min-api 24 "${LIB_ARGS[@]}" \
    --startup-profile "$OUTDIRS/startup.prof" \
    --output "$(outdir "$OUTDIRS/startup")" "${S[@]}"

  # Deliberate diagnostics: a dangling type reference, and no --lib at all.
  run broken-input --release --min-api 24 "${LIB_ARGS[@]}" \
    --output "$(outdir "$OUTDIRS/broken")" "$CORPUS/samples/broken.jar"
  run no-lib --release --min-api 24 "${CP_ARGS[@]}" \
    --output "$OUTDIRS/nolib.zip" "${S[@]}"
else
  NS="$(cat "$CORPUS/namespace.txt" 2>/dev/null || echo "com.example.reply")"
  # Every option below lives in a .pro file on purpose: R8's own CLI only
  # understands --flag style options, Proguard options must come from
  # --pg-conf (or --pg-compat).
  cat > "$RULES/base.pro" <<EOF
-keep public class $NS.MainActivity { *; }
-keep class $NS.data.** { *; }
-keep,includedescriptorclasses @kotlinx.serialization.Serializable class ** { *; }
-keepclasseswithmembers class ** { *** Companion; }
-keep class **\$\$serializer { *; }
-keepattributes *
-dontnote **
-dontwarn javax.annotation.**
EOF
  mk_rules() { # mk_rules <name> <extra options...>
    local name="$1"; shift
    cp "$RULES/base.pro" "$RULES/$name.pro"
    printf '%s\n' "$@" >> "$RULES/$name.pro"
  }
  mk_rules noopt        -dontoptimize
  mk_rules noshrink     -dontshrink
  mk_rules noobf        -dontobfuscate
  mk_rules flatten      -flattenpackagehierarchy ''
  mk_rules library      -dontskipnonpubliclibraryclasses -keeppackagenames
  mk_rules target11     -target 11
  mk_rules debug        -dontoptimize -dontshrink -dontobfuscate -keepparameternames
  mk_rules why          -whyareyoukeeping class $NS.MainActivity
  # NOTE: the '**' class patterns must stay quoted: bash would glob them
  # against the cwd before they ever reach the parser.
  mk_rules missing      '-dontnote **'
  mk_rules missing-ok   '-dontwarn **' -ignorewarnings
  cat > "$RULES/prints.pro" <<EOF
$(cat "$RULES/base.pro")
-printmapping $OUTDIRS/prints.map
-printusage $OUTDIRS/prints.usage
-printseeds $OUTDIRS/prints.seeds
-printconfiguration $OUTDIRS/prints.configuration
-whyareyoukeeping class $NS.MainActivity
EOF
  # Compiler passes the defaults never turn on.
  cat > "$RULES/rich.pro" <<EOF
$(cat "$RULES/base.pro")
-keepkotlinmetadata
-adaptclassstrings
-adaptresourcefilecontents SourceFile,SourceDir
-adaptresourcefilenames SourceFile
-renamesourcefileattribute SourceFile
-keepdirectories
-keepparameternames
-assumenosideeffects class $NS.** { *; }
-allowaccessmodification
-optimizationpasses 3
-checkdiscard class $NS.**
EOF
  cat > "$RULES/applymap.pro" <<EOF
$(cat "$RULES/base.pro")
-applymapping $OUTDIRS/prints.map
EOF

  # Tier A: the whole corpus.
  run full --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --pg-conf "$RULES/base.pro" --output "$OUTDIRS/full.jar" "${PROGS_ALL[@]}"
  run prints --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --pg-conf "$RULES/prints.pro" --output "$OUTDIRS/prints.jar" "${PROGS_ALL[@]}"
  run noopt --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --pg-conf "$RULES/noopt.pro" --output "$OUTDIRS/noopt.jar" "${PROGS_ALL[@]}"
  if [ -f "$OUTDIRS/prints.jar" ]; then
    # Second pass over the first pass' output with its mapping applied:
    # different compile-time starting point, repeated processing included.
    run second-pass --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
      --pg-conf "$RULES/applymap.pro" --output "$OUTDIRS/second.jar" \
      "$OUTDIRS/prints.jar"
  fi

  # Tier B: samples against the same library classpath.
  S=("${PROGS_SAMPLES[@]}")
  run noshrink --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --pg-conf "$RULES/noshrink.pro" --output "$OUTDIRS/noshrink.jar" "${S[@]}"
  run noobf --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --pg-conf "$RULES/noobf.pro" --output "$OUTDIRS/noobf.jar" "${S[@]}"
  run flatten --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --pg-conf "$RULES/flatten.pro" --output "$OUTDIRS/flatten.jar" "${S[@]}"
  run library --release --min-api 30 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --pg-conf "$RULES/library.pro" --output "$OUTDIRS/library.jar" "${S[@]}"
  run target11 --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --pg-conf "$RULES/target11.pro" --output "$OUTDIRS/target11.jar" "${S[@]}"
  run debug --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --pg-conf "$RULES/debug.pro" --output "$OUTDIRS/debug.jar" "${S[@]}"
  run rich --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --pg-conf "$RULES/rich.pro" --output "$OUTDIRS/rich.jar" "${S[@]}"
  run why --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --pg-conf "$RULES/why.pro" --output "$OUTDIRS/why.jar" "${S[@]}"
  run no-tree-shaking --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --no-tree-shaking --pg-conf "$RULES/base.pro" \
    --output "$OUTDIRS/notree.jar" "${S[@]}"
  run no-minification --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --no-minification --pg-conf "$RULES/base.pro" \
    --output "$OUTDIRS/nomin.jar" "${S[@]}"
  run classfile --release --lib "$ANDROID_LIB" --classfile "${CP_ARGS[@]}" \
    --pg-conf "$RULES/base.pro" --output "$(outdir "$OUTDIRS/classfile")" "${S[@]}"
  run dex-out --release --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" --dex \
    --pg-conf "$RULES/base.pro" --output "$OUTDIRS/dex-out.zip" "${S[@]}"
  run pg-compat --pg-compat --min-api 24 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --pg-conf "$RULES/base.pro" --output "$OUTDIRS/pgcompat.jar" "${S[@]}"
  run platform-build --release --min-api 30 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --android-platform-build --pg-conf "$RULES/base.pro" \
    --output "$OUTDIRS/platform.jar" "${S[@]}"
  run isolated-splits --release --min-api 30 "${LIB_ARGS[@]}" "${CP_ARGS[@]}" \
    --isolated-splits --pg-conf "$RULES/base.pro" \
    --output "$(outdir "$OUTDIRS/splits")" "${S[@]}"
  # Deliberate diagnostics: dangling reference, and a missing classpath so
  # the missing-class reporting and -dontwarn handling both run.
  run broken-input --release --min-api 24 "${LIB_ARGS[@]}" \
    --pg-conf "$RULES/missing.pro" --output "$OUTDIRS/broken.jar" \
    "$CORPUS/samples/broken.jar"
  run missing-classes --release --min-api 24 "${LIB_ARGS[@]}" \
    --pg-conf "$RULES/missing-ok.pro" --output "$OUTDIRS/missing.jar" "${S[@]}"
  run no-lib --release --min-api 24 --pg-conf "$RULES/missing-ok.pro" \
    --output "$OUTDIRS/nolib.jar" "${S[@]}"
fi

echo "--- merging $RUNS metadata directories into $META ---"
python3 "$REPO_ROOT/scripts/merge-meta.py" "$META" \
  $(for l in "${!RUN_META[@]}"; do printf '%s ' "${RUN_META[$l]}"; done)
echo "=== trace matrix done: runs=$RUNS failed=$FAILED ==="