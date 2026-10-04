# tool-snapshots

GraalVM `native-image` AOT snapshots of the build tools themselves —
`d8-snapshot`, `r8-snapshot`, `kotlinc-snapshot` — as instant-start native
binaries, built in CI (GitHub Actions runners have the ~16 GB RAM
native-image linking needs).

`d8` and `r8` are built **from R8 source**: every CI run fetches the current
googlesource revision, compiles it without Gradle, and links it with a short,
explicit list of native-image options. There is no tracing agent and no
recorded class list — see [`scripts/README.md`](scripts/README.md) for the
full pipeline.

## Run

Actions → `tool-snapshots` → Run workflow. Inputs:

| input | default | meaning |
|---|---|---|
| `tools` | `d8,r8` | comma list of `d8`, `r8`, `kotlinc` |
| `kotlin_version` | `v2.2.20` | kotlinc release tag (kotlinc job only) |

Jobs on `ubuntu-24.04-arm` with GraalVM 25:

- `snapshot d8`, `snapshot r8` — build R8 from source, link, smoke-test over a
  Compose corpus, upload `<tool>-snapshot-arm64`. Both roles of both tools come
  out of one source build: `d8` and `r8` are the same jar with different entry
  points, so the D8 image is the same code as the R8 image.
- `snapshot kotlinc` — unchanged legacy path: traced with the agent.
- `smoke snapshots on compose-aot` — runs both snapshots against real Compose
  bytecode from `sankarru/compose-aot`.

Artifacts (7-day retention): `d8-snapshot-arm64`, `r8-snapshot-arm64`, plus a
`<tool>-logs` artifact with the build log, native-image log, keep rules and
per-run smoke logs.

## Local use (arm64 Linux, no limitations)

The binaries are self-contained: no GraalVM, no wrapper, no paths baked in from
the build machine. Install the latest green build:

```sh
bash scripts/install-local.sh
# RUN_ID=37168606930 PREFIX=~/bin bash scripts/install-local.sh
```

This puts `d8-snapshot` / `r8-snapshot` on your `PATH`, prints their versions
and dexes a hello-world jar end to end. Afterwards use them exactly like the
JVM tools, pointing `--lib` at your own SDK:

```sh
export ANDROID_HOME=$HOME/Android/Sdk
mkdir -p dex-out                       # D8 wants an existing dir or a .zip
d8-snapshot --lib $ANDROID_HOME/platforms/android-36/android.jar \
  --min-api 24 --output dex-out app.jar
r8-snapshot --lib $ANDROID_HOME/platforms/android-36/android.jar \
  --min-api 24 --pg-conf rules.pro --output shrunk.zip app.jar
```

`--version` reports the upstream R8 commit the binary was built from:

```
D8 main (build b3af91e47faad5c37208f094ec87d4c408fcda34 from native-image-snapshot)
```

The images target the ARMv8-A baseline, so they run on any arm64 host —
including VMs that lack ARMv8.1 atomics, where a host-CPU-targeted image
would refuse to start.

## Layout

```
scripts/build-r8-source.sh      compile R8 from googlesource main, no Gradle
scripts/r8-overlay/             patches + extra sources for the image build
scripts/build-native-image.sh   native-image link for the D8/R8 entry points
scripts/snapshot.sh             per-tool driver (source build -> link -> smoke)
scripts/corpus.sh               validation corpus: Compose bytecode + keep rules
scripts/smoke-snapshot.sh       run the linked binary over that corpus
scripts/smoke-compose.sh        snapshots vs. real Compose app bytecode
scripts/install-local.sh        download + install the latest green binaries
scripts/README.md               pipeline details, env vars, debugging table
```

If a snapshot ever fails on an input where the JVM tool succeeds, the fix
belongs in `scripts/r8-overlay/` (a patch against upstream source) — not in
local config, and not in a list of class names committed here.