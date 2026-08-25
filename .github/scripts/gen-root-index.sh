#!/usr/bin/env bash
# Generates the root landing page (index.html) in the CURRENT directory, which
# must be the deployed `site/` root (i.e. run from site/, the same way
# gen-grid-index.sh is run from site/scaling/, site/parallel/ and
# site/reference/).
#
# The root page is a HUB: it links to the report sections that the Pages
# site hosts —
#   - scaling/index.html    the builder x -T scaling grid   (scaling-grid.yml)
#   - parallel/index.html   the Surefire forkCount grid     (fork-grid.yml)
#   - reference/index.html  the locally-measured grid       (publish-reference-reports.yml)
# Each link is emitted only when that section's index actually exists, so a
# deploy that carries only a subset of sections (e.g. because there was no live
# site to seed the other sections from yet — see seed-from-live-site.sh) still
# renders a clean hub with no dangling 404 links.
#
# Shared by all Pages workflows so the root index is IDENTICAL no matter
# which deployment produced it. Every workflow publishes to the single GitHub
# Pages site and rebuilds site/ from scratch on every deploy; without a shared
# generator each workflow would emit its own, different root page and clobber the
# others'.
#
# The <title> is the bare site name, "Maven build-performance examples"; each grid
# page's PAGE_TITLE is that same name plus a " · <section>" suffix, and the card
# titles below match those suffixes. Keep the three in step when renaming anything.
#
# Reads GITHUB_RUN_NUMBER / GITHUB_SHA / GITHUB_REF_NAME from the environment
# (blank is fine when run outside Actions).
set -euo pipefail

{
  cat <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Maven build-performance examples</title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 52rem; margin: 3rem auto; padding: 0 1rem; line-height: 1.5; }
    h1 { margin-bottom: 0.25rem; }
    .meta { color: #666; font-size: 0.9rem; margin-bottom: 1rem; }
    .repo { margin-bottom: 2rem; }
    .repo a { color: #0366d6; text-decoration: none; }
    .sections { display: flex; flex-direction: column; gap: 0.75rem; list-style: none; padding: 0; margin: 2rem 0; }
    .sections li { margin: 0; }
    .sections a { display: block; padding: 1rem 1.25rem; border: 1px solid #ddd; border-radius: 10px; text-decoration: none; color: #0366d6; }
    .sections a:hover { background: #f6f8fa; }
    .sections .title { font-weight: 600; font-size: 1.1rem; }
    .sections .desc { color: #666; font-size: 0.9rem; margin-top: 0.2rem; }
  </style>
</head>
<body>
  <h1>Maven build-performance examples</h1>
  <p class="meta">Run #${GITHUB_RUN_NUMBER:-?} · commit ${GITHUB_SHA:-?} · ${GITHUB_REF_NAME:-?}</p>
  <p class="repo">Project on GitHub: <a href="https://github.com/mvnflight/mvn-perf-examples">github.com/mvnflight/mvn-perf-examples</a></p>
  <p><a href="https://github.com/mvnflight/mvn-perf-examples/tree/main/.github/workflows"><code>.github/workflows</code></a> results:</p>
  <ul class="sections">
EOF
  # Each section link is emitted only when its index page exists, so a partial
  # deploy never shows a dangling link.
  if [ -f scaling/index.html ]; then
    echo "    <li><a href=\"scaling/index.html\"><span class=\"title\">Builder scaling grid</span></a>"
    echo "      <span class=\"desc\">Parallel (-T) &amp; Takari smart-builder scaling grid on a 10-module reactor.</span></li>"
  fi
  if [ -f parallel/index.html ]; then
    echo "    <li><a href=\"parallel/index.html\"><span class=\"title\">Test-fork parallelism grid</span></a>"
    echo "      <span class=\"desc\">Intra-module test parallelism on a dedicated parallel-tests module, compared across Surefire forkCount 5 / 1 / 0 (parallel forks vs. one serial fork vs. no fork).</span></li>"
  fi
  if [ -f reference/index.html ]; then
    echo "    <li><a href=\"reference/index.html\"><span class=\"title\">Reference reports</span></a>"
    echo "      <span class=\"desc\">The same scaling grid measured on real hardware rather than a shared CI runner, for comparison.</span></li>"
  fi
  cat <<EOF
  </ul>
</body>
</html>
EOF
} > index.html
