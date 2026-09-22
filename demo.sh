#!/usr/bin/env bash
# Guided demo: Onlook's partial authorization fix, seen through AppMap gold traces.
#
#   ./demo.sh               run the demo
#   NO_VISUAL=1 ./demo.sh   terminal only: do not open VS Code or the browser
#   DEMO_AUTO=1 ./demo.sh   no pauses and no windows (for checking the script)
#
# Keys, at every pause:
#   Enter, Space   continue
#   →              skip to the next step
#   ←              back to the previous step
#   l              list the steps and jump to one by number
#   q, Escape      quit (stops the query UI)
#
# Needs: the AppMap CLI, and for the visual steps VS Code with the AppMap extension.
# Does NOT need Onlook, Bun or a database. Everything it shows is committed in this repo.
#
# How it works
#   - Commands that do work (record, compare, index, query) are PRINTED, never run.
#     What they produced was saved ahead of time in demo/ and recordings/, and is shown
#     right after the command. scripts/demo-build.sh makes those files from real runs.
#   - Viewers are the one exception. `code` and `appmap query ui` really start,
#     because a window cannot be shown any other way. The query UI is stopped on exit.
#   - Each step runs in a subshell. A navigation key makes the subshell exit with a code
#     that tells the runner loop where to go next, so a step can be left at any pause.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
source scripts/env.sh
DEMO=demo
LIVE=recordings
QDB=work/query

AUTO="${DEMO_AUTO:-0}"
NO_VISUAL="${NO_VISUAL:-0}"
[ "$AUTO" = "1" ] && NO_VISUAL=1

if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; OFF=$'\033[0m'
else
  B=; DIM=; CYAN=; GREEN=; YELLOW=; RED=; OFF=
fi
COLS=$( (tput cols 2>/dev/null) || echo 120)

STEPS=(
  "Introduction"
  "The pull request, as a reviewer saw it"
  "Record what the code does"
  "Compare BASE and HEAD"
  "Where the fix worked: project.delete, called by a stranger"
  "Where the fix is missing: the traces with no diff"
  "Ask the recordings: which requests ran an authorization check?"
  "Browse both branches in the query UI"
  "The review this produces"
)
LAST=$(( ${#STEPS[@]} - 1 ))

# Exit codes a step's subshell uses to tell the runner where to go.
NAV_BACK=101; NAV_QUIT=102; NAV_JUMP=110   # NAV_JUMP + n = go to step n

# Bash 3 (macOS /bin/bash) only takes whole-second read timeouts.
if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then ESC_WAIT=0.05; else ESC_WAIT=1; fi

# ---- building blocks ---------------------------------------------------------

readkey() {  # sets KEY to one of: enter, next, back, list, quit, other
  local k rest
  IFS= read -rsn1 k </dev/tty || { KEY=quit; return; }
  case "$k" in
    $'\e')
      rest=""
      IFS= read -rsn2 -t "$ESC_WAIT" rest </dev/tty
      case "$rest" in
        '[C'|'OC') KEY=next ;;
        '[D'|'OD') KEY=back ;;
        '')        KEY=quit ;;     # Escape on its own
        *)         KEY=other ;;
      esac ;;
    q|Q)     KEY=quit ;;
    l|L)     KEY=list ;;
    ''|' ')  KEY=enter ;;
    *)       KEY=other ;;
  esac
}

pick_step() {  # shows the list; a digit jumps to that step, any other key stays
  local i n
  echo; echo
  for i in "${!STEPS[@]}"; do
    if [ "$i" = "$CUR" ]; then printf '  %s%d  %s%s  ← you are here\n' "$B" "$i" "${STEPS[$i]}" "$OFF"
    else printf '  %s%d%s  %s\n' "$B" "$i" "$OFF" "${STEPS[$i]}"; fi
  done
  echo
  printf '%s' "${DIM}  press a step number, or any other key to stay: ${OFF}"
  IFS= read -rsn1 n </dev/tty
  echo
  if [[ "$n" =~ ^[0-9]$ ]] && [ "$n" -le "$LAST" ]; then exit $(( NAV_JUMP + n )); fi
}

pause() {  # pause "prompt"   Waits for a key. Navigation keys leave the step (see readkey).
  [ "$AUTO" = "1" ] && { echo; return 0; }
  echo
  while :; do
    printf '%s' "${DIM}  ── ${1:-Press Enter to continue} ──   [Enter · ← → step · l list · q quit]${OFF} "
    readkey
    case "$KEY" in
      enter) echo; echo; return 0 ;;
      next)  echo; exit 0 ;;
      back)  echo; exit $NAV_BACK ;;
      quit)  echo; exit $NAV_QUIT ;;
      list)  pick_step ;;
      *)     echo ;;
    esac
  done
}

step() {   # step <number>   Clears the screen and prints the step's title.
  [ "$AUTO" = "1" ] || clear
  echo "${B}${CYAN}━━━ Step $1 of $LAST ━━━ ${STEPS[$1]}${OFF}"
  echo
}

say() {   # say <line>...   Joins the lines into paragraphs and wraps them to the terminal.
           # An empty line ends a paragraph. A line that starts with two spaces is printed as is.
  local w=$(( COLS < 100 ? COLS - 1 : 100 )) para="" line
  flush() { [ -n "$para" ] && { echo "$para" | fold -s -w "$w"; para=""; }; }
  for line in "$@"; do
    case "$line" in
      "")    flush; echo ;;
      "  "*) flush; echo "$line" ;;
      *)     para="${para:+$para }$line" ;;
    esac
  done
  flush
}
note() { echo "${YELLOW}▸ $*${OFF}"; }

cmd() {    # cmd <command text>   Prints a command. Does not run it.
  echo
  echo "${B}${GREEN}\$ $*${OFF}"
  pause "Press Enter to run it (simulated)"
}

artifact() {  # artifact <label>   Heading for something the command produced.
  echo "${DIM}┌─ $* ${OFF}"
}

show() {   # show <file>          Prints a saved output, colors kept.
  sed 's/^/  /' "$1"
}

show_fit() {  # show_fit <file>   Same, with long lines cut to the terminal width. For plain text only.
  cut -c1-$(( COLS - 4 )) "$1" | sed 's/^/  /'
}

view() {   # view <description> <command...>   Really runs a viewer, unless NO_VISUAL=1.
  local what="$1"; shift
  local shown="$*"
  echo "${B}${GREEN}\$ ${shown//$ROOT\//}${OFF}   ${DIM}(viewer: this one really runs)${OFF}"
  if [ "$NO_VISUAL" = "1" ]; then
    echo "${DIM}  skipped (NO_VISUAL): $what${OFF}"
    return
  fi
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "${RED}  '$1' is not on PATH, skipping: $what${OFF}"
    return
  fi
  "$@" >/dev/null 2>&1
  echo "${DIM}  opened: $what${OFF}"
}

start_ui() {  # start_ui <branch> <port>   Its pid goes to a file, so the runner can stop it.
  local b="$1" port="$2"
  echo "${B}${GREEN}\$ appmap query ui --port $port --query-db $QDB/$b.query.db${OFF}   ${DIM}(viewer: this one really runs)${OFF}"
  if [ "$NO_VISUAL" = "1" ]; then
    echo "${DIM}  skipped (NO_VISUAL): query UI for $b${OFF}"
    return
  fi
  if curl -s -o /dev/null "http://127.0.0.1:$port/"; then
    echo "${DIM}  already running: http://localhost:$port/${OFF}"
    return
  fi
  "$APPMAP" query ui --port "$port" --query-db "$QDB/$b.query.db" >"work/ui-$b.log" 2>&1 &
  echo $! > "work/ui-$b.pid"
  echo "${DIM}  query UI for $b: http://localhost:$port/${OFF}"
}

cleanup() {
  local f
  for f in work/ui-*.pid; do
    [ -f "$f" ] && { kill "$(cat "$f")" 2>/dev/null; rm -f "$f"; }
  done
}
trap cleanup EXIT

# ---- the steps ----------------------------------------------------------------

step_0() {
  [ "$AUTO" = "1" ] || clear
  echo "${B}Onlook: any signed in user could edit anyone's project${OFF}"
  echo
  say "In December 2025 Onlook fixed a security report by adding a membership check," \
      "verifyProjectAccess, to five tRPC procedures. About forty sibling procedures kept" \
      "trusting the project id from the browser. The gap stayed in production for seven months." \
      "" \
      "This demo reviews that pull request the way it could have been reviewed before merge:" \
      "by comparing recordings of what the code did, before and after." \
      "" \
      "  BASE  cb97e0127   the commit before the fix      (folder base/)" \
      "  HEAD  57ce1ccfa   the fix, pull request 3062     (folder head/)"
  echo
  note "Commands are printed, not run. What each one produced is shown right after it."
  note "Keys: Enter continues. ← and → move between steps. l lists the steps. q quits."
  pause "Press Enter to start"
}

step_1() {
  step 1
  say "Start where every review starts: the code diff."
  cmd "git diff cb97e0127 57ce1ccfa"
  artifact "the diff: 2 files, 41 lines added"
  show $DEMO/01-code.diff
  echo
  note "A new helper, called from five procedures. It reads well. Most reviewers would approve it."
  note "A code diff shows what changed. It cannot show what should have changed and did not."
  pause
}

step_2() {
  step 2
  say "Onlook had no tests for its server API, and the pull request added none. For this case" \
      "study we wrote 18 ordinary tests and put the same tests on both commits. They call the" \
      "real tRPC router over HTTP against PostgreSQL. Some run as the project owner. Some run" \
      "as a signed in stranger and expect to be refused: the tests a careful team writes for" \
      "an application with many tenants." \
      "" \
      "The gold-traces tool runs each test twice under the AppMap recorder and checks that the" \
      "two recordings agree."
  cmd "cd base && node ~/.claude/skills/appmap-gold-traces/assets/manage.mjs check --dir apps/web/client/gold_traces --record"
  artifact "test run under the recorder (first of two passes)"
  show $DEMO/02-record-tests.txt
  echo "  ${DIM}...${OFF}"
  show $DEMO/02-record-tail.txt
  echo
  artifact "the recordings: base/apps/web/client/tmp/appmap/vitest/  (one file per test, saved in $LIVE/base)"
  ( cd $LIVE/base && ls -1 *.appmap.json | sed 's/^/  /' )
  echo
  note "Each file is one HTTP request, the functions it ran, the SQL it issued, and the status."
  note "The same command runs in head/. Both sets are saved in $LIVE/."
  pause "Press Enter to open one recording"
  view "AppMap of the stranger's project.delete on BASE" \
       code "$ROOT/$LIVE/base/project.delete_called_by_a_non-member.appmap.json"
  note "On BASE the stranger's delete goes straight to DELETE FROM projects and returns 200."
  pause
}

step_3() {
  step 3
  say "base/ and head/ are two checkouts of one Onlook clone, on branches appmap-base and" \
      "appmap-head. Each branch commits its blessed recordings under gold_traces/baseline. The" \
      "review tool archives both sides and compares them."
  cmd "cd head && node ~/.claude/skills/appmap-review/assets/review.mjs compare --base appmap-base --head appmap-head --dir apps/web/client/gold_traces"
  artifact "compare output"
  show_fit $DEMO/03-compare.txt
  echo
  artifact "diff diagrams: $DEMO/report/diff/vitest/"
  ls -1 $DEMO/report/diff/vitest | sed 's/^/  /'
  echo
  note "18 traces. 9 changed. Hold on to that number: 9 did not."
  pause
}

step_4() {
  step 4
  say "First, a change that did what it should. This is the sequence diagram diff for the" \
      "stranger's delete request."
  cmd "appmap sequence-diagram-diff -f text base/project.delete_called_by_a_non-member.sequence.json head/project.delete_called_by_a_non-member.sequence.json"
  artifact "diff.txt"
  show_fit $DEMO/04-delete.diff.txt
  echo
  artifact "the same request as a call tree, BASE then HEAD   (appmap query tree <recording>)"
  echo "  ${B}BASE${OFF}"; show_fit $DEMO/04-tree-base.txt
  echo "  ${B}HEAD${OFF}"; show_fit $DEMO/04-tree-head.txt
  pause "Press Enter to open the visual diff"
  view "sequence diagram diff, project.delete called by a non-member" \
       code "$ROOT/$DEMO/report/diff/vitest/project.delete_called_by_a_non-member.diff.sequence.json"
  note "Removed: the two deletes. Added: the check and its SELECT. commit became rollback. 200 became 500."
  note "This is what a working authorization fix looks like in a trace."
  pause
}

step_5() {
  step 5
  say "Now the nine traces that did not change. Three of them are a stranger's requests." \
      "Here is every stranger request, on both branches."
  cmd "node scripts/summarize.mjs"
  artifact "status | was the check called | SQL that ran"
  show_fit $DEMO/05-summary.txt
  echo
  note "project.get, settings.upsert and member.remove: same 200, same SQL, no check, on both branches."
  pause "Press Enter to look at one of them"
  artifact "member.remove called by a non-member, BASE then HEAD   (appmap query tree <recording>)"
  echo "  ${B}BASE${OFF}"; show_fit $DEMO/05-tree-member-remove-base.txt
  echo "  ${B}HEAD${OFF}"; show_fit $DEMO/05-tree-member-remove-head.txt
  echo
  note "After the security fix, a stranger can still remove a member from someone else's project."
  note "There is no diff diagram to open for this trace. That absence is the finding."
  pause
}

step_6() {
  step 6
  say "appmap.yml labels verifyProjectAccess as security.authorization. The recordings are" \
      "indexed into a small query database, one per branch, and can be searched by label."
  cmd "appmap index --appmap-dir $LIVE/head --query-db $QDB/head.query.db"
  artifact "$QDB/base.query.db and $QDB/head.query.db"
  ls -lh $QDB/*.query.db | awk '{print "  " $5 "  " $NF}'
  cmd "appmap query find calls --label security.authorization --query-db $QDB/base.query.db"
  artifact "BASE"
  show_fit $DEMO/06-label-base.txt
  echo "  ${DIM}(no rows: BASE has no authorization check at all)${OFF}"
  cmd "appmap query find calls --label security.authorization --query-db $QDB/head.query.db"
  artifact "HEAD"
  show_fit $DEMO/06-label-head.txt
  echo
  note "Nine rows, and every one is a project.* procedure."
  note "settings, member and branch never appear. Nobody had to read the routers to learn that."
  pause
}

step_7() {
  step 7
  say "The same query databases have a local web UI: dashboard, endpoints, hotspots, traces." \
      "One window per branch."
  echo
  start_ui base 4476
  start_ui head 4477
  echo
  note "In each window open Traces, then 'member.remove called by a non-member'."
  note "Both show one DELETE and a 200. Then open 'project.update called by a non-member' to see the contrast."
  note "Every route reads /api/trpc/:param, because the sanitizer strips the procedure name. Find traces by test name."
  pause "Press Enter when done with the UI (it stays up until the demo ends)"
}

step_8() {
  step 8
  say "The appmap-review skill turns the compare output into a findings-first review: the one" \
      "this pull request could have received before merge."
  cmd "claude \"/appmap-review appmap-base appmap-head\""
  artifact "REVIEW.md: the findings"
  grep -E '^### [0-9🟢]' REVIEW.md | sed 's/^### //' | fold -s -w $(( COLS - 4 )) | sed 's/^/  /'
  echo
  view "the full review" code "$ROOT/REVIEW.md"
  echo
  echo "${B}Recap${OFF}"
  say "  1. The code diff looked complete." \
      "  2. Recordings of ordinary tests showed what each request really did." \
      "  3. Nine traces changed. The three that mattered most did not." \
      "  4. A label query listed exactly which requests were checked, and which were not." \
      "" \
      "The real fix, Onlook pull request 3129, landed seven months later."
  pause "Press Enter to finish (stops the query UI)"
}

# ---- preflight ----------------------------------------------------------------

need() { [ -e "$1" ] || { echo "${RED}Missing $1. It is made by scripts/demo-build.sh (see README).${OFF}"; exit 1; }; }
command -v "$APPMAP" >/dev/null 2>&1 || { echo "${RED}AppMap CLI not found. Install the AppMap IDE extension, or set APPMAP.${OFF}"; exit 1; }
mkdir -p work
# The query databases hold absolute paths, so they are built here, not committed.
if [ ! -f $QDB/base.query.db ] || [ ! -f $QDB/head.query.db ]; then
  echo "${DIM}First run: indexing the recordings (a few seconds)...${OFF}"
  build_query_dbs || { echo "${RED}appmap index failed.${OFF}"; exit 1; }
fi
for f in $DEMO/01-code.diff $DEMO/03-compare.txt $DEMO/05-summary.txt \
         $DEMO/report/diff/vitest/project.delete_called_by_a_non-member.diff.sequence.json \
         $DEMO/report/head/vitest/project.delete_called_by_a_non-member.appmap.json; do need "$f"; done

# ---- the runner ---------------------------------------------------------------

CUR=0
while [ "$CUR" -le "$LAST" ]; do
  ( "step_$CUR" ); rc=$?
  if   [ "$rc" -eq 0 ];         then CUR=$(( CUR + 1 ))
  elif [ "$rc" -eq $NAV_BACK ]; then [ "$CUR" -gt 0 ] && CUR=$(( CUR - 1 ))
  elif [ "$rc" -eq $NAV_QUIT ]; then echo "${DIM}Quit.${OFF}"; break
  elif [ "$rc" -ge $NAV_JUMP ] && [ $(( rc - NAV_JUMP )) -le "$LAST" ]; then CUR=$(( rc - NAV_JUMP ))
  else echo "${RED}Step $CUR failed (exit $rc).${OFF}"; exit "$rc"
  fi
done
