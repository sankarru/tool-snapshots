# tool-snapshots

GraalVM `native-image` AOT snapshots of the build tools themselves —
`kotlinc`, R8, D8 — as instant-start native binaries, built in CI
(GitHub Actions runners have the ~16 GB RAM native-image linking needs).

`acs` (the Rust build tool) is a separate, **local-only** project in
`sankarru/acs` — built from source, with no releases of its own. This repo
produces the snapshots only; `acs` consumes them at runtime via
`[tools] snapshot_home` / `$SNAPSHOT_HOME`.

## Run

Actions → `tool-snapshots` → Run workflow. Inputs:

| input | default | meaning |
|---|---|---|
| `tools` | `d8,r8` | comma list of `d8`, `r8`, `kotlinc` |
| `kotlin_version` | `v2.2.20` | kotlinc release tag |
| `r8_version` | `8.13.23` | R8 version from Google Maven |
| `release_tag` | `snapshots-<run number>` | release to publish the binaries to |

Runners are `ubuntu-24.04-arm` (arm64). Binaries are published as **GitHub
Release assets**, not workflow artifacts: Actions artifact storage is a small
account-wide quota (500 MB on the Free plan) that this repo does not control,
whereas release assets are not metered by it — and a release outlives the
7-day artifact retention anyway.

The release starts as a **prerelease** and is promoted to stable/latest by the
`finalize` job only if every requested job succeeded, so "latest stable" always
means "latest green". Assets:

* `<tool>-snapshot-arm64.tar.gz` — the binary and its `<tool>-snapshot-meta/`
  trace.

## Running acs with the snapshots

`acs --snapshot` runs D8 and R8 as the native images instead of
`java -cp d8.jar`: no JVM start, no AppCDS/SCC, no build-tools jar. It resolves
`d8-snapshot` / `r8-snapshot` from `[tools] snapshot_home`, then
`$SNAPSHOT_HOME`, then `~/.local/bin`, then `PATH` — and refuses to run unless
both self-identify as native-image snapshots. Install the snapshots (below) so
they sit beside `acs`, then:

```sh
bash scripts/install-local.sh          # d8-snapshot + r8-snapshot into ~/.local/bin
# acs is built from source in its own repo: cd acs && ./scripts/install-acs.sh
export SNAPSHOT_HOME=$HOME/.local/bin
export ANDROID_HOME=$HOME/Android/Sdk
acs --snapshot --min-sdk 26 <project>
```

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

### Building acs

`acs` is not built here — it is a local-only project in its own repo
(`sankarru/acs`). Build it from source there:

```sh
cd acs && cargo build --locked --release -p ca-e2e --config 'build.rustc-wrapper=""'
# or: ./scripts/install-acs.sh   (installs into ~/.local/bin)
```

`--config 'build.rustc-wrapper=""'` disables the sccache wrapper acs's
`.cargo/config.toml` sets; `--release` is the LLVM binary; `--locked` refuses to
silently re-resolve the committed `Cargo.lock`. acs is pure Rust — no
`build.rs`, no native deps — so a nightly toolchain is the only requirement.

## Local use (arm64 Linux, no limitations)

The snapshot binaries are self-contained: no GraalVM, no wrapper, no
hardcoded paths on the using machine. Install the latest green build:

```sh
bash scripts/install-local.sh
# TAG=snapshots-42 PREFIX=~/bin bash scripts/install-local.sh
```

This puts `d8-snapshot` / `r8-snapshot` on your `PATH`, prints their versions,
and dexes a hello-world jar end to end. `acs` is not installed from here: build
it from source in `sankarru/acs`; it then finds the snapshots in `~/.local/bin`
(or `$SNAPSHOT_HOME`). Afterwards use the snapshots exactly like the JVM tools,
pointing `--lib` at your own SDK:

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
