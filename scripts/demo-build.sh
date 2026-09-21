#!/usr/bin/env bash
# Rebuilds what demo.sh shows (demo/), from real tool runs. Needs ./setup.sh to have run,
# because the compare reads the gold traces from the branches behind base/ and head/.
#
#   scripts/demo-build.sh            rebuild demo/ from the recordings saved in recordings/
#   RECORD=1 scripts/demo-build.sh   first record both sides again (needs the demo database up)
#
# Everything written to demo/ has this machine's paths removed, so it is safe to commit.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
D=demo; W=work/diagrams
REC=apps/web/client/tmp/appmap/vitest

[ -d head/.git ] || [ -f head/.git ] || { echo "Run ./setup.sh first." >&2; exit 1; }
scrub() { sed -e "s#$DEMO_ROOT/##g" -e "s#$DEMO_ROOT##g" -e "s#$HOME#~#g"; }
mkdir -p "$D" work

if [ "${RECORD:-0}" = "1" ]; then
  db_ready || { echo "The demo database is not running. Try: source scripts/env.sh && db_start" >&2; exit 1; }
  for side in base head; do
    echo "record $side"
    # On head, an addTag trace sometimes differs between the two passes (see README, Known
    # quirks). The recordings are still good, so a failed check does not stop the build.
    ( cd "$side" && gold check --record ) > "work/check-$side.log" 2>&1 \
      || echo "  the check on $side/ reported a problem, see work/check-$side.log"
    rm -rf "recordings/$side" && mkdir -p "recordings/$side"
    cp "$side/$REC"/*.appmap.json "recordings/$side/"
  done
  clean() { grep -v -E 'punycode|trace-deprecation|PostHog|^[[:space:]]*$' work/check-base.log | scrub; }
  clean | grep -E '✓|Wrote [0-9]+ AppMaps' | head -24 > "$D/02-record-tests.txt"
  clean | grep -E 'Test Files|Tests |Start at|Duration|Wrote|Checked' | tail -8 > "$D/02-record-tail.txt"
fi

echo "query databases"
build_query_dbs

echo "code diff"
git -C head diff --color=always "$BASE_SHA" "$HEAD_SHA" > "$D/01-code.diff"

echo "compare"
( cd head && review compare --base appmap-base --head appmap-head ) > work/compare.raw 2>&1
R=$(grep -o '/[^ ]*appmap-review/out/report' work/compare.raw | head -1)
# Keep what the demo and the VS Code diff viewer read: the change report, the diff diagrams,
# and the recording on each side of every changed trace. The viewer looks for
# report/head/vitest/<name>.appmap.json next to report/diff/. The archives and index folders
# are left out: they are large and hold this machine's paths.
rm -rf "$D/report" && mkdir -p "$D/report/base/vitest" "$D/report/head/vitest"
cp "$R/change-report.json" "$D/report/"
cp -R "$R/diff" "$D/report/diff"
[ -d "$R/text" ] && cp -R "$R/text" "$D/report/text"
for f in "$D"/report/diff/vitest/*.diff.sequence.json; do
  t=$(basename "$f" .diff.sequence.json)
  cp "$R/base/vitest/$t.appmap.json" "$D/report/base/vitest/"
  cp "$R/head/vitest/$t.appmap.json" "$D/report/head/vitest/"
done
sed "s#$R#$D/report#g" work/compare.raw | scrub > "$D/03-compare.txt"

echo "sequence diagrams"
rm -rf "$W" && mkdir -p "$W/base" "$W/head"
for side in base head; do
  "$APPMAP" sequence-diagram -f json --output-dir "$W/$side" recordings/$side/*.appmap.json >/dev/null 2>&1
done
T=project.delete_called_by_a_non-member
t=$(mktemp -d)
"$APPMAP" sequence-diagram-diff -f text --output-dir "$t" "$W/base/$T.sequence.json" "$W/head/$T.sequence.json" >/dev/null 2>&1
cut -c1-150 "$t/diff.txt" > "$D/04-delete.diff.txt"

echo "queries"
node scripts/summarize.mjs > "$D/05-summary.txt"
for side in base head; do
  q $side tree "recordings/$side/$T.appmap.json" > "$D/04-tree-$side.txt"
  q $side tree "recordings/$side/member.remove_called_by_a_non-member.appmap.json" > "$D/05-tree-member-remove-$side.txt"
  q $side find calls --label security.authorization > "$D/06-label-$side.txt"
done

# The recorder sometimes logs the membership SELECT late (see README, Known quirks). Step 4 of
# the demo features this trace, so say so if the saved recording has the late order.
if ! awk '/select "projects"/{s=NR} /rollback/{r=NR} END{exit !(s && r && s<r)}' "$D/04-tree-head.txt"; then
  echo "WARNING: recordings/head/$T has the membership SELECT logged late."
  echo "         Step 4 will look wrong. Run RECORD=1 scripts/demo-build.sh again."
fi

if grep -rIl -e "$DEMO_ROOT" -e "$HOME" "$D" >/dev/null 2>&1; then
  echo "WARNING: these files still hold paths from this machine:"; grep -rIl -e "$DEMO_ROOT" -e "$HOME" "$D"
fi
echo "done. Check it:  DEMO_AUTO=1 ./demo.sh | less -R"
