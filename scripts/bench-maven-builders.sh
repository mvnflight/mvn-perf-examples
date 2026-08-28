#!/usr/bin/env bash
#
# bench-maven-builders.sh — benchmark `mvn -T` (default multithreaded builder)
# vs. the Takari smart builder across a range of thread counts, scrape each
# build's wall-clock time from Maven's own logs, write a tidy CSV, and render a
# self-contained HTML page whose dual-axis chart (wall clock + % of baseline)
# reproduces ~/Downloads/graphic.png.
#
# See scripts/README.md for usage.
#
# macOS-first: stays bash-3.2 safe (no `declare -A`, no `mapfile`), avoids
# GNU-isms (no `date +%N`, no `grep -P`, no `sed -i` without a backup suffix).
# Pivoting is done in awk, not associative arrays.

set -uo pipefail

# --- tiny helpers -----------------------------------------------------------
PROG="$(basename "$0")"
info() { printf '%s\n' "$*" >&2; }
warn() { printf '\033[33m%s\033[0m\n' "warning: $*" >&2; }
die()  { printf '\033[31m%s\033[0m\n' "error: $*" >&2; exit 1; }

# Portable absolute path (realpath may be absent on macOS).
abspath() {
  if [ -d "$1" ]; then
    ( cd "$1" && pwd )
  else
    ( cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd)" "$(basename "$1")" )
  fi
}

host_cpus() {
  if command -v sysctl >/dev/null 2>&1 && sysctl -n hw.ncpu >/dev/null 2>&1; then
    sysctl -n hw.ncpu
  elif command -v nproc >/dev/null 2>&1; then
    nproc
  else
    echo "?"
  fi
}

usage() {
  cat >&2 <<EOF
$PROG — benchmark mvn build on a project.

Usage:
  $PROG <source> <max-threads> <csv-path> [options]

Positional (required):
  source        HTTP(S)/git/ssh URL or scp-style git\@host:org/repo.git  -> cloned;
                OR a path to an existing local Git repo                  -> used in place.
  max-threads   Non-negative integer N; the matrix iterates t = 0..N.
  csv-path      Where the results CSV is written (parent dir created if needed).

Options:
  --c2-off                  Also run each build with C2 JIT disabled
                            (-XX:TieredStopAtLevel=1); adds the dashed curves.
  --no-mvnlens              Skip the mvn-lens on/off dimension. By default each
                            config is run twice — once without and once with the
                            mvn-lens extension — to measure its build overhead.
  --mvnlens-version <v>     mvn-lens-extension version to enable (default:
                            0.1.0-SNAPSHOT; must be resolvable — see --settings).
  --settings <path>         Maven settings file passed as -s to every build. Needed
                            when the benchmarked project cannot otherwise resolve
                            the mvn-lens extension (e.g. the Central snapshot repo
                            in this repo's .mvn/settings.xml).
  --goals "<goals>"         Maven goals/phases to time (default: "clean package").
  --html <path>             HTML output path (default: <csv-path> with .html).
  --runs <k>                Repeat each config k times; chart/table use the median.
  --workdir <dir>           Clone mode only: where to clone (default: mktemp -d).
  --keep                    Keep the clone (clone mode) and per-run logs.
  --ref <branch/tag/sha>    Clone mode: checkout this ref. Local mode: ignored.
  --mvn <cmd>               Force a Maven command (default: ./mvnw if present, else mvn).
  --takari-version <v>      Takari smart-builder version to inject (default: 1.1.0).
  --baseline <default-T0|default-T1>
                            Which build is 100% on the right axis (default: default-T0).
  --from-csv                Skip cloning/building; just regenerate HTML from the CSV.
  -h, --help                Show this help.

Examples:
  $PROG https://github.com/acme/widgets.git 8 ./out/widgets.csv
  $PROG https://github.com/acme/widgets.git 10 ./out/widgets.csv --c2-off --keep
  $PROG ./my-local-repo 6 ./out/local.csv --runs 3 --goals "clean verify"
  $PROG - - ./out/widgets.csv --from-csv
  $PROG https://github.com/acme/widgets.git 4 ./out/w.csv --settings "\$PWD/.mvn/settings.xml"
EOF
  exit "${1:-2}"
}

# --- argument parsing -------------------------------------------------------
C2_OFF=0
MVNLENS=1
MVNLENS_VERSION="0.1.0-SNAPSHOT"
SETTINGS=""
GOALS="clean package"
HTML=""
RUNS=1
WORKDIR=""
KEEP=0
REF=""
MVN_OVERRIDE=""
TAKARI_VERSION="1.1.0"
BASELINE="default-T0"
FROM_CSV=0
REACTOR_LIST="from CSV"
REACTOR_SUMMARY="from CSV"

POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --c2-off)            C2_OFF=1; shift ;;
    --no-mvnlens)      MVNLENS=0; shift ;;
    --mvnlens-version) MVNLENS_VERSION="${2:?--mvnlens-version needs a value}"; shift 2 ;;
    --settings)       SETTINGS="${2:?--settings needs a value}"; shift 2 ;;
    --goals)          GOALS="${2:?--goals needs a value}"; shift 2 ;;
    --html)           HTML="${2:?--html needs a value}"; shift 2 ;;
    --runs)           RUNS="${2:?--runs needs a value}"; shift 2 ;;
    --workdir)        WORKDIR="${2:?--workdir needs a value}"; shift 2 ;;
    --keep)           KEEP=1; shift ;;
    --ref)            REF="${2:?--ref needs a value}"; shift 2 ;;
    --mvn)            MVN_OVERRIDE="${2:?--mvn needs a value}"; shift 2 ;;
    --takari-version) TAKARI_VERSION="${2:?--takari-version needs a value}"; shift 2 ;;
    --baseline)       BASELINE="${2:?--baseline needs a value}"; shift 2 ;;
    --from-csv)       FROM_CSV=1; shift ;;
    -h|--help)        usage 0 ;;
    --)               shift; while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done ;;
    -)                POSITIONAL+=("$1"); shift ;;   # bare "-" placeholder (e.g. --from-csv)
    -*)               die "unknown option: $1 (try --help)" ;;
    *)                POSITIONAL+=("$1"); shift ;;
  esac
done

[ "${#POSITIONAL[@]}" -ge 3 ] || usage 2
SRC="${POSITIONAL[0]}"
MAXTHREADS="${POSITIONAL[1]}"
CSV="${POSITIONAL[2]}"

case "$BASELINE" in
  default-T0) BASELINE_T=0 ;;
  default-T1) BASELINE_T=1 ;;
  *) die "--baseline must be default-T0 or default-T1 (got: $BASELINE)" ;;
esac

case "$RUNS" in
  ''|*[!0-9]*) die "--runs must be a positive integer (got: $RUNS)" ;;
esac
[ "$RUNS" -ge 1 ] || die "--runs must be >= 1"

# Resolve the HTML output path (strip a trailing .csv, append .html).
if [ -z "$HTML" ]; then
  case "$CSV" in
    *.csv) HTML="${CSV%.csv}.html" ;;
    *)     HTML="${CSV}.html" ;;
  esac
fi

# mkdir -p the parent dirs of the CSV/HTML.
mkdir -p "$(dirname "$CSV")" "$(dirname "$HTML")" || die "cannot create output directories"

# Saved mvn-lens dashboards live next to the HTML so the relative links in the
# page resolve; REPORT_REL_DIR is the href prefix used from the page.
REPORT_REL_DIR="mvnlens-reports"
REPORTDIR="$(dirname "$HTML")/$REPORT_REL_DIR"

# ============================================================================
# Parse Maven's "Total time:" summary line into seconds (D7).
# stdin: a log file path is passed as $1; prints "<seconds>\t<raw>" or nothing.
# Handles: "12.345 s", "01:23 min", "1:02 h", "1 d 02:03 h".
# ============================================================================
parse_total_time() {
  awk '
    /Total time:/ { raw = $0 }
    END {
      if (raw == "") exit
      s = raw
      gsub(/\r/, "", s)
      sub(/.*Total time:[[:space:]]*/, "", s)
      rawout = s
      days = 0
      if (s ~ /^[0-9]+[[:space:]]*d[[:space:]]/) {
        match(s, /^[0-9]+/); days = substr(s, 1, RLENGTH) + 0
        sub(/^[0-9]+[[:space:]]*d[[:space:]]*/, "", s)
      }
      sec = ""
      if (s ~ /[0-9.]+[[:space:]]*s/)        { v = s; sub(/[[:space:]]*s.*/, "", v); sec = v + 0 }
      else if (s ~ /:[0-9]+[[:space:]]*min/) { split(s, a, ":"); sec = (a[1] + 0) * 60 + (a[2] + 0) }
      else if (s ~ /:[0-9]+[[:space:]]*h/)   { split(s, a, ":"); sec = (a[1] + 0) * 3600 + (a[2] + 0) * 60 }
      if (sec == "") exit
      sec = sec + days * 86400
      printf "%s\t%s\n", sec, rawout
    }
  ' "$1"
}

# ============================================================================
# Chart helper — a trimmed, seconds-native copy of emit_chart_svg from this
# repo's grid-index generator (.github/scripts/gen-grid-index.sh): the two now
# live side by side, so keep an eye on them drifting apart. Dual Y axis (wall clock left, % of
# baseline right), x starts at 0, dashed series are conditional.
#
# Each builder (Default=blue, Smart=orange) gets a SOLID and a DASHED curve. The
# solid/dashed dimension is chosen by the caller: by default it is mvn-lens
# off (solid) vs on (dashed) — the gap is the extension's overhead — or, in
# legacy --no-mvnlens mode, C2 on (solid) vs off (dashed).
#
# Args: $1 = baseline seconds ("" to omit the right axis); $2 = has_dashed (1/0);
#       $3 = x-axis max (forces ticks 0..N even when top points are missing);
#       $4..$7 = legend/tooltip labels for d-solid, s-solid, d-dashed, s-dashed;
#       $8 = caption sentence describing the solid/dashed split.
# Reads "thread d_solid s_solid d_dashed s_dashed" lines (seconds; blank/"null"
# = missing point). Prints a <figure>, or nothing when no data.
# ============================================================================
emit_chart_svg() {
  awk -v baseline="${1:-}" -v hasoff="${2:-0}" -v xmaxforce="${3:-}" \
      -v lblDS="${4:-Default &middot; C2 on}" -v lblSS="${5:-Smart &middot; C2 on}" \
      -v lblDD="${6:-Default &middot; C2 off}" -v lblSD="${7:-Smart &middot; C2 off}" \
      -v capSuffix="${8:-}" '
  function x(t){ return ml + (t-xmin)/(xmax-xmin)*pw }
  function y(v){ return mt + ph - (v/niceMax)*ph }
  function lab(v){ if (v==0) return "0"; if (v<10) return sprintf("%.1f s", v); return sprintf("%.0f s", v) }
  function tip(series,t,v,  s){ s=series ", T" t ": " lab(v+0); if (baseline!="" && baseline!="null" && baseline+0>0) s=s sprintf(" (%.0f%% of baseline)", v/(baseline+0)*100); return s }
  BEGIN { W=720; H=380; ml=72; mr=210; mt=28; mb=52; xmin=0; ymax=0; n=0; xmaxData=0 }
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
    xmax = xmaxData
    if (xmaxforce != "" && xmaxforce+0 > xmax) xmax = xmaxforce+0
    if (xmax < 1) xmax = 1
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

    # Right y-axis: same pixel scale as a percentage of the baseline (100% = baseline).
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

    dpoly=""; spoly=""; dnpoly=""; snpoly=""; dcirc=""; scirc=""; dncirc=""; sncirc=""; hit=""
    for (i=0;i<n;i++){
      xt=x(tt[i])
      if (dd[i]!="" && dd[i]!="null"){ yp=y(dd[i]+0); dpoly=dpoly sprintf("%.1f,%.1f ",xt,yp); dcirc=dcirc sprintf("<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3.5\" fill=\"#0366d6\"/>",xt,yp); hit=hit sprintf("<circle class=\"hit\" cx=\"%.1f\" cy=\"%.1f\" r=\"6\" fill=\"none\" pointer-events=\"all\" data-tip=\"%s\"/>",xt,yp,tip(lblDS,tt[i],dd[i]+0)) }
      if (ss[i]!="" && ss[i]!="null"){ yp=y(ss[i]+0); spoly=spoly sprintf("%.1f,%.1f ",xt,yp); scirc=scirc sprintf("<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3.5\" fill=\"#e8590c\"/>",xt,yp); hit=hit sprintf("<circle class=\"hit\" cx=\"%.1f\" cy=\"%.1f\" r=\"6\" fill=\"none\" pointer-events=\"all\" data-tip=\"%s\"/>",xt,yp,tip(lblSS,tt[i],ss[i]+0)) }
      if (dn[i]!="" && dn[i]!="null"){ yp=y(dn[i]+0); dnpoly=dnpoly sprintf("%.1f,%.1f ",xt,yp); dncirc=dncirc sprintf("<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3\" fill=\"#fff\" stroke=\"#0366d6\" stroke-width=\"1.5\"/>",xt,yp); hit=hit sprintf("<circle class=\"hit\" cx=\"%.1f\" cy=\"%.1f\" r=\"6\" fill=\"none\" pointer-events=\"all\" data-tip=\"%s\"/>",xt,yp,tip(lblDD,tt[i],dn[i]+0)) }
      if (sn[i]!="" && sn[i]!="null"){ yp=y(sn[i]+0); snpoly=snpoly sprintf("%.1f,%.1f ",xt,yp); sncirc=sncirc sprintf("<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3\" fill=\"#fff\" stroke=\"#e8590c\" stroke-width=\"1.5\"/>",xt,yp); hit=hit sprintf("<circle class=\"hit\" cx=\"%.1f\" cy=\"%.1f\" r=\"6\" fill=\"none\" pointer-events=\"all\" data-tip=\"%s\"/>",xt,yp,tip(lblSD,tt[i],sn[i]+0)) }
    }
    if (dpoly!="")  printf "<polyline fill=\"none\" stroke=\"#0366d6\" stroke-width=\"2\" points=\"%s\"/>\n", dpoly
    if (dnpoly!="") printf "<polyline fill=\"none\" stroke=\"#0366d6\" stroke-width=\"2\" stroke-dasharray=\"5 4\" points=\"%s\"/>\n", dnpoly
    if (spoly!="")  printf "<polyline fill=\"none\" stroke=\"#e8590c\" stroke-width=\"2\" points=\"%s\"/>\n", spoly
    if (snpoly!="") printf "<polyline fill=\"none\" stroke=\"#e8590c\" stroke-width=\"2\" stroke-dasharray=\"5 4\" points=\"%s\"/>\n", snpoly
    print dcirc; print scirc; print dncirc; print sncirc
    # Transparent, larger hit targets on top so hovering near a point reveals its
    # (thread, wall-clock) values via the data-tip tooltip (shared chart JS below).
    print hit

    lx=ml+pw+78; ly=mt+10; row=0
    printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#0366d6\" stroke-width=\"3\"/>\n", lx, ly+row*22, lx+14, ly+row*22
    printf "<text x=\"%.1f\" y=\"%.1f\" class=\"lg\">%s</text>\n", lx+20, ly+row*22+4, lblDS; row++
    printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#e8590c\" stroke-width=\"3\"/>\n", lx, ly+row*22, lx+14, ly+row*22
    printf "<text x=\"%.1f\" y=\"%.1f\" class=\"lg\">%s</text>\n", lx+20, ly+row*22+4, lblSS; row++
    if (hasoff+0==1) {
      printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#0366d6\" stroke-width=\"3\" stroke-dasharray=\"5 4\"/>\n", lx, ly+row*22, lx+14, ly+row*22
      printf "<text x=\"%.1f\" y=\"%.1f\" class=\"lg\">%s</text>\n", lx+20, ly+row*22+4, lblDD; row++
      printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#e8590c\" stroke-width=\"3\" stroke-dasharray=\"5 4\"/>\n", lx, ly+row*22, lx+14, ly+row*22
      printf "<text x=\"%.1f\" y=\"%.1f\" class=\"lg\">%s</text>\n", lx+20, ly+row*22+4, lblSD; row++
    }
    print "</svg>"
    cap = "Wall-clock time vs. thread count (<code>-T</code>), Default vs. Takari Smart builder. <code>T0</code> = no <code>-T</code> flag (legacy single-threaded build)."
    if (hasoff+0==1 && capSuffix!="") cap = cap " " capSuffix
    cap = cap " Lower is faster."
    print "<figcaption>" cap "</figcaption>"
    print "</figure>"
  }
  '
}

# ============================================================================
# Render the full HTML page from the CSV (used by the normal run and --from-csv).
# Uses the globals: CSV, HTML, HAS_C2OFF, BASELINE_T, BASELINE, and the META_* run
# metadata. Pivoting (median across --runs repeats) is done entirely in awk.
# ============================================================================
# Shared awk median() function text, prepended to the pivot programs below.
MEDIAN_AWK='
  function median(s,   a,nn,i,j,tmp){
    nn=split(s,a," ")
    if(nn==0) return ""
    for(i=2;i<=nn;i++){ tmp=a[i]; j=i-1; while(j>=1 && a[j]+0>tmp+0){ a[j+1]=a[j]; j-- } a[j+1]=tmp }
    if(nn%2==1) return a[(nn+1)/2]
    return (a[nn/2]+a[nn/2+1])/2
  }'

generate_html() {
  [ -f "$CSV" ] || die "CSV not found: $CSV"

  # Baseline wall clock (seconds) = default builder, C2 on, mvn-lens off, at BASELINE_T threads.
  local base
  base=$(awk -F, -v bt="$BASELINE_T" "$MEDIAN_AWK"'
    NR==1 { next }
    $2=="default" && $3=="on" && $4=="off" && ($1+0)==bt && $6=="SUCCESS" && $7!="" { v=v " " $7 }
    END { if (v!="") printf "%.6f", median(v) }
  ' "$CSV")

  # Max thread count present in the CSV (forces the chart x-axis ticks 0..N).
  local maxn
  maxn=$(awk -F, 'NR>1 && ($1+0)>m { m=$1+0 } END { print m+0 }' "$CSV")

  # Pick the solid/dashed dimension: mvn-lens off/on (overhead) by default, or
  # C2 on/off in legacy --no-mvnlens mode. The "other" dimension is pinned.
  local sec solid dash has_dash lblDS lblSS lblDD lblSD cap_suffix
  if [ "$HAS_MVNLENS" = "1" ]; then
    sec="mvnlens"; solid="off"; dash="on"; has_dash="$HAS_MVNLENS"
    lblDS="Default &middot; no mvn-lens"; lblSS="Smart &middot; no mvn-lens"
    lblDD="Default &middot; mvn-lens";    lblSD="Smart &middot; mvn-lens"
    cap_suffix="Solid = build without the mvn-lens extension, dashed = with it; the dashed&ndash;solid gap is the profiler's overhead."
  else
    sec="c2"; solid="on"; dash="off"; has_dash="$HAS_C2OFF"
    lblDS="Default &middot; C2 on"; lblSS="Smart &middot; C2 on"
    lblDD="Default &middot; C2 off"; lblSD="Smart &middot; C2 off"
    cap_suffix="Solid = C2 JIT enabled, dashed = C2 disabled (<code>-XX:TieredStopAtLevel=1</code>; best-effort on forked test JVMs)."
  fi

  # Chart feed: one "t d_solid s_solid d_dashed s_dashed" line per thread (median
  # seconds), pinning the non-charted dimension (c2=on when secondary=mvn-lens;
  # mvnlens=off when secondary=c2).
  local chart_svg
  chart_svg=$(awk -F, -v sec="$sec" -v solid="$solid" -v dash="$dash" "$MEDIAN_AWK"'
    NR==1 { next }
    { t=$1+0; b=$2; cc=$3; mf=$4; st=$6; w=$7
      if (sec=="mvnlens") { if (cc!="on") next; dim=mf } else { if (mf!="off") next; dim=cc }
      if (st=="SUCCESS" && w!="") vals[t SUBSEP b SUBSEP dim] = vals[t SUBSEP b SUBSEP dim] " " w
      if (t>maxt) maxt=t }
    function med(t,b,d,  k){ k=t SUBSEP b SUBSEP d; return (k in vals) ? median(vals[k]) : "null" }
    END {
      for (t=0;t<=maxt;t++)
        printf "%d %s %s %s %s\n", t, med(t,"default",solid), med(t,"smart",solid), med(t,"default",dash), med(t,"smart",dash)
    }
  ' "$CSV" | emit_chart_svg "$base" "$has_dash" "$maxn" "$lblDS" "$lblSS" "$lblDD" "$lblSD" "$cap_suffix")

  # Median mvn-lens overhead across thread counts (default builder, C2 on) — the
  # headline number, shown in the intro when the mvn-lens dimension is present.
  local overhead_note=""
  if [ "$HAS_MVNLENS" = "1" ]; then
    overhead_note=$(awk -F, "$MEDIAN_AWK"'
      NR==1 { next }
      { t=$1+0; b=$2; cc=$3; mf=$4; st=$6; w=$7
        if (b!="default" || cc!="on") next
        if (st=="SUCCESS" && w!="") vals[t SUBSEP mf] = vals[t SUBSEP mf] " " w
        if (t>maxt) maxt=t }
      END {
        np=0
        for (t=0;t<=maxt;t++){
          ko=t SUBSEP "off"; kn=t SUBSEP "on"
          if ((ko in vals) && (kn in vals)) {
            off=median(vals[ko]); on=median(vals[kn])
            if (off+0>0) { p[np]=(on-off)/off*100; np++ }
          }
        }
        if (np==0) exit
        for (i=1;i<np;i++){ tmp=p[i]; j=i-1; while(j>=0 && p[j]>tmp){ p[j+1]=p[j]; j-- } p[j+1]=tmp }
        med = (np%2==1) ? p[int((np-1)/2)] : (p[np/2-1]+p[np/2])/2
        printf "%+.0f%% across T0&ndash;T%d (%+.0f%% to %+.0f%%)", med, maxt, p[0], p[np-1]
      }
    ' "$CSV")
  fi

  # Results table rows (median per threads x builder x c2 x mvn-lens). When the
  # mvn-lens dimension is present, extra mvn-lens / overhead / report columns
  # are emitted; otherwise the legacy 6-column layout is kept.
  local table_rows
  table_rows=$(awk -F, -v baseline="$base" -v hasmf="$HAS_MVNLENS" "$MEDIAN_AWK"'
    NR==1 { next }
    { t=$1+0; b=$2; cc=$3; mf=$4; st=$6; w=$7; rep=$10
      k=t SUBSEP b SUBSEP cc SUBSEP mf
      present[k]=1; if (t>maxt) maxt=t
      if (st=="SUCCESS" && w!="") { vals[k]=vals[k] " " w; ok[k]=1 }
      if (rep!="" && rep!="null") repf[k]=rep }
    END {
      for (t=0;t<=maxt;t++)
        for (bi=1;bi<=2;bi++) {
          b=(bi==1)?"default":"smart"; blabel=(bi==1)?"Default":"Smart"
          for (ci=1;ci<=2;ci++) {
            cc=(ci==1)?"on":"off"
            for (mi=1;mi<=2;mi++) {
              mf=(mi==1)?"off":"on"; k=t SUBSEP b SUBSEP cc SUBSEP mf
              if (!(k in present)) continue
              over="&mdash;"; report="&mdash;"
              if (k in ok) { m=median(vals[k]); wall=sprintf("%.1f s", m); pct=(baseline!="" && baseline+0>0)?sprintf("%.0f%%", m/(baseline+0)*100):"&mdash;"; status="SUCCESS" }
              else { m=""; wall="&mdash;"; pct="&mdash;"; status="FAILURE" }
              if (mf=="on") {
                offk=t SUBSEP b SUBSEP cc SUBSEP "off"
                if ((k in ok) && (offk in ok)) {
                  om=median(vals[offk]); d=m-om
                  over=(om+0>0)?sprintf("%+.1f s (%+.0f%%)", d, d/om*100):sprintf("%+.1f s", d)
                }
                if (k in repf) report=sprintf("<a href=\"%s\">view</a>", repf[k])
              }
              if (hasmf+0==1)
                printf "      <tr><td class=\"num\">%d</td><td>%s</td><td>%s</td><td>%s</td><td class=\"num\">%s</td><td class=\"num\">%s</td><td class=\"num\">%s</td><td>%s</td><td>%s</td></tr>\n", t, blabel, cc, mf, wall, pct, over, status, report
              else
                printf "      <tr><td class=\"num\">%d</td><td>%s</td><td>%s</td><td class=\"num\">%s</td><td class=\"num\">%s</td><td>%s</td></tr>\n", t, blabel, cc, wall, pct, status
            }
          }
        }
    }
  ' "$CSV")

  # Table header matches the column set chosen above.
  local table_head
  if [ "$HAS_MVNLENS" = "1" ]; then
    table_head='      <th class="num">Threads (-T)</th>
      <th>Builder</th>
      <th>C2 JIT</th>
      <th>mvn-lens</th>
      <th class="num">Wall clock</th>
      <th class="num">% of baseline</th>
      <th class="num">Overhead</th>
      <th>Status</th>
      <th>Report</th>'
  else
    table_head='      <th class="num">Threads (-T)</th>
      <th>Builder</th>
      <th>C2 JIT</th>
      <th class="num">Wall clock</th>
      <th class="num">% of baseline</th>
      <th>Status</th>'
  fi

  # Optional intro paragraph that frames the mvn-lens overhead measurement.
  local mvnlens_intro=""
  if [ "$HAS_MVNLENS" = "1" ]; then
    mvnlens_intro="  <p class=\"meta\">
    <strong>mvn-lens extension overhead.</strong> Every configuration is built twice &mdash; once without and once with the
    <a href=\"https://central.sonatype.com/repository/maven-snapshots/io/github/mvn-perf/mvn-lens-extension/${MVNLENS_VERSION}/\">mvn-lens</a> JFR profiler (<code>io.github.mvn-perf:mvn-lens-extension:${MVNLENS_VERSION}</code>).
    Solid curves are the clean build; dashed curves add mvn-lens, so the gap between them is the profiler's build overhead.${overhead_note:+ Median overhead: <strong>${overhead_note}</strong>.}
    The <em>Report</em> column links each build's mvn-lens dashboard.
  </p>"
  fi

  local cpus; cpus="$(host_cpus)"
  local now;  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  {
    cat <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Maven build benchmark on ${META_SOURCE}</title>
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
  <h1>Maven build benchmark on $(echo "${META_SOURCE}" | sed -e 's_https://github.com/__')</h1>
  <p class="meta">
    Source: <a href="${META_SOURCE}"><code>${META_SOURCE}</code></a>${META_REF:+ · ref <code>${META_REF}</code>}.
    <details><summary>$(echo "${REACTOR_LIST}" | head -1 | cut -d '[' -f 1): $(echo "${REACTOR_LIST}" | wc -l) modules, packagings = ${REACTOR_SUMMARY}</summary>

<pre>${REACTOR_LIST}</pre>
    </details><br>
    mvn goals: <code>${META_GOALS}</code> · runs ${RUNS} · ${cpus} CPUs<br>
    ${META_MVN}<br>
    ${META_JAVA}<br>
    generated ${now}
  </p>
  <p class="meta">
    <strong>mvn -T</strong> test with default builder vs. <strong>Takari smart</strong> (<code>-b smart</code>), wall-clock time
    across thread counts. <code>T0</code> is the plain build with no <code>-T</code>
    flag; the right axis shows each point as a percentage of the
    <strong>${BASELINE}</strong> baseline.
  </p>
${mvnlens_intro}
  ${chart_svg}
  <table>
    <thead><tr>
${table_head}
    </tr></thead>
    <tbody>
${table_rows}
    </tbody>
  </table>
  <p class="meta">
EOF
    if [ "$HAS_MVNLENS" = "1" ]; then
      printf '    Each config is built without the mvn-lens extension (solid) and with it (dashed);\n'
      printf '    the dashed&ndash;solid gap is the profiler overhead. The <em>Overhead</em> column is the\n'
      printf '    extra wall-clock time the extension adds vs. the same config without it, and <em>Report</em>\n'
      printf '    links the saved mvn-lens dashboard for that build.<br>\n'
    fi
    if [ "$HAS_C2OFF" = "1" ]; then
      printf '    Solid = C2 JIT enabled, dashed = C2 disabled (<code>-XX:TieredStopAtLevel=1</code>).\n'
      printf '    C2-off reliably affects the build JVM; forked test JVMs only inherit it when the\n'
      printf '    project passes <code>MAVEN_OPTS</code>/argLine through, so the dashed curves are best-effort.<br>\n'
    fi
    if [ "${META_SINGLE_MODULE:-0}" = "1" ]; then
      printf '    This project looks single-module, so <code>-T</code> and the smart builder cannot\n'
      printf '    parallelize — expect flat, overlapping curves.<br>\n'
    fi
    cat <<'EOF'
    Build durations are scraped from Maven's own <code>Total time:</code> line.
  </p>
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
  } > "$HTML"

  info "HTML written: $HTML"
}

# ============================================================================
# --from-csv: regenerate the HTML and stop.
# ============================================================================
if [ "$FROM_CSV" = "1" ]; then
  [ -f "$CSV" ] || die "--from-csv: CSV not found: $CSV"
  # Detect the dimensions present so the chart/table match the data: any c2=off
  # rows draw the C2 dashed curves; any mvnlens=on rows switch to the overhead view.
  HAS_C2OFF=$(awk -F, 'NR>1 && $3=="off" { f=1 } END { print (f?1:0) }' "$CSV")
  HAS_MVNLENS=$(awk -F, 'NR>1 && $4=="on" { f=1 } END { print (f?1:0) }' "$CSV")
  META_SOURCE="(from CSV)"
  META_REF=""
  META_GOALS=$(awk -F, 'NR==2 { print $5; exit }' "$CSV"); META_GOALS="${META_GOALS:-?}"
  META_SINGLE_MODULE=0
  META_MVN="mvn: n/a"
  META_JAVA="java: n/a"
  generate_html
  exit 0
fi

# ============================================================================
# Normal run — preflight, resolve source, inject takari, warm up, run matrix.
# ============================================================================

# max-threads must be a non-negative integer.
case "$MAXTHREADS" in
  ''|*[!0-9]*) die "max-threads must be a non-negative integer (got: $MAXTHREADS)" ;;
esac
N="$MAXTHREADS"

# Preflight: required tools (the Maven launcher is checked after we know ROOT).
command -v git  >/dev/null 2>&1 || die "git not found on PATH"
command -v java >/dev/null 2>&1 || die "java not found on PATH"
command -v awk  >/dev/null 2>&1 || die "awk not found on PATH"
command -v sed  >/dev/null 2>&1 || die "sed not found on PATH"
case "$(bash --version 2>/dev/null | head -1)" in
  *version\ [123].*) warn "/bin/bash looks older than 4 — this script is written to be bash-3.2 safe." ;;
esac

# Tokenise the goals string into an array (bash-3.2 safe).
read -ra GOALS_ARR <<< "$GOALS"
[ "${#GOALS_ARR[@]}" -ge 1 ] || die "--goals is empty"

# --- cleanup trap state -----------------------------------------------------
MODE=""            # clone | local
EXT=""             # path to the (possibly injected) .mvn/extensions.xml
EXT_BASE=""        # temp copy of the takari "base" extensions.xml (mvn-lens off)
MVN_DIR=""         # path to <root>/.mvn
SNAPSHOT=""        # backup of a pre-existing extensions.xml (local mode)
HAD_EXT=0          # 1 if the repo already had an extensions.xml
MADE_MVN_DIR=0     # 1 if we created <root>/.mvn

cleanup() {
  if [ "$MODE" = "local" ] && [ -n "$EXT" ]; then
    if [ "$HAD_EXT" = "1" ]; then
      [ -f "$SNAPSHOT" ] && mv "$SNAPSHOT" "$EXT"
    else
      rm -f "$EXT"
      [ "$MADE_MVN_DIR" = "1" ] && rmdir "$MVN_DIR" 2>/dev/null
    fi
    [ -n "$SNAPSHOT" ] && rm -f "$SNAPSHOT" 2>/dev/null
  fi
  [ -n "$EXT_BASE" ] && rm -f "$EXT_BASE" 2>/dev/null
  if [ "$MODE" = "clone" ] && [ "$KEEP" != "1" ] && [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT INT TERM

# --- 7.2 resolve the source -------------------------------------------------
case "$SRC" in
  http://*|https://*|git://*|ssh://*|*@*:*)
    MODE=clone
    [ -n "$WORKDIR" ] || WORKDIR="$(mktemp -d)"
    mkdir -p "$WORKDIR"
    WORKDIR="$(abspath "$WORKDIR")"
    REPO="$WORKDIR/repo"
    info "Cloning $SRC -> $REPO"
    if [ -n "$REF" ]; then
      # Shallow --branch only accepts branch/tag names; fall back to a full clone
      # + checkout when --ref is a SHA.
      if ! git clone --depth 1 --branch "$REF" "$SRC" "$REPO" 2>/dev/null; then
        git clone "$SRC" "$REPO" || die "git clone failed"
        ( cd "$REPO" && git checkout "$REF" ) || die "git checkout $REF failed"
      fi
    else
      git clone --depth 1 "$SRC" "$REPO" || die "git clone failed"
    fi
    ;;
  *)
    MODE=local
    [ -d "$SRC" ] || die "not a URL and not an existing directory: $SRC"
    [ -d "$SRC/.git" ] || warn "$SRC has no .git — using it anyway as a local project"
    REPO="$(abspath "$SRC")"
    [ -n "$REF" ] && warn "--ref is ignored in local mode (the repo's current checkout is used)"
    warn "local mode: repeated '${GOALS_ARR[*]}' will delete the repo's target/ dirs, as any build does"
    ;;
esac

# Build root = the top-level pom.xml under REPO.
ROOT="$REPO"
[ -f "$ROOT/pom.xml" ] || die "no pom.xml at the build root: $ROOT"

# --- resolve the Maven launcher (preflight #2) ------------------------------
if [ -n "$MVN_OVERRIDE" ]; then
  MVN_CMD="$MVN_OVERRIDE"
elif [ -x "$ROOT/mvnw" ]; then
  MVN_CMD="$ROOT/mvnw"
elif [ -f "$ROOT/mvnw" ]; then
  MVN_CMD="bash $ROOT/mvnw"
else
  command -v mvn >/dev/null 2>&1 || die "no ./mvnw in the project and no mvn on PATH"
  MVN_CMD="mvn"
fi

# Optional -s <settings> for every build. run_mvn cds into the build root, so the
# path is absolutised here; a project cloned into a scratch dir has no settings of
# its own, and a core extension published only to a snapshot repository can be
# resolved *only* from a settings file (Maven's bootstrap reads extensions.xml
# before the POM, and the built-in `central` has snapshots disabled).
# ${arr[@]+"${arr[@]}"} rather than a bare "${arr[@]}": under `set -u`, bash 3.2
# treats an empty array expansion as an unbound variable.
SETTINGS_ARR=()
if [ -n "$SETTINGS" ]; then
  [ -f "$SETTINGS" ] || die "--settings: no such file: $SETTINGS"
  SETTINGS="$(abspath "$SETTINGS")"
  SETTINGS_ARR=( -s "$SETTINGS" )
  info "passing -s $SETTINGS to every build"
fi

# Run Maven from the build root with batch / no-transfer-progress for clean logs.
run_mvn() {
  ( cd "$ROOT" && $MVN_CMD -B -ntp ${SETTINGS_ARR[@]+"${SETTINGS_ARR[@]}"} "$@" )
}

# Capture run metadata for the HTML.
META_SOURCE="$SRC"
META_REF="$REF"
META_GOALS="$GOALS"
META_MVN="$( ( $MVN_CMD -v 2>/dev/null | head -1 ) 2>/dev/null )"; META_MVN="${META_MVN:-mvn: ?}"
META_JAVA="$( java -version 2>&1 | head -1 )"; META_JAVA="${META_JAVA:-java: ?}"
# grep -c already prints "0" (and exits 1) when there is no match, so do NOT chain
# `|| echo 0` — that would emit a second "0" and corrupt the integer test below.
ROOT_MODULE_COUNT="$(grep -c '<module>' "$ROOT/pom.xml" 2>/dev/null)"
case "${ROOT_MODULE_COUNT:-}" in ''|*[!0-9]*) ROOT_MODULE_COUNT=0 ;; esac
if [ "$ROOT_MODULE_COUNT" -le 0 ]; then
  META_SINGLE_MODULE=1
else
  META_SINGLE_MODULE=0
fi
HAS_C2OFF="$C2_OFF"
HAS_MVNLENS="$MVNLENS"

# --- 7.3 enable the Takari smart builder ------------------------------------
MVN_DIR="$ROOT/.mvn"
EXT="$MVN_DIR/extensions.xml"
if [ ! -d "$MVN_DIR" ]; then
  mkdir -p "$MVN_DIR"
  MADE_MVN_DIR=1
fi
if [ -f "$EXT" ]; then
  HAD_EXT=1
  if [ "$MODE" = "local" ]; then
    SNAPSHOT="$(mktemp)"
    cp "$EXT" "$SNAPSHOT"
  fi
  if grep -q 'takari-smart-builder' "$EXT" 2>/dev/null; then
    info "Takari smart builder already present in $EXT — leaving it"
  else
    info "Injecting Takari smart builder ($TAKARI_VERSION) into existing $EXT"
    awk -v ver="$TAKARI_VERSION" '
      /<\/extensions>/ && !ins {
        print "    <extension>"
        print "        <groupId>io.takari.maven</groupId>"
        print "        <artifactId>takari-smart-builder</artifactId>"
        print "        <version>" ver "</version>"
        print "    </extension>"
        ins=1
      }
      { print }
    ' "$EXT" > "$EXT.tmp" && mv "$EXT.tmp" "$EXT"
  fi
else
  HAD_EXT=0
  info "Writing $EXT with the Takari smart builder ($TAKARI_VERSION)"
  cat > "$EXT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<extensions>
    <extension>
        <groupId>io.takari.maven</groupId>
        <artifactId>takari-smart-builder</artifactId>
        <version>${TAKARI_VERSION}</version>
    </extension>
</extensions>
EOF
fi

# --- mvn-lens on/off toggling ----------------------------------------------
# Drop any <extension> block naming mvn-lens-extension from stdin file $1 (so a
# project that already registers mvn-lens does not contaminate the "off" baseline
# or get a duplicate entry on "on"). Other extensions (takari, etc.) pass through.
strip_mvnlens() {
  awk '
    /<extension>/ { inblk=1; buf=$0; hasmf=0; next }
    inblk {
      buf=buf ORS $0
      if ($0 ~ /mvn-lens-extension/) hasmf=1
      if ($0 ~ /<\/extension>/) { if (!hasmf) print buf; inblk=0; buf=""; hasmf=0 }
      next
    }
    { print }
  ' "$1"
}

# Snapshot the takari-enabled, mvn-lens-free extensions.xml as the "base"
# (mvn-lens off) state. Each build rewrites extensions.xml from this base, adding
# the mvn-lens extension only for the "on" rows — so the "off" rows are a clean
# baseline with the extension not even loaded (a true measure of its overhead).
EXT_BASE="$(mktemp)"
strip_mvnlens "$EXT" > "$EXT_BASE"
[ "$MVNLENS" = "1" ] && info "mvn-lens overhead dimension ON — registering io.github.mvn-perf:mvn-lens-extension:$MVNLENS_VERSION for the 'on' rows (must be in ~/.m2, or reachable via --settings)"

# Write <root>/.mvn/extensions.xml for a build: always the takari base, plus the
# mvn-lens extension when $1 is "on".
apply_extensions() {
  local want="$1"   # on | off
  if [ "$want" = "on" ]; then
    awk -v ver="$MVNLENS_VERSION" '
      /<\/extensions>/ && !ins {
        print "    <extension>"
        print "        <groupId>io.github.mvn-perf</groupId>"
        print "        <artifactId>mvn-lens-extension</artifactId>"
        print "        <version>" ver "</version>"
        print "    </extension>"
        ins=1
      }
      { print }
    ' "$EXT_BASE" > "$EXT.tmp" && mv "$EXT.tmp" "$EXT"
  else
    cp "$EXT_BASE" "$EXT"
  fi
}

# Keep mvn-lens out of the reactor-summary and warm-up builds.
apply_extensions off

# --- per-run logs -----------------------------------------------------------
if [ "$MODE" = "clone" ]; then
  LOGDIR="$WORKDIR/logs"
else
  LOGDIR="$(dirname "$CSV")/logs"
fi
mkdir -p "$LOGDIR"

# --- reactor info and summary
REACTOR_LOG="${CSV%.csv}.log"
if run_mvn help:active-profiles > "${REACTOR_LOG}" 2>&1; then
  info ""
  info "Getting project reactor description:"
  info ""
  REACTOR_LIST=$(awk '
    /Reactor Build Order:/ { in_list=1; next }
    in_list && /^\[INFO\][[:space:]]*-/ { exit }
    in_list && /^\[INFO\][[:space:]]*$/ { next }
    in_list { sub(/^\[INFO\][[:space:]]+/, ""); print }
  ' "${REACTOR_LOG}")
  info "$REACTOR_LIST"
  REACTOR_SUMMARY=$(printf '%s\n' "${REACTOR_LIST}" | awk '
    match($0, /\[[a-zA-Z-]+\]$/) { count[substr($0, RSTART+1, RLENGTH-2)]++ }
    END { sep=""; for (p in count) { printf "%s%d %s", sep, count[p], p; sep=", " }; printf "\n" }
  ')
  echo "  = $REACTOR_SUMMARY"
else
  die "reactor summary build failed — the project does not build, so there is nothing to benchmark (see REACTOR_LOG)"
fi

# --- 7.4 warm-up build (not recorded) ---------------------------------------
TOTAL=$(( (N + 1) * 2 ))
[ "$C2_OFF" = "1" ] && TOTAL=$(( TOTAL * 2 ))
[ "$MVNLENS" = "1" ] && TOTAL=$(( TOTAL * 2 ))
TOTAL=$(( TOTAL * RUNS ))
info ""
info "About to run a warm-up build, then ${TOTAL} timed builds (t=0..${N}, 2 builders$([ "$C2_OFF" = "1" ] && echo ", C2 on+off")$([ "$MVNLENS" = "1" ] && echo ", mvn-lens off+on")$([ "$RUNS" -gt 1 ] && echo ", ${RUNS} runs each")). This can take a while."
info ""
info "Warm-up build (mvn ${GOALS_ARR[*]}) — not recorded ..."
WARMUP_LOG="$LOGDIR/warmup.log"
SECONDS=0
if run_mvn -q "${GOALS_ARR[@]}" > "$WARMUP_LOG" 2>&1; then
  WARMUP_S="$SECONDS"
  info "Warm-up OK (${WARMUP_S}s). Rough matrix estimate: ~$(( WARMUP_S * TOTAL ))s of builds."
else
  info "----- warm-up log tail -----"
  tail -n 25 "$WARMUP_LOG" >&2 || true
  die "warm-up build failed — the project does not build, so there is nothing to benchmark (see $WARMUP_LOG)"
fi

# --- CSV header (D7 §8) -----------------------------------------------------
printf 'threads,builder,c2,mvnlens,goals,status,wall_clock_s,total_time_raw,log_file,report_file,timestamp\n' > "$CSV"

# Where saved mvn-lens dashboards go (one per successful mvnlens=on build).
[ "$MVNLENS" = "1" ] && mkdir -p "$REPORTDIR"

# Run a single (t, builder, c2, mvn-lens) build, parse it, and append a CSV row.
INDEX=0
run_one() {
  local t="$1" builder="$2" c2="$3" mvnlens="$4" run="$5"
  INDEX=$(( INDEX + 1 ))

  # Add/drop the mvn-lens extension in .mvn/extensions.xml for this build.
  apply_extensions "$mvnlens"

  local -a args
  args=( "${GOALS_ARR[@]}" )
  [ "$t" -ge 1 ] && args=( -T "$t" "${args[@]}" )
  [ "$builder" = "smart" ] && args=( -b smart "${args[@]}" )

  local old_opts="${MAVEN_OPTS:-}"
  if [ "$c2" = "off" ]; then
    export MAVEN_OPTS="${old_opts:+$old_opts }-XX:TieredStopAtLevel=1"
  fi

  local tag="${builder}-T${t}-c2${c2}-mf${mvnlens}"
  [ "$RUNS" -gt 1 ] && tag="${tag}-r${run}"
  local log="$LOGDIR/${tag}.log"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  printf '[%2d/%2d] %-7s -T%-2s C2 %-3s mf %-3s%s ... ' \
    "$INDEX" "$TOTAL" "$builder" "$t" "$c2" "$mvnlens" "$([ "$RUNS" -gt 1 ] && printf ' run %d' "$run")" >&2

  local status_rc=0
  run_mvn "${args[@]}" > "$log" 2>&1 || status_rc=$?

  export MAVEN_OPTS="$old_opts"   # restore
  [ -z "$old_opts" ] && unset MAVEN_OPTS 2>/dev/null

  local status wall_s raw report_rel=""
  if [ "$status_rc" -eq 0 ]; then
    local parsed; parsed="$(parse_total_time "$log")"
    if [ -n "$parsed" ]; then
      wall_s="${parsed%%	*}"
      raw="${parsed#*	}"
      status="SUCCESS"
      info "$(printf '%ss (%s)' "$wall_s" "$raw")"
    else
      wall_s=""; raw=""; status="FAILURE"
      info "ok but no 'Total time:' line — marked FAILURE-to-parse"
    fi
  else
    wall_s=""; raw=""; status="FAILURE"
    info "FAILED (exit $status_rc)"
    # Smart-builder load-failure hint (Maven 4 / version mismatch): only when the
    # SAME-config default run succeeded, so we don't blame Takari for a project
    # that simply doesn't build (§10).
    local def_ok; eval "def_ok=\${DEF_OK_${c2}_${mvnlens}:-0}"   # bash-3.2-safe indirect read
    if [ "$builder" = "smart" ] && [ "$def_ok" = "1" ]; then
      warn "-b smart failed but the same default build succeeded — Takari $TAKARI_VERSION may not support this project's Maven version; try --takari-version"
    fi
  fi

  # Save the mvn-lens dashboard (clean wipes target/, so copy it out per build).
  if [ "$mvnlens" = "on" ] && [ "$status" = "SUCCESS" ] && [ -f "$ROOT/target/mvnlens/report.html" ]; then
    if cp "$ROOT/target/mvnlens/report.html" "$REPORTDIR/${tag}.html" 2>/dev/null; then
      report_rel="$REPORT_REL_DIR/${tag}.html"
    fi
  fi
  if [ "$mvnlens" = "on" ] && [ "$status" = "SUCCESS" ] && [ -z "$report_rel" ]; then
    warn "mvn-lens build succeeded but no report at $ROOT/target/mvnlens/report.html — could the extension be resolved (see --settings)?"
  fi

  # Track default-builder success per (C2, mvn-lens) so the smart-failure hint
  # above can tell a smart-specific failure apart from a generally broken build.
  if [ "$builder" = "default" ]; then
    if [ "$status" = "SUCCESS" ]; then eval "DEF_OK_${c2}_${mvnlens}=1"; else eval "DEF_OK_${c2}_${mvnlens}=0"; fi
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$t" "$builder" "$c2" "$mvnlens" "$GOALS" "$status" "$wall_s" "$raw" "$log" "$report_rel" "$ts" >> "$CSV"
}

# --- 7.5 the matrix loop ----------------------------------------------------
C2_LEVELS="on"
[ "$C2_OFF" = "1" ] && C2_LEVELS="on off"
MVNLENS_LEVELS="off"
[ "$MVNLENS" = "1" ] && MVNLENS_LEVELS="off on"
# DEF_OK_<c2>_<mvn-lens> are read indirectly in run_one via eval, which ShellCheck
# cannot see — so it wrongly reports them unused.
# shellcheck disable=SC2034   # one simple command so the directive covers all four
DEF_OK_on_off=0 DEF_OK_on_on=0 DEF_OK_off_off=0 DEF_OK_off_on=0   # per-(t,c2,mf) default-build success

for t in $(seq 0 "$N"); do
  for builder in default smart; do
    for c2 in $C2_LEVELS; do
      for mvnlens in $MVNLENS_LEVELS; do
        for run in $(seq 1 "$RUNS"); do
          run_one "$t" "$builder" "$c2" "$mvnlens" "$run"
        done
      done
    done
  done
done

info ""
info "CSV written: $CSV"

# --- 7.8 generate the HTML --------------------------------------------------
generate_html

if [ "$MODE" = "clone" ] && [ "$KEEP" = "1" ]; then
  info "Kept the clone and logs under: $WORKDIR"
elif [ "$MODE" = "local" ]; then
  info "Per-run logs under: $LOGDIR"
fi
if [ "$MVNLENS" = "1" ] && [ -d "$REPORTDIR" ]; then
  info "mvn-lens dashboards under: $REPORTDIR (linked from the HTML)"
fi

info "Done."
