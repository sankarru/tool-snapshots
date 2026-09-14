#!/usr/bin/env bash
# Smoke-test the d8/r8 snapshot binaries against REAL Compose bytecode:
# the release classes of sankarru/compose-aot (built by the smoke-compose job).
# Env: ANDROID_HOME set, APKANALYZER points at apkanalyzer.
# Layout: ./compose-aot (app source + build outputs), ./dist (snapshots).
set -euo pipefail

APP=compose-aot
LIB="$ANDROID_HOME/platforms/android-35/android.jar"
APK="${APKANALYZER:?set APKANALYZER}"
chmod +x dist/d8-snapshot dist/r8-snapshot

# Program inputs: AGP puts Kotlin classes in tmp/kotlin-classes, Java (if any)
# in intermediates/javac. Pass both; at least one must exist.
PROG=()
for d in "$APP/app/build/tmp/kotlin-classes/release" \
         "$APP/app/build/intermediates/javac/release/classes"; do
  if [ -d "$d" ]; then PROG+=("$d"); fi
done
[ "${#PROG[@]}" -gt 0 ] || { echo "no compiled classes found" >&2; exit 1; }
echo "program inputs: ${PROG[*]}"

# Library classpath: every cached module jar (Compose, coroutines,
# serialization, AndroidX). R8/D8 need these to resolve references.
CP="$(find "$HOME/.gradle/caches/modules-2" -name '*.jar' \
  ! -name '*sources*' ! -name '*javadoc*' | tr '\n' ':')"
[ -n "$CP" ] || { echo "empty gradle-cache classpath" >&2; exit 1; }

mkdir -p smoke/d8-out

echo "--- d8-snapshot: dex app classes ---"
dist/d8-snapshot --lib "$LIB" --classpath "$CP" \
  --min-api 24 --output smoke/d8-out "${PROG[@]}"
"$APK" dex packages smoke/d8-out/classes.dex | grep 'Lcom/example/aotmin/MainActivity;'
echo "D8-OK: MainActivity present in snapshot-dexed classes.dex"

echo "--- r8-snapshot: shrink app classes with app rules ---"
rm -f smoke/r8-out.zip
dist/r8-snapshot --lib "$LIB" --classpath "$CP" \
  --min-api 24 --pg-conf "$APP/app/proguard-rules.pro" \
  --output smoke/r8-out.zip "${PROG[@]}"
unzip -l smoke/r8-out.zip | grep 'classes Dex\|classes.dex' || unzip -l smoke/r8-out.zip | grep -i dex
unzip -p smoke/r8-out.zip classes.dex > smoke/r8-classes.dex
"$APK" dex packages smoke/r8-classes.dex | grep 'Lcom/example/aotmin/MainActivity;'
echo "R8-OK: MainActivity present after snapshot shrink"

echo "=== compose smoketest passed ==="
