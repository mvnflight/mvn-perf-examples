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
# Every card also prints its own ABSOLUTE url beneath the description. The hub
# holds no data of its own, so the useful thing to hand someone is the section
# url, not this one — and a relative <a href> alone can only be read by hovering
# the card, which leaves nothing to copy from a screenshot or a chat message.
#
# A "Links" list below the cards carries the rest of the urls a reader of this
# page actually needs, absolute and as visible link text for the same reason:
# this page's own canonical url, the repository, the workflows that publish each
# section, the run list (a section is missing from the hub precisely when its
# workflow has not published yet, so that is the page to check), and the Maven
# Central snapshot directory the profiler resolves from — no workflow here builds
# it. The mvn-lens repository itself is deliberately NOT linked: it is private,
# so the link would 404 for every visitor.
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

# Public base url of this Pages site, used for the per-card absolute urls. The
# repo link below is hard-coded the same way: this generator only ever publishes
# this one site, and GITHUB_* carries no reliable Pages url to derive it from.
SITE="https://mvn-perf.github.io/mvn-perf-examples"
REPO="https://github.com/mvn-perf/mvn-perf-examples"
SNAPSHOTS="https://central.sonatype.com/repository/maven-snapshots/io/github/mvn-perf"

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
    .sections .url { display: block; color: #57606a; font-size: 0.85rem; margin-top: 0.2rem;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace; overflow-wrap: anywhere; }
    h2 { font-size: 1.1rem; margin: 2.5rem 0 0.5rem; }
    .links { list-style: none; padding: 0; margin: 0; }
    .links li { margin: 0.4rem 0; }
    .links .lbl { color: #666; }
    .links a { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.9rem;
      color: #0366d6; text-decoration: none; overflow-wrap: anywhere; }
    .links a:hover { text-decoration: underline; }
  </style>
</head>
<body>
  <h1>Maven build-performance examples</h1>
  <p class="meta">Run #${GITHUB_RUN_NUMBER:-?} · commit ${GITHUB_SHA:-?} · ${GITHUB_REF_NAME:-?}</p>
  <p><a href="$REPO/tree/main/.github/workflows"><code>.github/workflows</code></a> results:</p>
  <ul class="sections">
EOF
  # Each section link is emitted only when its index page exists, so a partial
  # deploy never shows a dangling link.
  if [ -f scaling/index.html ]; then
    echo "    <li><a href=\"scaling/index.html\"><span class=\"title\">Builder scaling grid</span></a>"
    echo "      <span class=\"desc\">Parallel (-T) &amp; Takari smart-builder scaling grid on a 10-module reactor.</span>"
    echo "      <span class=\"url\">$SITE/scaling/</span></li>"
  fi
  if [ -f parallel/index.html ]; then
    echo "    <li><a href=\"parallel/index.html\"><span class=\"title\">Test-fork parallelism grid</span></a>"
    echo "      <span class=\"desc\">Intra-module test parallelism on a dedicated parallel-tests module, compared across Surefire forkCount 5 / 1 / 0 (parallel forks vs. one serial fork vs. no fork).</span>"
    echo "      <span class=\"url\">$SITE/parallel/</span></li>"
  fi
  if [ -f reference/index.html ]; then
    echo "    <li><a href=\"reference/index.html\"><span class=\"title\">Reference reports</span></a>"
    echo "      <span class=\"desc\">The same scaling grid measured on real hardware rather than a shared CI runner, for comparison.</span>"
    echo "      <span class=\"url\">$SITE/reference/</span></li>"
  fi
  cat <<EOF
  </ul>
  <h2>Links</h2>
  <ul class="links">
    <li><span class="lbl">This page</span> — <a href="$SITE/">$SITE/</a></li>
    <li><span class="lbl">Repository</span> — <a href="$REPO">$REPO</a></li>
    <li><span class="lbl">Workflows that publish these sections</span> — <a href="$REPO/tree/main/.github/workflows">$REPO/tree/main/.github/workflows</a></li>
    <li><span class="lbl">Workflow runs</span> — <a href="$REPO/actions">$REPO/actions</a></li>
    <li><span class="lbl">The mvn-lens profiler, on Maven Central snapshots</span> — <a href="$SNAPSHOTS/">$SNAPSHOTS/</a></li>
  </ul>
</body>
</html>
EOF
} > index.html
