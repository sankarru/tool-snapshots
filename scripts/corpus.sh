#!/usr/bin/env bash
# Build the D8/R8 tracing corpus out of public Compose artifacts, with no
# Gradle/AGP anywhere: D8 and R8 are standalone tools here, so the corpus is
# built the same way they are used - plain jars on a command line.
#
# Why: tracing D8/R8 on a hello-world jar only records the handful of code
# paths a trivial class needs. Their real surface is class reading, desugaring,
# library resolution, shrinking and dex layout over Kotlin + Compose bytecode,
# so the corpus is:
#   * the androidx/compose runtime, UI, foundation and material3 AARs (the same
#     artifacts a Compose app resolves, straight from Google Maven, classes.jar
#     extracted - no build step, no AAPT2),
#   * real @Composable bytecode compiled here by kotlinc + the Compose compiler
#     plugin against those artifacts,
#   * JVM libraries that hit desugaring-heavy shapes (records, sealed types,
#     java.time/stream backed library desugaring, coroutines, reflection),
#   * synthetic samples for the byte shapes that need a hand-written trigger
#     (default/static interface methods, try-with-resources, records, a
#     deliberately broken class reference).
#
# Writes (all absolute paths, one per line):
#   $WORK/corpus/programs.txt    program inputs  (app classes + samples)
#   $WORK/corpus/classpath.txt   library inputs  (aar classes.jar + jvm libs)
#   $WORK/corpus/samples.txt     the synthetic samples only (cheap tier)
#   $WORK/corpus/env.txt         ANDROID_LIB / ANDROID_LIB2 (sourceable)
#   $WORK/corpus/report.txt      what went in, for the CI log
#
# Env: WORK (required), JAVA_BIN, ANDROID_SDK, HELLO_JAR, KOTLIN_TAG,
#      TRACE_BUILD, CORPUS_KEEP_GRADLE (unused, kept for compatibility).
# Nothing here is fatal: a failed clone / resolution / compile degrades the
# corpus and says so loudly in the report.
set -euo pipefail

WORK="${WORK:?set WORK}"
JAVA_BIN="${JAVA_BIN:-$JAVA_HOME/bin}"
ANDROID_SDK="${ANDROID_SDK:-${ANDROID_HOME:-$ANDROID_SDK_ROOT}}"
HELLO_JAR="${HELLO_JAR:-}"
CORPUS_KEEP_GRADLE="${CORPUS_KEEP_GRADLE:-1}"
# TRACE_BUILD=0 skips the kotlinc/Compose-plugin compile (dry runs on a machine
# without network); the corpus is then synthetic samples + libraries only.
TRACE_BUILD="${TRACE_BUILD:-1}"

KOTLIN_TAG="${KOTLIN_TAG:-v2.2.21}"
# Namespace the synthetic Compose sources live in; also what the R8 keep rules
# name (there is no app module to read a namespace from).
CORPUS_NS="${CORPUS_NS:-corpus.compose}"
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
  "https://repo1.maven.org/maven2/org/jetbrains/kotlinx/kotlinx-serialization-core-jvm/1.11.0/kotlinx-serialization-core-jvm-1.11.0.jar"
  "https://repo1.maven.org/maven2/org/jetbrains/kotlinx/kotlinx-serialization-json-jvm/1.11.0/kotlinx-serialization-json-jvm-1.11.0.jar"
  "https://repo1.maven.org/maven2/org/jetbrains/kotlinx/kotlinx-collections-immutable-jvm/0.5.2/kotlinx-collections-immutable-jvm-0.5.2.jar"
  "https://repo1.maven.org/maven2/com/google/guava/guava/33.4.8-jre/guava-33.4.8-jre.jar"
  "https://dl.google.com/dl/android/maven2/com/android/tools/desugar_jdk_libs/2.1.5/desugar_jdk_libs-2.1.5.jar"
  "https://dl.google.com/dl/android/maven2/com/android/tools/desugar_jdk_libs_configuration/2.1.5/desugar_jdk_libs_configuration-2.1.5.jar"
)
# add_remote <url> : fetch into the classpath dir, extracting classes.jar from
# AARs (androidx ships AARs; D8/R8 need the class files, not the archive).
add_remote() {
  local u="$1" base f
  base="$(basename "$u")"
  # The extension matters: D8/R8 reject a jar without one ("Unsupported
  # classpath file type"). AARs become directories holding classes.jar.
  case "$base" in
    *.aar) base="${base%.aar}" ;;
  esac
  f="$CP_JARS/$base"
  case "$u" in
    *.aar) [ -f "$f/classes.jar" ] && { add_cp "$f/classes.jar"; return; } ;;
    *)     [ -f "$f" ] && { add_cp "$f"; return; } ;;
  esac
  if curl -sSfL --retry 3 --retry-delay 2 -o "$f.part" "$u"; then
    mv "$f.part" "$f"
  else
    rm -f "$f.part"
    say "  skipped (fetch failed): $u"
    return
  fi
  case "$u" in
    *.aar)
      mkdir -p "$f.d"
      if unzip -o -q "$f" classes.jar -d "$f.d" 2>/dev/null; then
        rm -f "$f"
        mv "$f.d" "$f"
        add_cp "$f/classes.jar"
      else
        say "  no classes.jar in $base"
      fi
      ;;
    *) add_cp "$f" ;;
  esac
}

say "=== corpus: jvm libraries ==="
for u in "${JVM_LIBS[@]}"; do add_remote "$u"; done
say "jvm libraries: $(wc -l < "$CORPUS/classpath.txt") entries"

# androidx/compose artifacts a Compose app resolves, pinned to versions that
# exist on Google Maven. Extracted to classes.jar by add_remote.
COMPOSE_LIBS=(
  "https://dl.google.com/dl/android/maven2/androidx/compose/runtime/runtime-android/1.7.6/runtime-android-1.7.6.aar"
  "https://dl.google.com/dl/android/maven2/androidx/compose/runtime/runtime-saveable-android/1.7.6/runtime-saveable-android-1.7.6.aar"
  "https://dl.google.com/dl/android/maven2/androidx/compose/ui/ui-geometry-android/1.7.6/ui-geometry-android-1.7.6.aar"
  "https://dl.google.com/dl/android/maven2/androidx/compose/ui/ui-util-android/1.7.6/ui-util-android-1.7.6.aar"
  "https://dl.google.com/dl/android/maven2/androidx/compose/ui/ui-unit-android/1.7.6/ui-unit-android-1.7.6.aar"
  "https://dl.google.com/dl/android/maven2/androidx/collection/collection-jvm/1.5.0/collection-jvm-1.5.0.jar"
  "https://dl.google.com/dl/android/maven2/androidx/annotation/annotation-jvm/1.9.1/annotation-jvm-1.9.1.jar"
  "https://dl.google.com/dl/android/maven2/androidx/compose/ui/ui-android/1.7.6/ui-android-1.7.6.aar"
  "https://dl.google.com/dl/android/maven2/androidx/compose/foundation/foundation-layout-android/1.7.6/foundation-layout-android-1.7.6.aar"
  "https://dl.google.com/dl/android/maven2/androidx/compose/foundation/foundation-android/1.7.6/foundation-android-1.7.6.aar"
  "https://dl.google.com/dl/android/maven2/androidx/compose/material3/material3-android/1.3.2/material3-android-1.3.2.aar"
)

# The sources kotlinc + the Compose compiler plugin turn into the corpus's main
# program input: real @Composable bytecode, written against plain
# androidx.compose APIs so they compile against any 1.7+/1.9 runtime. The point
# is the bytecode shapes they produce - composable lambdas, remember slots,
# recomposer groups, rememberSaveable writers, LazyColumn item keys, flow
# state, immutable collections, a generated serializer - all of which the dexers
# have to rewrite.
make_compose_sources() {
  local d="$1"
  mkdir -p "$d"
  cat > "$d/Model.kt" <<'EOF'
package corpus.compose

import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class Item(
  val id: Long,
  val title: String,
  val done: Boolean = false,
  val tags: PersistentList<String> = persistentListOf(),
)

@Serializable
data class Snapshot(val items: PersistentList<Item>, val cursor: Int)

class ItemStore(seed: PersistentList<Item> = persistentListOf()) {
  private val _state = MutableStateFlow(seed)
  val state: StateFlow<PersistentList<Item>> = _state.asStateFlow()
  val open: StateFlow<Int> = MutableStateFlow(_state.value.count { !it.done }).asStateFlow()

  fun toggle(id: Long) {
    val next = _state.value.map { if (it.id == id) it.copy(done = !it.done) else it }
    _state.value = persistentListOf(*next.toTypedArray())
  }

  fun encode(): String =
    Json { encodeDefaults = true }.encodeToString(Snapshot(_state.value, 0))
}
EOF
  cat > "$d/Ui.kt" <<'EOF'
package corpus.compose

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

val LocalStore = staticCompositionLocalOf<ItemStore> { ItemStore() }

@Composable
fun ItemRow(item: Item, onToggle: (Long) -> Unit) {
  var label by remember(item.id) { mutableStateOf(item.title) }
  val styled by remember(item.id, item.done) { derivedStateOf { label.trim() } }
  Column(modifier = Modifier.fillMaxWidth().padding(4.dp)) {
    Text(styled)
    Checkbox(checked = item.done, onCheckedChange = { onToggle(item.id) })
    Button(onClick = { label = item.title.uppercase() }) { Text("rename") }
  }
}

@Composable
fun ItemList(store: ItemStore, modifier: Modifier = Modifier) {
  val list = store.state.value
  val scope = rememberCoroutineScope()
  var query by rememberSaveable { mutableStateOf("") }
  LaunchedEffect(query) { delay(1) }
  Scaffold(modifier = modifier) {
    LazyColumn {
      items(list, key = { it.id }) { item ->
        key(item.id) {
          CompositionLocalProvider(LocalStore provides store) {
            ItemRow(item) { id -> scope.launch { store.toggle(id) } }
          }
        }
      }
    }
  }
}

@Composable
fun App(store: ItemStore) {
  MaterialTheme {
    CompositionLocalProvider(LocalStore provides store) {
      ItemList(store, Modifier.fillMaxWidth())
    }
  }
}
EOF
  cat > "$d/Main.kt" <<'EOF'
package corpus.compose

import kotlinx.collections.immutable.persistentListOf

fun main() {
  val store = ItemStore(
    persistentListOf(
      Item(1, "one", tags = persistentListOf("a")),
      Item(2, "two"),
    ),
  )
  store.toggle(1)
  println(store.encode() + " open=" + store.open.value)
}
EOF
}

make_compose_app() {
  local tag="${KOTLIN_TAG:-v2.2.21}" ver="${KOTLIN_TAG#v}"
  local cdir="$WORK/kotlinc" csrc="$WORK/compose-src"
  mkdir -p "$csrc"
  local plugin
  make_compose_sources "$csrc"
  if [ ! -x "$cdir/bin/kotlinc" ]; then
    if ! curl -sSfL --retry 3 --retry-delay 2 -o "$WORK/kotlinc.zip" \
        "https://github.com/JetBrains/kotlin/releases/download/$tag/kotlin-compiler-$ver.zip"; then
      say "  skipped (kotlinc download failed)"; return
    fi
    unzip -q "$WORK/kotlinc.zip" -d "$WORK" || { say "  skipped (kotlinc unzip failed)"; return; }
  fi
  plugin="$cdir/lib/compose-compiler-plugin.jar"
  # The compiler plugins ship inside the kotlinc dist (kotlinc/lib). The
  # embeddable compose plugin from Maven Central is NOT usable standalone: it
  # expects the shaded intellij PSI classes the dist provides.
  [ -f "$plugin" ] || { say "  skipped (no compose plugin in $cdir/lib)"; return; }
  local serplugin="$cdir/lib/kotlinx-serialization-compiler-plugin.jar"
  local xplugin=(-Xplugin="$plugin")
  [ -f "$serplugin" ] && xplugin+=(-Xplugin="$serplugin")
  local cp="" e
  while IFS= read -r e; do
    [ -f "$e" ] || continue
    cp="${cp:+$cp:}$e"
  done < "$CORPUS/classpath.txt"
  rm -rf "$APP_CLASSES/compose"
  if "$cdir/bin/kotlinc" "${xplugin[@]}" -nowarn -jvm-target 17 \
       -classpath "$cp" -d "$APP_CLASSES/compose" "$csrc"/*.kt \
       > "$WORK/kotlinc-corpus.log" 2>&1; then
    "$JAVA_BIN/jar" --create --file "$APP_CLASSES/compose-app.jar" -C "$APP_CLASSES/compose" .
    add_prog "$APP_CLASSES/compose-app.jar"
    say "compose-app.jar: $(find "$APP_CLASSES/compose" -name '*.class' | wc -l) classes"
  else
    say "WARNING: compose sample did not compile, see $WORK/kotlinc-corpus.log"
    tail -20 "$WORK/kotlinc-corpus.log" | sed 's/^/    /' | tee -a "$REPORT"
  fi
}

# --------------------------------------------------- Compose program input
say "=== corpus: compose artifacts + composable bytecode ==="

# The compose runtime an app links against, straight from Google Maven. These
# are the libraries D8/R8 must READ for desugaring and resolution, which is a
# different code path from program classes. classes.jar is pulled out of each
# AAR because that is what a dexing classpath actually contains.
for u in "${COMPOSE_LIBS[@]}"; do add_remote "$u"; done
say "compose libraries: $(wc -l < "$CORPUS/classpath.txt") entries on the classpath"

if [ "$TRACE_BUILD" != 1 ]; then
  say "TRACE_BUILD=$TRACE_BUILD, skipping the kotlinc compose compile"
else
  make_compose_app
fi

# ------------------------------------------------------------ keep rules
# The Proguard files the snapshots are exercised with. R8's CLI only speaks
# --flag options, so everything else has to come in through --pg-conf; these
# files are the R8 surface the validation runs cover (keep rules, attributes,
# optimization/shrinking toggles, print outputs, -target, flatten).
RULES="$WORK/rules"
PRINTS_DIR="$CORPUS/prints"
rm -rf "$RULES" "$PRINTS_DIR"; mkdir -p "$RULES" "$PRINTS_DIR"
cat > "$RULES/base.pro" <<EOF
-keep public class $CORPUS_NS.MainActivity { *; }
-keep class $CORPUS_NS.data.** { *; }
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
# NOTE: the '**' class patterns must stay quoted: bash would glob them against
# the cwd before they ever reach the parser.
mk_rules noopt     -dontoptimize
mk_rules noshrink  -dontshrink
mk_rules noobf     -dontobfuscate
mk_rules flatten   -flattenpackagehierarchy ''
mk_rules library   -dontskipnonpubliclibraryclasses -keeppackagenames
mk_rules target11  -target 11
mk_rules missing   '-dontnote **'
mk_rules missing-ok '-dontwarn **' -ignorewarnings
cat > "$RULES/prints.pro" <<EOF
$(cat "$RULES/base.pro")
--printmapping $PRINTS_DIR/prints.map
--printusage $PRINTS_DIR/prints.usage
--printseeds $PRINTS_DIR/prints.seeds
--printconfiguration $PRINTS_DIR/prints.configuration
--whyareyoukeeping class $CORPUS_NS.MainActivity
EOF
say "keep rules: $(ls "$RULES" | tr '\n' ' ')"

# ----------------------------------------------------------------- summary
sort -u "$CORPUS/programs.txt" -o "$CORPUS/programs.txt"
sort -u "$CORPUS/classpath.txt" -o "$CORPUS/classpath.txt"
sort -u "$CORPUS/samples.txt" -o "$CORPUS/samples.txt"
say "programs:  $(wc -l < "$CORPUS/programs.txt")"
say "classpath: $(wc -l < "$CORPUS/classpath.txt")"
du -sh "$CORPUS" | tee -a "$REPORT"
df -h "$WORK" | tail -1 | tee -a "$REPORT"
echo "=== corpus ready: $CORPUS ==="