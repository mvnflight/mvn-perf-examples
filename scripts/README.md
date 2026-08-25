# `bench-maven-builders.sh`

Benchmark **`mvn -T`** (Maven's default multithreaded builder) against the
**[Takari smart builder](https://github.com/takari/takari-smart-builder)**
(`-b smart`) across a range of thread counts `0..N` for any Maven project, then
chart wall-clock time vs. threads.

For example, to benchmark a remote project across `0..8` threads:

```bash
./scripts/bench-maven-builders.sh https://github.com/acme/widgets.git 8 ./out/widgets.csv
```

This clones the repo, runs the build matrix, and writes the results to
`./out/widgets.csv` plus a self-contained `./out/widgets.html` chart next to it.

The script clones the repo (or uses a local one in place), makes the smart
builder available to it, runs a warm-up build, then runs the timed matrix —
`mvn -T t clean package` (default) and `mvn -T t -b smart clean package` (smart)
for every `t` in `0..N`. Each build's duration is scraped from Maven's own
`Total time:` log line, written to a tidy CSV, and rendered into a single
self-contained HTML page (inline SVG, no CDN — works offline via `file://`).

The smart builder only helps in the mid `-T` range of a multi-module reactor with
an uneven critical path. This repo's own [builder scaling grid](../.github/workflows/scaling-grid.yml)
measures exactly that on the example reactor, over a wider matrix (`-T1..-T10`,
plus a cold-repository leg and mvnd) and with mvnflight's own metrics rather than
scraped wall clock; this script is the portable version you can point at **any**
project.

## mvnflight extension overhead (on by default)

By default the script adds an **mvnflight on/off dimension**: every configuration
(each thread count × builder × C2 level) is built **twice** — once without and
once with the [mvnflight](https://central.sonatype.com/repository/maven-snapshots/io/github/mvnflight/mvnflight-extension/0.1.0-SNAPSHOT/) JFR profiler
extension — so you can read its **build overhead** directly off the chart and table.

- The extension is enabled per-build by adding `io.github.mvnflight:mvnflight-extension`
  to `.mvn/extensions.xml`, and **removed** for the "off" rows — so the off
  baseline is a clean build with the extension not even loaded (a true overhead
  measurement, not just `-Dmvnflight.disabled`).
- The extension must be **resolvable** for the "on" rows. It is published to the
  Maven Central snapshot repository, which the built-in `central` repository has
  disabled — and a `<repositories>` block cannot help, because core extensions are
  resolved by Maven's bootstrap *before* any POM is read. Pass this repo's
  committed settings file and the script hands it to every build as `-s`:

  ```bash
  --settings "$PWD/.mvn/settings.xml"
  ```

  Alternatively install the extension into your own `~/.m2` from an mvnflight
  checkout (`mvn -DskipTests install`), or add the `central-snapshots` repository
  from `.mvn/settings.xml` to your `~/.m2/settings.xml`. Override the coordinate
  version with `--mvnflight-version`.
- In the chart, the **solid** curves are the clean build and the **dashed** curves
  add mvnflight — the gap between them is the overhead. The results table gains an
  **Overhead** column (extra wall-clock vs. the same config without mvnflight) and
  a **Report** link to each build's saved mvnflight dashboard.
- Pass `--no-mvnflight` to skip it entirely. (In that legacy mode, `--c2-off`
  reclaims the dashed curves, as before.)

Because this doubles the build count, expect the matrix to take roughly twice as
long as `--no-mvnflight`.

## Prerequisites

- `git`
- A Maven launcher: the project's `./mvnw` if present (honours its intended Maven
  version), otherwise `mvn` on `PATH`.
- `java` (whatever the wrapper / `mvn` resolves).
- `awk` — stock on macOS and Linux (`gawk`, `mawk`, or BSD `awk` all work).
- Network access (clone + first-time dependency / Takari downloads).

> **Platform support — macOS *and* Linux.** The script is written to be
> **bash-3.2 safe** (macOS still ships `/bin/bash` 3.2) and avoids GNU-isms
> (`declare -A`, `mapfile`, `date +%N`, `grep -P`, `sed -i` without a backup
> suffix, gawk-only `asort`). Because that BSD-safe subset is a subset of the GNU
> tools, it runs unchanged on Linux too:
>
> - **CPU count** uses `sysctl -n hw.ncpu` (macOS) and falls back to `nproc` (Linux).
> - The **chart's non-ASCII glyphs** (`·`, `—`) are emitted by `awk` as HTML
>   entities (`&middot;` / `&mdash;`), not raw byte escapes, so the SVG renders
>   identically under any `awk` implementation.
>
> It runs under newer bash too; if `/bin/bash` is < 4 a one-line preflight warning
> notes the assoc-array idioms were avoided on purpose.

## Usage

```
scripts/bench-maven-builders.sh <source> <max-threads> <csv-path> [options]
```

**Positional (required):**

| Pos | Name | Meaning |
|-----|------|---------|
| 1 | `source` | An HTTP(S) git URL (also `git://`, `ssh://`, or scp-style `git@host:org/repo.git`) → **cloned** into a scratch workdir; **or** a path to an existing local Git repo → **used in place, not cloned** (non-destructive). |
| 2 | `max-threads` | Non-negative integer `N`; the matrix iterates `t = 0..N`. |
| 3 | `csv-path` | Where the results CSV is written (parent dir created if needed). |

**Options:**

| Option | Default | Meaning |
|--------|---------|---------|
| `--c2-off` | off | Also run each build with C2 JIT disabled (`-XX:TieredStopAtLevel=1`); adds the dashed curves (only in `--no-mvnflight` mode — see below). |
| `--no-mvnflight` | off (dimension on) | Skip the mvnflight on/off dimension. **By default** each config is built twice — without and with the mvnflight extension — to measure its build overhead. |
| `--mvnflight-version <v>` | `0.1.0-SNAPSHOT` | mvnflight-extension version to enable for the "on" rows. Must be resolvable — see `--settings`. |
| `--settings <path>` | none | Maven settings file passed as `-s` to **every** build (absolutised, so it survives the `cd` into the build root). This is how a cloned project reaches the Central snapshot repository that publishes the extension. |
| `--goals "<goals>"` | `clean package` | Maven goals/phases to time. |
| `--html <path>` | `<csv-path>` with `.html` | HTML output path. |
| `--runs <k>` | `1` | Repeat each config `k` times; the chart/table use the **median**. |
| `--workdir <dir>` | `$(mktemp -d)` | Clone mode only: where to clone; auto-cleaned unless `--keep`. |
| `--keep` | off | Keep the clone (clone mode) + per-run logs. A local repo is never deleted; its `.mvn/extensions.xml` is restored on exit regardless. |
| `--ref <branch/tag/sha>` | repo default | Clone mode: `git checkout` this ref after cloning. Local mode: **ignored**. |
| `--mvn <cmd>` | auto | Force a Maven command; otherwise prefer `./mvnw`, else `mvn`. |
| `--takari-version <v>` | `1.1.0` | Takari smart-builder version to inject. |
| `--baseline <default-T0\|default-T1>` | `default-T0` | Which build is 100% on the right axis. |
| `--from-csv` | off | Skip cloning/building; just regenerate the HTML from an existing CSV. |

### Examples

```bash
# Minimal: 2 curves, clean package, 0..8 threads, HTML next to the CSV
./scripts/bench-maven-builders.sh https://github.com/acme/widgets.git 8 ./out/widgets.csv

# All 4 curves (C2 on/off for both builders), keep the clone + logs
./scripts/bench-maven-builders.sh https://github.com/acme/widgets.git 10 ./out/widgets.csv \
    --c2-off --keep

# Median of 3 runs, integration tests too, explicit HTML path and a pinned ref
./scripts/bench-maven-builders.sh https://github.com/acme/widgets.git 6 ./out/widgets.csv \
    --runs 3 --goals "clean verify" --ref release/2.4 --html ./out/widgets.html

# Use a local repo in place (non-destructive), 0..4 threads
./scripts/bench-maven-builders.sh ./my-local-repo 4 ./out/local.csv

# Just re-render the chart from an existing CSV (no rebuilds)
./scripts/bench-maven-builders.sh - - ./out/widgets.csv --from-csv
```

## Output

### CSV (`<csv-path>`)

Long/tidy format — one row per build, easy to pivot and re-chart later:

```csv
threads,builder,c2,mvnflight,goals,status,wall_clock_s,total_time_raw,log_file,report_file,timestamp
0,default,on,off,clean package,SUCCESS,128.450,2:08 min,/tmp/.../logs/default-T0-c2on-mfoff.log,,2026-06-19T10:00:00Z
0,default,on,on,clean package,SUCCESS,138.900,2:18 min,/tmp/.../logs/default-T0-c2on-mfon.log,mvnflight-reports/default-T0-c2on-mfon.html,2026-06-19T10:02:10Z
...
```

| Column | Meaning |
|--------|---------|
| `threads` | The `-T` thread count. `0` = the "no `-T`" baseline build (plain `mvn`). |
| `builder` | `default` or `smart`. |
| `c2` | `on` for normal runs; `off` rows appear only with `--c2-off`. |
| `mvnflight` | `off` = clean build; `on` = built with the mvnflight extension. `on` rows are absent with `--no-mvnflight`. |
| `goals` | The Maven goals that were timed. |
| `status` | `SUCCESS`, or `FAILURE` (build failed, or no parseable `Total time:`). |
| `wall_clock_s` | Parsed seconds (float); blank on `FAILURE`. |
| `total_time_raw` | The raw `Total time:` string (e.g. `2:08 min`). |
| `log_file` | The saved full log for that build (kept with `--keep` in clone mode). |
| `report_file` | Relative path to the saved mvnflight dashboard (`mvnflight=on` rows only); blank otherwise. |
| `timestamp` | UTC start time of the build. |

With `--runs k`, there are `k` rows per `(threads, builder, c2)`; the HTML uses
their **median**.

### HTML (`<csv-path>.html` or `--html`)

A single self-contained page with:

- A **dual-axis chart** — wall clock (left) and **% of the baseline** (right) vs.
  threads. Two **solid** curves (**Default** = blue, **Smart** = orange) for the
  clean build, plus two **dashed** curves for the same builders **with mvnflight**
  — the gap is the extension overhead. `T0` is the no-`-T` baseline column.
  (With `--no-mvnflight`, the dashed curves instead show `--c2-off`, as before.)
- A headline **median overhead** figure in the intro (default builder, across
  thread counts).
- **Hover tooltips**: every data point shows e.g. `Default · mvnflight, T2: 99.1 s
  (78% of baseline)`.
- A **results table** (threads × builder × C2 × mvnflight × wall clock × % of
  baseline) with an **Overhead** column and a per-row **Report** link to each
  `mvnflight=on` build's dashboard (saved under `mvnflight-reports/` next to the
  HTML), plus the run metadata (source, ref, goals, module count, host CPU count,
  `mvn`/Java versions, date).

## Notes / caveats

- **Source may be remote or local (D11).** A URL is cloned into a scratch
  workdir (removed on exit unless `--keep`). A local path is used **in place** —
  no clone, no copy; its `.mvn/extensions.xml` is snapshotted and **restored on
  exit**, and the repo is never deleted. (Repeated `clean package` still deletes
  the repo's `target/` dirs, as any build does.)
- **`t = 0` means "no `-T` flag" (D4)** — plain `mvn clean package` (Maven's
  legacy single-threaded builder). `t ≥ 1` passes `-T t`. (`mvn -T 0` is rejected
  by Maven.)
- **The smart builder is enabled by injecting `.mvn/extensions.xml` (D6)**,
  registering `io.takari.maven:takari-smart-builder`. The extension is inert
  unless `-b smart` is passed, so default-builder runs are unaffected. For
  **Maven 4** projects `-b smart` selection differs and Takari may not load — the
  script prints a hint and `--takari-version` lets you override.
- **The `mvnflight=on` rows need the extension to be resolvable.** They register
  `io.github.mvnflight:mvnflight-extension:<version>` in the benchmarked project's
  `.mvn/extensions.xml`; pass `--settings "$PWD/.mvn/settings.xml"` so the clone can
  see the Central snapshot repository, or install the extension into `~/.m2`
  yourself (or use `--no-mvnflight`). If it can't be resolved, those builds fail and
  are recorded as `FAILURE` like any other failed build (the matrix continues). The
  saved dashboards live in `mvnflight-reports/` **next to the HTML**, so keep them
  together for the in-page links to resolve.
- **Warm the extension before you measure it.** The script's own warm-up build runs
  with mvnflight **off** on purpose, so the very first `mvnflight=on` build would
  otherwise download the extension mid-measurement and be charged for it. Build
  something with the extension once first (`mvn -DskipTests clean package` at this
  repo's root does it), or read the first `on` row with suspicion.
- **C2-off is best-effort on forked test JVMs (§11).**
  `-XX:TieredStopAtLevel=1` is passed via `MAVEN_OPTS`, which reliably affects the
  **build** JVM; forked **test** JVMs inherit it only if the project passes
  `MAVEN_OPTS`/argLine through (many don't).
- **The comparison is only meaningful for multi-module reactors.** A
  single-module project can't be parallelised by `-T` or the smart builder, so
  the curves are flat and overlapping (the page notes this when it detects a
  single-module root).
- **Resilient by design.** A failed build is recorded as `FAILURE` and the matrix
  continues; the chart simply omits that point. The CSV is appended row-by-row,
  so partial results survive an interrupt.

## Continuous integration

`.github/workflows/bench-script.yml` (**mvnflight overhead benchmark**) runs the
script end to end on Linux + JDK 21: it lint-checks the script (`bash -n` +
ShellCheck), warms the mvnflight + Takari extension closure into `~/.m2` by building
this repo's own reactor once with `-U -DskipTests`, then benchmarks a small,
Apache-2.0 licensed project
([`google/gson`](https://github.com/google/gson)) across `0..2` threads — each build
without and with mvnflight, with `--settings .mvn/settings.xml` so the clone can
resolve the extension — and uploads the generated CSV + HTML report (plus the
saved `mvnflight-reports/` dashboards) as the `bench-report` artifact (download it from
the run's **Summary ▸ Artifacts**). The workflow triggers only when `scripts/**` or the
workflow file changes, and can be launched manually from the Actions tab
(`workflow_dispatch`).
