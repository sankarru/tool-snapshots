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
  # Patch PathUtil for native-image: fallback to kotlin.home when
  # getResourceRoot returns null (class files not available as resources
  # inside the image). Without this, every kotlinc invocation in the
  # image throws IllegalStateException at KotlinCoreEnvironment startup.
  ASM_CP=$(find "$HOME/.gradle" /usr/share/gradle /opt -name "asm-*.jar" 2>/dev/null | tr '\n' ':' || true)
  echo "ASM_CP found: $(echo "$ASM_CP" | tr ':' '\n' | head -3 | tr '\n' ' ' || true)"
  if [ -z "$ASM_CP" ] || [ "$ASM_CP" = ":" ]; then
    echo "ASM not found, downloading"
    mkdir -p "$WORK/asm"
    curl -sSfL -o "$WORK/asm/asm-9.7.jar" https://repo1.maven.org/maven2/org/ow2/asm/asm/9.7/asm-9.7.jar
    curl -sSfL -o "$WORK/asm/asm-tree-9.7.jar" https://repo1.maven.org/maven2/org/ow2/asm/asm-tree/9.7/asm-tree-9.7.jar
    curl -sSfL -o "$WORK/asm/asm-commons-9.7.jar" https://repo1.maven.org/maven2/org/ow2/asm/asm-commons/9.7/asm-commons-9.7.jar
    ASM_CP="$WORK/asm/asm-9.7.jar:$WORK/asm/asm-tree-9.7.jar:$WORK/asm/asm-commons-9.7.jar:"
  fi
  "$JAVA_HOME/bin/javac" -cp "$ASM_CP" scripts/Patch.java -d "$WORK"
  "$JAVA_HOME/bin/java" -cp "$WORK:$ASM_CP" Patch "$kdir/lib/kotlin-compiler.jar"
  for jar in "$kdir"/lib/*.jar; do
    if unzip -l "$jar" 2>/dev/null | grep -q "JvmScriptingHostConfigurationKt.class"; then
      if [ "$jar" != "$kdir/lib/kotlin-compiler.jar" ]; then
        echo "patching $jar for JvmScripting"
        "$JAVA_HOME/bin/java" -cp "$WORK:$ASM_CP" Patch "$jar"
      fi
    fi
  done
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
  PPLUG="$kdir/lib/parcelize-compiler.jar"
  AOPLUG="$kdir/lib/allopen-compiler-plugin.jar"
  ANDROID_JAR="$(find "${ANDROID_HOME:-$ANDROID_SDK_ROOT}" -path "*platforms/android-3*/android.jar" 2>/dev/null | sort | tail -1 || true)"
  SAMPLES="$PWD/samples"
  [ -d "$SAMPLES" ] || { echo "samples/ dir missing" >&2; exit 1; }
  KJ="$JAVA_HOME/bin/java $AGENT -cp $cp org.jetbrains.kotlin.cli.jvm.K2JVMCompiler"
  # NOTE: the java -cp above loads the COMPILER; the COMPILATION classpath
  # must be passed explicitly via kotlinc -cp (K2 does not inherit the JVM
  # classpath, and only the stdlib is auto-found via kotlin-home).

  echo "--- trace: basic + warnings ---"
  rm -rf "$SAMPLE/kt-out" && mkdir -p "$SAMPLE/kt-out"
  # shellcheck disable=SC2086
  $KJ -jdk-home "$JAVA_HOME" -cp "$cp" -d "$SAMPLE/kt-out" "$SAMPLES/hello.kt" "$SAMPLES/warn.kt"
  find "$SAMPLE/kt-out" -name "*.class"

  echo "--- trace: language surface (data/sealed/enum/generics/coroutines) ---"
  rm -rf "$SAMPLE/kt-feat" && mkdir -p "$SAMPLE/kt-feat"
  # shellcheck disable=SC2086
  $KJ -jdk-home "$JAVA_HOME" -cp "$cp" -d "$SAMPLE/kt-feat" "$SAMPLES/features.kt"

  echo "--- trace: kotlin-reflect ---"
  rm -rf "$SAMPLE/kt-refl" && mkdir -p "$SAMPLE/kt-refl"
  # shellcheck disable=SC2086
  $KJ -jdk-home "$JAVA_HOME" -cp "$cp" -d "$SAMPLE/kt-refl" "$SAMPLES/reflect.kt"

  echo "--- trace: serialization plugin ---"
  rm -rf "$SAMPLE/kt-ser" && mkdir -p "$SAMPLE/kt-ser"
  # shellcheck disable=SC2086
  $KJ -jdk-home "$JAVA_HOME" -cp "$cp" -Xplugin="$SPLUG" -d "$SAMPLE/kt-ser" "$SAMPLES/serial.kt"

  echo "--- trace: compose plugin ---"
  rm -rf "$SAMPLE/kt-cmp" && mkdir -p "$SAMPLE/kt-cmp"
  # shellcheck disable=SC2086
  $KJ -jdk-home "$JAVA_HOME" -cp "$cp" -Xplugin="$CPLUG" -d "$SAMPLE/kt-cmp" "$SAMPLES/compose.kt"

  if [ -n "$ANDROID_JAR" ]; then
    echo "--- trace: parcelize plugin (lib: $ANDROID_JAR) ---"
    rm -rf "$SAMPLE/kt-par" && mkdir -p "$SAMPLE/kt-par"
    # shellcheck disable=SC2086
    $KJ -jdk-home "$JAVA_HOME" -cp "$cp:$ANDROID_JAR" -Xplugin="$PPLUG" -d "$SAMPLE/kt-par" "$SAMPLES/parcel.kt"
  else
    echo "--- trace: parcelize SKIPPED (no android.jar; no ANDROID_HOME) ---"
  fi

  echo "--- trace: allopen plugin ---"
  rm -rf "$SAMPLE/kt-ao" && mkdir -p "$SAMPLE/kt-ao"
  # shellcheck disable=SC2086
  $KJ -jdk-home "$JAVA_HOME" -cp "$cp" -Xplugin="$AOPLUG" \
    -P "plugin:org.jetbrains.kotlin.allopen:preset=spring" \
    -d "$SAMPLE/kt-ao" "$SAMPLES/allopen.kt"

  echo "--- trace: diagnostics (broken file, message bundles) ---"
  rm -rf "$SAMPLE/kt-err" && mkdir -p "$SAMPLE/kt-err"
  # shellcheck disable=SC2086
  $KJ -jdk-home "$JAVA_HOME" -cp "$cp" -d "$SAMPLE/kt-err" "$SAMPLES/err.kt" || true

  echo "--- trace: script execution ---"
  # shellcheck disable=SC2086
  $KJ -jdk-home "$JAVA_HOME" -cp "$cp" -script "$SAMPLES/script.kts" || true

  echo "--- trace: legacy jvm-target backend ---"
  rm -rf "$SAMPLE/kt-18" && mkdir -p "$SAMPLE/kt-18"
  # shellcheck disable=SC2086
  $KJ -jdk-home "$JAVA_HOME" -cp "$cp" -jvm-target 1.8 -d "$SAMPLE/kt-18" "$SAMPLES/hello.kt"

  echo "$cp" > "$WORK/kotlinc-cp.txt"
  echo "$SPLUG" > "$WORK/kotlinc-splug.txt"
}

# Room via standalone KSP2 (KSP2 is NOT a kotlinc plugin: it generates
# sources first, which kotlinc then compiles). Two roles here:
#  - the KSP run itself goes under the agent into ksp-meta/ (fuel for a
#    future ksp-snapshot; kept OUT of kotlinc's metadata dir), and
#  - kotlinc then compiles room.kt + the generated sources under the
#    kotlinc agent, so the snapshot provably handles Room-shaped code.
trace_room() { # $1 = kotlinc dist dir
  local kdir="$1"
  local ANDROID_JAR
  ANDROID_JAR="$(find "${ANDROID_HOME:-$ANDROID_SDK_ROOT}" -path "*platforms/android-3*/android.jar" 2>/dev/null | sort | tail -1 || true)"
  if [ -z "$ANDROID_JAR" ]; then
    echo "--- trace: Room SKIPPED (no android.jar; no ANDROID_HOME) ---"
    return 0
  fi
  echo "--- resolve KSP/Room artifacts ---"
  # Fresh output dir: Copy tasks don't delete stale artifacts from removed
  # dependencies, and stale jars on the kotlinc classpath cause exactly the
  # kind of split-package ghost this pipeline hunts.
  rm -rf ksp/fetch-deps/build
  gradle -p ksp/fetch-deps fetchAA fetchProc fetchCompile --console=plain --no-daemon -q
  local fdir=ksp/fetch-deps/build
  local aa_cp proc_cp cmp_cp
  aa_cp="$(ls "$fdir"/aa/*.jar | tr '\n' ':')$kdir/lib/kotlin-stdlib.jar:$(ls "$WORK"/tracelibs/kotlinx-coroutines-core-jvm-*.jar)"
  proc_cp="$(ls "$fdir"/proc/*.jar | tr '\n' ':')"
  cmp_cp="$(ls "$fdir"/compile/*.jar | tr '\n' ':')"
  # AARs carry their classes inside classes.jar -- explode once, reuse for
  # both the KSP -libraries and the kotlinc -cp.
  rm -rf "$WORK/room-cp" && mkdir -p "$WORK/room-cp"
  for a in "$fdir"/compile/*.aar; do
    n="$(basename "$a" .aar)"
    mkdir -p "$WORK/room-cp/$n"
    unzip -o -q "$a" classes.jar -d "$WORK/room-cp/$n"
    cmp_cp="$cmp_cp$WORK/room-cp/$n/classes.jar:"
  done
  echo "$cmp_cp" > "$WORK/room-compile-cp.txt"
  rm -rf "$WORK/room-src" && mkdir -p "$WORK/room-src"
  cp "$PWD/samples/room.kt" "$WORK/room-src/"

  echo "--- trace: KSP2 generates Room impls (agent -> ksp-meta, future fuel) ---"
  rm -rf "$WORK/ksp-out" "$WORK/ksp-meta" && mkdir -p "$WORK/ksp-meta"
  "$JAVA_HOME/bin/java" "-agentlib:native-image-agent=config-output-dir=$WORK/ksp-meta" \
    -cp "$aa_cp" com.google.devtools.ksp.cmdline.KSPJvmMain \
    -jvm-target 17 -module-name=room \
    -source-roots "$WORK/room-src" \
    -libraries "$cmp_cp$ANDROID_JAR" \
    -project-base-dir "$WORK/room-proj" \
    -output-base-dir="$WORK/ksp-out" \
    -caches-dir="$WORK/ksp-out/caches" \
    -class-output-dir="$WORK/ksp-out/classes" \
    -kotlin-output-dir="$WORK/ksp-out/kotlin" \
    -java-output-dir "$WORK/ksp-out/java" \
    -resource-output-dir "$WORK/ksp-out/res" \
    -language-version=2.2 -api-version=2.2 \
    "$proc_cp"
  find "$WORK/ksp-out/kotlin" "$WORK/ksp-out/java" -type f 2>/dev/null | head || true
  rm -rf "$OUT/ksp-trace-meta" && cp -r "$WORK/ksp-meta" "$OUT/ksp-trace-meta"

  echo "--- trace: kotlinc compiles Room sources + generated impls ---"
  rm -rf "$SAMPLE/kt-room" && mkdir -p "$SAMPLE/kt-room"
  local kcp
  kcp=$(ls "$kdir"/lib/*.jar | grep -v -e sources -e android-extensions | tr '\n' ':')
  # shellcheck disable=SC2086
  "$JAVA_HOME/bin/java" "$AGENT" -cp "$kcp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -jdk-home "$JAVA_HOME" -cp "$cmp_cp$ANDROID_JAR" -d "$SAMPLE/kt-room" \
    "$WORK/room-src/room.kt" "$WORK/ksp-out/kotlin/"*.kt
  find "$SAMPLE/kt-room" -name "*Db_Impl*" -o -name "*Dao_Impl*" | head -4
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
  # kotlinc locates its own jars via Class.getResource(".../CompilerSystemProperties.class")
  # and similar lookups (PathUtil.getResourcePathForClass). The agent only
  # records resources actually touched during tracing, but kotlinc's startup
  # touches dozens of them. Include the compiler's resources wholesale so
  # those lookups succeed inside the image; size cost is negligible vs the
  # already-165 MB binary.
  local extra_args=()
  if [ "$3" = "kotlinc-snapshot" ]; then
    extra_args+=("-H:IncludeResources=.*")
    # Kotlin's CoreJrtFileSystem uses FileSystems.newFileSystem("jrt:/") to
    # access JDK runtime modules. Native image excludes the jrt provider
    # by default — need both the URL protocol and the FileSystem provider.
    extra_args+=("-H:EnableURLProtocols=jrt")
    extra_args+=("--enable-url-protocols=jrt")
    extra_args+=("-H:IncludeFileSystems=jrt")
    extra_args+=("-H:+IncludeAllFileSystems")
  fi
  "$NI" \
    -J-Xmx12g \
    --no-fallback \
    --allow-incomplete-classpath \
    -H:ConfigurationFileDirectories="$META" \
    -H:Name="$OUT/$3" \
    -H:+ReportExceptionStackTraces \
    "${extra_args[@]}" \
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
    trace_room "$KDIR"
    KCP="$(cat "$WORK/kotlinc-cp.txt")"
    SPLUG="$(cat "$WORK/kotlinc-splug.txt")"
    CPLUG="$KDIR/lib/compose-compiler-plugin.jar"
    PPLUG="$KDIR/lib/parcelize-compiler-plugin.jar"
    AOPLUG="$KDIR/lib/allopen-compiler-plugin.jar"
    ANDROID_JAR="$(find "${ANDROID_HOME:-$ANDROID_SDK_ROOT}" -path "*platforms/android-3*/android.jar" 2>/dev/null | sort | tail -1 || true)"
    link_snapshot org.jetbrains.kotlin.cli.jvm.K2JVMCompiler "$KCP" kotlinc-snapshot
    echo "--- smoke: version ---"
    # NOTE: -kotlin-home is required on EVERY invocation, including
    # -version: arg setup runs PathUtil discovery before anything else,
    # and discovery cannot work inside an image (no jar file path).
    "$OUT/kotlinc-snapshot" -kotlin-home "$KDIR" -jdk-home "$JAVA_HOME" -version
    echo "--- smoke: compile full sample surface ---"
    rm -rf "$SAMPLE/kt-smoke" && mkdir -p "$SAMPLE/kt-smoke"
    # -kotlin-home is mandatory: the snapshot cannot discover the dist
    # layout via class-resource lookup (PathUtil.getResourcePathForClass has
    # no file path inside a native image), so point it at the home
    # explicitly. The home's lib/ (stdlib, reflect, plugins) must be present
    # at runtime -- the snapshot replaces only the launcher, not the dist.
    "$OUT/kotlinc-snapshot" -kotlin-home "$KDIR" -jdk-home "$JAVA_HOME" -cp "$KCP" \
      -Xplugin="$SPLUG" \
      -d "$SAMPLE/kt-smoke" \
      "$PWD/samples/hello.kt" "$PWD/samples/features.kt" \
      "$PWD/samples/reflect.kt" "$PWD/samples/serial.kt" \
      "$PWD/samples/warn.kt"
    find "$SAMPLE/kt-smoke" -name "*.class" | head -8
    echo "--- smoke: compose plugin inside the image ---"
    rm -rf "$SAMPLE/kt-smoke-cmp" && mkdir -p "$SAMPLE/kt-smoke-cmp"
    "$OUT/kotlinc-snapshot" -kotlin-home "$KDIR" -jdk-home "$JAVA_HOME" -cp "$KCP" \
      -Xplugin="$CPLUG" \
      -d "$SAMPLE/kt-smoke-cmp" "$PWD/samples/compose.kt"
    find "$SAMPLE/kt-smoke-cmp" -name "*.class" | head -4 && echo "COMPOSE-OK"
    if [ -n "$ANDROID_JAR" ]; then
      echo "--- smoke: parcelize plugin inside the image ---"
      rm -rf "$SAMPLE/kt-smoke-par" && mkdir -p "$SAMPLE/kt-smoke-par"
      "$OUT/kotlinc-snapshot" -kotlin-home "$KDIR" -jdk-home "$JAVA_HOME" -cp "$KCP:$ANDROID_JAR" \
        -Xplugin="$PPLUG" \
        -d "$SAMPLE/kt-smoke-par" "$PWD/samples/parcel.kt"
      find "$SAMPLE/kt-smoke-par" -name "*.class" | head -4 && echo "PARCELIZE-OK"
    fi
    echo "--- smoke: allopen plugin inside the image ---"
    rm -rf "$SAMPLE/kt-smoke-ao" && mkdir -p "$SAMPLE/kt-smoke-ao"
    "$OUT/kotlinc-snapshot" -kotlin-home "$KDIR" -jdk-home "$JAVA_HOME" -cp "$KCP" \
      -Xplugin="$AOPLUG" \
      -P "plugin:org.jetbrains.kotlin.allopen:preset=spring" \
      -d "$SAMPLE/kt-smoke-ao" "$PWD/samples/allopen.kt"
    find "$SAMPLE/kt-smoke-ao" -name "*.class" | head -4 && echo "ALLOPEN-OK"
    echo "--- smoke: diagnostics still render ---"
    "$OUT/kotlinc-snapshot" -kotlin-home "$KDIR" -jdk-home "$JAVA_HOME" -cp "$KCP" \
      -d "$SAMPLE/kt-smoke-err" "$PWD/samples/err.kt" 2>&1 \
      | grep -m1 "error:" && echo "DIAG-OK"
    echo "--- smoke: script execution ---"
    "$OUT/kotlinc-snapshot" -kotlin-home "$KDIR" -jdk-home "$JAVA_HOME" -cp "$KCP" \
      -script "$PWD/samples/script.kts" | grep -m1 "script says 42" && echo "SCRIPT-OK"
    if [ -d "$WORK/ksp-out/kotlin" ]; then
      echo "--- smoke: Room sources + generated impls inside the image ---"
      RCP="$(cat "$WORK/room-compile-cp.txt")"
      AJAR="$(find "${ANDROID_HOME:-$ANDROID_SDK_ROOT}" -path "*platforms/android-3*/android.jar" 2>/dev/null | sort | tail -1)"
      rm -rf "$SAMPLE/kt-smoke-room" && mkdir -p "$SAMPLE/kt-smoke-room"
      "$OUT/kotlinc-snapshot" -kotlin-home "$KDIR" -jdk-home "$JAVA_HOME" -cp "$RCP$AJAR" \
        -d "$SAMPLE/kt-smoke-room" \
        "$WORK/room-src/room.kt" "$WORK/ksp-out/kotlin/"*.kt
      find "$SAMPLE/kt-smoke-room" -name "*Db_Impl*" | head -2 && echo "ROOM-OK"
    fi
    ;;
  *)
    echo "unknown TOOL=$TOOL" >&2
    exit 1
    ;;
esac

echo "=== snapshot OK: $TOOL ==="
