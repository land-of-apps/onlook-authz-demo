import { afterAll, beforeAll, beforeEach, describe, expect, test } from 'vitest';
import {
    BRANCH_ID,
    cleanupFixture,
    clientFor,
    OWNER,
    PROJECT_ID,
    resetFixture,
    startServer,
    type TestServer,
} from './support/harness';

// The branch router over HTTP: a project's branches, each tied to a sandbox.

let server: TestServer;

beforeAll(async () => {
    server = await startServer();
});

afterAll(async () => {
    await server.close();
    await cleanupFixture();
});

beforeEach(resetFixture);

describe('branch procedures called by a member', () => {
    test('branch.getByProjectId called by the owner', async () => {
        const branches = await clientFor(server, OWNER).branch.getByProjectId.query({ projectId: PROJECT_ID });
        expect(branches.map((branch) => branch.id)).toEqual([BRANCH_ID]);
        expect(branches[0]?.isDefault).toBe(true);
    });
});
