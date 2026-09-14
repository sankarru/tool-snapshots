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
  cat > "$SAMPLE/hello.kt" <<'EOF'
fun main(args: Array<String>) {
  println("hello from ${args.firstOrNull() ?: "snapshot"}")
}
EOF
  rm -rf "$SAMPLE/kt-out" && mkdir -p "$SAMPLE/kt-out"
  "$JAVA_HOME/bin/java" "$AGENT" -cp "$cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -d "$SAMPLE/kt-out" "$SAMPLE/hello.kt"
  find "$SAMPLE/kt-out" -name "*.class"
  echo "$cp" > "$WORK/kotlinc-cp.txt"
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
    link_snapshot org.jetbrains.kotlin.cli.jvm.K2JVMCompiler "$KCP" kotlinc-snapshot
    echo "--- smoke: version ---"
    "$OUT/kotlinc-snapshot" -version
    echo "--- smoke: compile hello.kt ---"
    rm -rf "$SAMPLE/kt-smoke" && mkdir -p "$SAMPLE/kt-smoke"
    "$OUT/kotlinc-snapshot" \
      -d "$SAMPLE/kt-smoke" "$SAMPLE/hello.kt"
    find "$SAMPLE/kt-smoke" -name "*.class"
    ;;
  *)
    echo "unknown TOOL=$TOOL" >&2
    exit 1
    ;;
esac

echo "=== snapshot OK: $TOOL ==="
