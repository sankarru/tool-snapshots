#!/usr/bin/env bash
# Trace a JVM tool with the native-image agent, link it with native-image,
# and smoke-test the resulting snapshot binary.
# Env: TOOL (d8|r8|kotlinc), KOTLIN_TAG (vX.Y.Z), R8_VERSION (X.Y.Z).
# Requires: GraalVM 21 (JAVA_HOME), and for d8/r8 an Android SDK (ANDROID_HOME).
set -euo pipefail

TOOL="${TOOL:?set TOOL}"
WORK="$PWD/work-$TOOL"
OUT="$PWD/out"
META="$WORK/meta"
SAMPLE="$WORK/sample"
mkdir -p "$WORK" "$OUT" "$META" "$SAMPLE"

GRAAL_BIN="$JAVA_HOME/bin"
NI="$GRAAL_BIN/native-image"
AGENT="-agentlib:native-image-agent=config-output-dir=$META"

echo "=== tool=$TOOL graal=$(basename "$JAVA_HOME") ==="

fetch_r8() {
  if [ ! -f "$WORK/r8.jar" ]; then
    curl -sSfL -o "$WORK/r8.jar" \
      "https://dl.google.com/dl/android/maven2/com/android/tools/r8/${R8_VERSION:?}/r8-${R8_VERSION}.jar"
  fi
  echo "$WORK/r8.jar"
}

fetch_kotlinc() {
  if [ ! -d "$WORK/kotlinc" ]; then
    curl -sSfL -o "$WORK/kotlinc.zip" \
      "https://github.com/JetBrains/kotlin/releases/download/${KOTLIN_TAG:?}/kotlin-compiler-${KOTLIN_TAG#v}.zip"
    unzip -q "$WORK/kotlinc.zip" -d "$WORK"
  fi
  echo "$WORK/kotlinc"
}

make_sample_jar() {
  # Tiny Java sample -> hello.jar, the D8/R8 tracing + verification input.
  mkdir -p "$SAMPLE/src/hello"
  cat > "$SAMPLE/src/hello/Hello.java" <<'EOF'
package hello;
public class Hello {
  public static void main(String[] args) {
    System.out.println("hello from " + (args.length > 0 ? args[0] : "snapshot"));
  }
}
EOF
  "$JAVA_HOME/bin/javac" -d "$SAMPLE/classes" "$SAMPLE/src/hello/Hello.java"
  "$JAVA_HOME/bin/jar" --create --file "$SAMPLE/hello.jar" -C "$SAMPLE/classes" .
  echo "$SAMPLE/hello.jar"
}

trace_d8() {
  local r8jar="$1" hello="$2"
  local android_jar="$ANDROID_HOME/platforms/android-35/android.jar"
  rm -rf "$SAMPLE/dex-out" && mkdir -p "$SAMPLE/dex-out"
  # Real dex run under the agent: this is what teaches native-image which
  # classes/resources D8 touches. Not `--version` (that traces nothing).
  "$JAVA_HOME/bin/java" "$AGENT" -cp "$r8jar" com.android.tools.r8.D8 \
    --lib "$android_jar" --min-api 24 \
    --output "$SAMPLE/dex-out" "$hello"
  ls "$SAMPLE/dex-out"
}

trace_r8() {
  local r8jar="$1" hello="$2"
  cat > "$SAMPLE/rules.pro" <<'EOF'
-keep public class hello.Hello { public static void main(java.lang.String[]); }
EOF
  rm -rf "$SAMPLE/r8-out.jar"
  "$JAVA_HOME/bin/java" "$AGENT" -cp "$r8jar" com.android.tools.r8.R8 \
    --lib "$ANDROID_HOME/platforms/android-35/android.jar" \
    --min-api 24 --pg-conf "$SAMPLE/rules.pro" \
    --output "$SAMPLE/r8-out.jar" "$hello"
  ls -la "$SAMPLE/r8-out.jar"
}

trace_kotlinc() {
  local kdir="$1"
  # kotlin-compiler.jar bundles jline native-image.properties files whose
  # reflection/resource JSONs are NOT in the dist (packaging bug) -- the
  # link aborts on the dangling reference. Strip those dirs by repacking
  # the jar IN PLACE: kotlinc derives its home dir from the compiler jar's
  # location, so the patched jar must stay in lib/ next to kotlin-stdlib.
  python3 - "$kdir/lib/kotlin-compiler.jar" <<'EOF'
import sys, zipfile, os
src = sys.argv[1]
tmp = src + '.patched'
zin = zipfile.ZipFile(src)
zout = zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED)
dropped = 0
for item in zin.infolist():
    if item.filename.startswith('META-INF/native-image/org.jline/'):
        dropped += 1
        continue
    zout.writestr(item, zin.read(item.filename))
zin.close(); zout.close()
os.replace(tmp, src)
print(f"patched kotlin-compiler.jar in place, dropped {dropped} dangling jline entries")
EOF
  local cp
  cp=$(ls "$kdir"/lib/*.jar | grep -v -e sources -e android-extensions | tr '\n' ':')
  # Extra compile-only deps for the coverage samples (coroutines + explicit
  # serialization core; the serialization *plugin* ships in the dist).
  mkdir -p "$WORK/tracelibs"
  for a in \
    "org/jetbrains/kotlinx/kotlinx-coroutines-core-jvm/1.10.2/kotlinx-coroutines-core-jvm-1.10.2.jar" \
    "org/jetbrains/kotlinx/kotlinx-serialization-core-jvm/1.9.0/kotlinx-serialization-core-jvm-1.9.0.jar" \
    "org/jetbrains/kotlinx/kotlinx-serialization-json-jvm/1.9.0/kotlinx-serialization-json-jvm-1.9.0.jar" \
    "org/jetbrains/compose/runtime/runtime-desktop/1.7.1/runtime-desktop-1.7.1.jar" \
  ; do
    f="$WORK/tracelibs/$(basename "$a")"
    [ -f "$f" ] || curl -sSfL -o "$f" "https://repo1.maven.org/maven2/$a"
    cp="$cp$f:"
  done
  SPLUG="$kdir/lib/kotlin-serialization-compiler-plugin.jar"
  CPLUG="$kdir/lib/compose-compiler-plugin.jar"
  SAMPLES="$PWD/samples"
  [ -d "$SAMPLES" ] || { echo "samples/ dir missing" >&2; exit 1; }
  KJ="$JAVA_HOME/bin/java $AGENT -cp $cp org.jetbrains.kotlin.cli.jvm.K2JVMCompiler"
  # NOTE: the java -cp above loads the COMPILER; the COMPILATION classpath
  # must be passed explicitly via kotlinc -cp (K2 does not inherit the JVM
  # classpath, and only the stdlib is auto-found via kotlin-home).

  echo "--- trace: basic + warnings ---"
  rm -rf "$SAMPLE/kt-out" && mkdir -p "$SAMPLE/kt-out"
  # shellcheck disable=SC2086
  $KJ -cp "$cp" -d "$SAMPLE/kt-out" "$SAMPLES/hello.kt" "$SAMPLES/warn.kt"
  find "$SAMPLE/kt-out" -name "*.class"

  echo "--- trace: language surface (data/sealed/enum/generics/coroutines) ---"
  rm -rf "$SAMPLE/kt-feat" && mkdir -p "$SAMPLE/kt-feat"
  # shellcheck disable=SC2086
  $KJ -cp "$cp" -d "$SAMPLE/kt-feat" "$SAMPLES/features.kt"

  echo "--- trace: kotlin-reflect ---"
  rm -rf "$SAMPLE/kt-refl" && mkdir -p "$SAMPLE/kt-refl"
  # shellcheck disable=SC2086
  $KJ -cp "$cp" -d "$SAMPLE/kt-refl" "$SAMPLES/reflect.kt"

  echo "--- trace: serialization plugin ---"
  rm -rf "$SAMPLE/kt-ser" && mkdir -p "$SAMPLE/kt-ser"
  # shellcheck disable=SC2086
  $KJ -cp "$cp" -Xplugin="$SPLUG" -d "$SAMPLE/kt-ser" "$SAMPLES/serial.kt"

  echo "--- trace: compose plugin ---"
  rm -rf "$SAMPLE/kt-cmp" && mkdir -p "$SAMPLE/kt-cmp"
  # shellcheck disable=SC2086
  $KJ -cp "$cp" -Xplugin="$CPLUG" -d "$SAMPLE/kt-cmp" "$SAMPLES/compose.kt"

  echo "--- trace: diagnostics (broken file, message bundles) ---"
  rm -rf "$SAMPLE/kt-err" && mkdir -p "$SAMPLE/kt-err"
  # shellcheck disable=SC2086
  $KJ -cp "$cp" -d "$SAMPLE/kt-err" "$SAMPLES/err.kt" || true

  echo "--- trace: script execution ---"
  # shellcheck disable=SC2086
  $KJ -cp "$cp" -script "$SAMPLES/script.kts" || true

  echo "--- trace: legacy jvm-target backend ---"
  rm -rf "$SAMPLE/kt-18" && mkdir -p "$SAMPLE/kt-18"
  # shellcheck disable=SC2086
  $KJ -cp "$cp" -jvm-target 1.8 -d "$SAMPLE/kt-18" "$SAMPLES/hello.kt"

  echo "$cp" > "$WORK/kotlinc-cp.txt"
  echo "$SPLUG" > "$WORK/kotlinc-splug.txt"
}

link_snapshot() {
  # $1 = main class, $2 = classpath, $3 = binary name
  echo "--- traced metadata ($META) ---"
  ls -la "$META"
  for f in reflect-config.json jni-config.json resource-config.json \
           proxy-config.json serialization-config.json; do
    [ -f "$META/$f" ] && echo "$f: $(python3 -c "import json;print(len(json.load(open('$META/$f'))))" 2>/dev/null || echo '?') entries"
  done
  # Keep the trace next to the binary so later runs can diff/audit it.
  rm -rf "$OUT/$3-meta" && cp -r "$META" "$OUT/$3-meta"
  "$NI" \
    -J-Xmx12g \
    --no-fallback \
    --allow-incomplete-classpath \
    -H:ConfigurationFileDirectories="$META" \
    -H:Name="$OUT/$3" \
    -H:+ReportExceptionStackTraces \
    -cp "$2" "$1"
  ls -la "$OUT/$3"
}

case "$TOOL" in
  d8)
    R8JAR="$(fetch_r8)"
    HELLO="$(make_sample_jar)"
    trace_d8 "$R8JAR" "$HELLO"
    link_snapshot com.android.tools.r8.D8 "$R8JAR" d8-snapshot
    echo "--- smoke: version ---"
    "$OUT/d8-snapshot" --version
    echo "--- smoke: dex hello.jar ---"
    rm -rf "$SAMPLE/dex-smoke" && mkdir -p "$SAMPLE/dex-smoke"
    "$OUT/d8-snapshot" --lib "$ANDROID_HOME/platforms/android-35/android.jar" \
      --min-api 24 --output "$SAMPLE/dex-smoke" "$HELLO"
    ls "$SAMPLE/dex-smoke"
    ;;
  r8)
    R8JAR="$(fetch_r8)"
    HELLO="$(make_sample_jar)"
    trace_r8 "$R8JAR" "$HELLO"
    link_snapshot com.android.tools.r8.R8 "$R8JAR" r8-snapshot
    echo "--- smoke: version ---"
    "$OUT/r8-snapshot" --version
    echo "--- smoke: shrink hello.jar ---"
    rm -f "$SAMPLE/r8-smoke.jar"
    "$OUT/r8-snapshot" --lib "$ANDROID_HOME/platforms/android-35/android.jar" \
      --min-api 24 --pg-conf "$SAMPLE/rules.pro" \
      --output "$SAMPLE/r8-smoke.jar" "$HELLO"
    ls -la "$SAMPLE/r8-smoke.jar"
    ;;
  kotlinc)
    KDIR="$(fetch_kotlinc)"
    trace_kotlinc "$KDIR"
    KCP="$(cat "$WORK/kotlinc-cp.txt")"
    SPLUG="$(cat "$WORK/kotlinc-splug.txt")"
    CPLUG="$KDIR/lib/compose-compiler-plugin.jar"
    link_snapshot org.jetbrains.kotlin.cli.jvm.K2JVMCompiler "$KCP" kotlinc-snapshot
    echo "--- smoke: version ---"
    # NOTE: -kotlin-home is required on EVERY invocation, including
    # -version: arg setup runs PathUtil discovery before anything else,
    # and discovery cannot work inside an image (no jar file path).
    "$OUT/kotlinc-snapshot" -kotlin-home "$KDIR" -version
    echo "--- smoke: compile full sample surface ---"
    rm -rf "$SAMPLE/kt-smoke" && mkdir -p "$SAMPLE/kt-smoke"
    # -kotlin-home is mandatory: the snapshot cannot discover the dist
    # layout via class-resource lookup (PathUtil.getResourcePathForClass has
    # no file path inside a native image), so point it at the home
    # explicitly. The home's lib/ (stdlib, reflect, plugins) must be present
    # at runtime -- the snapshot replaces only the launcher, not the dist.
    "$OUT/kotlinc-snapshot" -kotlin-home "$KDIR" -cp "$KCP" \
      -Xplugin="$SPLUG" \
      -d "$SAMPLE/kt-smoke" \
      "$PWD/samples/hello.kt" "$PWD/samples/features.kt" \
      "$PWD/samples/reflect.kt" "$PWD/samples/serial.kt" \
      "$PWD/samples/warn.kt"
    find "$SAMPLE/kt-smoke" -name "*.class" | head -8
    echo "--- smoke: compose plugin inside the image ---"
    rm -rf "$SAMPLE/kt-smoke-cmp" && mkdir -p "$SAMPLE/kt-smoke-cmp"
    "$OUT/kotlinc-snapshot" -kotlin-home "$KDIR" -cp "$KCP" \
      -Xplugin="$CPLUG" \
      -d "$SAMPLE/kt-smoke-cmp" "$PWD/samples/compose.kt"
    find "$SAMPLE/kt-smoke-cmp" -name "*.class" | head -4 && echo "COMPOSE-OK"
    echo "--- smoke: diagnostics still render ---"
    "$OUT/kotlinc-snapshot" -kotlin-home "$KDIR" -cp "$KCP" \
      -d "$SAMPLE/kt-smoke-err" "$PWD/samples/err.kt" 2>&1 \
      | grep -m1 "error:" && echo "DIAG-OK"
    echo "--- smoke: script execution ---"
    "$OUT/kotlinc-snapshot" -kotlin-home "$KDIR" -cp "$KCP" \
      -script "$PWD/samples/script.kts" | grep -m1 "script says 42" && echo "SCRIPT-OK"
    ;;
  *)
    echo "unknown TOOL=$TOOL" >&2
    exit 1
    ;;
esac

echo "=== snapshot OK: $TOOL ==="
