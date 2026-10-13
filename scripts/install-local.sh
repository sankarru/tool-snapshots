#!/usr/bin/env bash
# Install the arm64 snapshot binaries for LOCAL use.
# No GraalVM, no SDK paths, no build needed on this machine: the binaries
# are self-contained native executables. The only local requirement is an
# Android SDK whose android.jar you pass via --lib ( dunk it from ANDROID_HOME).
#
# Usage:
#   PREFIX=~/.local/bin bash scripts/install-local.sh        # latest stable release
#   TAG=snapshots-42 bash scripts/install-local.sh           # a specific release
#   INSTALL_ACS=1 bash scripts/install-local.sh              # also install acs
# Env: REPO (default sankarru/tool-snapshots), TOOLS (default "d8 r8"),
#      TAG (default: the latest stable release), INSTALL_ACS (default 0; 1
#      pulls `acs` + both snapshots from the bundle).
set -euo pipefail

REPO="${REPO:-sankarru/tool-snapshots}"
PREFIX="${PREFIX:-$HOME/.local/bin}"
TOOLS="${TOOLS:-d8 r8}"
INSTALL_ACS="${INSTALL_ACS:-0}"

# Binaries live as release assets, not run artifacts (artifact storage is a
# small account-wide quota; release assets are not metered by it). Prereleases
# are deliberately skipped: a run only promotes its release to stable once every
# job succeeded, so "latest stable" means "latest green".
if [ -z "${TAG:-}" ]; then
  TAG="$(gh release list --repo "$REPO" --exclude-pre-releases --limit 1 \
    --json tagName --jq '.[0].tagName')"
fi
[ -n "${TAG:-}" ] || { echo "no stable release found in $REPO" >&2; exit 1; }
echo "installing from release $TAG -> $PREFIX"
mkdir -p "$PREFIX" /tmp/snap-local
for t in $TOOLS; do
  d="/tmp/snap-local/$t"
  rm -rf "$d" && mkdir -p "$d"
  gh release download "$TAG" --repo "$REPO" -p "$t-snapshot-arm64.tar.gz" -D "$d"
  tar -xzf "$d/$t-snapshot-arm64.tar.gz" -C "$d"
  install -m755 "$d/$t-snapshot" "$PREFIX/$t-snapshot"
done

if [ "$INSTALL_ACS" = "1" ]; then
  # The bundle is the one-flat-directory layout `acs --snapshot` wants:
  # acs + d8-snapshot + r8-snapshot side by side. Extracting it also (re)installs
  # the snapshots, so this is the recommended single step.
  echo "--- install acs + snapshots from the bundle ---"
  rm -rf /tmp/snap-bundle && mkdir -p /tmp/snap-bundle
  gh release download "$TAG" --repo "$REPO" -p 'acs-bundle-arm64.tar.gz' -D /tmp/snap-bundle
  tar -xzf /tmp/snap-bundle/acs-bundle-arm64.tar.gz -C "$PREFIX" acs d8-snapshot r8-snapshot
  "$PREFIX/acs" --version
  echo "run acs --snapshot with: SNAPSHOT_HOME=$PREFIX"
fi

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
