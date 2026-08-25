#!/usr/bin/env bash
# Seeds the deploy directory (default: site/) with the CURRENTLY-LIVE GitHub
# Pages site, so a workflow that rebuilds site/ from scratch preserves every
# section already published — independent of CI-artifact retention.
#
# Why this exists
# ---------------
# All three Pages workflows in this repo deploy to the SINGLE GitHub Pages site
# and each one rebuilds site/ from scratch before deploying:
#   scaling-grid.yml               owns scaling/
#   fork-grid.yml                  owns parallel/
#   publish-reference-reports.yml  owns reference/
# A workflow that rebuilt only its own subpath and deployed would therefore
# publish a site with the other two sections missing. Reconstructing them by
# re-fetching the other workflows' report artifacts does not work either: report
# artifacts expire (retention-days), so once they are gone, re-running any
# workflow silently drops the unreconstructable section from the root hub.
#
# Mirroring the live site instead never expires: whatever is currently published
# becomes the base for this deploy, and the calling workflow then overlays only
# the section it owns. That matters most for reference/, whose reports are
# measured locally and only exist in a checkout when someone has committed a
# grid — mirroring is the only way the two CI grids preserve it.
#
# Contract: BEST EFFORT. Prints a warning and exits 0 on any failure, so the
# caller's own freshly-built section still deploys. That explicitly includes the
# FIRST deploy, when https://<owner>.github.io/<repo>/ does not exist yet: wget
# exits non-zero on the 404, the `||` below swallows it, and the caller
# continues with an empty site/. The caller is responsible for rebuilding the
# section it owns on top of whatever this seeds.
#
# Usage: seed-from-live-site.sh [dest-dir]
#   dest-dir defaults to "site". The live URL defaults to the project-pages
#   convention https://<owner>.github.io/<repo>/ derived from $GITHUB_REPOSITORY,
#   and can be overridden with $SITE_URL.
set -uo pipefail

dest="${1:-site}"

# Resolve the live Pages URL. $SITE_URL wins; otherwise derive it from
# $GITHUB_REPOSITORY using the project-pages convention
# https://<owner>.github.io/<repo>/. If neither is available (e.g. run locally
# without args), skip rather than fail — this step is best effort.
if [ -n "${SITE_URL:-}" ]; then
  url="$SITE_URL"
elif [ -n "${GITHUB_REPOSITORY:-}" ]; then
  owner="${GITHUB_REPOSITORY%%/*}"
  repo="${GITHUB_REPOSITORY#*/}"
  url="https://${owner}.github.io/${repo}/"
else
  echo "seed-from-live-site: neither SITE_URL nor GITHUB_REPOSITORY set — skipping live-site seed (best effort)." >&2
  exit 0
fi

if ! command -v wget >/dev/null 2>&1; then
  echo "seed-from-live-site: wget not available — skipping live-site seed (best effort)." >&2
  exit 0
fi

mkdir -p "$dest"

echo "seed-from-live-site: mirroring $url -> $dest/ (best effort)"

# Recursively mirror the live site. It is a static tree of index.html hubs that
# link (with relative hrefs) to every report-*.html, so a link-following
# recursive fetch captures the whole thing. Flag notes:
#   --recursive --level=inf   follow links to any depth (root -> section -> reports)
#   --no-parent               never climb above the start URL's directory
#   --no-host-directories     drop the <owner>.github.io/ leading dir
#   --cut-dirs=1              drop the leading repo path segment (mvn-perf-examples/)
#   -P "$dest"                write the remaining tree under <dest>/
#   -e robots=off             ignore any robots.txt that might block crawling
#   retries/timeouts          so a transient blip doesn't abort the whole mirror
# wget stays on the start host by default (no --span-hosts), so the external
# github.com links in the pages are not followed; reports are self-contained
# (no external CSS/JS), so --page-requisites is unnecessary.
wget \
  --recursive --level=inf --no-parent \
  --no-host-directories --cut-dirs=1 \
  -e robots=off \
  --retry-connrefused --tries=5 --timeout=30 --waitretry=2 \
  --quiet \
  -P "$dest" \
  "$url" \
  || echo "seed-from-live-site: mirror incomplete or failed (best effort) — continuing." >&2

seeded=$(find "$dest" -name '*.html' 2>/dev/null | wc -l | tr -d ' ')
if [ "$seeded" = "0" ]; then
  # Normal on the first-ever deploy: there is no published site to mirror yet.
  echo "seed-from-live-site: nothing seeded — no live site yet, or the mirror was empty. Continuing with an empty ${dest}/."
else
  echo "seed-from-live-site: seeded ${seeded} HTML file(s) from the live site."
fi

exit 0
