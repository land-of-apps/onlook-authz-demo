# Onlook: Any signed in user could edit anyone's project

> This is the README of the original example, `onlook-partial-authorization-check`:
> https://github.com/evlawler/goldtrace-examples/tree/main/onlook-partial-authorization-check
> It records how the case was made. Only links and this note were changed.
> In this repo: `files/base` and `files/head` are `overlay/base` and `overlay/head`,
> `reproduce.sh` became `setup.sh` and `scripts/demo-build.sh`, and `setup-db.sh` is in
> `scripts/`. Its branches `appmap-base` and `appmap-head` are the folders `base/` and `head/`.

    upstream       onlook-dev/onlook
    what it is     Visual editor for web applications, with hosted projects
    stack          TypeScript, Next.js, tRPC, drizzle, PostgreSQL, Supabase
    BASE           cb97e0127   the commit before the bug
    HEAD           57ce1ccfa   the commit that introduced it (pull request 3062)
    bug shipped    13 Dec 2025
    bug fixed      21 Jul 2026 (pull request 3129)
    in production  About seven months
    taxonomy       lp1-019, matches AI-D10 and AI-07, CWE-862

The review of HEAD against BASE is in [REVIEW.md](../REVIEW.md). It is written as the
review the pull request would have received before merge. This README records how it
was produced, one section per stage of the protocol of the goldtrace-examples collection.

## What the application does

Onlook is a design tool where people build and host web projects. Each project belongs to
its members, listed in a `user_projects` table. The browser talks to the server through
tRPC, a typed remote procedure call layer: every operation is a procedure such as
`project.update`, reached over HTTP at `/api/trpc/project.update`. The server talks to
its database with an account that is exempt from the database's own row level security,
so every decision about who may see or change a project rests on the application code.

## Stage 1: where the bug is

After a security report in December 2025, HEAD added a helper, `verifyProjectAccess`,
that checks whether the signed in user is a member of the project named in the request,
and called it from five procedures in the project router: `update`, `delete`, `addTag`,
`removeTag` and `captureScreenshot`. About forty other procedures, in the same file and
in the sibling routers for settings, members, branches, frames, invitations, canvases and
chat, kept taking a project id from the browser and trusting it. Any signed in user who
obtained another user's project id could still read and change that project. This
knowledge chose BASE and HEAD and is used again only in stage 6 to judge the result.
Nothing from it went into stage 2.

## Stage 2: the baseline on BASE

**The project's own tests.** The web client has sixteen `bun test` files under
`apps/web/client/test` and `src`: locale files, a file cache, frame navigation, sandbox
port detection, a pages helper, git utilities. They test browser-side helpers. None of
them runs a tRPC procedure or touches the database, and `bun` cannot be instrumented by
the Node recorder. They were run as-is: 151 passed and 4 failed for want of environment
variables. They contributed nothing to the baseline, and the setup did not touch them.

**Recording depth.** The stack decided it. The application's own server code is recorded
in full: `src/server` (the tRPC routers, procedures and helpers) and the shared database
package `packages/db/src` (the drizzle schema and the row mappers). The request pipeline
is captured by the recorder's HTTP hook and the database layer by its SQL hook, so every
trace is one HTTP request, the application functions it ran, the SQL statements those
functions issued, and the response status. Frameworks (tRPC, drizzle, zod) are not
listed, because they decide nothing about who may do what. Nothing is excluded: the
largest recording is 6 KB and every function in it runs once. The one decision worth a
label on BASE, the sign-in check in `protectedProcedure`, is an anonymous function the
recorder cannot label, and the source has no named authorization function at all. That
absence is itself a fact about BASE.

**How the tests reach the code.** A small harness (`test/server/support/harness.ts`)
serves the application's real root router with tRPC's standalone HTTP adapter and calls
it with the real tRPC client, so a request travels the same pipeline as in production.
Two stand-ins were needed. Sign in: production asks Supabase for the user behind the
session cookie, the harness reads the test user from two request headers and builds the
same context. The database driver: the application uses postgres-js, which the recorder
does not hook, so the harness builds the same drizzle database over `pg`, which it does.
The fixture (two users, one project with a membership row, settings, a canvas and a
default branch) is written through postgres-js so it never appears in a trace.

**The tests written as ordinary coverage.** Four test files by router, thirteen tests,
all new because the project had none for the server:

- Eight as a member of the project, the flows a user takes: `project.list`,
  `project.get`, `project.update`, `project.delete`, `settings.upsert`, `member.list`,
  `branch.getByProjectId`.
- One with no session: `project.get` is refused with 401 before any SQL.
- Five as a signed in stranger who is not a member, one per project scoped operation
  category, the negative cases a careful team writes for a multi-tenant application:
  read (`project.get`), update (`project.update`), delete (`project.delete`), settings
  (`settings.upsert`), membership (`member.remove`). Each expects a refusal.

**What happened when they ran.** All five stranger tests failed on BASE. The application
refuses no signed in user anything. That was the first result of stage 2, before any
recording was compared. Because a gold trace must come from a passing test, the five
were marked with vitest's expected-failure marker (`test.fails`), which keeps the
assertion as written, records the defect, and lets the suite stay green. The recordings
of those runs show what the stranger's request did: `POST project.update` runs
`UPDATE projects` and returns 200, `member.remove` runs `DELETE FROM user_projects` and
returns 200, and so on.

**The engine.** `discover` was run for each of the thirteen tests to get its
`appmap_path`. `check --record` recorded each twice and found all thirteen stable. It
warned that the traces are small and that the five stranger entries cover no route,
table or function the member entries do not. Both were judged acceptable and the reasons
are in the entry summaries. `update` seeded the baseline. Commits on `appmap-base`:
`407011db` config, `3a59f69b` exclusions (a note that nothing needed excluding),
`5fbb4fbe` commands, `18ea1759` gold baseline.

## Stage 3: apply the change

The four commits were cherry-picked onto HEAD without conflict (`CLAUDE.md`, which got a
pointer line, is identical on both revisions). `check --record` was run with the same
entries and the same config. Two tests failed with "Expect test to fail":
`project.update called by a non-member` and `project.delete called by a non-member` now
get the refusal they expected, so their markers no longer held. The other three stranger
tests still passed as expected failures: the stranger still succeeds against
`project.get`, `settings.upsert` and `member.remove`. The two markers were removed
(commit `9573e74c`, the only test edit at this stage) so the set could be recorded, and
`update --dry-run` reported 4 traces to bless (`update` and `delete` by the owner and by
the stranger) and 9 unchanged. Nothing was added.

## Stage 4: review the drift and the coverage

`appmap-review compare` of BASE against the fresh HEAD recordings:

    Traces: 4 changed, 0 new, 0 removed.
    SQL: 2 new queries (the membership SELECT with a lateral join, and rollback), 0 removed.
    API: 1 non-breaking difference (a 500 response on POST /api/trpc/{param}).
    Scanner findings: 1 new (http-500 on project.delete called by a non-member).

What changed: the owner's `update` and `delete` gained `verifyProjectAccess` and its
`SELECT` in front of their writes, and `delete` now removes memberships before the
project. The stranger's `update` and `delete` lost their writes and gained the check, an
exception and a 500, with `delete` rolling back. What did not change: the nine other
traces, including the three stranger traces of `project.get`, `settings.upsert` and
`member.remove`, byte for byte in their digests. The stranger's request ran the same SQL
and got the same 200 on both revisions.

Coverage matrix of the diff: the helper and the guarded `update` and `delete` were
covered by traces that changed. The guarded `addTag`, `removeTag` and
`captureScreenshot` were covered by nothing. The helper's other branch, a project that
does not exist, was covered by nothing. The engine's `covers` command could not help:
the procedure handlers are anonymous, so no baseline names them. The important behaviors
the change touched with no test were therefore the check on the three guarded procedures
the baseline did not run, and the check's missing-project branch. The absence finding was
already visible: three recorded siblings, and about forty in the source, keep no check.

## Stage 5: go deep on those areas, on both branches

Five tests were added to `test/server/project.test.ts`, on both branches, with the
expected-failure marker on BASE where the stranger still succeeds there:

- `project.addTag called by the owner` (the check's member branch on a tag write).
- `project.addTag called by a non-member` and `project.removeTag called by a non-member`
  (refused on HEAD, expected failures on BASE).
- `project.captureScreenshot called by a non-member`. The procedure reports failure in
  its return value, so the test asserts only `success === false` and passes on both
  branches for different reasons. The recording shows which: on BASE no SQL runs and the
  request fails on a missing screenshot API key, on HEAD the membership query runs and the
  request fails on the check. The owner's screenshot path was not added: it needs the
  Firecrawl screenshot service and Supabase storage, and the project has no mocks for
  either.
- `project.update of a project that does not exist`, the empty-result branch of the write
  and of the check.

The recording was widened by one label: `appmap.yml` marks `verifyProjectAccess` as
`security.authorization` through a `functions:` block on the `src/server` package, on
both branches (the function does not exist on BASE, where the entry is inert). The layer
where the decision is made, the helper and its SQL, was already reached by the baseline.

On HEAD: `discover` for each new test, entries added, `check --record` stable across two
recordings, `update` blessed 4 and seeded 5, commit `90ea8d46`. On BASE: the same files,
`check --record`, `update` seeded 5 and left the 13 stage 2 baselines unchanged, commit
`e51d6447`. Between the two branches the test files differ by four expected-failure
markers and nothing else.

## Stage 6: compare and review

`appmap-review compare appmap-base appmap-head` with eighteen entries on each side:

    Traces: 9 changed, 0 new, 0 removed.
    SQL: 2 new queries, 0 removed.
    API: no breaking change, 0 other differences.
    Scanner findings: 4 new (authz-before-authn), 0 resolved.

The review is [REVIEW.md](../REVIEW.md). One high finding: a signed in stranger can still
open and change another person's project through every procedure the change did not
touch, proved by three recordings that are identical on both revisions next to four that
changed. One medium: a refused stranger gets a 500, and from `captureScreenshot` a 200.
One low: the check reads a whole project and a JSON list of memberships to answer yes or
no, and the tag procedures read the project twice. The four scanner findings are a false
alarm caused by the anonymous sign-in middleware, which no trace can name.

**Which stage made the bug visible.** The stage 2 baseline alone. The five stranger tests
written as ordinary coverage expected a refusal and failed on BASE, so the team would
have known before this change that no membership check existed. Run again on HEAD, two
passed and three still failed as expected failures, so the test suite alone said the fix
was partial. The stage 2 traces said the same thing in the compare: `project.get`,
`settings.upsert` and `member.remove` unchanged for the stranger, `update` and `delete`
changed. Stage 5 did not find the bug. It proved that the five procedures the change
protected are protected, recorded the check's missing-project branch, and showed one
case, `captureScreenshot`, where the test cannot tell a refusal from a configuration
failure and the trace can. The recordings prove three of the unprotected procedures. The
source shows about forty.

## What the stand-in database could not show

No container runtime was available, so a PostgreSQL 16.15 from Homebrew stood in for
Supabase, with an `auth` schema, an `auth.uid()` function and the Supabase roles created
by hand and three Supabase-only migrations skipped (`setup-db.sh`). What it could not
show: Supabase auth itself, that is how a session cookie becomes the user the router sees
(the harness supplies the user from a header, so a bug in that step is out of reach), row
level security as the `authenticated` role would experience it (it does not apply to the
application's own connection either, which is the point of the case), realtime broadcast
triggers, and the storage buckets that `captureScreenshot` uploads to. Remote services
the tested procedures would call (Firecrawl, Resend, CodeSandbox) were not reached and
not mocked. The project keeps no check that its mocks match the real services: its
`test/setup.ts` stubs the tRPC client by hand for the browser-side tests, and there is no
contract test or recorded fixture.

## Tool limitations met

- The sanitizer that runs before a baseline is committed keeps only purely alphabetic
  path segments, so `/api/trpc/project.update` is committed as `/api/trpc/:param`. The
  route in a committed trace does not name the procedure. The test name does, and the
  compare still tells the traces apart by their SQL, functions and status codes. The
  OpenAPI diff sees one route.
- The compare digest drops root events outside an HTTP request when a trace contains one.
  Nothing was lost here, because the harness is not recorded and every recorded event
  runs inside the request.
- The compare counts only recordings whose `metadata.recorder.type` is `tests` as
  changed. vitest recordings carry that type, so it was not hit.

## What is in this folder

    REVIEW.md          the AppMap behavioral review, findings first, with setup notes at the end
    files/base/        every file the setup added on top of BASE: appmap.yml, the vitest server
                       config, the test harness and tests, the gold traces manifest and baselines,
                       .gitattributes, and the two files it changed (.gitignore, CLAUDE.md) in full
    files/head/        the same on top of HEAD, with the baselines re-recorded there
    setup-db.sh        applies the project's migrations to a plain PostgreSQL with Supabase stand-ins
    reproduce.sh       rebuilds both branches in ./repo and runs the comparison

Nothing here is sent to the upstream project. The files only add recording
configuration, tests and gold traces on top of two of its existing commits, in a local
clone.

## Reproduce the review

Needs git, Node 22, Bun, the AppMap CLI at `~/.appmap/bin/appmap` (3.201 or newer, the
IDE extensions install it there) or `appmap` on PATH, and the skills from
getappmap/skills (the script clones them next to this folder if absent).

    ./reproduce.sh                        rebuild the branches and compare the committed gold traces
    PREPARE_DB=1 RECORD=1 ./reproduce.sh  also apply the migrations, install, re-record every gold
                                          trace on both branches, bless, and then compare

Re-recording needs a PostgreSQL database. Set `SUPABASE_DATABASE_URL` to it (the default
is `postgresql://postgres@127.0.0.1:54330/onlook_test`). `PREPARE_DB=1` runs
`setup-db.sh`, which needs `psql` on PATH and does what the Setup notes in REVIEW.md
describe: create the `auth` schema, `auth.users`, `auth.uid()` and the roles `anon`,
`authenticated` and `service_role`, then apply `apps/backend/supabase/migrations` in
order, skipping 0007, 0008 and 0012. On macOS start the server with `LC_ALL` set to a
valid locale.

To change what is recorded, edit `files/head/apps/web/client/appmap.yml` (and the same
file under `files/base/`), or the manifest under `apps/web/client/gold_traces`, and run
the script again with `RECORD=1`. The engine's commands are documented in
`skills/appmap-gold-traces/SKILL.md`.

## The commits the setup made

On `appmap-base`:

    407011db config: AppMap recording for the web client's tRPC API
    3a59f69b exclusions: measured the recordings, nothing to prune
    5fbb4fbe commands: gold-traces manifest with the vitest record command
    18ea1759 chore(gold-traces): establish baseline for the tRPC API
    e51d6447 chore(gold-traces): gold update, the same five entries on the base revision

On `appmap-head`, the first four above cherry-picked, then:

    9573e74c test: project.update and project.delete now refuse a non-member
    90ea8d46 chore(gold-traces): gold update for the project membership check

Repositories, commits and pull request numbers are named. The people who wrote
them are not.

Source: https://github.com/evlawler/goldtrace-examples/tree/main/onlook-partial-authorization-check · CC BY 4.0.
