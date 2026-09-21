import type { AppRouter } from '@/server/api/root';
import { appRouter } from '@/server/api/root';
import type { DrizzleDb } from '@onlook/db';
import * as schema from '@onlook/db/src/schema';
import type { User } from '@supabase/supabase-js';
import { createTRPCClient, httpLink, TRPCClientError } from '@trpc/client';
import { createHTTPServer } from '@trpc/server/adapters/standalone';
import { drizzle } from 'drizzle-orm/node-postgres';
import { createRequire } from 'node:module';
import type { AddressInfo } from 'node:net';
import postgres from 'postgres';
import superjson from 'superjson';

// Test harness for the server side of the web client: the tRPC API.
//
// The application's real router (appRouter) is served over HTTP with tRPC's
// standalone adapter, and the tests call it with the real tRPC client, so a
// request travels the same pipeline as in production: HTTP request, procedure
// lookup, input parsing, the protectedProcedure middleware, the procedure body,
// the SQL it issues, and the HTTP response.
//
// Two things stand in for services that are not available in a test:
//
// - Sign in. In production createTRPCContext asks Supabase auth for the user
//   behind the session cookie. Here the request carries the test user's id and
//   email in two headers and the context is built from them. Everything after
//   the context is the application's own code.
// - The database driver. The application connects with postgres-js, which the
//   AppMap recorder does not hook, so the tests build the same drizzle database
//   over node-postgres (`pg`, already a dependency of @onlook/db), which it does.
//   `pg` is loaded with require so a recorder that patches the driver when it is
//   required sees the same module instance drizzle uses.
//
// The fixture rows are written through postgres-js so that a recording of a
// test shows only the SQL the procedure under test issued.

export const DATABASE_URL = process.env.SUPABASE_DATABASE_URL!;

export type Person = { id: string; email: string };

export const OWNER: Person = { id: '11111111-1111-4111-8111-111111111111', email: 'owner@example.com' };
export const OUTSIDER: Person = { id: '22222222-2222-4222-8222-222222222222', email: 'outsider@example.com' };
export const PROJECT_ID = '33333333-3333-4333-8333-333333333333';
export const BRANCH_ID = '44444444-4444-4444-8444-444444444444';
export const CANVAS_ID = '55555555-5555-4555-8555-555555555555';
export const PROJECT_NAME = 'Owner project';
export const RUN_COMMAND = 'bun dev';
export const SEED_TAG = 'seed';
export const MISSING_PROJECT_ID = '99999999-9999-4999-8999-999999999999';

const pg = createRequire(import.meta.url)('pg') as typeof import('pg');
const pool = new pg.Pool({ connectionString: DATABASE_URL, max: 1 });
const db = drizzle(pool, { schema }) as unknown as DrizzleDb;

export const fixture = postgres(DATABASE_URL, { prepare: false, max: 1 });

function userFor(id: string, email: string): User {
    return {
        id,
        email,
        aud: 'authenticated',
        app_metadata: {},
        user_metadata: {},
        created_at: '2025-01-01T00:00:00.000Z',
    } as unknown as User;
}

export type TestServer = { url: string; close: () => Promise<void> };

export async function startServer(): Promise<TestServer> {
    const server = createHTTPServer({
        router: appRouter,
        basePath: '/api/trpc/',
        createContext: ({ req }) => {
            const id = req.headers['x-test-user-id'];
            const email = req.headers['x-test-user-email'];
            const user = typeof id === 'string' && typeof email === 'string' ? userFor(id, email) : null;
            const headers = new Headers();
            for (const [name, value] of Object.entries(req.headers)) {
                if (typeof value === 'string') headers.set(name, value);
            }
            return { db, supabase: null as never, user, headers };
        },
    });
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    const { port } = server.address() as AddressInfo;
    return {
        url: `http://127.0.0.1:${port}`,
        close: () =>
            new Promise<void>((resolve, reject) => server.close((error) => (error ? reject(error) : resolve()))),
    };
}

// A tRPC client signed in as `person`, or with no session when `person` is null.
export function clientFor(server: TestServer, person: Person | null) {
    return createTRPCClient<AppRouter>({
        links: [
            httpLink({
                url: `${server.url}/api/trpc`,
                transformer: superjson,
                headers: person ? { 'x-test-user-id': person.id, 'x-test-user-email': person.email } : {},
            }),
        ],
    });
}

// The tRPC error code of a failed call, or undefined when the call succeeded.
export async function errorCodeOf(call: Promise<unknown>): Promise<string | undefined> {
    try {
        await call;
        return undefined;
    } catch (error) {
        if (error instanceof TRPCClientError) return error.data?.code as string | undefined;
        throw error;
    }
}

// One project owned by OWNER, with a default branch, a canvas and settings.
// OUTSIDER is a signed in user with no relation to the project.
export async function resetFixture(): Promise<void> {
    await fixture`delete from projects where id = ${PROJECT_ID}`;
    await fixture`delete from auth.users where id in (${OWNER.id}, ${OUTSIDER.id})`;
    await fixture`insert into auth.users (id, email) values (${OWNER.id}, ${OWNER.email}), (${OUTSIDER.id}, ${OUTSIDER.email})`;
    await fixture`insert into users (id, email) values (${OWNER.id}, ${OWNER.email}), (${OUTSIDER.id}, ${OUTSIDER.email})`;
    await fixture`insert into projects (id, name, tags) values (${PROJECT_ID}, ${PROJECT_NAME}, ${[SEED_TAG]})`;
    await fixture`insert into user_projects (user_id, project_id, role) values (${OWNER.id}, ${PROJECT_ID}, 'owner')`;
    await fixture`insert into project_settings (project_id, run_command) values (${PROJECT_ID}, ${RUN_COMMAND})`;
    await fixture`insert into canvas (id, project_id) values (${CANVAS_ID}, ${PROJECT_ID})`;
    await fixture`insert into branches (id, project_id, name, is_default, sandbox_id) values (${BRANCH_ID}, ${PROJECT_ID}, 'main', true, 'sandbox-1')`;
}

export async function cleanupFixture(): Promise<void> {
    await fixture`delete from projects where id = ${PROJECT_ID}`;
    await fixture`delete from auth.users where id in (${OWNER.id}, ${OUTSIDER.id})`;
    await fixture.end();
    await pool.end();
}

// Read-back helpers, through the fixture connection.
export async function projectName(): Promise<string | undefined> {
    const rows = await fixture<{ name: string }[]>`select name from projects where id = ${PROJECT_ID}`;
    return rows[0]?.name;
}

export async function projectTags(): Promise<string[] | undefined> {
    const rows = await fixture<{ tags: string[] }[]>`select tags from projects where id = ${PROJECT_ID}`;
    return rows[0]?.tags;
}

export async function memberIds(): Promise<string[]> {
    const rows = await fixture<{ user_id: string }[]>`select user_id from user_projects where project_id = ${PROJECT_ID}`;
    return rows.map((row) => row.user_id);
}

export async function runCommand(): Promise<string | undefined> {
    const rows = await fixture<{ run_command: string }[]>`select run_command from project_settings where project_id = ${PROJECT_ID}`;
    return rows[0]?.run_command;
}
