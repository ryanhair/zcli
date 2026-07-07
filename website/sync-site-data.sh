#!/usr/bin/env sh
# Regenerate the website's build-derived files, so nothing has to be
# hand-maintained in the templates:
#
#   assets/site-data.json         — JSON bucket of values; templates read fields via
#                                   `$site.asset('site-data.json').ziggy().get('<field>')`
#                                   (Zine parses JSON as a Ziggy document).
#     version      <- root build.zig.zon `.version`
#     plugin_count <- number of plugin directories in packages/core/src/plugins
#
#   content/changelog/index.smd   — the changelog page body, generated from the
#                                   root CHANGELOG.md (the single source of truth
#                                   for release notes). Version headings get
#                                   $heading.id() anchors (v0.19.0 -> v0-19-0) so
#                                   deep links keep working.
#
# Both outputs are gitignored: a committed copy could drift from its source, and
# a missing file fails the Zine build loudly instead of rendering stale data.
#
# Runs automatically in CI (deploy-docs.yml) before `zine release`, and as a
# dependency of every website/build.zig step.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
zon="$script_dir/../build.zig.zon"
out="$script_dir/assets/site-data.json"

version=$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)".*/\1/p' "$zon" | head -n 1)

if [ -z "$version" ]; then
  echo "sync-site-data: could not find .version in $zon" >&2
  exit 1
fi

plugins_dir="$script_dir/../packages/core/src/plugins"
plugin_count=$(find "$plugins_dir" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')

if [ "$plugin_count" -eq 0 ]; then
  echo "sync-site-data: found no plugin directories in $plugins_dir" >&2
  exit 1
fi

cat > "$out" <<EOF
{
  "version": "$version",
  "plugin_count": "$plugin_count"
}
EOF
echo "sync-site-data: wrote version $version, plugin_count $plugin_count to $out"

# --- content/changelog/index.smd <- CHANGELOG.md ---------------------------

changelog_md="$script_dir/../CHANGELOG.md"
changelog_out="$script_dir/content/changelog/index.smd"

release_count=$(grep -c '^## ' "$changelog_md" || true)
if [ "$release_count" -eq 0 ]; then
  echo "sync-site-data: found no '## ' release headings in $changelog_md" >&2
  exit 1
fi

# Page date = the newest release's date (first YYYY-MM-DD in the first heading).
latest_date=$(sed -n 's/^## .*\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\).*/\1/p' "$changelog_md" | head -n 1)
if [ -z "$latest_date" ]; then
  echo "sync-site-data: could not extract a release date from $changelog_md" >&2
  exit 1
fi

cat > "$changelog_out" <<EOF
---
.title = "zcli — Changelog",
.description = "Every zcli release, newest first, with the versioning policy and Zig support table. Generated from CHANGELOG.md in the repo.",
.date = @date("$latest_date"),
.author = "Ryan Hair",
.layout = "changelog.shtml",
---
EOF

# Body: everything from the first release heading onward (the H1 and policy
# intro are presented by the layout instead). Each `## vX.Y.Z ...` heading gets
# a $heading.id() anchor derived from its first version number.
awk '
  /^## / { started = 1 }
  !started { next }
  /^## / {
    line = substr($0, 4)
    if (match(line, /v[0-9]+\.[0-9]+\.[0-9]+/)) {
      anchor = substr(line, RSTART, RLENGTH)
      gsub(/\./, "-", anchor)
      printf "## [%s]($heading.id(%c%s%c))\n", line, 39, anchor, 39
      next
    }
  }
  { print }
' "$changelog_md" >> "$changelog_out"

echo "sync-site-data: wrote $release_count releases (latest $latest_date) to $changelog_out"
