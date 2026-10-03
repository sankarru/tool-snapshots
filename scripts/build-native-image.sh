#!/usr/bin/env bash
# Link GraalVM native binaries for D8 and R8 from the source-built r8.jar.
#
# Input is the jar produced by build-r8-source.sh plus the Maven jars it was
# compiled against; there is no tracing agent involved. What an image builder
# cannot see statically is spelled out explicitly here instead:
#
#   * resources. R8 reads its own resources at run time through
#     ClassLoader/Class.getResourceAsStream (VersionProperties,
#     AndroidApiDataAccess for resources/api_database.ser, AmendApiFromResources
#     for the api-model text files). Resources are not code, so nothing in the
#     sources points at them statically; they have to be included by name.
#
#   * the threading module provider. build-r8-source.sh patches that away in
#     ThreadingModule, so no reflection registration is needed for it.
#
# Everything else R8 does is ordinary static code (dex parsing, dex writing,
# ProGuard configs, retrace), which is why the image needs no metadata beyond
# the resource list.
#
# Env: WORK (required), JAVA_BIN, OUT_DIR, NI_EXTRA_OPTS, TOOLS (default "d8 r8"),
#       NATIVE_IMAGE_ARGS_FILE (optional, extra args one per line).
set -euo pipefail

WORK="${WORK:?set WORK}"
OUT_DIR="${OUT_DIR:-$WORK/native}"
TOOLS="${TOOLS:-d8 r8}"
JAVA_BIN="${JAVA_BIN:-$(dirname "$(readlink -f "$(command -v java)")")}"
R8_JAR="${R8_JAR:-$WORK/r8-src.jar}"

say() { echo "[native-image] $*"; }

[ -f "$R8_JAR" ] || { echo "missing $R8_JAR (run build-r8-source.sh first)"; exit 1; }

# native-image lives next to java in a GraalVM installation.
NI="$JAVA_BIN/native-image"
[ -x "$NI" ] || { echo "no native-image at $NI (set JAVA_BIN to a GraalVM)"; exit 1; }
say "native-image: $("$NI" --version)"

DEPS="$(find "$WORK/r8-src/deps" -name '*.jar' -not -name 'protoc-*' \
          -not -name 'kotlin-compiler-embeddable-*' | paste -sd: -)"
CP="$R8_JAR:$DEPS"

mkdir -p "$OUT_DIR"

# `R8 main`, `D8 main`, `--version`, and `System.exit` codes all come from here.
COMMON_OPTS=(
  --no-fallback
  -H:+ReportExceptionStackTraces
  -H:-CheckToolchain
  # Default to the ARMv8-A baseline instead of whatever the build host happens
  # to support: the runner has LSE atomics and generates casal/ldadd for them,
  # which makes the image refuse to start on any machine without ARMv8.1 (a
  # plain qemu/aarch64 VM, some older phones). Every arm64 Android device and
  # every Mac has the baseline.
  -march=armv8-a
  # Resources R8 loads through the class loader at run time. `resources/.*`
  # covers api_database.ser, hidden.api.txt, hidden.jar.txt and
  # missing.api.txt; the version file sits at the root of the jar.
  -H:IncludeResources=r8-version\.properties
  -H:IncludeResources=resources/.*
)

if [ -n "${NATIVE_IMAGE_ARGS_FILE:-}" ] && [ -f "$NATIVE_IMAGE_ARGS_FILE" ]; then
  while IFS= read -r arg; do
    [ -n "$arg" ] && COMMON_OPTS+=("$arg")
  done < "$NATIVE_IMAGE_ARGS_FILE"
fi
# shellcheck disable=SC2206
[ -n "${NI_EXTRA_OPTS:-}" ] && COMMON_OPTS+=(${NI_EXTRA_OPTS})

entry_point() {
  case "$1" in
    d8) echo com.android.tools.r8.D8 ;;
    r8) echo com.android.tools.r8.R8 ;;
    *) echo "unknown tool: $1" >&2; return 1 ;;
  esac
}

for tool in $TOOLS; do
  main="$(entry_point "$tool")"
  out="$OUT_DIR/$tool-snapshot"
  log="$OUT_DIR/$tool-snapshot.native-image.log"
  say "linking $tool ($main) -> $out"
  # Keep the full command in the log: when an image build fails, this is the
  # first thing needed to reproduce it.
  {
    echo "classpath: $CP"
    echo "command: $NI -cp $CP ${COMMON_OPTS[*]} -o $out $main"
  } > "$log"
  start=$(date +%s)
  if "$NI" -cp "$CP" "${COMMON_OPTS[@]}" -o "$out" "$main" >> "$log" 2>&1; then
    say "$tool: ok in $(( $(date +%s) - start ))s, $(du -h "$out" | cut -f1)"
  else
    say "$tool: FAILED (see $log)"
    tail -40 "$log"
    exit 1
  fi
  # A native binary that cannot report its version is not worth shipping.
  "$out" --version
done

say "done: $OUT_DIR"