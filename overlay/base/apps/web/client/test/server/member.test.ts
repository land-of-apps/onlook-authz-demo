import { afterAll, beforeAll, beforeEach, describe, expect, test } from 'vitest';
import {
    cleanupFixture,
    clientFor,
    errorCodeOf,
    memberIds,
    OUTSIDER,
    OWNER,
    PROJECT_ID,
    resetFixture,
    startServer,
    type TestServer,
} from './support/harness';

// The member router over HTTP: who belongs to a project. See project.test.ts
// for the shape of these tests and the meaning of the `fails` marker.

let server: TestServer;

beforeAll(async () => {
    server = await startServer();
});

afterAll(async () => {
    await server.close();
    await cleanupFixture();
});

beforeEach(resetFixture);

describe('member procedures called by a member', () => {
    test('member.list called by the owner', async () => {
        const members = await clientFor(server, OWNER).member.list.query({ projectId: PROJECT_ID });
        expect(members.map((member) => member.user.id)).toEqual([OWNER.id]);
    });
});

describe('member procedures called by a signed in user who is not a member', () => {
    test.fails('member.remove called by a non-member', async () => {
        const code = await errorCodeOf(
            clientFor(server, OUTSIDER).member.remove.mutate({ userId: OWNER.id, projectId: PROJECT_ID }),
        );
        expect(code).toBeDefined();
        expect(await memberIds()).toEqual([OWNER.id]);
    });
});
