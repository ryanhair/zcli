#!/usr/bin/env sh
# Regenerate website/assets/site-data.json — the single place the site pulls
# build-derived values from, so they never have to be hand-maintained in the
# templates. Templates read fields via `$site.asset('site-data.json').ziggy().get('<field>')`
# (Zine parses JSON as a Ziggy document).
#
# Currently sourced:
#   version <- root build.zig.zon `.version`
# Add more fields here as they're needed (pulled from wherever their source of truth is).
#
# Runs automatically in CI (deploy-docs.yml) before `zine release`; run it
# manually before a local `zine` / `zine release` preview if any source changed.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
zon="$script_dir/../build.zig.zon"
out="$script_dir/assets/site-data.json"

version=$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)".*/\1/p' "$zon" | head -n 1)

if [ -z "$version" ]; then
  echo "sync-site-data: could not find .version in $zon" >&2
  exit 1
fi

cat > "$out" <<EOF
{
  "version": "$version"
}
EOF
echo "sync-site-data: wrote version $version to $out"
