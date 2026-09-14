#!/usr/bin/env bash
# Install the arm64 snapshot binaries for LOCAL use.
# No GraalVM, no SDK paths, no build needed on this machine: the binaries
# are self-contained native executables. The only local requirement is an
# Android SDK whose android.jar you pass via --lib ( dunk it from ANDROID_HOME).
#
# Usage:
#   PREFIX=~/.local/bin bash scripts/install-local.sh        # latest green run
#   RUN_ID=34896218148 bash scripts/install-local.sh         # a specific run
# Env: REPO (default sankarru/tool-snapshots), TOOLS (default "d8 r8").
set -euo pipefail

REPO="${REPO:-sankarru/tool-snapshots}"
PREFIX="${PREFIX:-$HOME/.local/bin}"
TOOLS="${TOOLS:-d8 r8}"

if [ -z "${RUN_ID:-}" ]; then
  RUN_ID="$(gh run list --repo "$REPO" --workflow snapshot.yml \
    --status success --limit 1 --json databaseId --jq '.[0].databaseId')"
fi
[ -n "${RUN_ID:-}" ] || { echo "no successful run found" >&2; exit 1; }
echo "installing from run $RUN_ID -> $PREFIX"
mkdir -p "$PREFIX" /tmp/snap-local
for t in $TOOLS; do
  rm -rf "/tmp/snap-local/$t" && mkdir -p "/tmp/snap-local/$t"
  gh run download "$RUN_ID" --repo "$REPO" -n "$t-snapshot-arm64" -D "/tmp/snap-local/$t"
  install -m755 "/tmp/snap-local/$t/$t-snapshot" "$PREFIX/$t-snapshot"
done

echo "--- verify ---"
export PATH="$PREFIX:$PATH"
d8-snapshot --version
r8-snapshot --version 2>/dev/null || true

# End-to-end: dex + shrink a hello-world jar with the snapshots.
S=/tmp/snap-local/hello && rm -rf "$S" && mkdir -p "$S/src/hello" "$S/classes"
cat > "$S/src/hello/Hello.java" <<'EOF'
package hello;
public class Hello {
  public static void main(String[] args) {
    System.out.println("hello from " + (args.length > 0 ? args[0] : "snapshot"));
  }
}
EOF
JAVAC="$(command -v javac || echo "$JAVA_HOME/bin/javac")"
"$JAVAC" -d "$S/classes" "$S/src/hello/Hello.java"
"$JAVA_HOME/bin/jar" --create --file "$S/hello.jar" -C "$S/classes" .
LIB="$(find "${ANDROID_HOME:-$ANDROID_SDK_ROOT}" -path "*platforms/android-3*/android.jar" | sort | tail -1)"
[ -n "$LIB" ] || { echo "no android.jar found under ANDROID_HOME" >&2; exit 1; }
echo "lib: $LIB"
d8-snapshot --lib "$LIB" --min-api 24 --output "$S/dex-out" "$S/hello.jar"
ls "$S/dex-out"
echo "=== local snapshots work ==="
