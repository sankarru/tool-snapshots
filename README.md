# tool-snapshots

GraalVM `native-image` AOT snapshots of the build tools themselves —
`kotlinc`, R8, D8 — as instant-start native binaries, built in CI
(GitHub Actions runners have the ~16 GB RAM native-image linking needs).

The workflow also builds **`acs`** (the Rust build tool) and packs it together
with the D8/R8 snapshots into a single, ready-to-run bundle.

## Run

Actions → `tool-snapshots` → Run workflow. Inputs:

| input | default | meaning |
|---|---|---|
| `tools` | `d8,r8` | comma list of `d8`, `r8`, `kotlinc` |
| `acs_ref` | `main` | acs git ref (branch/tag/sha) to build into the bundle |
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
* `acs` — the `acs` binary on its own.
* `acs-bundle-arm64.tar.gz` — **`acs` + `d8-snapshot` + `r8-snapshot` side by
  side** (nothing to install: untar a directory and run `acs` from it, or point
  `SNAPSHOT_HOME` at it), plus a `.sha256`. Built only when `tools` contains
  both `d8` and `r8`.

### Required secret: `ACS_REPO_TOKEN`

`acs` lives in the private `sankarru/acs` repo, which the runner's
`GITHUB_TOKEN` cannot read. Add a **fine-grained PAT with `Contents: Read` on
`sankarru/acs`** as a repository secret named `ACS_REPO_TOKEN`
(Settings → Secrets and variables → Actions → New repository secret). The
`acs` job fails early with an explicit message if it is missing.

## The bundle

`acs --snapshot` runs D8 and R8 as the native images instead of
`java -cp d8.jar`: no JVM start, no AppCDS/SCC, no build-tools jar. It resolves
`d8-snapshot` / `r8-snapshot` from `[tools] snapshot_home`, then
`$SNAPSHOT_HOME`, then `~/.local/bin`, then `PATH` — and refuses to run unless
both self-identify as native-image snapshots. The bundle is exactly the layout
that satisfies it:

```sh
# download from the latest green release, e.g. with gh:
gh release download --repo sankarru/tool-snapshots \
  --pattern acs-bundle-arm64.tar.gz -D /tmp/acs-bundle
mkdir -p ~/tool-bundle && tar -xzf /tmp/acs-bundle/acs-bundle-arm64.tar.gz -C ~/tool-bundle
# ~/tool-bundle/{acs,d8-snapshot,r8-snapshot}
export SNAPSHOT_HOME=$HOME/tool-bundle
export ANDROID_HOME=$HOME/Android/Sdk
~/tool-bundle/acs --snapshot --min-sdk 26 <project>
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

The `acs` job checks out the private repo (via `ACS_REPO_TOKEN`) and runs a
plain release build:

```sh
cargo build --locked --release -p ca-e2e --config 'build.rustc-wrapper=""'
```

`--config 'build.rustc-wrapper=""'` disables the sccache wrapper acs's
`.cargo/config.toml` sets (sccache is not installed on the runner); `--release`
is the LLVM binary people ship; `--locked` refuses to silently re-resolve the
committed `Cargo.lock`. acs is pure Rust — no `build.rs`, no native deps — so a
nightly toolchain is the only requirement.

## Local use (arm64 Linux, no limitations)

The snapshot binaries are self-contained: no GraalVM, no wrapper, no
hardcoded paths on the using machine. Install the latest green build:

```sh
bash scripts/install-local.sh
# TAG=snapshots-42 PREFIX=~/bin bash scripts/install-local.sh
# INSTALL_ACS=1 bash scripts/install-local.sh   # also install `acs`
```

This puts `d8-snapshot` / `r8-snapshot` on your `PATH`, prints their
versions, and dexes a hello-world jar end to end. With `INSTALL_ACS=1` it
extracts the bundle instead, so `acs` lands next to both snapshots and
`SNAPSHOT_HOME=$PREFIX acs --snapshot …` just works. Afterwards use the
snapshots exactly like the JVM tools, pointing `--lib` at your own SDK:

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
