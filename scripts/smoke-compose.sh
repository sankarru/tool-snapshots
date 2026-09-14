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

APP=compose-aot
LIB="$ANDROID_HOME/platforms/android-35/android.jar"
APK="${APKANALYZER:?set APKANALYZER}"
chmod +x dist/d8-snapshot dist/r8-snapshot
[ -f "$LIB" ] || { echo "missing $LIB" >&2; exit 1; }

echo "--- 1. resolve dependencies (no Android/R8/D8 plugins) ---"
gradle -p tool-snapshots/smoke/fetch-deps fetch --console=plain --no-daemon -q
ls tool-snapshots/smoke/fetch-deps/build/libs | head -5

echo "--- 2. explode AARs to classes for the kotlinc classpath ---"
rm -rf smoke/cp && mkdir -p smoke/cp
CP=""
for f in tool-snapshots/smoke/fetch-deps/build/libs/*; do
  case "$f" in
    *.jar) CP="$CP:$f" ;;
    *.aar)
      n="$(basename "$f" .aar)"
      mkdir -p "smoke/cp/$n"
      unzip -o -q "$f" classes.jar -d "smoke/cp/$n"
      CP="$CP:smoke/cp/$n/classes.jar"
      ;;
  esac
done
CP="${CP#:}:$LIB"
echo "classpath entries: $(echo "$CP" | tr ':' '\n' | grep -c .)"

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

echo "--- 5a. d8-snapshot: dex app classes ---"
rm -rf smoke/d8-out && mkdir -p smoke/d8-out
dist/d8-snapshot --lib "$LIB" --classpath "$CP" \
  --min-api 24 --output smoke/d8-out smoke/classes
"$APK" dex packages smoke/d8-out/classes.dex | grep 'Lcom/example/aotmin/MainActivity;'
echo "D8-OK: MainActivity present in snapshot-dexed classes.dex"

echo "--- 5b. r8-snapshot: shrink app classes with app rules ---"
rm -f smoke/r8-out.zip
dist/r8-snapshot --lib "$LIB" --classpath "$CP" \
  --min-api 24 --pg-conf "$APP/app/proguard-rules.pro" \
  --output smoke/r8-out.zip smoke/classes
unzip -p smoke/r8-out.zip classes.dex > smoke/r8-classes.dex
"$APK" dex packages smoke/r8-classes.dex | grep 'Lcom/example/aotmin/MainActivity;'
echo "R8-OK: MainActivity present after snapshot shrink"

echo "=== compose smoketest passed (snapshots only) ==="
