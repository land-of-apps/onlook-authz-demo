# Shared settings and short commands. Every script sources this. You can too:
#
#   source scripts/env.sh
#
# Override any of these in the environment before sourcing:
#   APPMAP   the AppMap CLI              (default: ~/.appmap/bin/appmap, else appmap on PATH)
#   SKILLS   the getappmap/skills folder (default: ~/.claude/skills, else cloned to work/skills)
#   PG_BIN   folder with initdb, pg_ctl, psql (default: newest Homebrew postgresql@N, else PATH)
#   PG_PORT  port for the demo database  (default: 54330)

DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# The two Onlook commits this case is about.
UPSTREAM="https://github.com/onlook-dev/onlook"
BASE_SHA="cb97e012729eca441e09b1503282cb4bc2f4bcfb"   # the commit before the partial fix
HEAD_SHA="57ce1ccfacc7e8484cae59013a2b1e34518560e5"   # the partial fix, pull request 3062
GOLD_DIR="apps/web/client/gold_traces"                 # inside base/ and head/

# AppMap CLI
if [ -z "${APPMAP:-}" ]; then
  if [ -x "$HOME/.appmap/bin/appmap" ]; then APPMAP="$HOME/.appmap/bin/appmap"; else APPMAP="appmap"; fi
fi
case "$APPMAP" in */*) PATH="$(dirname "$APPMAP"):$PATH" ;; esac

# AppMap skills (the gold-traces and review tools)
if [ -z "${SKILLS:-}" ]; then
  if [ -d "$HOME/.claude/skills/appmap-review" ]; then SKILLS="$HOME/.claude/skills"; else SKILLS="$DEMO_ROOT/work/skills"; fi
fi

# PostgreSQL. Only needed to record again, not to watch the demo.
PG_PORT="${PG_PORT:-54330}"
if [ -z "${PG_BIN:-}" ]; then
  for v in 18 17 16 15; do
    for prefix in /opt/homebrew/opt /usr/local/opt; do
      if [ -x "$prefix/postgresql@$v/bin/initdb" ]; then PG_BIN="$prefix/postgresql@$v/bin"; break 2; fi
    done
  done
fi
[ -n "${PG_BIN:-}" ] && PATH="$PG_BIN:$PATH"
export PATH
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export SUPABASE_DATABASE_URL="${SUPABASE_DATABASE_URL:-postgresql://postgres@127.0.0.1:$PG_PORT/onlook_test}"

# The demo database is its own PostgreSQL under pgdata/. It touches no other server.
db_start() {
  pg_ctl -D "$DEMO_ROOT/pgdata" -l "$DEMO_ROOT/pgdata.log" \
    -o "-p $PG_PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -w start
}
db_stop()  { pg_ctl -D "$DEMO_ROOT/pgdata" -m fast stop; }
db_ready() { pg_isready -q -h 127.0.0.1 -p "$PG_PORT"; }

# gold <command> [options]     the gold-traces tool. Run it inside base/ or head/.
# review <command> [options]   the review tool. Run it inside head/.
gold()   { node "$SKILLS/appmap-gold-traces/assets/manage.mjs" "$@" --dir "$GOLD_DIR"; }
review() { node "$SKILLS/appmap-review/assets/review.mjs" "$@" --dir "$GOLD_DIR"; }

# q <base|head> <query verb> ...   query the saved recordings, for example:
#   q head find calls --label security.authorization
#   q head tree recordings/head/project.delete_called_by_a_non-member.appmap.json
q() { local side="$1"; shift; "$APPMAP" query "$@" --query-db "$DEMO_ROOT/work/query/$side.query.db"; }

# Builds the query databases from recordings/. Takes a few seconds. Needs only the AppMap CLI.
build_query_dbs() {
  local side
  mkdir -p "$DEMO_ROOT/work/query"
  for side in base head; do
    rm -f "$DEMO_ROOT/work/query/$side.query.db"
    "$APPMAP" index --appmap-dir "$DEMO_ROOT/recordings/$side" \
      --query-db "$DEMO_ROOT/work/query/$side.query.db" >/dev/null 2>&1 || return 1
  done
}
