#!/usr/bin/env bash
# Generates a benchmark grid page (index.html) in the CURRENT directory, which
# must contain that grid's report-*.html files (i.e. run from site/scaling,
# site/parallel or site/reference).
#
# Shared by every workflow that publishes a grid — scaling-grid.yml,
# fork-grid.yml and publish-reference-reports.yml — so each section is laid out
# identically no matter which deployment produced it; that is what keeps the
# single GitHub Pages site from clobbering a section it does not own.
#
# The report file-name convention is the generator's only input contract, and is
# unchanged from the grids this script has always produced:
#   report-<builder>-T<n>[-f<fork>][-noC2].html   builder = default | smart
#   report-default-T1-noCache.html                the cold local-repository leg
#   report-mvnd[-noC2].html                       the Maven Daemon leg
# The -f<fork> suffix appears only on the fork-comparison page (FORK_LEVELS set).
#
# Each report-*.html is a self-contained mvn-lens dashboard that embeds its
# model as JSON in <script id="mvnlens-data" type="application/json">. We pull
# that JSON out (perl) and read the headline metrics (node) so the index can show,
# per report: wall-clock, CPU, cumulative JIT C2 compilation, cumulative Maven
# dependency download time, and cumulative GC time.
#
# node, not jq: fork recordings use JFR stackdepth=128 and the embedded
# cpuFlameGraph tree nests ~2 levels per stack frame, which blows past jq 1.7's
# hard 256-level parser cap ("Exceeds depth limit for parsing" — no flag raises
# it, and it silently turned almost every row into "no data"). node's JSON.parse
# has no comparable limit, and node is preinstalled on the ubuntu runners.
#
# Environment knobs, all optional and all defaulted — the defaults reproduce the
# builder × -T scaling grid:
#   FORK_LEVELS       unset. When set (e.g. "5 1 0") the page becomes the
#                     fork-comparison grid: report files carry a -f<fork> suffix,
#                     the charts gain one curve per builder × fork × C2 and the
#                     table gains one row block per fork level.
#   PAGE_TITLE        "Maven build-performance examples" — the <title>, i.e. the
#                     browser tab and bookmark name. Every page sets it explicitly
#                     as "<that name> · <section>" (see gen-root-index.sh); the bare
#                     default only keeps an unconfigured page from misnaming itself.
#   PAGE_HEADING      the <h1> text.
#   PAGE_INTRO        the <p class="meta"> description (after the Run/commit line).
#   BACK_HREF         "../index.html" — the "← all reports" back link. Every grid
#                     sits one level below the site root, so the default is right
#                     for /scaling/, /parallel/ and /reference/ alike.
#   SHOW_NOCACHE_ROW  1 emits the no-cache first table row; 0 omits it.
#   SHOW_MVND         1 emits the two mvnd table rows; 0 omits them.
# Reads GITHUB_RUN_NUMBER / GITHUB_SHA / GITHUB_REF_NAME from the environment
# (blank is fine when run outside Actions).
set -euo pipefail

# Refuse to render a grid from a directory holding no reports.
#
# Every caller runs this from the directory that holds its section's
# report-*.html. With none of them present the generator still succeeds and emits
# a complete, plausible-looking page — every table row an em-dash, every chart
# empty — which then DEPLOYS over the live site and reads as "the grid published,
# the build must be broken". That is exactly what shipped: both grid workflows
# were dispatched with index_only=true before a single report had ever been
# published, so the live site had nothing to seed from, and two green runs
# published a 43-row table of "—".
#
# Failing here instead stops the deploy job before the Pages upload, so the last
# good site keeps serving. publish-reference-reports.yml already makes this exact
# check against its source directory; doing it in the generator covers the other
# two callers — and both workflows' index_only paths, where there is no matrix
# failure to notice — from one place.
if ! ls report-*.html >/dev/null 2>&1; then
  echo "::error::gen-grid-index.sh: no report-*.html in $(pwd) — refusing to generate a grid page with no reports." >&2
  echo "If this is an index_only run, the live site had no reports to seed from: re-dispatch" >&2
  echo "with index_only UNCHECKED so the report matrix actually builds them." >&2
  exit 1
fi

# Extract the embedded mvn-lens model JSON from a report HTML file.
# The data script tag is a single line; the renderer neutralises any inner
# "</script" to "<\/script", so the first literal "</script>" is the real close.
extract_json() {
  perl -0777 -ne 'print $1 if /<script id="mvnlens-data" type="application\/json">(.*?)<\/script>/s' "$1"
}

# Format a millisecond count the same way the dashboard's fmtMs() does, so the
# index numbers match what you see after clicking through to a report.
fmt_ms() {
  awk -v ms="$1" 'BEGIN {
    if (ms == "" || ms == "null") { print "—"; exit }
    ms = ms + 0
    if (ms < 1000)  { printf "%d ms\n", ms + 0.5; exit }
    s = ms / 1000
    if (s < 60)     { printf "%.1f s\n", s; exit }
    m = int(s / 60); rs = s - m * 60
    printf "%dm %.0fs\n", m, rs
  }'
}

# Format a wall-clock value as a percentage of the baseline (Default · -T1).
# Blank when either side is missing or the baseline is zero, so the baseline
# row and any no-data rows simply omit the percentage.
fmt_pct() {
  awk -v ms="$1" -v base="$2" 'BEGIN {
    if (ms == "" || ms == "null" || base == "" || base == "null" || base + 0 == 0) { exit }
    printf "%.0f%%\n", (ms + 0) / (base + 0) * 100
  }'
}

# Format the wall-clock delta from the baseline (Default · -T1) in signed seconds,
# e.g. "+30.0 s" (slower than baseline) / "-28.0 s" (faster). The baseline row
# itself yields "0 s". Blank when either side is missing or the baseline is zero,
# so the no-data / missing rows simply omit the delta.
fmt_diff() {
  awk -v ms="$1" -v base="$2" 'BEGIN {
    if (ms == "" || ms == "null" || base == "" || base == "null" || base + 0 == 0) { exit }
    s = ((ms + 0) - (base + 0)) / 1000
    if (s > -0.05 && s < 0.05) { print "0 s"; exit }
    printf "%+.1f s\n", s
  }'
}

# Read the row metrics from the report model JSON on stdin and print them as one
# TSV line: wall, cpu, c2-jit, downloads, gc (all ms; "null" when absent, which
# fmt_ms/fmt_pct render as "—" / no percentage).
read_metrics() {
  node -e '
    const j = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const s = j.session || {}, n = v => v == null ? "null" : v;
    const c2 = (Array.isArray(j.jit) ? j.jit : [])
      .filter(e => e && e.level >= 4)
      .reduce((a, e) => a + (e.durationMs || 0), 0);
    console.log([n(s.wallMs), n(s.cpuMs), c2,
      n((j.repoTransferSummary || {}).millisDownloadedThisBuild), n(s.gcMs)].join("\t"));
  '
}

# Extract just the wall-clock ms of a report, for baseline computation.
# Blank (and silent) when the file is missing or the JSON can't be read.
extract_wall_ms() {
  [ -f "$1" ] || return 0
  extract_json "$1" | node -e '
    const v = (JSON.parse(require("fs").readFileSync(0, "utf8")).session || {}).wallMs;
    if (v != null) console.log(v);
  ' 2>/dev/null || true
}

# Extract just the cumulative JIT C2 compilation ms of a report — the sum of the
# tier >= 4 jit entries, matching read_metrics' c2 column — for the C2 chart.
# Prints a number (0 when there were no C2 compilations, as happens with C2 off);
# blank (and silent) when the file is missing or the JSON can't be read.
extract_c2_ms() {
  [ -f "$1" ] || return 0
  extract_json "$1" | node -e '
    const j = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const c2 = (Array.isArray(j.jit) ? j.jit : [])
      .filter(e => e && e.level >= 4)
      .reduce((a, e) => a + (e.durationMs || 0), 0);
    console.log(c2);
  ' 2>/dev/null || true
}

# Emit one <tr> for a report file + human label. Missing file → a muted row;
# unreadable JSON → link only. The optional third arg is the baseline wall-clock
# ms (Default · -T1); when set, the wall-clock cell shows the percentage of that
# baseline and a dedicated "Δ vs baseline" cell shows the signed seconds delta, so
# the table reads as relative speed-ups (percentage) plus absolute seconds saved.
emit_row() {
  local f="$1" label="$2" baseline="${3:-}"
  if [ ! -f "$f" ]; then
    printf '      <tr><td class="miss">%s</td><td class="miss" colspan="6">—</td></tr>\n' "$label"
    return
  fi
  local vals
  vals=$(extract_json "$f" | read_metrics 2>/dev/null) || vals=""
  if [ -z "$vals" ]; then
    printf '      <tr><td><a href="%s">%s</a></td><td class="miss" colspan="6">no data</td></tr>\n' "$f" "$label"
    return
  fi
  local wall cpu c2 dl gc
  IFS=$'\t' read -r wall cpu c2 dl gc <<<"$vals"
  local wall_disp pct diff
  wall_disp="$(fmt_ms "$wall")"
  pct=$(fmt_pct "$wall" "$baseline")
  [ -n "$pct" ] && wall_disp="$wall_disp <span class=\"pct\">$pct</span>"
  diff=$(fmt_diff "$wall" "$baseline")
  printf '      <tr><td><a href="%s">%s</a></td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td></tr>\n' \
    "$f" "$label" "$wall_disp" "${diff:-—}" "$(fmt_ms "$cpu")" "$(fmt_ms "$c2")" "$(fmt_ms "$dl")" "$(fmt_ms "$gc")"
}

# Emit a self-contained inline SVG line chart of wall-clock time (y) by thread
# count (x): one curve per builder (Default / Smart), solid for C2 enabled and
# dashed for C2 disabled (-XX:TieredStopAtLevel=1). The left y-axis is wall-clock
# time; a right y-axis shows the same scale as a percentage of the baseline
# (arg $1 = Default · -T1 wall-clock ms = 100%), so each curve doubles as a
# relative-speed read-off.
# Reads "thread default_ms smart_ms default_noc2_ms smart_noc2_ms nocache_ms"
# lines on stdin (blank/"null" = missing point; nocache_ms is set only on the -T1
# row — the single-threaded default build with no local dependency cache, drawn as
# a standalone point). Prints a <figure> with the chart, or nothing at all when
# there is no data, so the page still renders cleanly when run locally without
# reports.
emit_chart_svg() {
  awk -v baseline="${1:-}" '
  function x(t){ return ml + (t-xmin)/(xmax-xmin)*pw }
  function y(v){ return mt + ph - (v/niceMax)*ph }
  function lab(v){ if (v==0) return "0"; if (v/1000<10) return sprintf("%.1f s", v/1000); return sprintf("%.0f s", v/1000) }
  # Hover-tooltip text for a data point: which curve, the thread count (x) and the
  # wall-clock value (y), plus % of baseline when a baseline is known.
  function tip(series,t,v,  s){ s=series ", T" t ": " lab(v+0); if (baseline!="" && baseline!="null" && baseline+0>0) s=s sprintf(" (%.0f%% of baseline)", v/(baseline+0)*100); return s }
  BEGIN { W=720; H=380; ml=72; mr=210; mt=28; mb=52; xmin=1; ymax=0; n=0; xmaxData=1 }
  {
    tt[n]=$1+0; dd[n]=$2; ss[n]=$3; dn[n]=$4; sn[n]=$5; nc[n]=$6
    if (dd[n]!="" && dd[n]!="null") { if (dd[n]+0>ymax) ymax=dd[n]+0; if (tt[n]>xmaxData) xmaxData=tt[n] }
    if (ss[n]!="" && ss[n]!="null") { if (ss[n]+0>ymax) ymax=ss[n]+0; if (tt[n]>xmaxData) xmaxData=tt[n] }
    if (dn[n]!="" && dn[n]!="null") { if (dn[n]+0>ymax) ymax=dn[n]+0; if (tt[n]>xmaxData) xmaxData=tt[n] }
    if (sn[n]!="" && sn[n]!="null") { if (sn[n]+0>ymax) ymax=sn[n]+0; if (tt[n]>xmaxData) xmaxData=tt[n] }
    if (nc[n]!="" && nc[n]!="null") { if (nc[n]+0>ymax) ymax=nc[n]+0; if (tt[n]>xmaxData) xmaxData=tt[n] }
    n++
  }
  END {
    if (ymax<=0) exit
    xmax = (xmaxData>=2)?xmaxData:2
    pw = W-ml-mr; ph = H-mt-mb
    raw = ymax/4
    mag = exp(log(10)*int(log(raw)/log(10)))
    norm = raw/mag
    if (norm<=1) step=1; else if (norm<=2) step=2; else if (norm<=5) step=5; else step=10
    step = step*mag
    ticks = int(ymax/step)+1
    niceMax = ticks*step

    print "<figure class=\"chart\">"
    printf "<svg viewBox=\"0 0 %d %d\" role=\"img\" aria-label=\"Wall clock time by thread count\" preserveAspectRatio=\"xMidYMid meet\">\n", W, H
    for (i=0;i<=ticks;i++){
      gv=i*step; gy=y(gv)
      printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#eee\"/>\n", ml, gy, ml+pw, gy
      printf "<text x=\"%.1f\" y=\"%.1f\" class=\"yl\">%s</text>\n", ml-8, gy+4, lab(gv)
    }
    printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#ccc\"/>\n", ml, mt+ph, ml+pw, mt+ph
    for (t=xmin;t<=xmax;t++){
      xt=x(t)
      printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#ccc\"/>\n", xt, mt+ph, xt, mt+ph+5
      printf "<text x=\"%.1f\" y=\"%.1f\" class=\"xl\">%d</text>\n", xt, mt+ph+20, t
    }
    printf "<text x=\"%.1f\" y=\"%.1f\" class=\"axt\">Threads (-T)</text>\n", ml+pw/2, H-8
    printf "<text transform=\"translate(%.1f,%.1f) rotate(-90)\" class=\"axt\">Wall clock</text>\n", 16, mt+ph/2

    # Right y-axis: same scale as a percentage of the baseline (100% = baseline).
    if (baseline != "" && baseline != "null" && baseline+0 > 0) {
      rax = ml+pw
      printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#ccc\"/>\n", rax, mt, rax, mt+ph
      pctTop = niceMax/(baseline+0)*100
      pstep = 10
      for (p=0; p<=pctTop+0.0001; p+=pstep) {
        gy=y(p/100*(baseline+0))
        printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#ccc\"/>\n", rax, gy, rax+5, gy
        printf "<text x=\"%.1f\" y=\"%.1f\" class=\"yr\">%g%%</text>\n", rax+8, gy+4, p
      }
      printf "<text transform=\"translate(%.1f,%.1f) rotate(90)\" class=\"axt\">%% of baseline</text>\n", rax+52, mt+ph/2
    }

    dpoly=""; spoly=""; dnpoly=""; snpoly=""; dcirc=""; scirc=""; dncirc=""; sncirc=""; nccirc=""; hit=""
    for (i=0;i<n;i++){
      xt=x(tt[i])
      if (dd[i]!="" && dd[i]!="null"){ yp=y(dd[i]+0); dpoly=dpoly sprintf("%.1f,%.1f ",xt,yp); dcirc=dcirc sprintf("<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3.5\" fill=\"#0366d6\"/>",xt,yp); hit=hit sprintf("<circle class=\"hit\" cx=\"%.1f\" cy=\"%.1f\" r=\"6\" fill=\"none\" pointer-events=\"all\" data-tip=\"%s\"/>",xt,yp,tip("Default · C2 on",tt[i],dd[i]+0)) }
      if (ss[i]!="" && ss[i]!="null"){ yp=y(ss[i]+0); spoly=spoly sprintf("%.1f,%.1f ",xt,yp); scirc=scirc sprintf("<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3.5\" fill=\"#e8590c\"/>",xt,yp); hit=hit sprintf("<circle class=\"hit\" cx=\"%.1f\" cy=\"%.1f\" r=\"6\" fill=\"none\" pointer-events=\"all\" data-tip=\"%s\"/>",xt,yp,tip("Smart · C2 on",tt[i],ss[i]+0)) }
      if (dn[i]!="" && dn[i]!="null"){ yp=y(dn[i]+0); dnpoly=dnpoly sprintf("%.1f,%.1f ",xt,yp); dncirc=dncirc sprintf("<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3\" fill=\"#fff\" stroke=\"#0366d6\" stroke-width=\"1.5\"/>",xt,yp); hit=hit sprintf("<circle class=\"hit\" cx=\"%.1f\" cy=\"%.1f\" r=\"6\" fill=\"none\" pointer-events=\"all\" data-tip=\"%s\"/>",xt,yp,tip("Default · C2 off",tt[i],dn[i]+0)) }
      if (sn[i]!="" && sn[i]!="null"){ yp=y(sn[i]+0); snpoly=snpoly sprintf("%.1f,%.1f ",xt,yp); sncirc=sncirc sprintf("<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3\" fill=\"#fff\" stroke=\"#e8590c\" stroke-width=\"1.5\"/>",xt,yp); hit=hit sprintf("<circle class=\"hit\" cx=\"%.1f\" cy=\"%.1f\" r=\"6\" fill=\"none\" pointer-events=\"all\" data-tip=\"%s\"/>",xt,yp,tip("Smart · C2 off",tt[i],sn[i]+0)) }
      # No-cache leg: a single standalone point (no curve) in a distinct purple, at
      # whatever thread count carried it (the -T1 row).
      if (nc[i]!="" && nc[i]!="null"){ hasNc=1; yp=y(nc[i]+0); nccirc=nccirc sprintf("<circle cx=\"%.1f\" cy=\"%.1f\" r=\"4.5\" fill=\"#8250df\"/>",xt,yp); hit=hit sprintf("<circle class=\"hit\" cx=\"%.1f\" cy=\"%.1f\" r=\"6\" fill=\"none\" pointer-events=\"all\" data-tip=\"%s\"/>",xt,yp,tip("Default · no cache",tt[i],nc[i]+0)) }
    }
    if (dpoly!="")  printf "<polyline fill=\"none\" stroke=\"#0366d6\" stroke-width=\"2\" points=\"%s\"/>\n", dpoly
    if (dnpoly!="") printf "<polyline fill=\"none\" stroke=\"#0366d6\" stroke-width=\"2\" stroke-dasharray=\"5 4\" points=\"%s\"/>\n", dnpoly
    if (spoly!="")  printf "<polyline fill=\"none\" stroke=\"#e8590c\" stroke-width=\"2\" points=\"%s\"/>\n", spoly
    if (snpoly!="") printf "<polyline fill=\"none\" stroke=\"#e8590c\" stroke-width=\"2\" stroke-dasharray=\"5 4\" points=\"%s\"/>\n", snpoly
    print dcirc; print scirc; print dncirc; print sncirc; print nccirc
    # Transparent, larger hit targets on top of everything so hovering near a
    # point reveals its (thread, wall-clock) values via the data-tip tooltip below.
    print hit

    lx=ml+pw+78; ly=mt+10
    printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#0366d6\" stroke-width=\"3\"/>\n", lx, ly, lx+14, ly
    printf "<text x=\"%.1f\" y=\"%.1f\" class=\"lg\">Default · C2 on</text>\n", lx+20, ly+4
    printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#0366d6\" stroke-width=\"3\" stroke-dasharray=\"5 4\"/>\n", lx, ly+22, lx+14, ly+22
    printf "<text x=\"%.1f\" y=\"%.1f\" class=\"lg\">Default · C2 off</text>\n", lx+20, ly+26
    printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#e8590c\" stroke-width=\"3\"/>\n", lx, ly+44, lx+14, ly+44
    printf "<text x=\"%.1f\" y=\"%.1f\" class=\"lg\">Smart · C2 on</text>\n", lx+20, ly+48
    printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#e8590c\" stroke-width=\"3\" stroke-dasharray=\"5 4\"/>\n", lx, ly+66, lx+14, ly+66
    printf "<text x=\"%.1f\" y=\"%.1f\" class=\"lg\">Smart · C2 off</text>\n", lx+20, ly+70
    if (hasNc) {
      printf "<circle cx=\"%.1f\" cy=\"%.1f\" r=\"4.5\" fill=\"#8250df\"/>\n", lx+7, ly+88
      printf "<text x=\"%.1f\" y=\"%.1f\" class=\"lg\">Default · no cache</text>\n", lx+20, ly+92
    }
    print "</svg>"
    cap = "Wall-clock time vs. thread count (<code>-T</code>), Default vs. Takari Smart builder. Solid = C2 JIT enabled, dashed = C2 disabled (<code>-XX:TieredStopAtLevel=1</code>). Lower is faster."
    if (hasNc) cap = cap " The standalone purple point is the single-threaded default build with no local dependency cache (cold <code>~/.m2</code>), so its wall clock also carries the full first-time dependency-download cost."
    print "<figcaption>" cap "</figcaption>"
    print "</figure>"
  }
  '
}

# Emit a self-contained inline SVG line chart of cumulative JIT C2 compilation
# time (y) by thread count (x): one curve per builder (Default / Smart), solid
# for C2 enabled and dashed for C2 disabled (-XX:TieredStopAtLevel=1, which keeps
# only C1 — so the dashed curves hug the x-axis on purpose). C2 time is summed
# across the parent + all forked test JVMs, so it can exceed wall clock and it
# climbs with -T as more JVMs compile concurrently.
# Reads "thread default_ms smart_ms default_noc2_ms smart_noc2_ms" lines on stdin
# (blank/"null" = missing point). Prints a <figure>, or nothing when there is no
# data, so the page still renders cleanly when run locally without reports.
emit_c2_chart_svg() {
  awk '
  function x(t){ return ml + (t-xmin)/(xmax-xmin)*pw }
  function y(v){ return mt + ph - (v/niceMax)*ph }
  function lab(v){ if (v==0) return "0"; if (v/1000<10) return sprintf("%.1f s", v/1000); return sprintf("%.0f s", v/1000) }
  # Hover-tooltip text for a data point: which curve, the thread count (x) and the
  # cumulative C2 compilation value (y).
  function tip(series,t,v){ return series ", T" t ": " lab(v+0) }
  BEGIN { W=720; H=380; ml=72; mr=210; mt=28; mb=52; xmin=1; ymax=0; n=0; xmaxData=1 }
  {
    tt[n]=$1+0; dd[n]=$2; ss[n]=$3; dn[n]=$4; sn[n]=$5
    if (dd[n]!="" && dd[n]!="null") { if (dd[n]+0>ymax) ymax=dd[n]+0; if (tt[n]>xmaxData) xmaxData=tt[n] }
    if (ss[n]!="" && ss[n]!="null") { if (ss[n]+0>ymax) ymax=ss[n]+0; if (tt[n]>xmaxData) xmaxData=tt[n] }
    if (dn[n]!="" && dn[n]!="null") { if (dn[n]+0>ymax) ymax=dn[n]+0; if (tt[n]>xmaxData) xmaxData=tt[n] }
    if (sn[n]!="" && sn[n]!="null") { if (sn[n]+0>ymax) ymax=sn[n]+0; if (tt[n]>xmaxData) xmaxData=tt[n] }
    n++
  }
  END {
    if (ymax<=0) exit
    xmax = (xmaxData>=2)?xmaxData:2
    pw = W-ml-mr; ph = H-mt-mb
    raw = ymax/4
    mag = exp(log(10)*int(log(raw)/log(10)))
    norm = raw/mag
    if (norm<=1) step=1; else if (norm<=2) step=2; else if (norm<=5) step=5; else step=10
    step = step*mag
    ticks = int(ymax/step)+1
    niceMax = ticks*step

    print "<figure class=\"chart\">"
    printf "<svg viewBox=\"0 0 %d %d\" role=\"img\" aria-label=\"Cumulative JIT C2 compilation time by thread count\" preserveAspectRatio=\"xMidYMid meet\">\n", W, H
    for (i=0;i<=ticks;i++){
      gv=i*step; gy=y(gv)
      printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#eee\"/>\n", ml, gy, ml+pw, gy
      printf "<text x=\"%.1f\" y=\"%.1f\" class=\"yl\">%s</text>\n", ml-8, gy+4, lab(gv)
    }
    printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#ccc\"/>\n", ml, mt+ph, ml+pw, mt+ph
    for (t=xmin;t<=xmax;t++){
      xt=x(t)
      printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#ccc\"/>\n", xt, mt+ph, xt, mt+ph+5
      printf "<text x=\"%.1f\" y=\"%.1f\" class=\"xl\">%d</text>\n", xt, mt+ph+20, t
    }
    printf "<text x=\"%.1f\" y=\"%.1f\" class=\"axt\">Threads (-T)</text>\n", ml+pw/2, H-8
    printf "<text transform=\"translate(%.1f,%.1f) rotate(-90)\" class=\"axt\">C2 JIT compilation</text>\n", 16, mt+ph/2

    dpoly=""; spoly=""; dnpoly=""; snpoly=""; dcirc=""; scirc=""; dncirc=""; sncirc=""; hit=""
    for (i=0;i<n;i++){
      xt=x(tt[i])
      if (dd[i]!="" && dd[i]!="null"){ yp=y(dd[i]+0); dpoly=dpoly sprintf("%.1f,%.1f ",xt,yp); dcirc=dcirc sprintf("<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3.5\" fill=\"#0366d6\"/>",xt,yp); hit=hit sprintf("<circle class=\"hit\" cx=\"%.1f\" cy=\"%.1f\" r=\"6\" fill=\"none\" pointer-events=\"all\" data-tip=\"%s\"/>",xt,yp,tip("Default \xc2\xb7 C2 on",tt[i],dd[i]+0)) }
      if (ss[i]!="" && ss[i]!="null"){ yp=y(ss[i]+0); spoly=spoly sprintf("%.1f,%.1f ",xt,yp); scirc=scirc sprintf("<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3.5\" fill=\"#e8590c\"/>",xt,yp); hit=hit sprintf("<circle class=\"hit\" cx=\"%.1f\" cy=\"%.1f\" r=\"6\" fill=\"none\" pointer-events=\"all\" data-tip=\"%s\"/>",xt,yp,tip("Smart \xc2\xb7 C2 on",tt[i],ss[i]+0)) }
      if (dn[i]!="" && dn[i]!="null"){ yp=y(dn[i]+0); dnpoly=dnpoly sprintf("%.1f,%.1f ",xt,yp); dncirc=dncirc sprintf("<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3\" fill=\"#fff\" stroke=\"#0366d6\" stroke-width=\"1.5\"/>",xt,yp); hit=hit sprintf("<circle class=\"hit\" cx=\"%.1f\" cy=\"%.1f\" r=\"6\" fill=\"none\" pointer-events=\"all\" data-tip=\"%s\"/>",xt,yp,tip("Default \xc2\xb7 C2 off",tt[i],dn[i]+0)) }
      if (sn[i]!="" && sn[i]!="null"){ yp=y(sn[i]+0); snpoly=snpoly sprintf("%.1f,%.1f ",xt,yp); sncirc=sncirc sprintf("<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3\" fill=\"#fff\" stroke=\"#e8590c\" stroke-width=\"1.5\"/>",xt,yp); hit=hit sprintf("<circle class=\"hit\" cx=\"%.1f\" cy=\"%.1f\" r=\"6\" fill=\"none\" pointer-events=\"all\" data-tip=\"%s\"/>",xt,yp,tip("Smart \xc2\xb7 C2 off",tt[i],sn[i]+0)) }
    }
    if (dpoly!="")  printf "<polyline fill=\"none\" stroke=\"#0366d6\" stroke-width=\"2\" points=\"%s\"/>\n", dpoly
    if (dnpoly!="") printf "<polyline fill=\"none\" stroke=\"#0366d6\" stroke-width=\"2\" stroke-dasharray=\"5 4\" points=\"%s\"/>\n", dnpoly
    if (spoly!="")  printf "<polyline fill=\"none\" stroke=\"#e8590c\" stroke-width=\"2\" points=\"%s\"/>\n", spoly
    if (snpoly!="") printf "<polyline fill=\"none\" stroke=\"#e8590c\" stroke-width=\"2\" stroke-dasharray=\"5 4\" points=\"%s\"/>\n", snpoly
    print dcirc; print scirc; print dncirc; print sncirc
    # Transparent, larger hit targets on top so hovering near a point reveals its
    # (thread, C2 compilation) values via the data-tip tooltip (shared chart JS below).
    print hit

    lx=ml+pw+78; ly=mt+10
    printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#0366d6\" stroke-width=\"3\"/>\n", lx, ly, lx+14, ly
    printf "<text x=\"%.1f\" y=\"%.1f\" class=\"lg\">Default \xc2\xb7 C2 on</text>\n", lx+20, ly+4
    printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#0366d6\" stroke-width=\"3\" stroke-dasharray=\"5 4\"/>\n", lx, ly+22, lx+14, ly+22
    printf "<text x=\"%.1f\" y=\"%.1f\" class=\"lg\">Default \xc2\xb7 C2 off</text>\n", lx+20, ly+26
    printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#e8590c\" stroke-width=\"3\"/>\n", lx, ly+44, lx+14, ly+44
    printf "<text x=\"%.1f\" y=\"%.1f\" class=\"lg\">Smart \xc2\xb7 C2 on</text>\n", lx+20, ly+48
    printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#e8590c\" stroke-width=\"3\" stroke-dasharray=\"5 4\"/>\n", lx, ly+66, lx+14, ly+66
    printf "<text x=\"%.1f\" y=\"%.1f\" class=\"lg\">Smart \xc2\xb7 C2 off</text>\n", lx+20, ly+70
    print "</svg>"
    print "<figcaption>Cumulative JIT C2 compilation time vs. thread count (<code>-T</code>), Default vs. Takari Smart builder. Solid = C2 JIT enabled, dashed = C2 disabled (<code>-XX:TieredStopAtLevel=1</code>, which drops C2 to nearly nothing). Summed across the parent and forked test JVMs, so it can exceed wall clock and rises with more threads.</figcaption>"
    print "</figure>"
  }
  '
}

# Average CPU usage of a report, mirroring the dashboard Overview "CPU usage"
# section (dashboard.js computeCpuStats):
#   machine = time-weighted mean of the parent Maven JVM's machineTotal samples
#             (systemPct) — the whole box (every process), as a % of total
#             machine capacity. Only the parent is used: each JVM measures the
#             machine over its own sampling window and simultaneous readings
#             from different JVMs disagree.
#   maven   = the Maven JVMs' combined share. A periodic jdk.CPULoad value is
#             the average load since that JVM's previous sample, so each JVM is
#             a step function over (prev, cur]; integrating those step
#             functions weights a short-lived fork by the time it actually
#             lived and cannot add a dying fork and its successor as if they
#             had overlapped. Each recording's baseline-less first sample only
#             anchors its successor's interval (its 0/0 load values are unused).
# Prints "machineAvg<TAB>mavenSumAvg"; blank when the file is missing or carries
# no CPU samples (silent, like extract_wall_ms, so no-data legs just omit points).
extract_cpu_stats() {
  [ -f "$1" ] || return 0
  extract_json "$1" | node -e '
    const j = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const cpu = Array.isArray(j.cpu) ? j.cpu : [];
    const byJvm = new Map();
    for (const e of cpu) {
      if (!e || e.timeMs == null) continue;
      const jvm = e.jvm || "unknown";
      if (!byJvm.has(jvm)) byJvm.set(jvm, []);
      byJvm.get(jvm).push(e);
    }
    for (const s of byJvm.values()) s.sort((a, b) => a.timeMs - b.timeMs);
    // Time-weighted mean of `field` over one series; the first sample only
    // anchors the second one, its value is never used.
    const weighted = (s, field) => {
      let load = 0, span = 0;
      for (let i = 1; i < s.length; i++) {
        const gap = s[i].timeMs - s[i - 1].timeMs;
        const v = s[i][field];
        if (gap > 0 && v != null && !isNaN(v)) { load += gap * v; span += gap; }
      }
      return span > 0 ? load / span : null;
    };
    const parent = byJvm.get("maven")
      || [...byJvm.values()].sort((a, b) => b.length - a.length)[0];
    const machineAvg = parent ? weighted(parent, "systemPct") : null;
    if (machineAvg == null) process.exit(0);
    // Combined share: integrate every JVM step function over the session span
    // covered by its samples, then divide by the parent-covered span.
    let load = 0, span = 0;
    for (const s of byJvm.values()) {
      for (let i = 1; i < s.length; i++) {
        const gap = s[i].timeMs - s[i - 1].timeMs;
        const v = s[i].processPct;
        if (gap > 0 && v != null && !isNaN(v)) load += gap * v;
      }
    }
    if (parent) {
      for (let i = 1; i < parent.length; i++) {
        const gap = parent[i].timeMs - parent[i - 1].timeMs;
        if (gap > 0) span += gap;
      }
    }
    const mavenSumAvg = span > 0 ? load / span : 0;
    console.log(machineAvg + "\t" + mavenSumAvg);
  ' 2>/dev/null || true
}

# Emit a self-contained inline SVG line chart of average CPU usage (y, % of total
# machine capacity) by thread count (x). Two metrics × two builders = four curves:
# solid = whole machine, dashed = summed Maven processes; blue = Default builder,
# orange = Takari Smart. Higher means more cores kept busy.
# Reads "thread machine_default machine_smart maven_default maven_smart" lines on
# stdin (blank/"null" = missing point). Prints a <figure>, or nothing when there is
# no data, so the page still renders cleanly when run locally without reports.
emit_cpu_chart_svg() {
  awk '
  function x(t){ return ml + (t-xmin)/(xmax-xmin)*pw }
  function y(v){ return mt + ph - (v/niceMax)*ph }
  function lab(v){ return sprintf("%g%%", v) }
  # Hover-tooltip text for a data point: which curve, the thread count (x) and the
  # CPU usage (y).
  function tip(series,t,v){ return sprintf("%s, T%d: %.1f%%", series, t, v) }
  BEGIN { W=720; H=380; ml=64; mr=210; mt=28; mb=52; xmin=1; ymax=0; n=0; xmaxData=1 }
  {
    tt[n]=$1+0; md[n]=$2; ms[n]=$3; sd[n]=$4; ss[n]=$5
    for (k=2;k<=5;k++){ v=$k; if (v!="" && v!="null" && v+0>ymax) ymax=v+0 }
    if (tt[n]>xmaxData) xmaxData=tt[n]
    n++
  }
  END {
    if (ymax<=0) exit
    xmax = (xmaxData>=2)?xmaxData:2
    pw = W-ml-mr; ph = H-mt-mb
    raw = ymax/4
    mag = exp(log(10)*int(log(raw)/log(10)))
    norm = raw/mag
    if (norm<=1) step=1; else if (norm<=2) step=2; else if (norm<=5) step=5; else step=10
    step = step*mag
    ticks = int(ymax/step)+1
    niceMax = ticks*step

    print "<figure class=\"chart\">"
    printf "<svg viewBox=\"0 0 %d %d\" role=\"img\" aria-label=\"CPU usage by thread count\" preserveAspectRatio=\"xMidYMid meet\">\n", W, H
    for (i=0;i<=ticks;i++){
      gv=i*step; gy=y(gv)
      printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#eee\"/>\n", ml, gy, ml+pw, gy
      printf "<text x=\"%.1f\" y=\"%.1f\" class=\"yl\">%s</text>\n", ml-8, gy+4, lab(gv)
    }
    printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#ccc\"/>\n", ml, mt+ph, ml+pw, mt+ph
    for (t=xmin;t<=xmax;t++){
      xt=x(t)
      printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#ccc\"/>\n", xt, mt+ph, xt, mt+ph+5
      printf "<text x=\"%.1f\" y=\"%.1f\" class=\"xl\">%d</text>\n", xt, mt+ph+20, t
    }
    printf "<text x=\"%.1f\" y=\"%.1f\" class=\"axt\">Threads (-T)</text>\n", ml+pw/2, H-8
    printf "<text transform=\"translate(%.1f,%.1f) rotate(-90)\" class=\"axt\">CPU usage</text>\n", 16, mt+ph/2

    mdpoly=""; mspoly=""; sdpoly=""; sspoly=""; mdcirc=""; mscirc=""; sdcirc=""; sscirc=""; hit=""
    for (i=0;i<n;i++){
      xt=x(tt[i])
      if (md[i]!="" && md[i]!="null"){ yp=y(md[i]+0); mdpoly=mdpoly sprintf("%.1f,%.1f ",xt,yp); mdcirc=mdcirc sprintf("<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3.5\" fill=\"#0366d6\"/>",xt,yp); hit=hit sprintf("<circle class=\"hit\" cx=\"%.1f\" cy=\"%.1f\" r=\"6\" fill=\"none\" pointer-events=\"all\" data-tip=\"%s\"/>",xt,yp,tip("Machine \xc2\xb7 Default",tt[i],md[i]+0)) }
      if (ms[i]!="" && ms[i]!="null"){ yp=y(ms[i]+0); mspoly=mspoly sprintf("%.1f,%.1f ",xt,yp); mscirc=mscirc sprintf("<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3.5\" fill=\"#e8590c\"/>",xt,yp); hit=hit sprintf("<circle class=\"hit\" cx=\"%.1f\" cy=\"%.1f\" r=\"6\" fill=\"none\" pointer-events=\"all\" data-tip=\"%s\"/>",xt,yp,tip("Machine \xc2\xb7 Smart",tt[i],ms[i]+0)) }
      if (sd[i]!="" && sd[i]!="null"){ yp=y(sd[i]+0); sdpoly=sdpoly sprintf("%.1f,%.1f ",xt,yp); sdcirc=sdcirc sprintf("<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3\" fill=\"#fff\" stroke=\"#0366d6\" stroke-width=\"1.5\"/>",xt,yp); hit=hit sprintf("<circle class=\"hit\" cx=\"%.1f\" cy=\"%.1f\" r=\"6\" fill=\"none\" pointer-events=\"all\" data-tip=\"%s\"/>",xt,yp,tip("Maven sum \xc2\xb7 Default",tt[i],sd[i]+0)) }
      if (ss[i]!="" && ss[i]!="null"){ yp=y(ss[i]+0); sspoly=sspoly sprintf("%.1f,%.1f ",xt,yp); sscirc=sscirc sprintf("<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3\" fill=\"#fff\" stroke=\"#e8590c\" stroke-width=\"1.5\"/>",xt,yp); hit=hit sprintf("<circle class=\"hit\" cx=\"%.1f\" cy=\"%.1f\" r=\"6\" fill=\"none\" pointer-events=\"all\" data-tip=\"%s\"/>",xt,yp,tip("Maven sum \xc2\xb7 Smart",tt[i],ss[i]+0)) }
    }
    if (mdpoly!="") printf "<polyline fill=\"none\" stroke=\"#0366d6\" stroke-width=\"2\" points=\"%s\"/>\n", mdpoly
    if (mspoly!="") printf "<polyline fill=\"none\" stroke=\"#e8590c\" stroke-width=\"2\" points=\"%s\"/>\n", mspoly
    if (sdpoly!="") printf "<polyline fill=\"none\" stroke=\"#0366d6\" stroke-width=\"2\" stroke-dasharray=\"5 4\" points=\"%s\"/>\n", sdpoly
    if (sspoly!="") printf "<polyline fill=\"none\" stroke=\"#e8590c\" stroke-width=\"2\" stroke-dasharray=\"5 4\" points=\"%s\"/>\n", sspoly
    print mdcirc; print mscirc; print sdcirc; print sscirc
    # Transparent, larger hit targets on top so hovering near a point reveals its
    # (thread, CPU usage) values via the data-tip tooltip (shared chart JS below).
    print hit

    lx=ml+pw+78; ly=mt+10
    printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#0366d6\" stroke-width=\"3\"/>\n", lx, ly, lx+14, ly
    printf "<text x=\"%.1f\" y=\"%.1f\" class=\"lg\">Machine \xc2\xb7 Default</text>\n", lx+20, ly+4
    printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#e8590c\" stroke-width=\"3\"/>\n", lx, ly+22, lx+14, ly+22
    printf "<text x=\"%.1f\" y=\"%.1f\" class=\"lg\">Machine \xc2\xb7 Smart</text>\n", lx+20, ly+26
    printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#0366d6\" stroke-width=\"3\" stroke-dasharray=\"5 4\"/>\n", lx, ly+44, lx+14, ly+44
    printf "<text x=\"%.1f\" y=\"%.1f\" class=\"lg\">Maven sum \xc2\xb7 Default</text>\n", lx+20, ly+48
    printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#e8590c\" stroke-width=\"3\" stroke-dasharray=\"5 4\"/>\n", lx, ly+66, lx+14, ly+66
    printf "<text x=\"%.1f\" y=\"%.1f\" class=\"lg\">Maven sum \xc2\xb7 Smart</text>\n", lx+20, ly+70
    print "</svg>"
    print "<figcaption>Average CPU usage vs. thread count (<code>-T</code>): solid = whole machine (every process), dashed = the summed Maven JVMs (parent + forks). Both are a percentage of total machine capacity across all cores; blue = Default builder, orange = Takari Smart. Higher means more cores kept busy.</figcaption>"
    print "</figure>"
  }
  '
}

# Generic N-series inline SVG line chart, used by the fork-comparison page
# (/parallel/, FORK_LEVELS set) where the wall / C2 / CPU charts each carry
# 12 curves (Default & Smart × forkCount 5/1/0 × C2 on/off, or machine/Maven for
# CPU) — too many for the fixed-column emit_*_chart_svg helpers above, which the
# baseline pages keep using unchanged.
#
# Args:
#   $1 ylabel    left y-axis title (e.g. "Wall clock")
#   $2 valfmt    "time" (ms → s) or "pct" (value already a percentage)
#   $3 baseline  baseline ms for the right-hand "% of baseline" axis; "" to omit
#   $4 aria      <svg> aria-label
#   $5 caption   <figcaption> HTML
#   $6 spec      series definitions "color;dash;label" joined by "~", one per data
#                column in order; dash is "solid" or "dash".
# Reads "x v1 v2 ... vN" lines on stdin (blank/"null" = missing point), N = number
# of series. Prints a <figure>, or nothing when there is no data.
emit_series_chart_svg() {
  awk -v ylabel="$1" -v valfmt="$2" -v baseline="$3" -v aria="$4" -v caption="$5" -v spec="$6" '
  function x(t){ return ml + (t-xmin)/(xmax-xmin)*pw }
  function y(v){ return mt + ph - (v/niceMax)*ph }
  function lab(v){
    if (valfmt=="pct") return sprintf("%g%%", v)
    if (v==0) return "0"
    if (v/1000<10) return sprintf("%.1f s", v/1000)
    return sprintf("%.0f s", v/1000)
  }
  # Hover-tooltip text for a data point: the series label, the thread count (x) and
  # the value (y), plus % of baseline when a baseline is known (wall chart only).
  function tip(label,t,v,  s){
    if (valfmt=="pct") return sprintf("%s, T%d: %.1f%%", label, t, v)
    s=label ", T" t ": " lab(v+0)
    if (baseline!="" && baseline!="null" && baseline+0>0) s=s sprintf(" (%.0f%% of baseline)", v/(baseline+0)*100)
    return s
  }
  BEGIN {
    W=900; H=420; ml=72; mr=300; mt=28; mb=52; xmin=1; ymax=0; n=0; xmaxData=1
    ns=split(spec, sp, "~")
    for (i=1;i<=ns;i++){ split(sp[i], a, ";"); col[i]=a[1]; dsh[i]=a[2]; lbl[i]=a[3] }
  }
  {
    tt[n]=$1+0
    for (i=1;i<=ns;i++){
      val[n,i]=$(i+1)
      if (val[n,i]!="" && val[n,i]!="null"){ if (val[n,i]+0>ymax) ymax=val[n,i]+0; if (tt[n]>xmaxData) xmaxData=tt[n] }
    }
    n++
  }
  END {
    if (ymax<=0) exit
    xmax = (xmaxData>=2)?xmaxData:2
    pw = W-ml-mr; ph = H-mt-mb
    raw = ymax/4
    mag = exp(log(10)*int(log(raw)/log(10)))
    norm = raw/mag
    if (norm<=1) step=1; else if (norm<=2) step=2; else if (norm<=5) step=5; else step=10
    step = step*mag
    ticks = int(ymax/step)+1
    niceMax = ticks*step

    print "<figure class=\"chart\">"
    printf "<svg viewBox=\"0 0 %d %d\" role=\"img\" aria-label=\"%s\" preserveAspectRatio=\"xMidYMid meet\">\n", W, H, aria
    for (i=0;i<=ticks;i++){
      gv=i*step; gy=y(gv)
      printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#eee\"/>\n", ml, gy, ml+pw, gy
      printf "<text x=\"%.1f\" y=\"%.1f\" class=\"yl\">%s</text>\n", ml-8, gy+4, lab(gv)
    }
    printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#ccc\"/>\n", ml, mt+ph, ml+pw, mt+ph
    for (t=xmin;t<=xmax;t++){
      xt=x(t)
      printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#ccc\"/>\n", xt, mt+ph, xt, mt+ph+5
      printf "<text x=\"%.1f\" y=\"%.1f\" class=\"xl\">%d</text>\n", xt, mt+ph+20, t
    }
    printf "<text x=\"%.1f\" y=\"%.1f\" class=\"axt\">Threads (-T)</text>\n", ml+pw/2, H-8
    printf "<text transform=\"translate(%.1f,%.1f) rotate(-90)\" class=\"axt\">%s</text>\n", 16, mt+ph/2, ylabel

    # Right y-axis: same scale as a percentage of the baseline (wall chart only).
    if (baseline != "" && baseline != "null" && baseline+0 > 0) {
      rax = ml+pw
      printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#ccc\"/>\n", rax, mt, rax, mt+ph
      pctTop = niceMax/(baseline+0)*100
      for (p=0; p<=pctTop+0.0001; p+=10) {
        gy=y(p/100*(baseline+0))
        printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#ccc\"/>\n", rax, gy, rax+5, gy
        printf "<text x=\"%.1f\" y=\"%.1f\" class=\"yr\">%g%%</text>\n", rax+8, gy+4, p
      }
      printf "<text transform=\"translate(%.1f,%.1f) rotate(90)\" class=\"axt\">%% of baseline</text>\n", rax+52, mt+ph/2
    }

    hit=""
    for (i=1;i<=ns;i++){
      poly=""; pts=""
      for (j=0;j<n;j++){
        v=val[j,i]
        if (v=="" || v=="null") continue
        xt=x(tt[j]); yp=y(v+0)
        poly=poly sprintf("%.1f,%.1f ", xt, yp)
        if (dsh[i]=="dash") pts=pts sprintf("<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3\" fill=\"#fff\" stroke=\"%s\" stroke-width=\"1.5\"/>", xt, yp, col[i])
        else                pts=pts sprintf("<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3.5\" fill=\"%s\"/>", xt, yp, col[i])
        hit=hit sprintf("<circle class=\"hit\" cx=\"%.1f\" cy=\"%.1f\" r=\"6\" fill=\"none\" pointer-events=\"all\" data-tip=\"%s\"/>", xt, yp, tip(lbl[i], tt[j], v+0))
      }
      if (poly!=""){
        if (dsh[i]=="dash") printf "<polyline fill=\"none\" stroke=\"%s\" stroke-width=\"2\" stroke-dasharray=\"5 4\" points=\"%s\"/>\n", col[i], poly
        else                printf "<polyline fill=\"none\" stroke=\"%s\" stroke-width=\"2\" points=\"%s\"/>\n", col[i], poly
        print pts
      }
    }
    # Transparent, larger hit targets on top so hovering near a point reveals its
    # values via the data-tip tooltip (shared chart JS below).
    print hit

    lx=ml+pw+30; ly=mt+10
    for (i=1;i<=ns;i++){
      yy=ly+(i-1)*20
      if (dsh[i]=="dash") printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"%s\" stroke-width=\"3\" stroke-dasharray=\"5 4\"/>\n", lx, yy, lx+14, yy, col[i]
      else                printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"%s\" stroke-width=\"3\"/>\n", lx, yy, lx+14, yy, col[i]
      printf "<text x=\"%.1f\" y=\"%.1f\" class=\"lg\">%s</text>\n", lx+20, yy+4, lbl[i]
    }
    print "</svg>"
    print "<figcaption>" caption "</figcaption>"
    print "</figure>"
  }
  '
}

# Baseline for the wall-clock percentages: the single-threaded default build.
BASELINE_WALL=$(extract_wall_ms "report-default-T1.html")

# The no-cache leg's wall clock (single-threaded default build against an empty
# local repo), plotted as a standalone point on the wall-clock chart so the
# first-time download cost is visible there too — not just in the table's Maven
# downloads column. Blank/absent → no extra point (e.g. local runs without it).
NOCACHE_WALL=$(extract_wall_ms "report-default-T1-noCache.html")

# Collect wall-clock ms per thread count for the chart: Default + Smart, each
# with C2 enabled (solid curve) and C2 disabled (dashed curve), plus the no-cache
# point on the -T1 row.
chart_rows=()
for t in 1 2 3 4 5 6 7 8 9 10; do
  cd_ms=$(extract_wall_ms "report-default-T${t}.html")
  cs_ms=$(extract_wall_ms "report-smart-T${t}.html")
  cd_noc2_ms=$(extract_wall_ms "report-default-T${t}-noC2.html")
  cs_noc2_ms=$(extract_wall_ms "report-smart-T${t}-noC2.html")
  # The no-cache leg is a single-threaded default build, so its point sits at -T1;
  # every other thread column carries "null" for it.
  nc_ms="null"; [ "$t" = "1" ] && nc_ms="${NOCACHE_WALL:-null}"
  # Use "null" (which emit_chart_svg treats as a missing point) for absent values
  # so a blank column never collapses under awk's whitespace splitting and shifts
  # the remaining values into the wrong curve (e.g. when report-default-T2 is gone).
  chart_rows+=("${t} ${cd_ms:-null} ${cs_ms:-null} ${cd_noc2_ms:-null} ${cs_noc2_ms:-null} ${nc_ms}")
done
CHART_SVG=$(printf '%s\n' "${chart_rows[@]}" | emit_chart_svg "$BASELINE_WALL")

# Collect cumulative JIT C2 compilation ms per thread count for the C2 chart:
# Default + Smart, each with C2 enabled (solid curve) and C2 disabled (dashed
# curve, which sits near zero — that is the point of the contrast).
c2_chart_rows=()
for t in 1 2 3 4 5 6 7 8 9 10; do
  cd_c2=$(extract_c2_ms "report-default-T${t}.html")
  cs_c2=$(extract_c2_ms "report-smart-T${t}.html")
  cd_noc2_c2=$(extract_c2_ms "report-default-T${t}-noC2.html")
  cs_noc2_c2=$(extract_c2_ms "report-smart-T${t}-noC2.html")
  # "null" (a missing point to emit_c2_chart_svg) for absent values so a blank
  # column never collapses under awk's whitespace splitting and misassigns a curve.
  c2_chart_rows+=("${t} ${cd_c2:-null} ${cs_c2:-null} ${cd_noc2_c2:-null} ${cs_noc2_c2:-null}")
done
C2_CHART_SVG=$(printf '%s\n' "${c2_chart_rows[@]}" | emit_c2_chart_svg)

# Collect average CPU usage per thread count for the CPU chart: machine % and the
# summed Maven-process % for each builder (Default + Smart), C2 enabled.
cpu_chart_rows=()
for t in 1 2 3 4 5 6 7 8 9 10; do
  d_machine=""; d_sum=""; s_machine=""; s_sum=""
  d_stats=$(extract_cpu_stats "report-default-T${t}.html")
  s_stats=$(extract_cpu_stats "report-smart-T${t}.html")
  [ -n "$d_stats" ] && IFS=$'\t' read -r d_machine d_sum <<<"$d_stats"
  [ -n "$s_stats" ] && IFS=$'\t' read -r s_machine s_sum <<<"$s_stats"
  # "null" (a missing point to emit_cpu_chart_svg) for absent values so a blank
  # column never collapses under awk's whitespace splitting and misassigns a curve.
  cpu_chart_rows+=("${t} ${d_machine:-null} ${s_machine:-null} ${d_sum:-null} ${s_sum:-null}")
done
CPU_CHART_SVG=$(printf '%s\n' "${cpu_chart_rows[@]}" | emit_cpu_chart_svg)

# --- Fork-comparison page (/parallel/) --------------------------------------
# When FORK_LEVELS is set (e.g. "5 1 0") the report files carry a -f<fork> suffix
# and the page compares Surefire forkCount levels: the wall / C2 / CPU charts gain
# one curve per (builder × fork × C2) — or (machine|Maven × builder × fork) for the
# CPU chart — and the table gains one row block per fork level. This OVERRIDES the
# fixed-column charts/baseline computed above (whose unsuffixed report files do not
# exist on this page). FORK_LEVELS unset → the baseline pages above are untouched.
if [ -n "${FORK_LEVELS:-}" ]; then
  # 6-colour palette keyed by builder × fork: cool hues = Default builder, warm =
  # Takari Smart; the three hues per builder just need to be distinguishable. The
  # forkCount=5 hues reuse the baseline pages' Default/Smart colours for continuity.
  fork_color() {
    case "$1:$2" in
      default:5) echo "#0366d6" ;; default:1) echo "#0aa2c0" ;; default:0) echo "#6741d9" ;;
      smart:5)   echo "#e8590c" ;; smart:1)   echo "#e03131" ;; smart:0)   echo "#c2255c" ;;
      *)         echo "#888888" ;;
    esac
  }
  # forkCount → human label: 5 forks (parallel), 1 fork (serial), no fork (in the
  # Maven build JVM, forkCount=0).
  fork_label() { case "$1" in 5) echo "5 forks" ;; 1) echo "1 fork" ;; 0) echo "no fork" ;; *) echo "f$1" ;; esac; }
  builder_label() { case "$1" in default) echo "Default" ;; smart) echo "Smart" ;; *) echo "$1" ;; esac; }

  # Baseline for the % / Δ columns: single-threaded default build at the headline
  # forkCount=5 (the page's primary, fastest config).
  BASELINE_WALL=$(extract_wall_ms "report-default-T1-f5.html")

  # Series order shared by the wall + C2 charts: builder × fork × C2 (solid = C2 on,
  # dashed = C2 off). Build the "color;dash;label" spec and the per-thread data rows
  # from the SAME nested loops so columns and series line up.
  wall_spec=""
  for b in default smart; do
    for fk in $FORK_LEVELS; do
      for c2 in on off; do
        dsh="solid"; [ "$c2" = "off" ] && dsh="dash"
        lbl="$(builder_label "$b") · $(fork_label "$fk") · C2 $c2"
        wall_spec="${wall_spec}${wall_spec:+~}$(fork_color "$b" "$fk");${dsh};${lbl}"
      done
    done
  done
  wall_rows=(); fc2_rows=()
  for t in 1 2 3 4 5 6 7 8 9 10; do
    wrow="$t"; crow="$t"
    for b in default smart; do
      for fk in $FORK_LEVELS; do
        for c2 in on off; do
          sfx=""; [ "$c2" = "off" ] && sfx="-noC2"
          f="report-${b}-T${t}-f${fk}${sfx}.html"
          w=$(extract_wall_ms "$f"); c=$(extract_c2_ms "$f")
          wrow="$wrow ${w:-null}"; crow="$crow ${c:-null}"
        done
      done
    done
    wall_rows+=("$wrow"); fc2_rows+=("$crow")
  done
  CHART_SVG=$(printf '%s\n' "${wall_rows[@]}" | emit_series_chart_svg \
    "Wall clock" "time" "$BASELINE_WALL" "Wall clock time by thread count and fork count" \
    "Wall-clock time vs. thread count (<code>-T</code>) at three Surefire fork counts (<code>forkCount</code> = 5 / 1 / 0). Cool colours = Default builder, warm = Takari Smart; solid = C2 JIT enabled, dashed = C2 disabled (<code>-XX:TieredStopAtLevel=1</code>). <code>forkCount=5</code> runs <code>parallel-tests</code>' five classes in five fork JVMs (~15 s), <code>forkCount=1</code> runs them serially in one fork (~75 s), and <code>forkCount=0</code> (no fork) runs them inside the Maven build JVM. <code>forkCount=0</code> is a single point at <code>-T1</code> only — Surefire forbids it under a parallel reactor (<code>-T&gt;1</code>) — the &quot;no new JVM for tests&quot; marker. Lower is faster." \
    "$wall_spec")
  C2_CHART_SVG=$(printf '%s\n' "${fc2_rows[@]}" | emit_series_chart_svg \
    "C2 JIT compilation" "time" "" "Cumulative JIT C2 compilation time by thread count and fork count" \
    "Cumulative JIT C2 compilation time vs. thread count (<code>-T</code>) at three fork counts (<code>forkCount</code> = 5 / 1 / 0). Cool colours = Default builder, warm = Takari Smart; solid = C2 enabled, dashed = C2 disabled (<code>-XX:TieredStopAtLevel=1</code>, which drops C2 to nearly nothing). Summed across the parent and forked test JVMs, so it can exceed wall clock." \
    "$wall_spec")

  # CPU chart: metric (machine = solid, Maven-sum = dashed) × builder × fork (C2 on).
  cpu_spec=""
  for metric in machine maven; do
    for b in default smart; do
      for fk in $FORK_LEVELS; do
        dsh="solid"; mlabel="Machine"
        [ "$metric" = "maven" ] && { dsh="dash"; mlabel="Maven sum"; }
        cpu_spec="${cpu_spec}${cpu_spec:+~}$(fork_color "$b" "$fk");${dsh};${mlabel} · $(builder_label "$b") · $(fork_label "$fk")"
      done
    done
  done
  cpu_rows=()
  for t in 1 2 3 4 5 6 7 8 9 10; do
    declare -A MACH SUM
    for b in default smart; do
      for fk in $FORK_LEVELS; do
        st=$(extract_cpu_stats "report-${b}-T${t}-f${fk}.html")
        mm="null"; nn="null"
        [ -n "$st" ] && IFS=$'\t' read -r mm nn <<<"$st"
        MACH["$b$fk"]="${mm:-null}"; SUM["$b$fk"]="${nn:-null}"
      done
    done
    row="$t"
    for metric in machine maven; do
      for b in default smart; do
        for fk in $FORK_LEVELS; do
          if [ "$metric" = "machine" ]; then row="$row ${MACH[$b$fk]}"; else row="$row ${SUM[$b$fk]}"; fi
        done
      done
    done
    cpu_rows+=("$row")
    unset MACH SUM
  done
  CPU_CHART_SVG=$(printf '%s\n' "${cpu_rows[@]}" | emit_series_chart_svg \
    "CPU usage" "pct" "" "CPU usage by thread count and fork count" \
    "Average CPU usage vs. thread count (<code>-T</code>) at three fork counts: solid = whole machine (every process), dashed = the summed Maven JVMs (parent + forks). Both are a percentage of total machine capacity across all cores; colour = builder × <code>forkCount</code> (cool = Default, warm = Smart). Higher means more cores kept busy." \
    "$cpu_spec")
fi

# Page chrome, parameterised so the SAME generator produces every grid page; the
# header comment above lists the knobs. The defaults reproduce the builder × -T
# scaling grid (/scaling/, scaling-grid.yml); the reference grid (/reference/,
# publish-reference-reports.yml) is the same layout under its own title and
# heading, with SHOW_MVND=0 because generate-local-reports.ps1 skips the mvnd legs
# by design; and the fork-comparison page (/parallel/, fork-grid.yml) overrides the
# title, heading and intro and sets SHOW_NOCACHE_ROW=0 / SHOW_MVND=0, because it
# runs neither the cold-repository leg nor mvnd.
PAGE_TITLE="${PAGE_TITLE:-Maven build-performance examples}"
PAGE_HEADING="${PAGE_HEADING:-Build performance grid — parallel &amp; smart builder}"
# Every grid lives one level under the site root, so the back link is the hub.
BACK_HREF="${BACK_HREF:-../index.html}"
if [ -z "${PAGE_INTRO:-}" ]; then
  PAGE_INTRO='10-module reactor: core → 4 filler libs (18 s) + a 4-deep pipe chain (8 s
    each = the 32 s critical path) → app. The smart builder ranks modules by
    downstream chain length, so it starts the chain ahead of the cheap
    fillers.<br>
    Columns are headline metrics pulled from each report: cumulative JIT C2
    compilation, Maven dependency download time and GC time can exceed wall
    clock because they sum across parallel workers / JVMs.<br>
    Wall-clock percentages are relative to the <strong>Default builder ·
    -T1</strong> baseline (single-threaded), so lower is faster.<br>
    Each scenario is shown twice: the normal run, then the same run with the JVM'\''s
    <strong>C2 JIT tier disabled</strong> (<code>-XX:TieredStopAtLevel=1</code>,
    keeping only C1) on both the build and forked test JVMs — watch the JIT C2
    compilation column drop to nearly nothing.<br>
    The <strong>first row</strong> is the single-threaded default build run with
    <strong>no local dependency cache</strong> (an empty local repository, seeded
    with only the mvn-lens extension): every plugin and project dependency is
    downloaded during the build — compare its Maven downloads column with the
    warm-cache rows below, which all reuse the local repository.'
fi

{
  cat <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${PAGE_TITLE}</title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 64rem; margin: 3rem auto; padding: 0 1rem; line-height: 1.5; }
    h1 { margin-bottom: 0.25rem; }
    .meta { color: #666; font-size: 0.9rem; margin-bottom: 1.5rem; }
    table { border-collapse: collapse; width: 100%; margin: 1rem 0; }
    th, td { border: 1px solid #ddd; padding: 0.5rem 0.75rem; text-align: left; }
    th { background: #f6f8fa; }
    td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
    td.miss { color: #999; }
    .pct { color: #888; font-weight: normal; margin-left: 0.35rem; }
    a { color: #0366d6; text-decoration: none; }
    a:hover { text-decoration: underline; }
    .back { display: inline-block; margin-bottom: 1rem; }
    figure.chart { margin: 1.5rem 0; }
    figure.chart svg { width: 100%; height: auto; display: block; }
    figure.chart figcaption { color: #666; font-size: 0.85rem; margin-top: 0.5rem; }
    .yl { font-size: 11px; fill: #555; text-anchor: end; }
    .yr { font-size: 11px; fill: #555; text-anchor: start; }
    .xl { font-size: 11px; fill: #555; text-anchor: middle; }
    .axt { font-size: 12px; fill: #333; text-anchor: middle; }
    .lg { font-size: 12px; fill: #333; }
    .hit { cursor: help; }
    #chart-tip { position: fixed; z-index: 10; pointer-events: none; opacity: 0;
      background: #1b1f23; color: #fff; font-size: 12px; line-height: 1.3;
      padding: 4px 8px; border-radius: 4px; white-space: nowrap;
      box-shadow: 0 1px 4px rgba(0,0,0,0.3); transition: opacity 0.08s; }
  </style>
</head>
<body>
  <a class="back" href="${BACK_HREF}">← all reports</a>
  <h1>${PAGE_HEADING}</h1>
  <p class="meta">Run #${GITHUB_RUN_NUMBER:-?} · commit ${GITHUB_SHA:-?} · ${GITHUB_REF_NAME:-?}<br>
    ${PAGE_INTRO}</p>
  ${CHART_SVG}
  ${C2_CHART_SVG}
  ${CPU_CHART_SVG}
  <table>
    <thead><tr>
      <th>Report</th>
      <th class="num">Wall clock</th>
      <th class="num">Δ vs baseline</th>
      <th class="num">CPU</th>
      <th class="num">JIT C2 compilation</th>
      <th class="num">Maven downloads</th>
      <th class="num">GC</th>
    </tr></thead>
    <tbody>
EOF
  if [ -n "${FORK_LEVELS:-}" ]; then
    # Fork-comparison page: one row block per forkCount level (5 / 1 / 0), each
    # with the full Default & Smart × -T1..-T10 × C2 on/off grid — except forkCount=0,
    # which Surefire only permits at -T1 (no fork under a parallel reactor), so that
    # block holds just the four -T1 rows instead of a grid of "—" placeholders.
    for fk in $FORK_LEVELS; do
      flabel=$(fork_label "$fk")
      fk_threads="1 2 3 4 5 6 7 8 9 10"; [ "$fk" = "0" ] && fk_threads="1"
      for t in $fk_threads; do
        emit_row "report-default-T${t}-f${fk}.html"      "Default builder · -T${t} · ${flabel}"          "$BASELINE_WALL"
        emit_row "report-default-T${t}-f${fk}-noC2.html" "Default builder · -T${t} · ${flabel} · C2 off" "$BASELINE_WALL"
      done
      for t in $fk_threads; do
        emit_row "report-smart-T${t}-f${fk}.html"      "Smart builder · -T${t} · ${flabel}"          "$BASELINE_WALL"
        emit_row "report-smart-T${t}-f${fk}-noC2.html" "Smart builder · -T${t} · ${flabel} · C2 off" "$BASELINE_WALL"
      done
    done
  else
    if [ "${SHOW_NOCACHE_ROW:-1}" = "1" ]; then
      emit_row "report-default-T1-noCache.html" "Default builder · -T1 · no dependency cache" "$BASELINE_WALL"
    fi
    for t in 1 2 3 4 5 6 7 8 9 10; do
      emit_row "report-default-T${t}.html"      "Default builder · -T${t}"          "$BASELINE_WALL"
      emit_row "report-default-T${t}-noC2.html" "Default builder · -T${t} · C2 off" "$BASELINE_WALL"
    done
    for t in 1 2 3 4 5 6 7 8 9 10; do
      emit_row "report-smart-T${t}.html"      "Smart builder · -T${t}"          "$BASELINE_WALL"
      emit_row "report-smart-T${t}-noC2.html" "Smart builder · -T${t} · C2 off" "$BASELINE_WALL"
    done
    if [ "${SHOW_MVND:-1}" = "1" ]; then
      emit_row "report-mvnd.html"      "Maven Daemon (mvnd)"          "$BASELINE_WALL"
      emit_row "report-mvnd-noC2.html" "Maven Daemon (mvnd) · C2 off" "$BASELINE_WALL"
    fi
  fi
  cat <<'EOF'
    </tbody>
  </table>
  <p><a href="https://github.com/mvn-perf/mvn-perf-examples">mvn-perf-examples source on GitHub</a></p>
  <div id="chart-tip"></div>
  <script>
  // Instant, styled hover tooltip for the chart's data points: each .hit circle
  // carries its label in data-tip; we follow the cursor and flip near the edges.
  (function () {
    var tip = document.getElementById("chart-tip");
    if (!tip) return;
    function move(e) {
      var pad = 12, x = e.clientX + pad, y = e.clientY + pad;
      var w = tip.offsetWidth, h = tip.offsetHeight;
      if (x + w > window.innerWidth - 4) x = e.clientX - w - pad;
      if (y + h > window.innerHeight - 4) y = e.clientY - h - pad;
      tip.style.left = x + "px";
      tip.style.top = y + "px";
    }
    function show(e) {
      var t = e.target.getAttribute("data-tip");
      if (!t) return;
      tip.textContent = t;
      tip.style.opacity = "1";
      move(e);
    }
    function hide() { tip.style.opacity = "0"; }
    var hits = document.querySelectorAll(".hit");
    for (var i = 0; i < hits.length; i++) {
      hits[i].addEventListener("mouseenter", show);
      hits[i].addEventListener("mousemove", move);
      hits[i].addEventListener("mouseleave", hide);
    }
  })();
  </script>
</body>
</html>
EOF
} > index.html
