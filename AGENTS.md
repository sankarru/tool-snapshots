# AGENTS.md — tool-snapshots

Agent memory for this repo. Read this before touching the pipeline; the
README is for humans, this file is for the next session.

## What this is

GraalVM 25 `native-image` builds of the Android dexers, built from R8 sources
instead of from a prebuilt jar:

- `d8-snapshot`, `r8-snapshot` — **one source build, two entry points**. The
  `d8` job and the `r8` job each run `scripts/snapshot.sh`, which builds
  `r8-src.jar` from `r8.googlesource.com/r8@main` and links a different main
  class out of the *same* jar. A change to the jar moves both images.
- `kotlinc-snapshot` — the older path, still built with the tracing agent. Not
  affected by anything in the R8 source build.

Consumers: [sankarru/acs](https://github.com/sankarru/acs) runs them as
`acs <project> --snapshot` for the D8 and R8 roles.

## Commands

```sh
# build + link + smoke on the ARM runner (there is no local GraalVM)
gh workflow run snapshot.yml --ref <branch> -f tools=d8,r8
gh run list --workflow snapshot.yml --limit 3
gh run view <id> --json jobs --jq '.jobs[] | "\(.name): \(.conclusion)"'

# install the latest FULLY green run (all four jobs) into ~/.local/bin
bash scripts/install-local.sh
RUN_ID=37174522807 PREFIX=~/bin bash scripts/install-local.sh

# jar only, no native-image: the fast way to test a source-build change
WORK=/tmp/r8build JAVA_BIN=~/opt/jdk-25.0.4+7/bin ANDROID_SDK=~/Android/Sdk \
  bash scripts/build-r8-source.sh      # ~8 min cold; ends in "jar audit: all N ..."
```

Local builds stop at the jar: **GraalVM `native-image` is not installed
locally**, so anything image-shaped (reachability, linking, `--version`
output) is CI-only evidence. Say so rather than implying it was tested.

## Hard rules

1. **A dexer gap is fixed in `scripts/r8-overlay/`**, as a patch against
   upstream source — never as a list of class names, and never by passing
   tracing/`reachability-metadata` options to `native-image`. Precedent:
   `0001-threading-module-bundled-provider.patch` replaces a `Class.forName`
   provider lookup with a plain virtual call, keeping the reflective path as a
   fallback for providers outside the jar.
2. **Upstream drift is visible, never silent.** Patches are `patch -p1`ed
   after a dry run; a patch that stops applying prints a WARNING and is
   skipped. Read the build log for that line before trusting a green build.
3. **`CLASS_DIRS` in `scripts/build-r8-source.sh` is the packaging contract.**
   R8 is not all Java: `keepanno` (27 `.kt`) and `resourceshrinker` (9 `.kt`)
   are compiled by kotlinc into `classes-kotlin/`, javac reads that directory
   for cross-language resolution, and the jar is built from *every* entry of
   `CLASS_DIRS`. `audit_jar_class_files` then fails the build if any compiled
   class is not readable from the jar.

   This exists because the jar once carried javac's output only: 56 classes
   were silently missing, `--version`/dex/shrink all worked, and the compiler
   died with `NoClassDefFoundError: ...resourceshrinker.usages.AppCompat` the
   first time anything asked it to shrink resources. **When a snapshot fails
   on an input where the JVM tool succeeds, check the input jar before
   blaming native-image reachability.**
4. **arm64 only.** Everything targets the ARMv8-A baseline on
   `ubuntu-24.04-arm`; an x86 build would need a new matrix entry and a new
   artifact name, not a flag.

## The interface acs depends on

- `--version` must print a line containing **`native-image-snapshot`** — acs
  runs `--version` on both binaries and refuses the build otherwise. It comes
  from `releaser=native-image-snapshot` in the generated
  `r8-version.properties`.
- The same line is acs's **cache key**: `Sdk::snapshot_bucket_tag` digests it,
  so the R8 commit in the line decides which dex-cache buckets are used. Keep
  the `D8 main (build <sha> from native-image-snapshot)` shape; a new CI run is
  a new version and must read as one.
- Both binaries must exist in the same directory; acs resolves
  `snapshot_home` → `$SNAPSHOT_HOME` → `~/.local/bin` → `PATH`.

## Testing

`scripts/smoke-snapshot.sh` runs the linked binary over the corpus. Primary
cases (`dex-corpus`, `shrink-corpus`, `version`) are fatal; variant cases are
reported into `<tool>-smoke-report.txt`, which travels with the artifact
because a variant regression is a reachability gap in the image.

**Resource shrinking is not covered by the smoke matrix**, and cannot easily
be: the consumer that pulls in `resourceshrinker.usages.*` is set through the
`R8Command.Builder` API by AGP, not by a CLI flag, so no command line reaches
it. Coverage for that path is the acs release build with
`[build] shrink_resources = true` plus `--snapshot` — do that after any change
to packaging or to the resource-shrinker classes, and install the APK on
`emulator-5554` before calling it done.

## Traps

- **R8 rejects a directory as program input.** Pass `.class` files (acs
  expands them with `collect_classes`) or a jar/zip. `--output` for D8, by
  contrast, wants an existing directory or a `.zip`.
- **Proguard syntax needs the leading dash**: `-keep`, not `keep`.
- `r8.googlesource.com` and `storage.googleapis.com` return 503 under CI load;
  the fetch helpers retry with backoff, and a half-downloaded tarball is
  rejected rather than unpacked.
- The api database is memory-mapped at runtime, so it is stored
  (`--no-compress`) in the jar.
- `resources/` in the jar ships the API-level files resource shrinking needs;
  the overlay's `META-INF/` is merged in too.