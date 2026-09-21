# AppMap Behavioral Review: membership check added to five project procedures, not to their neighbors

**Revisions:** `appmap-head` (57ce1ccf) vs `appmap-base` (cb97e012) · **Date:** 2026-09-16 ·
**Commits:** `57ce1ccf` Fix CVE-2025-63783: Add authorization checks to project mutation APIs (#3062)

> ⚠️ **How this review works.** Eighteen small tests call the Onlook web client's tRPC API
> over HTTP, through the application's real router, against a real PostgreSQL database.
> Each test run was recorded (a gold trace: the HTTP request, the functions and the SQL
> the request actually executed, and the response) on the base revision and again on the
> head revision, and the two sets of recordings were compared. Timing and data values are
> excluded from the comparison, so every change reported below is a real difference in
> what ran. Three caveats, stated once. This is the first baseline for the repository.
> The committed recordings are sanitized, and the sanitizer turns the request path
> `/api/trpc/project.update` into `/api/trpc/:param`, so a trace's route does not name
> the procedure. The test name does. The tRPC procedure handlers and the sign-in middleware
> are anonymous functions, which the Node recorder does not name, so a trace shows the
> request, the named helpers, the SQL and the response.

## What the change does

Onlook projects belong to the people listed as their members. Before this change any
signed in person could send a request naming any project id, and the server would rename,
delete or re-tag that project without asking whether the caller was a member. The change
adds one function, `verifyProjectAccess`, that looks the project up together with the
caller's membership row and refuses when either is missing, and calls it from five
procedures in the project router: `update`, `delete`, `addTag`, `removeTag` and
`captureScreenshot`. The `delete` procedure now runs the check inside its transaction and
deletes the membership rows before the project row. Everything else in the API is
unchanged, including the neighboring procedures in the same file and the sibling routers
that read and write a project by id.

## Summary

| Severity | Findings | Action required |
| --- | --- | --- |
| 🔴 High | 1 · A signed in stranger can still open and change another person's project through every project scoped procedure the change did not touch (#1) | Apply the membership check to every procedure that takes a project id, or a child of a project, before merge |
| 🟡 Medium | 1 · A refused stranger receives a server error (HTTP 500), and from `captureScreenshot` a 200 that looks like a configuration failure (#2) | Throw a `TRPCError` from the helper, let `captureScreenshot` propagate it |
| 🟢 Low | 1 · The membership check reads the whole project plus a JSON list of memberships to answer yes or no, and the tag procedures then read the project a second time (#3) | Narrow the query, reuse the loaded row |

Merge blocking. The five procedures the change protects are protected, and the recordings
prove it. The recordings also prove that `project.get`, `settings.upsert` and
`member.remove` still succeed for a stranger on the head revision exactly as they did on
the base revision, and the source shows the same pattern in roughly forty more procedures
across the routers. The single most important action is to finish the job the pull request
describes: one membership check on every project scoped procedure, ideally as a shared
tRPC middleware so a new procedure cannot forget it.

## Findings

### 1 · 🔴 HIGH: A signed in stranger can still open and change another person's project through the procedures the change did not touch

**File:** [apps/web/client/src/server/api/routers/project/project.ts:194](apps/web/client/src/server/api/routers/project/project.ts) (`get`),
[apps/web/client/src/server/api/routers/project/settings.ts:27](apps/web/client/src/server/api/routers/project/settings.ts) (`upsert`),
[apps/web/client/src/server/api/routers/project/member.ts:44](apps/web/client/src/server/api/routers/project/member.ts) (`remove`),
and the sibling routers listed below ·
**Evidence:** traces `project.get called by a non-member`, `settings.upsert called by a non-member`
and `member.remove called by a non-member` (unchanged between base and head, HTTP 200 and
the write on both) against `project.update called by a non-member` and
`project.delete called by a non-member` (changed, HTTP 500 and no write on head)

**Background.** The web client's API is a set of tRPC procedures behind `/api/trpc`.
`protectedProcedure` checks only that someone is signed in. Which projects that person
may touch is recorded in the `user_projects` table, and the server's database connection
is exempt from row level security, so membership is enforced only where application code
checks it. The change adds that check, `verifyProjectAccess`, and calls it from five
procedures in `project.ts`.

```
signed in stranger S, not a member of project P
  |
  |  procedures the change protected (head recordings)
  |-- POST project.update(P)  -> verifyProjectAccess -> SELECT projects + S's memberships
  |                              -> Error -> 500, no UPDATE
  |-- POST project.delete(P)  -> BEGIN -> verifyProjectAccess -> SELECT ... -> Error
  |                              -> ROLLBACK -> 500, no DELETE
  |
  |  procedures the change left alone (head recordings, identical to base)
  |-- GET  project.get(P)         -> SELECT projects WHERE id = P       -> 200, P returned to S
  |-- POST settings.upsert(P)     -> INSERT project_settings ...        -> 200, P's run command
  |                                  ON CONFLICT DO UPDATE                 replaced by S
  |-- POST member.remove(owner,P) -> DELETE FROM user_projects          -> 200, owner removed
  |                                  WHERE user_id = owner AND project_id = P   from their project
  |
  |  same pattern, read from the source at head, not recorded
  |-- project.getProjectWithCanvas, settings.get, settings.delete, member.list,
      branch.getByProjectId / create / update / delete / fork / createBlank,
      frame.get / getByCanvas / create / update / delete, invitation.list / create / delete,
      createRequest.*, chat conversations and messages, domains, deployments, userCanvas
```

**What is right.** The five procedures that got the check refuse a non-member and let a
member through, and the recordings show exactly how: the owner's `update` gains the
membership query in front of its `UPDATE`, the stranger's `update` stops at that query
with an exception and never reaches the `UPDATE` or the row mapper, and the stranger's
`delete` opens its transaction, is refused, and rolls back instead of issuing the two
`DELETE`s. Moving the check inside the `delete` transaction and deleting memberships
before the project are both sound.

**What is off.** A person who creates an account and obtains a project id, by guessing,
from a shared link, or from an old invitation, can still read your project, change the
run, build and install commands that execute in your sandbox, remove you from your own
project, and create, rename, or delete branches and frames. The pull request's
description says all project mutations now verify ownership. Three recordings on the head
revision show project scoped requests that do not: `settings.upsert` and `member.remove`
write to the project's data for a stranger exactly as they did on the base revision, and
`project.get` hands the project back. The test suite says the same thing in its own way:
the five stranger tests written before this change all expected a refusal, two of them
now get one, and three still carry the expected-failure marker.

**Fix.** Apply `verifyProjectAccess(ctx.db, ctx.user.id, input.projectId)` at the top of
every procedure whose input names a project, and for procedures keyed by a branch, frame,
canvas, conversation or invitation id, load the parent project id first and check that.
Better, define a `projectProcedure` middleware in `trpc.ts` that reads `projectId` from
the parsed input and runs the check once, so a procedure cannot be added without it.
The regression tests already exist in `test/server/`: remove the `fails` marker from
`project.get called by a non-member`, `settings.upsert called by a non-member` and
`member.remove called by a non-member`, and add one stranger test per remaining router in
the same shape:

```ts
test('branch.getByProjectId called by a non-member', async () => {
    const code = await errorCodeOf(
        clientFor(server, OUTSIDER).branch.getByProjectId.query({ projectId: PROJECT_ID }),
    );
    expect(code).toBeDefined();
});
```

### 2 · 🟡 MEDIUM: A refused stranger receives a server error, and from `captureScreenshot` a success status

**File:** [apps/web/client/src/server/api/routers/project/helper.ts:50](apps/web/client/src/server/api/routers/project/helper.ts) ·
**Evidence:** traces `project.update called by a non-member`, `project.delete called by a non-member`,
`project.addTag called by a non-member`, `project.removeTag called by a non-member` and
`project.update of a project that does not exist` (head: `verifyProjectAccess` returns
with an exception of class `Error`, response 500) and
`project.captureScreenshot called by a non-member` (head: the same exception, response 200)

**Background.** tRPC reports a procedure's failure to the client with a code. A
`TRPCError` keeps the code it was given, and any other exception is wrapped as
`INTERNAL_SERVER_ERROR`, which the HTTP layer sends as a 500. `captureScreenshot` wraps
its whole body in a try block and returns `{ success: false, error }` for any failure.

```
verifyProjectAccess -> membership query -> no membership row (or no project)
                    -> throw new Error('Unauthorized or not found')       (plain Error)
tRPC                -> code INTERNAL_SERVER_ERROR, HTTP 500                 (update, delete, tags)
captureScreenshot   -> catch -> { success: false, error: '...' }, HTTP 200  (screenshot)

base recording of the same stranger screenshot request:
                    -> throw new Error('FIRECRAWL_API_KEY is not configured')
                    -> catch -> { success: false, error: '...' }, HTTP 200
```

**What is right.** The message is the same whether the project is missing or the caller
is not a member, so a stranger cannot use the reply to learn which project ids exist.
The recording of `project.update of a project that does not exist` shows the same path as
a refused stranger on head.

**What is off.** The refused person sees a generic failure instead of a not found or not
allowed answer, error monitoring counts every refused request as a server fault, and a
client cannot tell a refusal from an outage. For `captureScreenshot` the stranger gets a
200 whose body is the same shape as a missing API key. The stage 5 test for it passes on
both revisions for different reasons, and only the recording tells them apart: on base
no SQL runs and the request fails on configuration, on head the membership query runs and
the request fails on the check.

**Fix.** Throw `new TRPCError({ code: 'NOT_FOUND', message: 'Unauthorized or not found' })`
from the helper, keeping one code for both cases so nothing about project existence
leaks, move the `verifyProjectAccess` call in `captureScreenshot` above the try block so
the refusal propagates as an error, and assert the code in the refusal tests.

### 🟢 Low

- **3** · The membership check reads more than it needs, and the tag procedures read the project twice ·
  [apps/web/client/src/server/api/routers/project/helper.ts:40](apps/web/client/src/server/api/routers/project/helper.ts),
  [project.ts:387](apps/web/client/src/server/api/routers/project/project.ts) ·
  The new query in every changed trace selects every column of `projects` and a
  `json_agg` of the caller's membership rows through a lateral join, to answer a yes or
  no question, and the `project.addTag called by the owner` trace shows `addTag` then
  loading the same project again with a second `SELECT` before its `UPDATE`. A
  `select 1 from user_projects where user_id = $1 and project_id = $2` answers the
  question in one small round trip, or the helper can return the project it loaded so the
  tag procedures reuse it.

## Checks performed

| Check | Result | Note |
| --- | --- | --- |
| Recorded behavior compared | ⚠️ 9 changed, 0 new, 0 removed → #1, #2, #3 | eighteen gold traces on each side, run-to-run noise such as timings and generated values is ignored, so every reported change is a real difference in what ran |
| Behavior changed in code the PR did not touch | ✅ none | the nine unchanged traces have identical digests on both sides, and all nine changed traces run `project.ts`, which the diff touched |
| Places that should have the check but do not | 🔴 → #1 | three recorded procedures and about forty read from the source still take a project id from the client with no membership check |
| Tests and recordings for the new behavior | ✅ | the helper's member, stranger and missing-project branches and all five guarded procedures are recorded on both revisions, the owner's screenshot path is not, it needs the screenshot service and Supabase storage |
| Database queries | ⚠️ → #3 | the new membership query is parameterized and the new `rollback` is correct, the query shape is wider than the question |
| HTTP responses | ⚠️ → #2 | five head traces return 500 where a refusal is meant, one returns 200 |
| Intended changes confirmed by a recording | ✅ | `update` and `addTag` by the owner still succeed with the check in front of them, `update`, `delete`, `addTag` and `removeTag` by a non-member are refused before any write, `delete` rolls back its transaction, `captureScreenshot` by a non-member stops at the check |

<details>
<summary><b>Review detail</b>: features, coverage, labels, drift</summary>

### Feature List

1. **Membership helper.** Added `verifyProjectAccess(db, userId, projectId)` in `helper.ts`, which loads the project with the caller's membership rows and throws `Unauthorized or not found` when either is missing, accepting a database or a transaction.
2. **Guarded update and tags.** `project.update`, `project.addTag` and `project.removeTag` call the helper before they read or write.
3. **Guarded delete inside its transaction.** `project.delete` calls the helper inside the transaction and now deletes `user_projects` rows before the `projects` row.
4. **Guarded screenshot.** `project.captureScreenshot` calls the helper inside its try block, so a refusal comes back as `{ success: false, error }`.

### Coverage Matrix

| Feature | Covered by | Status |
| --- | --- | --- |
| Membership helper, member allowed | `project.update called by the owner`, `project.addTag called by the owner`, `project.delete called by the owner` | ✅ |
| Membership helper, stranger refused | `project.update called by a non-member`, `project.delete called by a non-member`, `project.addTag called by a non-member`, `project.removeTag called by a non-member` | ✅ |
| Membership helper, project missing | `project.update of a project that does not exist` | ✅ |
| Guarded update | `project.update called by the owner`, `project.update called by a non-member` | ✅ |
| Guarded delete inside its transaction | `project.delete called by the owner`, `project.delete called by a non-member` | ✅ |
| Guarded addTag and removeTag | `project.addTag called by the owner`, `project.addTag called by a non-member`, `project.removeTag called by a non-member` | ✅ |
| Guarded screenshot, stranger | `project.captureScreenshot called by a non-member` | ✅ |
| Guarded screenshot, member | no test | out of reach: the success path calls the Firecrawl screenshot service and Supabase storage, and the project has no mocks for either |
| **Sibling procedures that take a project id** | `project.get`, `settings.upsert`, `member.remove` by a non-member | ❌ **unguarded** → #1 (the traces exist and show the stranger succeeding on both revisions, they become the refusal tests once the check is applied) |

The stage 2 baseline (thirteen entries recorded before the change was reviewed) covered
the first two rows for `update` and `delete` and the last row. The five entries added
after reviewing the drift cover the tag procedures, the screenshot procedure and the
missing-project branch. The engine's `covers` command could not answer coverage by name
here: the procedure handlers are anonymous, so the only named application function in
these traces is the helper itself.

### Suggested Labels

- **`security.authorization`** · [apps/web/client/src/server/api/routers/project/helper.ts:35](apps/web/client/src/server/api/routers/project/helper.ts) `verifyProjectAccess` · applied for this review from `appmap.yml` (a `functions:` block on the `src/server` package), so every head trace that runs the check carries the label and the compare shows the check appearing by name. Move it into the source as a `// @label security.authorization` comment above the function so it travels with the code.
- **`security.authentication`** · [apps/web/client/src/server/api/trpc.ts:131](apps/web/client/src/server/api/trpc.ts), the `protectedProcedure` middleware · it is an anonymous arrow function, so it cannot carry a label and does not appear in any trace. Give it a name (`const requireUser = ...`) and label it. Without it, the AppMap scanner reported `authz-before-authn` on four head traces, an authorization check with no recorded authentication before it, which is a false alarm caused by the missing name.

### Behavioral Drift

All nine changed traces are explained by the feature and by code the diff touched.
`project.update called by the owner` and `project.addTag called by the owner` gained
`verifyProjectAccess` and its membership `SELECT` in front of their unchanged writes.
`project.delete called by the owner` kept its `BEGIN` and `COMMIT`, gained the check, and
now deletes `user_projects` before `projects`. The four stranger traces of guarded
procedures (`update`, `delete`, `addTag`, `removeTag`) lost their writes and their row
mapping and gained the check, its `SELECT`, an exception and a 500 response, with
`delete` replacing its two `DELETE`s and `COMMIT` by a `ROLLBACK`.
`project.captureScreenshot called by a non-member` went from a request that ran no SQL
(it failed on a missing API key) to one that runs the check and its `SELECT`, with a 200
on both sides. `project.update of a project that does not exist` replaced an `UPDATE`
that matched no row by the check's `SELECT`, with a 500 on both sides. The nine traces of
procedures the change did not touch held still to the byte in their behavioral digests,
which is the evidence for finding #1: the stranger's calls to `project.get`,
`settings.upsert` and `member.remove` ran the same SQL and got the same 200 on both
revisions. No trace moved outside the stated scope, so there are no side effects to
grade.

</details>

## Setup notes

This section records how the comparison above was produced. It is not part of the review
a pull request would receive. The case's README tells the same story stage by stage.

**Repository and revisions.** onlook-dev/onlook cloned to
a local folder, `cases/onlook/repo`. Branch `appmap-base` at
`cb97e012` (the parent of the change), branch `appmap-head` at `57ce1ccf`. History note
for the reader of this demonstration: the membership check was applied across all
routers seven months later in `423e2e92` (pull request 3129), which touched 25 files.

**Commits made.** On `appmap-base`: config `407011db`, exclusions `3a59f69b`, commands
`5fbb4fbe`, gold baseline `18ea1759`, gold update `e51d6447`. On `appmap-head`, after
cherry-picking the first four (`9427f1a3`, `c3802257`, `31c5dcfe`, `196b0e84`, no
conflicts, `CLAUDE.md` is identical on both revisions): test markers `9573e74c`, gold
update `90ea8d46`. Nothing was pushed.

**Record command from `plan`** (run from `apps/web/client`, the directory that holds
`gold_traces/`, with the engine's detected vitest launcher):

```
npx appmap-node npx vitest run test/server/project.test.ts test/server/settings.test.ts test/server/member.test.ts test/server/branch.test.ts -t '(project\.list called by the owner|...|project\.update of a project that does not exist)' --config vitest.server.config.ts
```

with `SUPABASE_DATABASE_URL=postgresql://postgres@127.0.0.1:54330/onlook_test` in the
environment of every engine run, and `APPMAP_DISPLAY_PARAMS=true` from the manifest's
`record_env`. The engine records the whole set in one vitest run.

**Recording depth.** `appmap.yml` records `src/server` (the tRPC routers and helpers)
and `packages/db/src` (the drizzle schema and row mappers) in full. HTTP requests come
from the recorder's `node:http` hook, SQL from its `pg` hook. No framework is listed and
nothing is excluded: `appmap stats` on the largest recordings showed every function
called once per trace. The test harness is not recorded, so fixture writes and
read-backs never enter a trace. `verifyProjectAccess` is labeled `security.authorization`
from `appmap.yml`.

**Manifest entries and baseline sizes** (`apps/web/client/gold_traces/manifest.yaml`,
`appmap_path` under `vitest/`, bytes as committed):

| test_name | test_file | base bytes | head bytes | stage |
| --- | --- | --- | --- | --- |
| project.list called by the owner | project.test.ts | 6493 | 6493 | 2 |
| project.get called by the owner | project.test.ts | 5196 | 5196 | 2 |
| project.update called by the owner | project.test.ts | 5264 | 8702 | 2 |
| project.delete called by the owner | project.test.ts | 2966 | 5895 | 2 |
| project.get without signing in | project.test.ts | 1600 | 1600 | 2 |
| project.get called by a non-member | project.test.ts | 5205 | 5205 | 2 |
| project.update called by a non-member | project.test.ts | 5271 | 4611 | 2 |
| project.delete called by a non-member | project.test.ts | 2970 | 5265 | 2 |
| settings.upsert called by the owner | settings.test.ts | 3451 | 3451 | 2 |
| settings.upsert called by a non-member | settings.test.ts | 3454 | 3454 | 2 |
| member.list called by the owner | member.test.ts | 5126 | 5126 | 2 |
| member.remove called by a non-member | member.test.ts | 1879 | 1879 | 2 |
| branch.getByProjectId called by the owner | branch.test.ts | 4710 | 4710 | 2 |
| project.addTag called by the owner | project.test.ts | 2701 | 5552 | 5 |
| project.addTag called by a non-member | project.test.ts | 2707 | 4612 | 5 |
| project.removeTag called by a non-member | project.test.ts | 2684 | 4617 | 5 |
| project.captureScreenshot called by a non-member | project.test.ts | 1508 | 4462 | 5 |
| project.update of a project that does not exist | project.test.ts | 2552 | 4621 | 5 |

`check --record` reported all eighteen stable across two recordings on both revisions. It
warned that most traces are small (2 to 14 events) and that the stranger entries cover no
code object, table or route the member entries do not. Both warnings were judged
acceptable: a trace here is the request, the helper calls, the SQL and the response, which
is the behavior under review, and the stranger entries are negative branch tests kept on
purpose, as their summaries say.

**Database.** No container runtime and no Supabase were available on this machine. A
PostgreSQL 16.15 from Homebrew (`brew install postgresql@16`) was initialized with
`initdb -U postgres --auth=trust` in `cases/onlook/pgdata`
and started on port 54330 (`pg_ctl -o "-p 54330 -k /tmp"`, with `LC_ALL=en_US.UTF-8`
set, otherwise the server refuses to start on macOS with "postmaster became
multithreaded"). A database `onlook_test` was created. The project's SQL migrations in
`apps/backend/supabase/migrations` were applied with psql in order (`setup-db.sh` in this
folder) after creating stand-ins for what Supabase provides: an `auth` schema with an
`auth.users` table and an `auth.uid()` function, and the roles `anon`, `authenticated`
and `service_role`. Migrations `0007` (Supabase realtime), `0008` and `0012` (Supabase
storage buckets) were skipped. Row level security policies were applied but do not apply
to the superuser connection the tests use, which matches the application's own
connection.

**Auth.** Supabase auth was not exercised. The test harness serves the real `appRouter`
with tRPC's standalone HTTP adapter and builds the context from two request headers
(`x-test-user-id`, `x-test-user-email`) where production reads the Supabase session, so
`protectedProcedure` sees a signed in user or none, and everything after the context is
the application's own code. Two users and one project, with a membership row, settings, a
canvas and a default branch, are inserted as fixtures with fixed UUIDs before each test.

**Test runner.** The repository's own tests use `bun test`, which appmap-node cannot
instrument. The server tests were written for vitest (already a dev dependency) and run
under Node with a new `apps/web/client/vitest.server.config.ts`, because the existing
`vitest.config.ts` is the Storybook browser project. That config aliases `@` and `~` to
`src`, aliases `@onlook/ai` to its source entry (the package declares only a `module`
field, which vite did not resolve), and supplies dummy values for the environment schema
in `src/env.ts`.

**Recording the SQL.** The application connects with the `postgres` (postgres-js) driver,
which appmap-node does not hook. The harness builds the drizzle database over `pg`
(node-postgres, already a dependency of `@onlook/db`), which appmap-node does hook, and
passes it as `ctx.db`. appmap-node patches `pg` when it is loaded with `require`, so the
harness loads it with `createRequire`. The fixture rows are written through postgres-js
so they do not appear in the recordings.

**Tool limitations met.** Three, none of which changed the result. First, the sanitizer
that runs before a baseline is committed keeps only purely alphabetic path segments, so
`/api/trpc/project.update` is committed as `/api/trpc/:param`: the route in a committed
trace does not name the procedure, the OpenAPI diff sees one route, and the test name
carries the procedure. Second, the compare digest drops root events outside an HTTP
request when a trace contains one. Nothing was lost here because the harness is not
recorded and every recorded event runs inside the request, and that is one reason the
test directory is not listed in `appmap.yml`. Third, the compare counts only recordings
whose `metadata.recorder.type` is `tests` as changed. vitest recordings carry that type,
so it was not hit.

**Other deviations.** Bun 1.4.2 from Homebrew was used where the repository pins
`bun@1.3.1`. `bun install --frozen-lockfile` left `bun.lock` untouched. The project's own
`bun test` in `apps/web/client` ran 155 tests in 16 files: 151 passed and 4 failed for
want of environment variables the env schema requires, none of them server-side. No
`sleep` was used, engine and test runs were given long timeouts.

Source: https://github.com/evlawler/goldtrace-examples/tree/main/onlook-partial-authorization-check · CC BY 4.0.
