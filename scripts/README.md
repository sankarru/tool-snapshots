# d8/r8 snapshot pipeline

How a `d8-snapshot` / `r8-snapshot` binary is produced, what each script
does, and what to change when it breaks.

No Gradle, no AGP, no Android app, and **no native-image agent tracing**.
R8 is compiled from the upstream googlesource tree and linked with a short,
explicit list of native-image options. Everything CI produces is reproducible
from a stock JDK plus a GraalVM 25 install.

## Pipeline

```
r8.googlesource.com/r8 @ main ──► scripts/build-r8-source.sh ──► work-<tool>/r8-src.jar
                                        │  (18 MB, 6050 classes, source sha in --version)
                                        ▼
                                 scripts/build-native-image.sh
                                        │  native-image 25, -march=armv8-a
                                        ▼
                                 out/d8-snapshot, out/r8-snapshot
                                        │
                                        ▼
                                 scripts/smoke-snapshot.sh
                                 (corpus from scripts/corpus.sh)
```

One source build serves both tools: `d8` and `r8` are the same jar with
different entry points (`com.android.tools.r8.D8` / `com.android.tools.r8.R8`).
The two CI jobs each redo the build because they run on separate machines.

## scripts/build-r8-source.sh

Compiles the compiler. Steps, in order:

| step | what it does |
|---|---|
| `fetch_source` | `+archive/refs/heads/main.tar.gz` from googlesource into `work/r8-src/src`; records the commit from `+log` in `source-sha.txt` |
| `apply_overlay` | `patch -p1` over every `scripts/r8-overlay/patches/*.patch`; a dry run first, so upstream drift is a visible warning, not a mangled file |
| `fetch_deps` | parses `gradle/libs.versions.toml` + the selected modules' `build.gradle.kts`, downloads Maven/Google jars, AAR `classes.jar`s, `-jvm` variants, drops Android metadata stubs |
| `fetch_api_database` | `third_party/api_database/api_database.tar.gz.sha1` names an object in `storage.googleapis.com/r8-deps`; SHA1-verified, extracted to `resources/api_database.ser` |
| `gen_protos` | `protoc` (downloaded, arch-matched) for the keepanno + keepradius protos |
| `compile_kotlin` | 36 `.kt` files (keepanno 27, resourceshrinker 9) with `kotlin-compiler-embeddable` |
| `compile_r8` | 3497 `.java` files, `javac --release 17` |
| `package_r8` | jar + `src/main/resources` + generated `r8-version.properties` |
| `verify_on_jvm` | `D8/R8 --version`, a dex run and a shrink run on a generated hello-world |

Modules compiled: `main utils assistant keepradius keepanno resourceshrinker`.
`library_desugar` is deliberately excluded — it declares `java.nio.*` types
and is the desugared-library payload, not part of the compiler jar.

Env: `WORK` (required), `JAVA_BIN`, `R8_REPO_URL`, `R8_REF` (default `main`),
`R8_JAVA_RELEASE` (default `17`). Takes ~4.5 min from cold on one core.

`r8-version.properties` carries the source sha, so a snapshot reports the
upstream commit it was built from:

```
D8 main (build b3af91e47faad5c37208f094ec87d4c408fcda34 from native-image-snapshot)
```

## scripts/r8-overlay/

Upstream fixes the image builder cannot infer. Applied as patches so the
delta against googlesource stays reviewable in a diff.

`patches/0001-threading-module-bundled-provider.patch` — `ThreadingModule.Loader`
did `Class.forName(name).getDeclaredConstructor().newInstance()` over a list of
provider class names. A native image has no classpath to scan at run time, so
that lookup cannot find classes that are right there in the image. The patch
constructs `ThreadingModuleBlockingProvider` / `ThreadingModuleSingleThreadedProvider`
directly, in the same order, and keeps the reflective loop as the fallback for
providers that live outside this jar (upstream supports those).

The overlay directory also accepts `*.java` (compiled on top of the upstream
sources) and `META-INF` (copied into the jar) if a future need is not a patch.

## scripts/build-native-image.sh

```
native-image --no-fallback -H:+UnlockExperimentalVMOptions \
  -H:+ReportExceptionStackTraces -H:-CheckToolchain \
  -march=armv8-a \
  -H:IncludeResources=r8-version\.properties \
  -H:IncludeResources=resources/.* \
  -cp work/r8-src.jar:<deps> \
  -o out/<tool>-snapshot com.android.tools.r8.<Tool>
```

Each option is there for a reason:

- `-H:IncludeResources` — R8 reads its own resources at run time through
  `ClassLoader`/`Class.getResourceAsStream`: `VersionProperties`,
  `AndroidApiDataAccess` (`resources/api_database.ser`), `AmendApiFromResources`
  (`resources/*.txt`). Resources are not code, so nothing in the sources points
  at them statically. `resources/.*` covers the api database and the
  hidden/missing-api lists.
- `-march=armv8-a` — native-image otherwise targets the build host's CPU. On a
  GitHub arm64 runner that emits LSE atomics (`casal`/`ldadd`) and the binary
  then refuses to start on any machine without ARMv8.1. The baseline is what
  every arm64 device has; the cost is negligible next to losing the whole tool.
- `-H:+UnlockExperimentalVMOptions` — `IncludeResources` and `CheckToolchain`
  are still experimental; they only warn today, but the next GraalVM will
  reject them.
- no reflection or `Feature` config: after the `ThreadingModule` patch the only
  reflection left is on *target program* classes (R8 models reflection for the
  code it compiles), which an image builder has no business registering.

Env: `WORK` (required), `JAVA_BIN` (must be a GraalVM), `OUT_DIR`
(default `$WORK/native`), `TOOLS` (default `d8 r8`), `NI_EXTRA_OPTS`,
`NATIVE_IMAGE_ARGS_FILE`. Each link takes ~2.5 min and produces 69 MB (d8) /
81 MB (r8). The full command line is written next to the binary as
`<tool>-snapshot.native-image.log`, and warning counts are echoed to stdout.

## scripts/corpus.sh

Builds the validation corpus into `work-<tool>/corpus` — plain jars, no Gradle:

- `synthetic samples`: java8 / java21 / desugaring shapes / a broken jar
  (dangling type reference, so the error-reporting path runs too)
- `jvm libraries`: kotlin stdlib + reflect, coroutines, serialization
  (core/json), collections-immutable, guava, desugar_jdk_libs (+ its config)
- `compose`: androidx compose runtime/ui/foundation/material3/animation/
  graphics/text (Google Maven), `org.jetbrains:annotations`, and real
  `@Composable` bytecode compiled by `kotlinc` + the Compose compiler plugin
  from synthetic sources in package `corpus.compose`
- `rules/`: the Proguard files the R8 smoke runs use — `base.pro`,
  `prints.pro`, `noopt`, `noshrink`, `target11`, `flatten`, `missing`,
  `library`, `noobf`, `missing-ok`

Two things to keep in mind when editing the corpus:

- The keep rules keep the corpus' public surface (`UiKt`, `Item`, `ItemStore`,
  `Snapshot`, the generated serializers). R8 resolves everything a kept class
  mentions in its signature, so the classpath must contain the Compose
  artifacts those signatures reference — otherwise every shrink run dies with
  `Missing class androidx.compose.animation.core.AnimationState`. Keep the
  keeps narrow, or widen the classpath.
- Proguard print options take a **single** dash: `-printmapping`,
  `-printusage`, `-printseeds`, `-printconfiguration`, `-whyareyoukeeping`.
  The `--` forms are rejected by R8's Proguard parser.

Env: `WORK` (required), `JAVA_BIN`, `ANDROID_SDK`, `HELLO_JAR`, `KOTLIN_TAG`,
`CORPUS_NS`, `TRACE_BUILD=0` (skip the kotlinc/Compose compile).

## scripts/smoke-snapshot.sh

Runs the linked binary over the corpus. Primary runs are fatal, variants are
reported as degraded and listed in `out/<tool>-smoke-report.txt`.

- d8: dex the corpus at min-api 24, dex at 19, `--no-desugaring`, `--classfile`,
  `--file-per-class` + globals, dex the dex it just produced, and the broken
  input.
- r8: `--version`, shrink the corpus, `-print*` outputs, `-dontoptimize`,
  `-dontshrink`, `-target 11`, `--classfile`, `-flattenpackagehierarchy`, and
  the broken input. Finally it compares the shrunk jar against the
  `-dontshrink` jar over the same inputs and fails if shrinking did nothing
  (expect ~18.9 KB vs ~23.5 KB).

Env: `TOOL`, `WORK`, `OUT` (holds `<tool>-snapshot`). Per-run logs land in
`work-<tool>/smoke-<tool>/<label>.txt`.

## scripts/smoke-compose.sh (separate CI job)

Checks the snapshots against real Compose bytecode from
`sankarru/compose-aot`: Gradle resolves the app's dependencies (resolution
only, no AGP/R8/D8 plugins), `kotlinc` compiles the app, the snapshots shrink
and dex it, and `MainActivity` is asserted present in both outputs.

The assertion reads the dex string table directly instead of using
`apkanalyzer`: apkanalyzer needs `aapt`, and Google's build-tools only ship
x86-64 binaries, which cannot run on the arm64 runner.

## scripts/install-local.sh

Downloads the binaries of the latest green run (or `RUN_ID=…`) into
`~/.local/bin` as `d8-snapshot` / `r8-snapshot` and dexes a hello-world jar
to prove they work. Needs `gh`; a JDK is used only to package that input.

## Debugging a failure

| symptom | cause | fix |
|---|---|---|
| `no android.jar found; set ANDROID_SDK` | SDK platforms not installed, or an interrupted sdkmanager left a stub jar | `sdkmanager "platforms;android-36"`; the lookup ignores jars under 1 MB on purpose |
| `curl: (22) ... 503` from googlesource | transient | already retried 8× with backoff; re-run the job |
| `Error in rules/*.pro` | rule file syntax; note single-dash print options | fix `scripts/corpus.sh` |
| `Missing class org.jetbrains.annotations.*` | annotations jar not on the corpus classpath | it is in `COMPOSE_LIBS`; check it was downloaded |
| `patch does not apply, skipping (upstream drift?)` | upstream changed the patched hunk | rebase the patch against the new `main` — the warning is deliberately non-fatal so the rest of the build still tells you what else broke |
| `The current machine does not support all of the following CPU features` | image built for the host CPU | `-march=armv8-a` is already set; an image predating that commit needs a rebuild |
| binary dies with a `ClassNotFoundException` for a class that exists | an unpatched reflective lookup | add an overlay patch, not a reflection-config blob |

When R8's *shape* changes upstream (new reflective entry point, new resource),
the fix belongs in `scripts/r8-overlay/`: it is a one-line diff against a known
upstream tree and it survives every rebuild. Reachability must never be a list
of class names in this repo.