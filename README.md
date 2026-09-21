# Onlook: the security fix that left the door open

A guided demo of reviewing a pull request by what the code **does**, not only by what the
diff says, using AppMap gold traces.

    upstream     onlook-dev/onlook (Apache 2.0). Visual editor for web apps, with hosted projects.
    stack        TypeScript, Next.js, tRPC, drizzle, PostgreSQL, Supabase
    BASE         cb97e0127   the commit before the fix
    HEAD         57ce1ccfa   the fix, pull request 3062, merged 13 Dec 2025
    real fix     pull request 3129, 21 Jul 2026, about seven months later
    bug class    missing authorization (CWE-862)

## The story

After a security report, Onlook added a membership check, `verifyProjectAccess`, to five
tRPC procedures. About forty sibling procedures kept trusting the project id sent by the
browser. Any signed in user who knew another user's project id could still read and change
that project.

The pull request looked complete. This demo shows what a reviewer would have seen with
recordings of the code running, before and after:

| A signed in stranger calls | BASE | HEAD (after the fix) |
|---|---|---|
| `project.update` | 200, `UPDATE projects` | 500, check ran, no write |
| `project.delete` | 200, deletes committed | 500, check ran, rollback |
| `project.addTag`, `removeTag` | 200, `UPDATE projects` | 500, check ran, no write |
| `project.get` | 200, reads the project | **200, no check, same read** |
| `settings.upsert` | 200, `INSERT` | **200, no check, same `INSERT`** |
| `member.remove` | 200, `DELETE FROM user_projects` | **200, no check, same `DELETE`** |

The bold rows are the finding. Those recordings are identical on both commits. The full
review is in [REVIEW.md](REVIEW.md), and the record of how the case was made is in
[docs/CASE-STUDY.md](docs/CASE-STUDY.md).

Onlook had no tests for its server API, and the pull request added none. The 18 tests here
were written for this case study and put on both commits unchanged (apart from
expected-failure markers). They are the tests a careful team writes for an application
with many tenants.

## Watch the demo

Needs the AppMap CLI (the AppMap IDE extension installs it in `~/.appmap/bin`) and, for the
visual steps, VS Code with the AppMap extension. It does **not** need Onlook, Bun or a
database. Everything it shows is committed here.

    ./demo.sh               8 steps, waits for Enter, opens VS Code and the query UI
    NO_VISUAL=1 ./demo.sh   terminal only
    DEMO_AUTO=1 ./demo.sh   no pauses, no windows

The demo prints each working command without running it, then shows what that command
produced. Those outputs are real. `scripts/demo-build.sh` made them from actual runs. Only
the viewers really start: `code`, and `appmap query ui` on ports 4476 and 4477.

| Step | You see |
|---|---|
| 1 | The code diff: 2 files, 41 lines. It reads well. |
| 2 | The tests running under the recorder, the recording files, and one AppMap in VS Code |
| 3 | The compare: 18 traces, 9 changed |
| 4 | Where the fix worked: the sequence diagram diff for a stranger's `project.delete` |
| 5 | Where it is missing: the stranger traces with no diff at all |
| 6 | A label query: which requests ran an authorization check |
| 7 | Both commits side by side in the query UI |
| 8 | The review this produces |

## Record it yourself

Needs git, Node 22, Bun, PostgreSQL 15 or newer, the AppMap CLI, and the
[getappmap/skills](https://github.com/getappmap/skills) (cloned for you if missing).

    ./setup.sh

```
this repo (committed)                       built by setup.sh (ignored by git)
─────────────────────                       ──────────────────────────────────
overlay/base/  ──copied on top of──▶  base/   Onlook at cb97e0127, branch appmap-base
overlay/head/  ──copied on top of──▶  head/   Onlook at 57ce1ccfa, branch appmap-head
                                        │
                                        └── both are worktrees of work/onlook.git (one clone)

recordings/  ◀──saved from── base/ and head/ test runs
demo/        ◀──saved from── the compare and query tools
                                      pgdata/   PostgreSQL for the tests, port 54330
```

`base/` and `head/` are two checkouts of the same clone. You can work in both at once, and
the review tool can still compare them as two git revisions, which is what it needs.

    source scripts/env.sh                  short commands: gold, review, q, db_start, db_stop
    (cd head && gold check --record)       record every gold trace twice, check they agree
    (cd head && gold update --dry-run)     fresh recordings against the committed baselines
    (cd head && review compare --base appmap-base --head appmap-head)
    q head find calls --label security.authorization

    RECORD=1 scripts/demo-build.sh         record both sides again, refresh recordings/ and demo/
    scripts/sync-overlay.sh                copy your changes in base/ and head/ back to overlay/

`overlay/` is the master copy of everything added to Onlook: `appmap.yml`, the vitest
config, the test harness and tests, and the gold traces manifest and baselines. Edit in
`base/` or `head/`, run `scripts/sync-overlay.sh`, then commit this repo.

## What is in this repo

    README.md            this file
    REVIEW.md            the behavioral review of HEAD against BASE, findings first
    docs/CASE-STUDY.md   how the case was made, stage by stage
    demo.sh              the guided demo
    setup.sh             builds base/, head/ and the database
    overlay/             the files added on top of each Onlook commit (about 370 KB)
    recordings/          the 36 live recordings, values replaced by tokens (about 230 KB)
    demo/                saved outputs the demo shows, and the compare report
    scripts/             env.sh, demo-build.sh, sync-overlay.sh, setup-db.sh, summarize.mjs

Nothing from Onlook's source is stored here except the two files the overlay changes in
full (`.gitignore` and `CLAUDE.md`).

## Known quirks

- **`bun install --frozen-lockfile` fails** at these commits, because the lockfile does not
  match `package.json`. `setup.sh` installs normally and then restores `bun.lock`.
- **A trace that runs the check is sometimes unstable on HEAD.** The recorder sometimes logs
  the membership `SELECT` after the HTTP response instead of inside `verifyProjectAccess`.
  The request, the SQL and the status are the same. It shows up most on the `addTag` traces,
  and now and then on others. `gold check --record` then reports "Nondeterministic gold
  traces". Run it again. The committed baseline for `project.addTag called by the owner` has
  the late order, so `gold update --dry-run` may offer to bless that one trace.
  `scripts/demo-build.sh` warns if the trace featured in step 4 was saved with the late order.
- **Keep recordings out of hidden folders.** The query UI returns 404 for a recording under
  a folder whose name starts with a dot, and the VS Code diff viewer fails the same way.
- **The VS Code diff viewer needs the HEAD recording** at `report/head/vitest/<name>.appmap.json`
  next to `report/diff/`. `scripts/demo-build.sh` keeps that layout in `demo/report/`.
- **Every route reads `/api/trpc/:param`.** The sanitizer strips the procedure name. Find
  traces by test name.
- **The database is a stand-in.** A plain PostgreSQL replaces Supabase, with the `auth`
  schema and roles made by hand and three Supabase-only migrations skipped. What that
  cannot show is listed in [docs/CASE-STUDY.md](docs/CASE-STUDY.md).

## Credits and licenses

The case study (the tests, the recording setup, the gold traces, `REVIEW.md` and
`docs/CASE-STUDY.md`) comes from the `onlook-partial-authorization-check` example in
goldtrace-examples:

https://github.com/evlawler/goldtrace-examples/tree/main/onlook-partial-authorization-check

It is licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). `docs/CASE-STUDY.md` is that example's README. Only its links and an
opening note were changed.

Onlook is by onlook-dev, licensed Apache 2.0. Repositories, commits and pull request
numbers are named. The people who wrote them are not. Nothing here is sent upstream.
