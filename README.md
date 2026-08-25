# Maven build-performance examples

A single, self-contained Maven project that shows, with real
[mvnflight](#what-is-mvnflight) reports, how a build scales with the **parallel
builder** (`-T`) and the **Takari smart builder** (`-b smart`).

The same project is run **locally** (Maven Wrapper + Maven Daemon wrapper) and
**in CI** (one report per scenario, published to GitHub Pages).

## What it demonstrates

- **`-T` scaling, and its limits.** Wall-clock time drops as `-T` rises from 1 to
  the module count — but sub-linearly, and it plateaus once `-T` exceeds the
  reactor's parallel width.
- **The smart builder.** At the same `-T`, `-b smart` schedules the module that
  sits in front of the longest dependency **chain** first, instead of the default
  reactor (declaration) order. It starts the long pole earlier and shortens the
  makespan. It weights each module as `serviceTime(m) + max(weight(downstream))`
  and schedules highest-weight-first, so the module fronting the longest chain
  outranks every cheap leaf no matter how fat that leaf is.
- **Intra-module test parallelism (`forkCount`).** `-T` parallelises across
  *modules*; it does nothing for a single module whose test suite is slow. A
  dedicated **`parallel-tests`** module — built **only** under the `-Pparallel`
  profile, so it is absent from the baseline reactor — carries five independent 15 s
  tests (`Parallel1..5Test`), one per class, so Surefire's `forkCount` can fan them
  out across **parallel fork JVMs**. Pass `-Pparallel -Ddemo.forkCount=5` and each
  class runs in its own fork, so they all execute in a single parallel wave and the
  module's whole test phase collapses to its longest single test (~15 s) instead of
  ~75 s serial — mvnflight then renders one **fork lane per JVM**. This is a
  different axis from `-T` (it scales *within* a module, not across the reactor), and
  the two compose. It has its **own GitHub Pages page** (`parallel/`); the
  baseline page (`scaling/`) never builds the `parallel-tests` module.

## The reactor (10 modules — a chain + fillers)

```
   core ─┬─ lib-01  lib-02  lib-03  lib-04         4 short "filler" leaves (18 s each)
         │
         └─ pipe-1 → pipe-2 → pipe-3 → pipe-4      a 4-deep chain (8 s each = 32 s)
                                       └─────────► app   (depends on pipe-4 + every lib)
```

- **`pipe-1 → … → pipe-4` is the critical path** — 32 s of strictly serial work.
  The smart builder weights `pipe-1` highest (longest downstream chain) and starts
  it immediately; the default builder, following reactor order, grabs the cheap
  fillers first and only reaches `pipe-1` once a thread frees.
- **The fillers are declared *before* the pipe chain** in the parent POM on
  purpose — that declaration order is what the default builder follows, so it makes
  the "wrong" early choice and the chain starts late.
- The smart builder ranks by **chain length, not build time**, so the fat `lib-04`
  leaf is *not* what it optimizes — the win comes entirely from the chain's depth.

The tests do nothing but `Thread.sleep` for **fixed per-module durations** (core
and app 2 s, libs 18 s, pipe links 8 s), set as `demo.sleep.minMs == maxMs` in each
module's POM, so the numbers are deterministic and the default-vs-smart reports are
directly comparable. The sleep logic lives in `DemoSleep`
(`core/src/main/java/demo/DemoSleep.java`).

An **extra independent leaf, `parallel-tests`** (five 15 s test classes), exists
only to demonstrate intra-module test parallelism and is added to the reactor
**only** under `-Pparallel` — the 10-module baseline above never builds it.

## What is mvnflight?

mvnflight is a JFR-based Maven build profiler: it loads as a Maven **core
extension**, instruments the Maven JVM and the forked test JVMs with Flight
Recorder, and renders a single self-contained dashboard at
`target/mvnflight/report.html`. Every report this repo publishes is one of those
dashboards. It ships to Maven Central snapshots as
[`io.github.mvnflight:mvnflight-extension:0.1.0-SNAPSHOT`](https://central.sonatype.com/repository/maven-snapshots/io/github/mvnflight/mvnflight-extension/0.1.0-SNAPSHOT/).

### How the extension is resolved (nothing to install)

`.mvn/extensions.xml` declares the profiler at the floating version
`0.1.0-SNAPSHOT`. Maven resolves that file during **bootstrap, before the project
POM is read**, so a `<repositories>` block in `pom.xml` would come too late — and
Maven's built-in `central` repository has snapshots disabled. The repository has to
come from a settings file, so this repo commits two small ones:

- **`.mvn/settings.xml`** — adds a `central-snapshots` repository *and*
  pluginRepository (`https://central.sonatype.com/repository/maven-snapshots/`,
  snapshots enabled, releases disabled). That is its only job. The profile is
  switched on **twice** on purpose — `activeByDefault` *and* an entry in
  `<activeProfiles>` — because `activeByDefault` switches off as soon as any
  profile is named on the command line, and this README tells you to pass
  `-Pparallel`, which would otherwise drop the snapshot repository on exactly the
  runs that need it.
- **`.mvn/maven.config`** — a comment block plus the single argument line
  `--settings=.mvn/settings.xml`, so a plain `./mvnw clean verify` from the repo
  root picks the settings file up with no extra flags. The **attached**
  `--settings=<path>` form is required: Maven 3.9 treats each *line* of
  `maven.config` as one argument and does **not** split it on whitespace, so
  `-s .mvn/settings.xml` on one line is read as the option `-s` with the value
  `" .mvn/settings.xml"` — leading space included — and the build dies with *"The
  specified user settings file does not exist"*. The path is relative to the
  directory Maven was launched from, so anything invoking Maven from elsewhere
  has to pass an absolute `-s` itself (the workflows and
  `generate-local-reports.ps1` do).

**If you are behind a corporate mirror or proxy:** `--settings` (like `-s`)
*replaces* your `~/.m2/settings.xml` rather than merging with it, so the committed
file would drop your mirror and credentials. In that case delete
`.mvn/maven.config` and add the `central-snapshots` repository to your own
`~/.m2/settings.xml` instead.

## Run it locally

Every run writes the dashboard to `target/mvnflight/report.html`. Run the commands
from the repo root.

| Goal | Command |
|---|---|
| Baseline (1 thread) | `./mvnw -T1 clean verify` |
| Parallel, N threads | `./mvnw -T<n> clean verify`  (n = 1 … 10) |
| Smart builder | `./mvnw -T<n> -b smart clean verify` |
| Maven Daemon (mvnd) | `./mvndw -s .mvn/settings.xml clean verify` |
| Tests in parallel forks | add `-Pparallel -Ddemo.forkCount=5` to any command (builds the extra `parallel-tests` module and runs its five test classes each in their own fork JVM) |
| Faster demo loop | add `-Ddemo.weight=0.2` to any command (shrinks every sleep to 20 %) |

Windows: use `mvnw.cmd` / `mvndw.cmd`. The first `mvndw` run downloads a pinned
Maven Daemon (1.0.6) into `.mvnd/`. The mvnd row passes `-s` explicitly because the
daemon's handling of `.mvn/maven.config` is its own; `./mvnw` needs no such flag,
`.mvn/maven.config` covers it.

> The smart builder's win shows up where threads are scarce. Run
> `./mvnw -T4 clean verify` then `./mvnw -T4 -b smart clean verify` and compare the
> **Total time**: the default builder grabs the four cheap libs first and the
> `pipe-1 → … → pipe-4` chain starts late; the smart builder starts the chain
> immediately. (At `-T1` they tie, and from `-T5` up they converge.)

## Tuning knobs (all `-D`)

| Property | Default | Effect |
|---|---|---|
| `demo.weight` | `1.0` | **global time scale** — multiplies every module's fixed sleep (e.g. `0.2` = 20 % for a fast loop) |
| `demo.sleep.minMs` / `maxMs` | per module | each module's POM sets these **equal** for a fixed duration (core/app 2 s, libs 18 s, pipe links 8 s) |
| `demo.sleep.seed` | `42` | only used when `minMs < maxMs` (random mode) |
| `demo.sleep.random` | `false` | only used when `minMs < maxMs`; `true` = genuinely random |
| `demo.forkCount` | `1` | Surefire fork JVMs per module. With `-Pparallel`, `5` runs each of the `parallel-tests` module's five test classes in its own fork (one mvnflight fork lane each, one parallel wave); a no-op for the single-test-class modules |

Durations are **fixed per module** (not random), so the `-T1…-T10` and
default-vs-smart reports are directly comparable. Scale them all at once with
`-Ddemo.weight`.

## What to look at in the report

- **Environment** — confirms the builder (`multithreaded` vs `smart`), thread
  count, and CPU cores (the local-vs-CI core-count contrast).
- **Overview** — the per-module build timeline, where the `-T` legs show the
  filler libs overlapping while the `core → pipe-1 → pipe-2 → pipe-3 → pipe-4 →
  app` chain stays strictly serial, and the machine CPU curve beneath it.
- **Flame graphs → Build activity** — per-worker time, with each test method's sleep visible.

## In CI / on GitHub Pages

Three manual (`workflow_dispatch`) workflows publish three sections of the single
Pages site at **https://mvnflight.github.io/mvn-perf-examples/**. None of them
builds the profiler: it resolves from Central snapshots like any other dependency.

**`scaling/` — builder × `-T` grid** (`.github/workflows/scaling-grid.yml`,
*Builder scaling grid*):

1. runs a **no-cache first scenario** — default builder, `-T1`, against a scratch
   local repository pre-seeded with only the mvnflight artifacts, so the report
   shows the full dependency-download cost of the project's own dependencies. All
   other scenarios reuse the warm local dependency cache,
2. runs the demo at **`-T1 … -T10`** with the **default** and **smart** builders,
   each with the JVM's C2 JIT on and off, plus an **mvnd** reference leg (legs run
   one at a time so timings compare),
3. publishes every `report.html` under **`scaling/`** with an index grid (default vs
   smart at each thread count). The `parallel-tests` module is **not** built here.

**`parallel/` — tests in parallel forks** (`.github/workflows/fork-grid.yml`,
*Test-fork parallelism grid*):

1. runs the **same default & smart × `-T1 … -T10` × C2 on/off grid** with
   **`-Pparallel`** at **three Surefire fork counts** (`-Ddemo.forkCount=5`, `1` and
   `0`), so the page contrasts parallel forks against no forking — no mvnd leg, no
   no-cache leg:
   - **`forkCount=5`** — the `parallel-tests` module's five test classes each run in
     their own fork JVM (one parallel wave, ~15 s instead of ~75 s serial),
   - **`forkCount=1`** — the five classes run serially in a single fork (~75 s),
   - **`forkCount=0`** ("no fork") — Surefire runs them **inside the Maven build JVM**;
     there is no fork lane and the test time folds into the parent recording,
2. publishes under **`parallel/`** with its own index grid whose wall-clock,
   C2 and CPU charts each carry **12 curves** (Default & Smart × C2 on/off × forkCount
   5 / 1 / 0).

**`reference/` — the same grid, measured on real hardware**
(`.github/workflows/publish-reference-reports.yml`, *Publish reference reports*):
CI runners are shared and throttled, so the `scaling/` numbers are noisy in
absolute terms. This section carries the same builder × `-T` × C2 grid measured on
a workstation with real cores and stable clocks, generated locally with
[`generate-local-reports.ps1`](./generate-local-reports.ps1) into
`published/reference/`. The workflow runs **no build at all**: it copies the
committed `report-*.html` files and regenerates `index.html` with
`.github/scripts/gen-grid-index.sh`, the same generator the other two sections use. **That
directory starts empty — it holds a `.gitkeep` and nothing else; no report HTML is
committed to this repo** (each dashboard is ~1.8 MB). Generate a grid yourself,
commit it, then dispatch the workflow:

```powershell
./generate-local-reports.ps1                 # writes published/reference/report-*.html
```

Because CI regenerates the index, a locally generated `index.html` is never
published; `-Index` is for previewing the grid in a browser before you commit, not
a prerequisite for dispatching the workflow:

```powershell
./generate-local-reports.ps1 -Index          # ... plus a local index.html to preview
```

The workflow fails with an explicit message if `published/reference/` holds no
`report-*.html` — the committed `.gitkeep` on its own does not count.

All three workflows deploy to the same Pages site **without clobbering each
other**: each one seeds `site/` from the currently-live site
(`.github/scripts/seed-from-live-site.sh`), then resets and rebuilds only the
subpath it owns, then regenerates the root hub. Seeding is best effort, so the very
first deploy — when there is no live site yet — publishes just its own section. The
mvnd leg of the scaling grid installs the daemon through the local
[`setup-mvnd`](.github/actions/setup-mvnd) composite action.

### A fourth workflow, which publishes nothing

**`mvnflight overhead benchmark`** (`.github/workflows/bench-script.yml`) is the
odd one out: it does not touch the Pages site. It points
[`scripts/bench-maven-builders.sh`](./scripts/README.md) at a **third-party**
reactor ([`google/gson`](https://github.com/google/gson)) and builds every
configuration **twice** — once with the mvnflight extension absent from that
project's `.mvn/extensions.xml` and once with it added — so the gap between the two
curves is the profiler's own **build overhead**. Everywhere else in this repo
mvnflight is the instrument; here it is the thing being measured.

The result is the **`bench-report`** artifact on the run (CSV + a self-contained
HTML chart + one saved dashboard per instrumented build), downloadable from the
run's *Summary ▸ Artifacts*. It triggers on pushes and PRs that touch `scripts/**`
or the workflow itself, and on `workflow_dispatch`. The same script benchmarks any
Maven project you point it at, locally or in CI — see
[`scripts/README.md`](./scripts/README.md).

## License

Apache License 2.0 — see [`LICENSE`](./LICENSE).
