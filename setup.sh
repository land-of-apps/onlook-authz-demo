#!/usr/bin/env bash
# Sets up everything needed to RECORD again. You do not need this to watch the demo.
#
#   ./setup.sh                  clone Onlook, build base/ and head/, install, create the database
#   SKIP_INSTALL=1 ./setup.sh   skip `bun install` (about 2.4 GB per side)
#   SKIP_DB=1 ./setup.sh        skip the PostgreSQL database
#   REBUILD=1 ./setup.sh        throw away base/ and head/ and build them again from overlay/
#
# What it builds (all ignored by git):
#
#   work/onlook.git   one bare, blobless clone of onlook-dev/onlook
#   base/             worktree: commit cb97e0127 + overlay/base, on branch appmap-base
#   head/             worktree: commit 57ce1ccfa + overlay/head, on branch appmap-head
#   pgdata/           a PostgreSQL just for this demo, port 54330, database onlook_test
#
# base/ and head/ are two checkouts of the SAME clone. You can work in both at once, and the
# review tool can still compare them as two git revisions.
set -euo pipefail
cd "$(dirname "$0")"
source scripts/env.sh

say()  { echo; echo "== $*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1. $2" >&2; exit 1; }; }

need git  "Install git."
need node "Install Node 22."
need "$APPMAP" "Install the AppMap IDE extension (it puts the CLI in ~/.appmap/bin), or set APPMAP."
if [ ! -d "$SKILLS/appmap-review" ]; then
  say "AppMap skills not found, cloning getappmap/skills into work/skills"
  mkdir -p work && git clone --depth 1 https://github.com/getappmap/skills work/skills
fi

say "Onlook clone"
if [ ! -d work/onlook.git ]; then
  mkdir -p work
  git clone --bare --filter=blob:none "$UPSTREAM" work/onlook.git
fi
for sha in "$BASE_SHA" "$HEAD_SHA"; do
  git -C work/onlook.git cat-file -e "$sha^{commit}" 2>/dev/null || git -C work/onlook.git fetch origin "$sha"
done

worktree() {  # worktree <side> <sha>
  local side="$1" sha="$2"
  if [ "${REBUILD:-0}" = "1" ] && [ -d "$side" ]; then
    git -C work/onlook.git worktree remove --force "$DEMO_ROOT/$side"
  fi
  if [ -d "$side" ]; then
    echo "$side/ exists, leaving it alone (REBUILD=1 to build it again)"
    return
  fi
  git -C work/onlook.git worktree prune
  git -C work/onlook.git worktree add -q -f -B "appmap-$side" "$DEMO_ROOT/$side" "$sha"
  cp -R "overlay/$side/." "$side/"
  git -C "$side" add -A
  git -C "$side" -c user.name=goldtrace -c user.email=goldtrace@example.invalid \
    commit -q -m "appmap: recording config, tests and gold traces on $side"
  echo "$side/ = $(git -C "$side" log --oneline -1)"
}
say "Worktrees"
worktree base "$BASE_SHA"
worktree head "$HEAD_SHA"

if [ "${SKIP_INSTALL:-0}" != "1" ]; then
  need bun "Install Bun, or run with SKIP_INSTALL=1."
  for side in base head; do
    if [ -d "$side/node_modules" ]; then echo "$side/node_modules exists, skipping install"; continue; fi
    say "bun install in $side/"
    # The lockfile at these commits does not match package.json, so --frozen-lockfile fails.
    # Install normally, then put the lockfile back so the worktree stays clean.
    ( cd "$side" && bun install >"$DEMO_ROOT/work/bun-install-$side.log" 2>&1 && git checkout -q bun.lock ) \
      || { echo "bun install failed, see work/bun-install-$side.log" >&2; exit 1; }
  done
fi

if [ "${SKIP_DB:-0}" != "1" ]; then
  say "Demo database on port $PG_PORT"
  need initdb "Install PostgreSQL 15 or newer, or set PG_BIN, or run with SKIP_DB=1."
  if [ ! -d pgdata ]; then
    initdb -D pgdata -U postgres --auth=trust -E UTF8 >/dev/null
    db_start >/dev/null
    createdb -h 127.0.0.1 -p "$PG_PORT" -U postgres onlook_test
    # Both commits have the same migrations. Notices about missing policies are expected.
    scripts/setup-db.sh "$DEMO_ROOT/head" "$SUPABASE_DATABASE_URL" 2>&1 | grep -E '^(apply|skip)|ERROR' || true
  elif ! db_ready; then
    db_start >/dev/null
  fi
  db_ready && echo "database is up: $SUPABASE_DATABASE_URL"
fi

say "Query databases for the demo"
build_query_dbs && echo "work/query/base.query.db, work/query/head.query.db"

cat <<EOF

Ready.
  ./demo.sh                                  the guided demo
  source scripts/env.sh                      short commands: gold, review, q, db_start, db_stop
  (cd head && gold check --record)           record every gold trace twice and check they agree
  (cd head && review compare --base appmap-base --head appmap-head)
  RECORD=1 scripts/demo-build.sh             record both sides again and refresh what the demo shows
  scripts/sync-overlay.sh                    copy your changes in base/ and head/ back to overlay/
EOF
