#!/usr/bin/env bash
# Smoke-test the d8/r8 AOT snapshots against REAL Compose bytecode with
# NO JVM R8/D8 anywhere in the pipeline:
#   1. resolve the app's dependencies (pure Gradle resolution, no plugins)
#   2. compile compose-aot sources with kotlinc (compiler role only)
#   3. shrink with r8-snapshot, dex with d8-snapshot
#   4. verify MainActivity survives in both outputs via apkanalyzer
#
# Layout: ./compose-aot (sources+rules), ./dist (snapshots),
#         ./tool-snapshots (this repo). Env: ANDROID_HOME, APKANALYZER,
#         KOTLIN_TAG (vX.Y.Z), JAVA_HOME (any JDK 17+).
set -euo pipefail

# Repo root (this script lives at <repo>/scripts/) vs workspace root:
# CI checks out tool-snapshots/ AND compose-aot/ side by side, so the
# workspace is the PARENT of the repo; locally compose-aot is symlinked
# (or checked out) next to it. Either way we end up with ./compose-aot
# and ./dist side by side.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -d "$REPO_ROOT/compose-aot" ]; then WS="$REPO_ROOT"; else WS="$(dirname "$REPO_ROOT")"; fi
cd "$WS"

# apkanalyzer is a launcher script that honors JAVA_HOME; fail fast with a
# clear message instead of a cryptic tool error halfway through.
"$JAVA_HOME/bin/java" -version >/dev/null 2>&1 \
  || { echo "JAVA_HOME is invalid: $JAVA_HOME" >&2; exit 1; }

APP=compose-aot
LIB="$ANDROID_HOME/platforms/android-35/android.jar"
APK="${APKANALYZER:?set APKANALYZER}"
chmod +x dist/d8-snapshot dist/r8-snapshot
[ -f "$LIB" ] || { echo "missing $LIB" >&2; exit 1; }

echo "--- 1. resolve dependencies (no Android/R8/D8 plugins) ---"
gradle -p "$REPO_ROOT/smoke/fetch-deps" fetch --console=plain --no-daemon -q
ls "$REPO_ROOT/smoke/fetch-deps/build/libs" | head -5

echo "--- 2. explode AARs to classes for the kotlinc classpath ---"
rm -rf smoke/cp && mkdir -p smoke/cp
CP=""
for f in "$REPO_ROOT"/smoke/fetch-deps/build/libs/*; do
  case "$f" in
    *.jar) CP="$CP:$f" ;;
    *.aar)
      n="$(basename "$f" .aar)"
      mkdir -p "smoke/cp/$n"
      unzip -o -q "$f" classes.jar -d "smoke/cp/$n"
      CP="$CP:$WS/smoke/cp/$n/classes.jar"
      ;;
  esac
done
CP="${CP#:}:$LIB"
echo "classpath entries: $(echo "$CP" | tr ':' '\n' | grep -c .)"
# D8/R8 take one --classpath flag PER entry (a colon-joined string is read
# as a single path), so expand into an array. All entries are absolute.
CP_ARGS=()
while IFS= read -r e; do
  [ -n "$e" ] && CP_ARGS+=(--classpath "$e")
done < <(echo "$CP" | tr ':' '\n')

echo "--- 3. fetch kotlinc dist (compiler only) ---"
if [ ! -d smoke/kotlinc ]; then
  curl -sSfL -o smoke/kotlinc.zip \
    "https://github.com/JetBrains/kotlin/releases/download/${KOTLIN_TAG:?}/kotlin-compiler-${KOTLIN_TAG#v}.zip"
  unzip -q smoke/kotlinc.zip -d smoke
fi
KOTLINC=smoke/kotlinc/bin/kotlinc
CPLUG=smoke/kotlinc/lib/compose-compiler-plugin.jar
SPLUG=smoke/kotlinc/lib/kotlin-serialization-compiler-plugin.jar

echo "--- 4. compile compose-aot with kotlinc ---"
rm -rf smoke/classes && mkdir -p smoke/classes
"$KOTLINC" -cp "$CP" -Xplugin="$CPLUG" -Xplugin="$SPLUG" \
  -d smoke/classes "$APP"/app/src/main/java/com/example/aotmin/*.kt
find smoke/classes -name "*.class" | head -5
# D8/R8 take archives, not raw class directories.
"$JAVA_HOME/bin/jar" --create --file smoke/app.jar -C smoke/classes .

echo "--- 5a. d8-snapshot: dex app classes ---"
rm -rf smoke/d8-out && mkdir -p smoke/d8-out
dist/d8-snapshot --lib "$LIB" "${CP_ARGS[@]}" \
  --min-api 24 --output smoke/d8-out smoke/app.jar
"$APK" dex packages smoke/d8-out/classes.dex | grep 'com.example.aotmin.MainActivity'
echo "D8-OK: MainActivity present in snapshot-dexed classes.dex"

echo "--- 5b. r8-snapshot: shrink app classes with app rules ---"
rm -f smoke/r8-out.zip
dist/r8-snapshot --lib "$LIB" "${CP_ARGS[@]}" \
  --min-api 24 --pg-conf "$APP/app/proguard-rules.pro" \
  --output smoke/r8-out.zip smoke/app.jar
unzip -p smoke/r8-out.zip classes.dex > smoke/r8-classes.dex
"$APK" dex packages smoke/r8-classes.dex | grep 'com.example.aotmin.MainActivity'
echo "R8-OK: MainActivity present after snapshot shrink"

echo "=== compose smoketest passed (snapshots only) ==="
