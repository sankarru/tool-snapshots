#!/usr/bin/env bash
# Build the D8/R8 tracing corpus out of a PUBLIC Compose Android app.
#
# Why: tracing D8/R8 on a hello-world jar only records the handful of code
# paths a trivial class needs. The tool's real surface is class reading,
# desugaring, library resolution, shrinking and dex layout over Kotlin +
# Compose bytecode, so the corpus is a real app module built by Gradle, its
# real runtime classpath (every androidx/compose AAR), plus JVM libraries
# that hit desugaring-heavy shapes (records, sealed types, java.time/stream
# backed library desugaring, coroutines, reflection).
#
# Writes (all absolute paths, one per line):
#   $WORK/corpus/programs.txt    program inputs  (app classes + samples)
#   $WORK/corpus/classpath.txt   library inputs  (aar classes.jar + jvm libs)
#   $WORK/corpus/samples.txt     the synthetic samples only (cheap tier)
#   $WORK/corpus/env.txt         ANDROID_LIB / ANDROID_LIB2 (sourceable)
#   $WORK/corpus/report.txt      what went in, for the CI log
#
# Env: WORK (required), JAVA_BIN, ANDROID_SDK, HELLO_JAR, TRACE_REPO,
#      TRACE_REF, TRACE_APP, CORPUS_CLEAN_GRADLE.
# A failed app build is NOT fatal: the corpus falls back to the synthetic
# samples + JVM libraries and says so loudly in the report.
set -euo pipefail

WORK="${WORK:?set WORK}"
JAVA_BIN="${JAVA_BIN:-$JAVA_HOME/bin}"
ANDROID_SDK="${ANDROID_SDK:-${ANDROID_HOME:-$ANDROID_SDK_ROOT}}"
HELLO_JAR="${HELLO_JAR:-}"
TRACE_REPO="${TRACE_REPO:-android/compose-samples}"
TRACE_REF="${TRACE_REF:-v2025.12.00}"
TRACE_APP="${TRACE_APP:-Reply}"
CORPUS_CLEAN_GRADLE="${CORPUS_CLEAN_GRADLE:-1}"
# TRACE_BUILD=0 skips the Gradle build of the app module (dry runs on a
# machine without an SDK/network); the corpus is then samples + JVM libs.
TRACE_BUILD="${TRACE_BUILD:-1}"

CORPUS="$WORK/corpus"
CP_JARS="$CORPUS/cp"
SAMPLES="$CORPUS/samples"
APP_CLASSES="$CORPUS/app-classes"
REPORT="$CORPUS/report.txt"
rm -rf "$CORPUS"
mkdir -p "$CP_JARS" "$SAMPLES" "$APP_CLASSES"
: > "$REPORT"
say() { echo "$*" | tee -a "$REPORT"; }
add_prog() { [ -e "$1" ] && printf '%s\n' "$1" >> "$CORPUS/programs.txt"; }
add_cp()   { [ -e "$1" ] && printf '%s\n' "$1" >> "$CORPUS/classpath.txt"; }
add_sample(){ [ -e "$1" ] && printf '%s\n' "$1" >> "$CORPUS/samples.txt"; }

# ---------------------------------------------------------------- android.jar
ALL_LIBS="$(find "$ANDROID_SDK/platforms" -maxdepth 2 -name android.jar 2>/dev/null | sort -V || true)"
[ -n "$ALL_LIBS" ] || { say "FATAL: no android.jar under $ANDROID_SDK/platforms"; exit 1; }
ANDROID_LIB="$(echo "$ALL_LIBS" | tail -1)"
ANDROID_LIB2="$(echo "$ALL_LIBS" | tail -2 | head -1)"
{
  echo "ANDROID_LIB=\"$ANDROID_LIB\""
  echo "ANDROID_LIB2=\"$ANDROID_LIB2\""
} > "$CORPUS/env.txt"
say "android lib:  $ANDROID_LIB"
say "android lib2: $ANDROID_LIB2"

# ------------------------------------------------- synthetic JVM samples
# Three shapes on purpose: Java 8 baseline, Java 8 desugar bait (default and
# static interface methods, try-with-resources, lambdas, anonymous classes)
# and modern bytecode (records, pattern matching, switch expressions, text
# blocks) that only exists when javac is new enough.
make_java8_samples() {
  mkdir -p "$SAMPLES/src8"
  cat > "$SAMPLES/src8/Hello.java" <<'EOF'
package hello;
public class Hello {
  public static void main(String[] args) {
    System.out.println("hello from " + (args.length > 0 ? args[0] : "snapshot"));
  }
}
EOF
  cat > "$SAMPLES/src8/Plain.java" <<'EOF'
package hello;
import java.util.*;
public class Plain {
  public enum Kind { A, B }
  public static <T extends Comparable<T>> T max(List<T> xs) {
    T best = null;
    for (T x : xs) { if (best == null || x.compareTo(best) > 0) best = x; }
    return best;
  }
  public static int[][] arrays(Kind k) { return new int[][] { { 1, 2 }, { k.ordinal() } }; }
}
EOF
  # Desugar bait lives in its own jar: default/static interface methods,
  # try-with-resources, lambdas and anonymous classes are exactly what
  # --no-desugaring refuses, and that run needs a clean input.
  cat > "$SAMPLES/src8/DesugarBait.java" <<'EOF'
package hello;
import java.util.*;
public class DesugarBait {
  interface Api {
    default String greet() { return "hi"; }
    static int zero() { return 0; }
  }
  public static String run(List<String> xs) throws Exception {
    try (AutoCloseable c = () -> { }) {
      for (String s : xs) { if (s.isEmpty()) continue; }
    }
    Api a = new Api() { @Override public String greet() { return "anon"; } };
    Comparator<String> cmp = (l, r) -> l.length() - r.length();
    List<String> copy = new ArrayList<>(xs);
    copy.sort(cmp);
    return a.greet() + Api.zero() + copy;
  }
}
EOF
  "$JAVA_BIN/javac" --release 8 -d "$SAMPLES/classes8" \
    "$SAMPLES/src8/Hello.java" "$SAMPLES/src8/Plain.java" "$SAMPLES/src8/DesugarBait.java"
  mkdir -p "$SAMPLES/plain8/hello" "$SAMPLES/desugar8/hello"
  cp "$SAMPLES"/classes8/hello/Hello.class \
     "$SAMPLES"/classes8/hello/Plain*.class "$SAMPLES/plain8/hello/"
  cp "$SAMPLES"/classes8/hello/DesugarBait*.class "$SAMPLES/desugar8/hello/"
  "$JAVA_BIN/jar" --create --file "$SAMPLES/java8.jar" -C "$SAMPLES/plain8" .
  "$JAVA_BIN/jar" --create --file "$SAMPLES/desugar8.jar" -C "$SAMPLES/desugar8" .
}

make_modern_jar() {
  mkdir -p "$SAMPLES/src17" "$SAMPLES/src21"
  cat > "$SAMPLES/src17/Point.java" <<'EOF'
package modern;
public record Point(int x, int y) { public int sum() { return x + y; } }
EOF
  cat > "$SAMPLES/src17/Modern.java" <<'EOF'
package modern;
public class Modern {
  public static String describe(Object o) {
    if (o instanceof Point p && p.x() > 0) return "point " + p.sum();
    return """
        modern
        bytecode""";
  }
  public static int sw(Object o) {
    return switch (Math.abs(o.hashCode()) % 2) { case 0 -> 1; case 1 -> 2; default -> 3; };
  }
}
EOF
  # Java 21 only: sealed hierarchies + exhaustive pattern switch over them.
  cat > "$SAMPLES/src21/Shape.java" <<'EOF'
package modern;
public sealed interface Shape permits Circle, Square {}
EOF
  cat > "$SAMPLES/src21/Circle.java" <<'EOF'
package modern;
public record Circle(double r) implements Shape {}
EOF
  cat > "$SAMPLES/src21/Square.java" <<'EOF'
package modern;
public record Square(double s) implements Shape {}
EOF
  cat > "$SAMPLES/src21/Shapes.java" <<'EOF'
package modern;
public class Shapes {
  public static double area(Shape shape) {
    return switch (shape) {
      case Circle c -> Math.PI * c.r() * c.r();
      case Square s -> s.s() * s.s();
    };
  }
}
EOF
  local rel=21
  if ! "$JAVA_BIN/javac" --release 21 -d "$SAMPLES/classes21" \
        "$SAMPLES"/src21/*.java "$SAMPLES"/src17/*.java 2>"$SAMPLES/javac21.log"; then
    say "javac --release 21 unavailable, falling back to 17-only modern sample"
    rel=17
    "$JAVA_BIN/javac" --release 17 -d "$SAMPLES/classes21" "$SAMPLES"/src17/*.java
  fi
  "$JAVA_BIN/jar" --create --file "$SAMPLES/modern.jar" -C "$SAMPLES/classes21" .
  say "modern sample compiled at --release $rel"
}

# A jar with a deliberately dangling reference: exercises the compilers'
# missing-class diagnostics (and their reporting code) under the agent.
make_broken_jar() {
  mkdir -p "$SAMPLES/broken"
  cat > "$SAMPLES/broken/Dep.java" <<'EOF'
package broken;
public class Dep { public int value() { return 1; } }
EOF
  cat > "$SAMPLES/broken/Broken.java" <<'EOF'
package broken;
public class Broken {
  public static Dep get() { return new Dep(); }
  public static int use() { return get().value(); }
}
EOF
  "$JAVA_BIN/javac" --release 8 -d "$SAMPLES/broken/classes" \
    "$SAMPLES/broken/Dep.java" "$SAMPLES/broken/Broken.java"
  rm -f "$SAMPLES/broken/classes/broken/Dep.class"
  ( cd "$SAMPLES/broken/classes" && "$JAVA_BIN/jar" --create --file "$SAMPLES/broken.jar" . )
}

say "=== corpus: synthetic samples ==="
make_java8_samples
make_modern_jar
make_broken_jar
add_sample "$SAMPLES/java8.jar";  add_prog "$SAMPLES/java8.jar"
add_sample "$SAMPLES/desugar8.jar"; add_prog "$SAMPLES/desugar8.jar"
add_sample "$SAMPLES/modern.jar"; add_prog "$SAMPLES/modern.jar"
add_sample "$SAMPLES/broken.jar"; add_prog "$SAMPLES/broken.jar"
if [ -n "$HELLO_JAR" ] && [ -f "$HELLO_JAR" ]; then
  add_sample "$HELLO_JAR"; add_prog "$HELLO_JAR"
fi

# ------------------------------------------------------------- JVM libraries
# Library (not program) inputs: they must be READ, desugared against and
# resolved, which is a different code path from program classes.
JVM_LIBS=(
  "https://repo1.maven.org/maven2/org/jetbrains/kotlin/kotlin-stdlib/2.2.21/kotlin-stdlib-2.2.21.jar"
  "https://repo1.maven.org/maven2/org/jetbrains/kotlin/kotlin-reflect/2.2.21/kotlin-reflect-2.2.21.jar"
  "https://repo1.maven.org/maven2/org/jetbrains/kotlinx/kotlinx-coroutines-core-jvm/1.11.0/kotlinx-coroutines-core-jvm-1.11.0.jar"
  "https://repo1.maven.org/maven2/org/jetbrains/kotlinx/kotlinx-serialization-json-jvm/1.11.0/kotlinx-serialization-json-jvm-1.11.0.jar"
  "https://repo1.maven.org/maven2/org/jetbrains/kotlinx/kotlinx-collections-immutable-jvm/0.5.2/kotlinx-collections-immutable-jvm-0.5.2.jar"
  "https://repo1.maven.org/maven2/com/google/guava/guava/33.4.8-jre/guava-33.4.8-jre.jar"
  "https://dl.google.com/dl/android/maven2/com/android/tools/desugar_jdk_libs/2.1.5/desugar_jdk_libs-2.1.5.jar"
  "https://dl.google.com/dl/android/maven2/com/android/tools/desugar_jdk_libs_configuration/2.1.5/desugar_jdk_libs_configuration-2.1.5.jar"
)
say "=== corpus: jvm libraries ==="
for u in "${JVM_LIBS[@]}"; do
  f="$CP_JARS/$(basename "$u")"
  if [ ! -f "$f" ]; then
    curl -sSfL --retry 3 --retry-delay 2 -o "$f.part" "$u" && mv "$f.part" "$f" \
      || say "  skipped (fetch failed): $u"
  fi
  [ -f "$f" ] && add_cp "$f"
done
say "jvm libraries: $(wc -l < "$CORPUS/classpath.txt") entries"

# ------------------------------------------------------- the Compose app
say "=== corpus: $TRACE_REPO@$TRACE_REF ($TRACE_APP) ==="
SRC="$WORK/compose-samples"
APP="$SRC/$TRACE_APP"
APP_BUILT=0
if [ "$TRACE_BUILD" != 1 ]; then
  say "TRACE_BUILD=$TRACE_BUILD, skipping the app build"
elif [ ! -d "$APP" ]; then
  rm -rf "$SRC"
  git clone --depth 1 --branch "$TRACE_REF" --single-branch \
    "https://github.com/$TRACE_REPO.git" "$SRC"
  [ -d "$APP" ] || say "WARNING: $TRACE_APP not found in $TRACE_REPO@$TRACE_REF"
fi
if [ "$APP_BUILT" = 0 ] && [ "$TRACE_BUILD" = 1 ] && [ -d "$APP" ]; then
  # Resolve the module's real debug runtime classpath (AARs included) and
  # print it, instead of copying it around: AGP's configurations know which
  # artifacts are AARs, which are plain jars, and which are local projects.
  INIT="$WORK/init-tracecp.gradle"
  cat > "$INIT" <<'EOF'
// Registers a task that dumps `debugRuntimeClasspath` as absolute paths so
// the tracing corpus can feed production libraries to D8/R8. Applied with
// -I, so the cloned project stays untouched.
allprojects { p ->
  p.tasks.register('fetchTraceCp') {
    doLast {
      def cfg = p.configurations.findByName('debugRuntimeClasspath')
      def out = new File(p.layout.buildDirectory.get().asFile, 'tracecp')
      out.mkdirs()
      def files = cfg == null ? [] : cfg.files.findAll {
        it.name.endsWith('.jar') || it.name.endsWith('.aar')
      }.collect { it.absolutePath }
      new File(out, 'cp.txt').text = files.join('\n')
    }
  }
}
EOF
  # assembleDebug is the whole real pipeline (resources, kotlin+java compile,
  # dexing) - it is the only task set that proves the module really builds.
  if ( cd "$APP" && ./gradlew --no-daemon --console=plain --no-configuration-cache \
         "-Dorg.gradle.jvmargs=-Xmx3g -XX:MaxMetaspaceSize=768m" \
         -I "$INIT" :app:assembleDebug :app:fetchTraceCp ) > "$WORK/gradle-app.log" 2>&1; then
    APP_BUILT=1
    say "gradle assembleDebug: ok"
  else
    say "WARNING: gradle assembleDebug failed, see $WORK/gradle-app.log"
    tail -30 "$WORK/gradle-app.log" | sed 's/^/    /' | tee -a "$REPORT"
  fi
fi

if [ "$APP_BUILT" = 1 ]; then
  # The app's namespace seeds the R8 keep rules (entry point + data layer).
  ns="$(sed -n 's/^[[:space:]]*namespace[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$APP/app/build.gradle.kts" 2>/dev/null | head -1 || true)"
  if [ -n "$ns" ]; then
    echo "$ns" > "$CORPUS/namespace.txt"
    say "app namespace: $ns"
  fi
  CP_LIST="$APP/app/build/tracecp/cp.txt"
  if [ -f "$CP_LIST" ]; then
    n_jar=0; n_aar=0
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      case "$f" in
        *.aar)
          name="$(basename "$f" .aar)"
          mkdir -p "$CP_JARS/aar-$name"
          if unzip -o -q "$f" classes.jar -d "$CP_JARS/aar-$name" 2>/dev/null; then
            add_cp "$CP_JARS/aar-$name/classes.jar"; n_aar=$((n_aar + 1))
          fi
          ;;
        *.jar)
          n_jar=$((n_jar + 1))
          dst="$CP_JARS/j$n_jar-$(basename "$f")"
          cp -f "$f" "$dst"
          add_cp "$dst"
          ;;
      esac
    done < "$CP_LIST"
    say "app classpath: $n_jar jars, $n_aar aars"
  else
    say "WARNING: fetchTraceCp produced no cp.txt"
  fi
  # Harvest the app's own compiled classes (kotlin metadata, composables,
  # generated serializers) as PROGRAM input, copied out of the build tree so
  # the tree can be deleted to free disk before native-image runs.
  n_cls=0
  for d in "$APP/app/build/tmp/kotlin-classes/debug" \
           "$APP/app/build/intermediates/javac/debug/compileDebugJavaWithJavac/classes"; do
    [ -d "$d" ] || continue
    tgt="$APP_CLASSES/$(basename "$(dirname "$d")")-$(basename "$d")"
    mkdir -p "$tgt"; cp -r "$d/." "$tgt/" 2>/dev/null || true
    add_prog "$tgt"; n_cls=$((n_cls + 1))
  done
  for j in $(find "$APP/app/build/intermediates" -path "*r_class_jar*" -name R.jar 2>/dev/null); do
    cp "$j" "$APP_CLASSES/R-$(basename "$(dirname "$j")").jar" 2>/dev/null || true
    add_prog "$APP_CLASSES/R-$(basename "$(dirname "$j")").jar"
    n_cls=$((n_cls + 1))
  done
  say "app program inputs: $n_cls"
fi

# ----------------------------------------------------------------- summary
sort -u "$CORPUS/programs.txt" -o "$CORPUS/programs.txt"
sort -u "$CORPUS/classpath.txt" -o "$CORPUS/classpath.txt"
sort -u "$CORPUS/samples.txt" -o "$CORPUS/samples.txt"
say "programs:  $(wc -l < "$CORPUS/programs.txt")"
say "classpath: $(wc -l < "$CORPUS/classpath.txt")"
du -sh "$CORPUS" | tee -a "$REPORT"

# The Compose build leaves several GB of Gradle caches and build outputs
# behind; native-image needs that disk (and RAM) for the link itself.
if [ "$CORPUS_CLEAN_GRADLE" = 1 ]; then
  say "=== freeing build disk ==="
  rm -rf "$SRC"
  rm -rf "${GRADLE_USER_HOME:-$HOME/.gradle}/caches" \
         "${GRADLE_USER_HOME:-$HOME/.gradle}/wrapper" 2>/dev/null || true
  df -h "$WORK" | tail -1 | tee -a "$REPORT"
fi
echo "=== corpus ready: $CORPUS ==="