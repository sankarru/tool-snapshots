# tool-snapshots

GraalVM `native-image` AOT snapshots of the build tools themselves —
`kotlinc`, R8, D8 — as instant-start native binaries, built in CI
(GitHub Actions runners have the ~16 GB RAM native-image linking needs).

## Run

Actions → `tool-snapshots` → Run workflow. Inputs:

| input | default | meaning |
|---|---|---|
| `tools` | `d8,r8` | comma list of `d8`, `r8`, `kotlinc` |
| `arch` | `x64,arm64` | `ubuntu-latest` / `ubuntu-24.04-arm` runners |
| `kotlin_version` | `v2.2.20` | kotlinc release tag |
| `r8_version` | `8.13.23` | R8 version from Google Maven |

Artifacts: `<tool>-snapshot-<arch>` binaries (7-day retention).

## How it works (`scripts/snapshot.sh`)

1. Fetch the tool jars (R8 from Google Maven, kotlinc dist from GitHub).
2. Run the tool **for real under the tracing agent** (D8 dexes a sample
   jar, R8 shrinks one, kotlinc compiles `hello.kt`) — `--version` alone
   would trace nothing.
3. Link with `native-image --no-fallback --allow-incomplete-classpath`.
4. Smoke-test the snapshot binary the same way (version + real work).

Start with `d8,r8` (smallest closed-world surface). `kotlinc` is included
but expected to need metadata iterations — the compiler leans on services,
message bundles and plugins that only show up when exercised.

## Local use (arm64 Linux, no limitations)

The snapshot binaries are self-contained: no GraalVM, no wrapper, no
hardcoded paths on the using machine. Install the latest green build:

```sh
bash scripts/install-local.sh
# RUN_ID=34896218148 PREFIX=~/bin bash scripts/install-local.sh
```

This puts `d8-snapshot` / `r8-snapshot` on your `PATH`, prints their
versions, and dexes a hello-world jar end to end. Afterwards use them
exactly like the JVM tools, pointing `--lib` at your own SDK:

```sh
export ANDROID_HOME=$HOME/Android/Sdk
d8-snapshot --lib $ANDROID_HOME/platforms/android-35/android.jar \
  --min-api 24 --output dex-out app.jar
r8-snapshot --lib $ANDROID_HOME/platforms/android-35/android.jar \
  --min-api 24 --pg-conf rules.pro --output shrunk.zip app.jar
```

Reflection/JNI/resources used during the traced runs are baked in (see the
`*-meta` folders uploaded next to each binary). If a snapshot ever fails
on a new input where the JVM tool succeeds, that input exercises untraced
code — extend the tracing workload in `scripts/snapshot.sh`, not local
config: there is deliberately nothing to configure locally.
