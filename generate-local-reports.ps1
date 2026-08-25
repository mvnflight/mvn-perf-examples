<#
.SYNOPSIS
  Generate the mvnflight reports locally, mirroring the `report` matrix of
  .github/workflows/scaling-grid.yml — without GitHub Actions.

.DESCRIPTION
  For each scenario it runs a profiled `clean verify` of this reactor and copies
  the rendered target/mvnflight/report.html into the output dir under the same
  name the CI uses (report-<builder>-T<n>[-noCache][-noC2].html), so the files are
  byte-for-byte the same kind the CI publishes to GitHub Pages under scaling/.

  The point of running them here is the hardware: a workstation with real cores
  and stable clocks, instead of a shared, throttled CI runner. That is what the
  reference/ section of the Pages site publishes.

  Default grid (mvnd legs intentionally excluded):
    1 no-cache leg (default builder, -T1, empty local repo)
    + builders default + smart  x  -T1..-T10  x  C2 on/off  = 41 builds.

  The no-cache leg runs FIRST: it points Maven at a scratch local repository
  seeded with ONLY the mvnflight-* artifacts (never this reactor's own
  io.github.mvnflight.examples jars), so every plugin and project
  dependency is downloaded during the profiled build and shows up in the
  report's "Maven downloads" metric. All other legs use the normal warm ~/.m2
  local cache.

  C2-off legs disable the C2 JIT tier (keep only C1) on BOTH JVMs, exactly like
  the workflow: the build JVM via MAVEN_OPTS, the forked test JVMs via
  -Dtest.argLine (which the root pom prepends ahead of mvnflight's -javaagent).

  The mvnflight extension itself is resolved from Maven Central snapshots via
  the committed .mvn/settings.xml (which .mvn/maven.config wires into runs from
  the repo root; every build below passes it explicitly with an absolute -s, so
  the script works from any directory), so there is nothing to install first.

  This is a long run: the modules sleep for their full fixed durations (core and
  app 2 s, pipe links 8 s, libs 18 s), one build at a time. The parallel-tests
  module (five 15 s classes, -Pparallel) is not part of this grid. Trim it with
  -Threads / -Builders / -C2 while iterating.

.PARAMETER Builders   Which builders to run. Default: default, smart.
.PARAMETER Threads    Thread widths (-T). Default: 1..10.
.PARAMETER C2         JIT C2 states. Default: on, off.
.PARAMETER OutDir     Where report-*.html land. Default: published\reference
                      (the folder the "Publish reference reports" workflow copies
                      to GitHub Pages under reference/, regenerating the index
                      itself). It starts empty — no report HTML is committed to
                      this repo.
.PARAMETER Index      Generate index.html via gen-grid-index.sh, to preview the grid
                      locally. Needs node + bash on PATH; skipped with a warning
                      otherwise. Not a prerequisite for publishing: the "Publish
                      reference reports" workflow copies only report-*.html and
                      regenerates index.html with this same generator.
.PARAMETER SkipNoCache  Skip the no-cache first leg (useful while iterating on a
                      subset with -Threads / -Builders / -C2).

.EXAMPLE
  # Full faithful grid (41 builds) plus a local index page to preview it:
  ./generate-local-reports.ps1 -Index

.EXAMPLE
  # Quick subset while iterating (no-cache leg skipped too):
  ./generate-local-reports.ps1 -Threads 1,4,8 -C2 on -SkipNoCache
#>
[CmdletBinding()]
param(
  [string[]] $Builders = @('default','smart'),
  [int[]]    $Threads  = (1..10),
  [ValidateSet('on','off')]
  [string[]] $C2       = @('on','off'),
  [string]   $OutDir,
  [switch]   $Index,
  [switch]   $SkipNoCache
)

$ErrorActionPreference = 'Stop'
$repoRoot  = $PSScriptRoot                            # the script sits at the repo root
$demoPom   = Join-Path $repoRoot 'pom.xml'
$reportSrc = Join-Path $repoRoot 'target\mvnflight\report.html'
$settings  = Join-Path $repoRoot '.mvn\settings.xml'
if (-not $OutDir) { $OutDir = Join-Path $repoRoot 'published\reference' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Build the leg list (mvnd excluded by design). The no-cache leg comes FIRST:
# a single-threaded default build against an empty scratch local repo (seeded
# with only the mvnflight artifacts below), so the report shows the full
# dependency-download cost; every other leg uses the warm ~/.m2 cache.
$legs = @()
if (-not $SkipNoCache) {
  $legs += [pscustomobject]@{ Builder = 'default'; Threads = 1; C2 = 'on'; Cache = 'cold' }
}
$legs += foreach ($b in $Builders) {
  foreach ($t in $Threads) {
    foreach ($c in $C2) {
      [pscustomobject]@{ Builder = $b; Threads = $t; C2 = $c; Cache = 'warm' }
    }
  }
}

$total  = @($legs).Count
$idx    = 0
$failed = New-Object System.Collections.Generic.List[string]
$start  = Get-Date

foreach ($leg in $legs) {
  $idx++
  $suffix = ''
  if ($leg.Cache -eq 'cold') { $suffix += '-noCache' }
  if ($leg.C2 -eq 'off')     { $suffix += '-noC2' }
  $out = "report-$($leg.Builder)-T$($leg.Threads)$suffix.html"

  Write-Host ""
  Write-Host "==> [$idx/$total] $($leg.Builder) -T$($leg.Threads) C2=$($leg.C2) cache=$($leg.Cache) -> $out" -ForegroundColor Cyan

  # Assemble args mirroring the workflow's "Run profiled build" step. -s is passed
  # explicitly, and absolute, rather than relying on .mvn/maven.config: that file is
  # only read when Maven finds a .mvn directory walking up from the directory mvn
  # was launched in (-f alone does not move that search), and the relative path it
  # carries — --settings=.mvn/settings.xml — resolves against that same launch
  # directory, so an invocation from anywhere but the repo root would silently lose
  # the snapshot repository. The explicit -s also wins when both are present: Maven
  # puts the command-line options ahead of maven.config's and reads the first value.
  $mvnArgs = @('-B','-ntp',"-T$($leg.Threads)")
  if ($leg.Builder -eq 'smart') { $mvnArgs += @('-b','smart') }
  $mvnArgs += @('-f', $demoPom, '-s', $settings)

  if ($leg.Cache -eq 'cold') {
    # Scratch local repo seeded with ONLY the mvnflight artifacts, copied out of
    # the warm ~/.m2. mvnflight resolves fine from Central snapshots, so this is
    # no longer strictly required to make the build start — it is kept so this
    # leg measures the same thing it always has: the download cost of the
    # PROJECT's own dependencies and plugins, with the profiler already present.
    # Seeding it keeps these reports comparable with the published ones.
    # Only the mvnflight-* artifacts are seeded, never the whole io\github\mvnflight
    # directory: it also holds `examples`, THIS reactor's own groupId
    # (io.github.mvnflight.examples), which is there as soon as anyone has run
    # `mvn install` here once. Seeding that would pre-populate the reactor's own
    # jars, the leg would under-report the download cost, and it would stop being
    # comparable with the CI no-cache leg it mirrors (scaling-grid.yml copies
    # mvnflight-* for the same reason).
    $mvnflightArtifacts = Join-Path $HOME '.m2\repository\io\github\mvnflight'
    $coldRepo = Join-Path $env:TEMP 'mvnflight-cold-repo'
    if (Test-Path $coldRepo) { Remove-Item $coldRepo -Recurse -Force }
    $coldMvnflight = Join-Path $coldRepo 'io\github\mvnflight'
    New-Item -ItemType Directory -Force -Path $coldMvnflight | Out-Null
    $seeded = @(Get-ChildItem -Path $mvnflightArtifacts -Directory -Filter 'mvnflight-*' -ErrorAction SilentlyContinue)
    if ($seeded.Count) {
      Copy-Item -Path $seeded.FullName -Destination $coldMvnflight -Recurse
    } else {
      # First ever run on this machine: nothing to seed. The extension is then
      # downloaded during the timed build too, so this one report over-reports
      # the download cost slightly. Run any warm leg once and re-run to fix it.
      Write-Warning "    no mvnflight-* artifacts in $mvnflightArtifacts - the cold leg will download the extension too."
    }
    $mvnArgs += "-Dmaven.repo.local=$coldRepo"
  }

  $savedOpts = $env:MAVEN_OPTS
  if ($leg.C2 -eq 'off') {
    $env:MAVEN_OPTS = (("$savedOpts", '-XX:TieredStopAtLevel=1') -join ' ').Trim()
    # One quoted token so PowerShell doesn't split on the dot in test.argLine.
    $mvnArgs += '-Dtest.argLine=-XX:TieredStopAtLevel=1'
  }
  $mvnArgs += @('clean','verify')

  try {
    & mvn @mvnArgs
    $code = $LASTEXITCODE
  } finally {
    $env:MAVEN_OPTS = $savedOpts          # restore (clears it if it was unset)
  }

  if ($code -eq 0 -and (Test-Path $reportSrc)) {
    Copy-Item $reportSrc (Join-Path $OutDir $out) -Force
    Write-Host "    collected -> $out" -ForegroundColor Green
  } else {
    Write-Warning "    no report for $($leg.Builder)/T$($leg.Threads)/C2=$($leg.C2) (exit $code)"
    $failed.Add($out)
  }
}

# Optional: the index.html grid + SVG chart (gen-grid-index.sh, needs node + bash).
# node, not jq: the generator parses each report's embedded model JSON, which nests
# far deeper than jq 1.7's hard 256-level parser cap — see the comment at the top of
# gen-grid-index.sh.
if ($Index) {
  $node = Get-Command node -ErrorAction SilentlyContinue
  $bash = Get-Command bash -ErrorAction SilentlyContinue
  if ($node -and $bash) {
    Write-Host ""
    Write-Host "==> Generating index.html" -ForegroundColor Cyan
    $gen = (Join-Path $repoRoot '.github\scripts\gen-grid-index.sh') -replace '\\','/'
    # Same knobs publish-reference-reports.yml passes, so the local preview matches
    # what CI will publish at /reference/. Without SHOW_MVND=0 the grid would carry
    # two permanently empty "Maven Daemon (mvnd)" rows: this script excludes the mvnd
    # legs by design, so nothing ever fills them.
    $env:PAGE_TITLE   = 'Maven build-performance examples · reference reports'
    $env:PAGE_HEADING = 'Reference reports — measured on real hardware'
    $env:SHOW_MVND    = '0'
    Push-Location $OutDir
    try { & bash $gen } finally {
      Pop-Location
      Remove-Item Env:PAGE_TITLE, Env:PAGE_HEADING, Env:SHOW_MVND -ErrorAction SilentlyContinue
    }
  } else {
    Write-Warning "Skipping index.html: needs node AND bash on PATH (node:$([bool]$node) bash:$([bool]$bash)). Install node, then re-run with -Index."
  }
}

$elapsed = (Get-Date) - $start
Write-Host ""
Write-Host ("==> Done in {0:hh\:mm\:ss}. {1}/{2} reports in {3}" -f $elapsed, ($total - $failed.Count), $total, $OutDir) -ForegroundColor Cyan
Write-Host '    Commit them under published/reference/ and dispatch the "Publish reference reports" workflow to deploy.' -ForegroundColor DarkGray
if ($failed.Count) { Write-Warning ("Failed legs: " + ($failed -join ', ')) }
