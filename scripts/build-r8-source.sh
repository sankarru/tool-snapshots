#!/usr/bin/env bash
# Build r8.jar out of the Google-hosted R8 sources with nothing but javac.
#
# Why not R8's own build: `tools/gradle.py` downloads a hermetic dependency set
# from a Google Cloud Storage bucket through gsutil, which is not something a
# public CI runner can do. The compiler itself has no such dependency: src/ is
# plain Java (no Kotlin), and everything it imports from the outside world is a
# normal Maven artifact pinned in gradle/libs.versions.toml. So: fetch the
# source archive from r8.googlesource.com, read the version catalog, download
# those jars, run javac over the module source sets, and package the result.
#
# Env: WORK (required), JAVA_BIN, R8_REPO_URL, R8_REF, R8_JAVA_RELEASE.
# Writes: $WORK/r8-src/{src,deps,classes,res} and $WORK/r8-src.jar
set -euo pipefail

WORK="${WORK:?set WORK}"
if [ -z "${JAVA_BIN:-}" ]; then
  if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/javac" ]; then
    JAVA_BIN="$JAVA_HOME/bin"
  else
    JAVA_BIN="$(dirname "$(readlink -f "$(command -v javac)")")"
  fi
fi
R8_REPO_URL="${R8_REPO_URL:-https://r8.googlesource.com/r8}"
R8_REF="${R8_REF:-main}"
R8_JAVA_RELEASE="${R8_JAVA_RELEASE:-17}"

BASE="$WORK/r8-src"
SRC="$BASE/src"
DEPS="$BASE/deps"
CLASSES="$BASE/classes"
RES="$BASE/res"
JAR="$WORK/r8-src.jar"
DL="$BASE/dl"

say() { echo "[r8-src] $*"; }

# googlesource and storage.googleapis.com both return 503 under CI load, and a
# tarball that half-downloaded is worse than one that never started. Retry with
# backoff on every transient failure, including connection resets.
CURL=(curl -sSfL --retry 8 --retry-delay 5 --retry-max-time 300
      --retry-all-errors --connect-timeout 30)

# The module source sets that make up the shipped jar. `main` is the compiler,
# the rest are libraries it links against.
# library_desugar is deliberately absent: it is the desugared-library payload
# (its sources declare java.nio.* and friends), not part of the compiler jar.
MODULES=(main utils assistant keepradius keepanno resourceshrinker)

fetch_source() {
  local sha
  # Record which upstream commit this is, for --version and the report. Done
  # before the cache check so a reused checkout still knows its revision.
  sha="$("${CURL[@]}" "$R8_REPO_URL/+log/refs/heads/$R8_REF?format=JSON" 2>/dev/null |
         tr -d ' \n' | sed -n 's/.*"log":\[{"commit":"\([0-9a-f]*\)".*/\1/p' || true)"
  mkdir -p "$BASE"
  echo "${sha:-unknown}" > "$BASE/source-sha.txt"
  if [ -d "$SRC" ] && [ -f "$SRC/settings.gradle.kts" ]; then
    say "source already present: $SRC (sha ${sha:-unknown})"
    return
  fi
  mkdir -p "$DL"
  local tgz="$DL/r8-$R8_REF.tar.gz"
  # gitiles serves a tar of the tree for any ref; no git, no clone.
  local url="$R8_REPO_URL/+archive/refs/heads/$R8_REF.tar.gz"
  say "fetching $url"
  "${CURL[@]}" -o "$tgz.part" "$url"
  mv "$tgz.part" "$tgz"
  rm -rf "$SRC"; mkdir -p "$SRC"
  # The archive has no top-level directory; reject entries that try to escape
  # (path traversal in a remote tarball).
  tar -tzf "$tgz" | grep -qE '(^|/)\.\.(/|$)' && { echo "tarball contains ../"; exit 1; }
  tar -xzf "$tgz" -C "$SRC"
  [ -f "$SRC/settings.gradle.kts" ] || { echo "unexpected archive layout"; exit 1; }
  say "source sha: ${sha:-unknown}"
}

# Every Maven coordinate the compiled modules need, read out of R8's own version
# catalog and build files instead of being copied here: compilerDeps plus
# whatever libs.<alias> those build files mention (the resource shrinker, for
# one, pulls in the layoutlib/AAPT2 protos). Tracks upstream by construction.
dep_list() {
  python3 - "$SRC/gradle/libs.versions.toml" "$SRC" "$@" <<'PY'
import os, re, sys, tomllib

data = tomllib.load(open(sys.argv[1], "rb"))
versions, libs, bundles = data["versions"], data["libraries"], data["bundles"]

def resolve(alias):
    """-> (module, version) or None"""
    lib = libs.get(alias)
    if lib is None or "module" not in lib:
        return None
    ver = lib.get("version")
    if isinstance(ver, dict):            # version = { ref = "guava" }
        ver = versions[ver["ref"]]
    return lib["module"], ver

wanted = set()
builds = [f"{sys.argv[2]}/d8_r8/{m}/build.gradle.kts" for m in sys.argv[3:]]
for build in [b for b in builds if os.path.exists(b)]:
    text = open(build).read()
    for alias in re.findall(r"\blibs\.([A-Za-z0-9_]+)", text):
        if alias != "bundles":           # libs.bundles.x, handled below
            wanted.add(alias)
    for alias in re.findall(r"\blibs\.bundles\.([A-Za-z0-9_]+)", text):
        wanted.add("bundles." + alias)
wanted.add("bundles.compilerDeps")
# Artifacts this build needs that upstream pulls from its internalized GCS set
# instead of the catalog: androidx annotations, the Kotlin toolchain, and the
# asm-tree/asm-analysis siblings of asm.
wanted.update(a for a in ("androidxAnnotation", "kotlinStdLib",
                         "kotlinCompilerEmbeddable", "kotlinScriptRuntime",
                         "kotlinReflect", "androidxTracingDriverDesktop")
              if a in libs)

coords = []
for alias in sorted(wanted):
    if alias.startswith("bundles."):
        members = bundles.get(alias[len("bundles."):])
        if members is None:
            print(f"!unknown:{alias}", file=sys.stderr)
            continue
        for member in members:
            got = resolve(member)
            if got and not got[0].startswith("com.android.tools:r8"):
                coords.append(got)
    else:
        got = resolve(alias)
        if got and not got[0].startswith("com.android.tools:r8"):
            coords.append(got)
        else:
            print(f"!unknown:{alias}", file=sys.stderr)

extras = [
    # asm-tree/asm-analysis sit next to asm; the catalog only lists the three.
    (f"org.ow2.asm:asm-tree", versions["asm"]),
    (f"org.ow2.asm:asm-analysis", versions["asm"]),
    # kotlin-stdlib-jdk8 is a thin wrapper; the compiler needs the real one.
    (f"org.jetbrains.kotlin:kotlin-stdlib", versions["kotlinGradlePlugin"]),
    (f"org.jetbrains.kotlin:kotlin-daemon-embeddable", versions["kotlinGradlePlugin"]),
    # The embeddable compiler's CLI runs on coroutines.
    (f"org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm", "1.8.1"),
    (f"org.jetbrains:annotations", "24.1.0"),
    # The desktop tracing wire driver and okio back PerfettoTiming.
    (f"androidx.tracing:tracing-wire-desktop", versions["androidxTracing"]),
    (f"com.squareup.okio:okio-jvm", "3.9.0"),
]
# com.android.tools:annotations (the @Nullable/@NonNull the SDK jars use) is not
# in the catalog; it moves in lockstep with the tools artifacts.
tools_version = next((v for m, v in coords if m.startswith("com.android.tools:")), None)
if tools_version:
    extras.append((f"com.android.tools:annotations", tools_version))

for module, ver in coords + extras:
    print(f"{module}:{ver}")
PY
}

# protoc has to match protobuf-java, so the catalog also gets asked for a single
# version (`catalog_version com.google.protobuf:protobuf-java`).
catalog_version() {
  dep_list "${MODULES[@]}" | sed -n 's|^com\.google\.protobuf:protobuf-java:\(.*\)$|\1|p' | head -1
}

# androidx/com.android artifacts live on Google Maven; everything else on Central.
repo_url() {
  # NB: bash `case` has no pattern alternation, hence one arm per pattern.
  case "$1" in
    androidx.*) echo "https://dl.google.com/dl/android/maven2" ;;
    com.android) echo "https://dl.google.com/dl/android/maven2" ;;
    com.android.*) echo "https://dl.google.com/dl/android/maven2" ;;
    *) echo "https://repo1.maven.org/maven2" ;;
  esac
}

fetch_deps() {
  mkdir -p "$DEPS" "$DL"
  local coord group rest artifact ver base cand f rc=0
  while IFS= read -r coord; do
    [ -n "$coord" ] || continue
    group="${coord%%:*}"; rest="${coord#*:}"; artifact="${rest%%:*}"; ver="${rest##*:}"
    base="$artifact-$ver"
    # Google Maven serves a metadata-only .jar for Kotlin-multiplatform androidx
    # artifacts (annotation, tracing, collection); their classes live in the
    # -jvm variant or in the .aar. So try those in order and keep the first
    # candidate that actually contains classes.
    f=""
    stub=""
    if [ -f "$DEPS/$base.jar" ] && [ -n "$(unzip -Z1 "$DEPS/$base.jar" 2>/dev/null | sed -n '/\.class$/p' | head -1)" ]; then
      f="$DEPS/$base.jar"
    elif [ -f "$DEPS/$base/classes.jar" ]; then
      f="$DEPS/$base/classes.jar"
    else
      for cand in "$artifact" "$artifact-jvm"; do
        local path tmp dst
        path="${group//.//}/$cand/$ver/$cand-$ver"
        tmp="$DL/$base.tmp"
        dst="$DEPS/$base"
        # NB: no `unzip | grep -q` here. With pipefail, grep exiting early makes
        # unzip die on SIGPIPE and the whole test report failure.
        if "${CURL[@]}" -o "$tmp" \
             "$(repo_url "$group")/$path.jar" 2>/dev/null; then
          unzip -Z1 "$tmp" > "$tmp.list" 2>/dev/null || true
          if grep -q '\.class$' "$tmp.list"; then
            mv "$tmp" "$DEPS/$base.jar"; f="$DEPS/$base.jar"; break
          fi
          stub="$DL/$base.stub"           # real artifact, but no classes in it
          mv "$tmp" "$stub"
        fi
        rm -f "$tmp" "$tmp.list"
        if "${CURL[@]}" -o "$tmp" \
             "$(repo_url "$group")/$path.aar" 2>/dev/null; then
          unzip -p "$tmp" classes.jar > "$tmp.cj" 2>/dev/null || true
          if grep -aq 'class' "$tmp.cj"; then
            mkdir -p "$dst"
            if unzip -o -q "$tmp" classes.jar -d "$dst" 2>/dev/null; then
              f="$dst/classes.jar"; break
            fi
            rm -rf "$dst"
          fi
          stub="$DL/$base.stub"
          mv "$tmp" "$stub"
        fi
        rm -f "$tmp" "$tmp.list" "$tmp.cj"
      done
    fi
    if [ -z "$f" ] && [ -n "$stub" ]; then
      # Android variants of the multiplatform tracing artifacts publish no
      # classes at all; the desktop ones carry them. Keep the stub for fidelity.
      mv "$stub" "$DEPS/$base.stub"; f="$DEPS/$base.stub"
      say "dep $coord -> $(basename "$f") (no classes, metadata only)"
    elif [ -n "$f" ]; then
      say "dep $coord -> $(basename "$f")"
    else
      say "ERROR: could not fetch $coord (no jar/-jvm/aar)"
      rc=1
    fi
  done < <(dep_list "${MODULES[@]}")
  return $rc
}

# keepanno ships its keep-spec schema as a .proto file and the Gradle build runs
# protoc over it. protoc itself is a plain Maven binary, so: fetch the one that
# matches the protobuf-java version from the catalog and run it by hand.
gen_protos() {
  local ver protoc arch gen
  ver="$(catalog_version com.google.protobuf:protobuf-java)"
  [ -n "$ver" ] || { echo "no protobuf version in catalog"; return 1; }
  case "$(uname -m)" in
    aarch64|arm64) arch=linux-aarch_64 ;;
    x86_64|amd64) arch=linux-x86_64 ;;
    *) echo "no protoc for $(uname -m)"; return 1 ;;
  esac
  protoc="$DEPS/protoc-$ver.exe"
  if [ ! -x "$protoc" ]; then
    say "fetching protoc $ver ($arch)"
    "${CURL[@]}" -o "$protoc" \
      "https://repo1.maven.org/maven2/com/google/protobuf/protoc/$ver/protoc-$ver-$arch.exe"
    chmod +x "$protoc"
  fi
  gen="$BASE/generated"
  rm -rf "$gen"; mkdir -p "$gen"
  local protos=()
  while IFS= read -r f; do protos+=("$f"); done < <(find "$SRC/src" -path '*/proto/*.proto' \
      -not -path '*/libanalyzer/*')
  [ "${#protos[@]}" -gt 0 ] || return 0
  local inc=()
  while IFS= read -r d; do inc+=("-I" "$d"); done < <(find "$SRC/src" -type d -name proto \
      -not -path '*/libanalyzer/*')
  say "protoc: ${#protos[@]} proto file(s)"
  "$protoc" "${inc[@]}" --java_out="$gen" "${protos[@]}"
  find "$gen" -name '*.java' | sed 's/^/[r8-src] proto-gen: /'
}

# All .java (plus protoc output and the native-image overlay) in one list, so
# the Kotlin pass and the javac pass see exactly the same tree.
collect_java_sources() {
  local srcs="$BASE/sources.txt" m
  : > "$srcs"
  for m in "${MODULES[@]}"; do
    if [ -d "$SRC/src/$m/java" ]; then
      find "$SRC/src/$m/java" -name '*.java' >> "$srcs"
    else
      say "WARNING: module source set missing: src/$m/java"
    fi
  done
  # protobuf output for the keepanno and keepradius schemas.
  if [ -d "$BASE/generated" ]; then
    find "$BASE/generated" -name '*.java' >> "$srcs"
  fi
  # Native-image adaptations applied on top of the upstream sources.
  if [ -d "$HERE/r8-overlay" ]; then
    find "$HERE/r8-overlay" -name '*.java' >> "$srcs"
    say "overlay sources: $(find "$HERE/r8-overlay" -name '*.java' | wc -l)"
  fi
}

dep_cp() {
  find "$DEPS" -name '*.jar' -not -name 'kotlin-compiler-embeddable-*' -not -name 'protoc-*' |
    paste -sd: -
}

# 36 of the sources are Kotlin (keepanno's androidx.annotation.keep annotations
# and the resource-shrinker helpers). Gradle would compile them with the Kotlin
# plugin; here it is the embeddable compiler, invoked directly. It gets the .java
# files too, purely so Kotlin can resolve across the two languages.
compile_kotlin() {
  local kt ksrcs args launch kclasses
  kt="$(find "$DEPS" -name 'kotlin-compiler-embeddable-*.jar' | head -1)"
  [ -n "$kt" ] || { echo "kotlin-compiler-embeddable was not fetched"; return 1; }
  ksrcs="$BASE/kotlin-sources.txt"
  : > "$ksrcs"
  local m
  for m in "${MODULES[@]}"; do
    [ -d "$SRC/src/$m/java" ] && find "$SRC/src/$m/java" -name '*.kt' >> "$ksrcs"
  done
  [ -s "$ksrcs" ] || { say "no Kotlin sources"; return 0; }
  args="$BASE/kotlin-args.txt"
  cat "$ksrcs" "$BASE/sources.txt" > "$args"
  launch="$(find "$DEPS" -name '*.jar' -not -name 'protoc-*' | paste -sd: -)"
  kclasses="$BASE/classes-kotlin"
  rm -rf "$kclasses"; mkdir -p "$kclasses"
  say "kotlinc: $(wc -l < "$ksrcs") .kt files (+ $(wc -l < "$BASE/sources.txt") .java for resolution)"
  "$JAVA_BIN/java" -Xmx4g -cp "$launch" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -nowarn -jvm-target "$R8_JAVA_RELEASE" -classpath "$(dep_cp)" \
    -d "$kclasses" "@$args"
}

# Upstream sources plus the adaptations in scripts/r8-overlay: patches against
# upstream files, extra Java sources, and extra resources. Patches are applied
# with `patch`, so upstream drift shows up as a failed dry run instead of a
# silently mangled file.
apply_overlay() {
  [ -d "$HERE/r8-overlay" ] || return 0
  local p n=0
  for p in "$HERE"/r8-overlay/patches/*.patch; do
    [ -e "$p" ] || continue
    n=$((n + 1))
    if patch -d "$SRC" -p1 --batch --forward --dry-run < "$p" > /dev/null 2>&1; then
      patch -d "$SRC" -p1 --batch --forward < "$p" > /dev/null
      say "patched $(basename "$p")"
    else
      say "WARNING: patch does not apply, skipping (upstream drift?): $(basename "$p")"
    fi
  done
  [ "$n" -gt 0 ] || say "WARNING: no overlay patches found in $HERE/r8-overlay/patches"
}

# R8's own build fetches a few prebuilt blobs from gs://r8-deps through gsutil.
# That bucket is public read over HTTPS and its objects are named after their own
# SHA1 (which is what the .sha1 files in third_party/ contain), so no gsutil and
# no credentials are needed. The api database is what makes resource shrinking
# able to tell which android.R.attr.* / android.content.* constants a resource
# table references.
fetch_api_database() {
  local sha_file sha tgz want
  sha_file="$SRC/third_party/api_database/api_database.tar.gz.sha1"
  [ -f "$sha_file" ] || { say "no api_database.sha1 in the tree; skipping"; return 0; }
  sha="$(tr -d ' \n' < "$sha_file")"
  tgz="$DL/api_database.tar.gz"
  if [ ! -f "$tgz" ]; then
    say "fetching api database $sha from storage.googleapis.com/r8-deps"
    "${CURL[@]}" -o "$tgz.part" "https://storage.googleapis.com/r8-deps/$sha"
    mv "$tgz.part" "$tgz"
  fi
  want="$sha"
  [ "$(sha1sum "$tgz" | cut -d' ' -f1)" = "$want" ] || { echo "api database sha1 mismatch"; return 1; }
  rm -rf "$BASE/api_database"; mkdir -p "$BASE/api_database"
  tar -xzf "$tgz" -C "$BASE/api_database" --strip-components=1
  [ -f "$BASE/api_database/resources/api_database.ser" ] ||
    { echo "api_database.ser missing from the tarball"; return 1; }
  say "api database: $(du -h "$BASE/api_database/resources/api_database.ser" | cut -f1)"
}

compile_r8() {
  rm -rf "$CLASSES"; mkdir -p "$CLASSES"
  local srcs="$BASE/sources.txt"
  say "javac: $(wc -l < "$srcs") files (release $R8_JAVA_RELEASE)"
  "$JAVA_BIN/javac" -J-Xmx4g -nowarn -proc:none -encoding UTF-8 \
    --release "$R8_JAVA_RELEASE" -classpath "$(dep_cp):$BASE/classes-kotlin" \
    -d "$CLASSES" "@$srcs"
}

package_r8() {
  rm -rf "$RES"; mkdir -p "$RES"
  # resources/ ships with the compiler (API level files for resource shrinking).
  if [ -d "$SRC/src/main/resources" ]; then
    cp -r "$SRC/src/main/resources/." "$RES/"
  fi
  # VersionProperties reads this from the classpath root; generate it from the
  # source revision so `--version` names the build.
  local sha; sha="$(cat "$BASE/source-sha.txt")"
  cat > "$RES/r8-version.properties" <<EOF
version-file.version.code=1
version.sha=$sha
releaser=native-image-snapshot
EOF
  if [ -f "$BASE/api_database/resources/api_database.ser" ]; then
    mkdir -p "$RES/resources"
    cp "$BASE/api_database/resources/api_database.ser" "$RES/resources/"
  fi
  # Any META-INF/services entries from the overlay (native-image Feature).
  if [ -d "$HERE/r8-overlay/META-INF" ]; then
    cp -r "$HERE/r8-overlay/META-INF" "$RES/"
  fi
  rm -f "$JAR"
  ( cd "$CLASSES" && "$JAVA_BIN/jar" --create --file "$JAR" . )
  ( cd "$RES" && "$JAVA_BIN/jar" --update --file "$JAR" . )
  # R8 memory-maps the api database, so it has to be stored, not deflated.
  if [ -f "$RES/resources/api_database.ser" ]; then
    "$JAVA_BIN/jar" --update --file "$JAR" --no-compress -C "$RES" resources/api_database.ser
  fi
  say "jar: $JAR ($(du -h "$JAR" | cut -f1)), $(find "$CLASSES" -name '*.class' | wc -l) classes"
}

# The android.jar the JVM check dexes and shrinks against. Search the roots an
# SDK can live in, and insist on a real jar: an interrupted sdkmanager unpack
# leaves a stub android.jar behind, which R8 reports as a wall of missing
# java.lang.Object errors rather than as a broken SDK.
find_android_jar() {
  local root
  for root in "${ANDROID_SDK:-}" "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
              "$HOME/Android/Sdk" "$HOME/.android/sdk" /usr/local/lib/android/sdk; do
    [ -n "$root" ] || continue
    find "$root/platforms" -maxdepth 2 -name android.jar -size +1M 2>/dev/null
  done | sort -V | tail -1 || true
}

verify_on_jvm() {
  say "verifying on the JVM: D8/R8 --version and a dex run"
  local android_jar
  android_jar="$(find_android_jar)"
  if [ -n "$android_jar" ]; then
    say "android lib: $android_jar ($(du -h "$android_jar" | cut -f1))"
  else
    echo "no android.jar found; set ANDROID_SDK" >&2
    exit 1
  fi
  local hello="$BASE/hello.jar" out="$BASE/hello-out"
  rm -rf "$out"; mkdir -p "$out" "$BASE/hello-src"
  cat > "$BASE/hello-src/Hello.java" <<'EOF'
package hello;
public class Hello {
  public interface Api { default int one() { return 1; } static int two() { return 2; } }
  public static class Impl implements Api {}
  public static void main(String[] args) { System.out.println(new Impl().one() + Api.two()); }
}
EOF
  "$JAVA_BIN/javac" --release 11 -d "$BASE/hello-classes" "$BASE/hello-src/Hello.java"
  ( cd "$BASE/hello-classes" && "$JAVA_BIN/jar" --create --file "$hello" . )
  # Upstream internalizes its dependencies into r8.jar; here they stay beside
  # it, so the runtime classpath is the jar plus whatever dep_cp finds.
  local run_cp="$JAR:$(dep_cp)"
  "$JAVA_BIN/java" -cp "$run_cp" com.android.tools.r8.D8 --version
  "$JAVA_BIN/java" -cp "$run_cp" com.android.tools.r8.R8 --version
  local lib=(--lib "$android_jar")
  "$JAVA_BIN/java" -cp "$run_cp" com.android.tools.r8.D8 "${lib[@]}" --release --min-api 24 \
    --output "$out" "$hello"
  ls "$out"
  # Same thing through R8 with a keep rule, to cover the shrinking path.
  local rules="$BASE/hello.pro" shrunk="$BASE/hello-shrunk.jar"
  printf -- '-keep public class hello.Hello { public static void main(java.lang.String[]); }\n' > "$rules"
  "$JAVA_BIN/java" -cp "$run_cp" com.android.tools.r8.R8 "${lib[@]}" --release --min-api 24 \
    --pg-conf "$rules" --output "$shrunk" "$hello"
  ls -la "$shrunk"
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fetch_source
apply_overlay
fetch_deps
fetch_api_database
gen_protos
collect_java_sources
compile_kotlin
compile_r8
package_r8
verify_on_jvm
say "done: $JAR"