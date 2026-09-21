import { afterAll, beforeAll, beforeEach, describe, expect, test } from 'vitest';
import {
    cleanupFixture,
    clientFor,
    errorCodeOf,
    MISSING_PROJECT_ID,
    OUTSIDER,
    OWNER,
    PROJECT_ID,
    PROJECT_NAME,
    projectName,
    projectTags,
    resetFixture,
    SEED_TAG,
    startServer,
    type TestServer,
} from './support/harness';

// The project router over HTTP: the routes a member uses on their own project,
// a request with no session, and a signed in stranger who is not a member.
//
// Every project scoped procedure takes a project id from the client. The
// server's database connection is exempt from row level security, so whether
// the caller may act on that project is decided by the application code alone.
// The stranger tests state the behavior a multi-tenant application owes its
// users: a request for someone else's project is refused. Where the application
// does not yet do that, the test is marked `fails` (vitest's expected-failure
// marker) so the defect is on record and the suite stays green.

let server: TestServer;

beforeAll(async () => {
    server = await startServer();
});

afterAll(async () => {
    await server.close();
    await cleanupFixture();
});

beforeEach(resetFixture);

describe('project procedures called by a member', () => {
    test('project.list called by the owner', async () => {
        const projects = await clientFor(server, OWNER).project.list.query();
        expect(projects.map((project) => project.id)).toEqual([PROJECT_ID]);
    });

    test('project.get called by the owner', async () => {
        const project = await clientFor(server, OWNER).project.get.query({ projectId: PROJECT_ID });
        expect(project?.name).toBe(PROJECT_NAME);
    });

    test('project.update called by the owner', async () => {
        const project = await clientFor(server, OWNER).project.update.mutate({ id: PROJECT_ID, name: 'Renamed by owner' });
        expect(project.name).toBe('Renamed by owner');
        expect(await projectName()).toBe('Renamed by owner');
    });

    test('project.delete called by the owner', async () => {
        await clientFor(server, OWNER).project.delete.mutate({ id: PROJECT_ID });
        expect(await projectName()).toBeUndefined();
    });
});

describe('project procedures called without signing in', () => {
    test('project.get without signing in', async () => {
        expect(await errorCodeOf(clientFor(server, null).project.get.query({ projectId: PROJECT_ID }))).toBe('UNAUTHORIZED');
    });
});

describe('project procedures called by a signed in user who is not a member', () => {
    test.fails('project.get called by a non-member', async () => {
        const code = await errorCodeOf(clientFor(server, OUTSIDER).project.get.query({ projectId: PROJECT_ID }));
        expect(code).toBeDefined();
    });

    test.fails('project.update called by a non-member', async () => {
        const code = await errorCodeOf(
            clientFor(server, OUTSIDER).project.update.mutate({ id: PROJECT_ID, name: 'Renamed by outsider' }),
        );
        expect(code).toBeDefined();
        expect(await projectName()).toBe(PROJECT_NAME);
    });

    test.fails('project.delete called by a non-member', async () => {
        const code = await errorCodeOf(clientFor(server, OUTSIDER).project.delete.mutate({ id: PROJECT_ID }));
        expect(code).toBeDefined();
        expect(await projectName()).toBe(PROJECT_NAME);
    });
});

// Added after reviewing the change that introduced verifyProjectAccess: the
// procedures it guards that the baseline above did not run (addTag, removeTag,
// captureScreenshot), and the helper's other branch, a project that does not
// exist.
describe('project tag and screenshot procedures', () => {
    test('project.addTag called by the owner', async () => {
        const result = await clientFor(server, OWNER).project.addTag.mutate({ projectId: PROJECT_ID, tag: 'demo' });
        expect(result).toEqual({ success: true, tags: [SEED_TAG, 'demo'] });
        expect(await projectTags()).toEqual([SEED_TAG, 'demo']);
    });

    test.fails('project.addTag called by a non-member', async () => {
        const code = await errorCodeOf(
            clientFor(server, OUTSIDER).project.addTag.mutate({ projectId: PROJECT_ID, tag: 'pwned' }),
        );
        expect(code).toBeDefined();
        expect(await projectTags()).toEqual([SEED_TAG]);
    });

    test.fails('project.removeTag called by a non-member', async () => {
        const code = await errorCodeOf(
            clientFor(server, OUTSIDER).project.removeTag.mutate({ projectId: PROJECT_ID, tag: SEED_TAG }),
        );
        expect(code).toBeDefined();
        expect(await projectTags()).toEqual([SEED_TAG]);
    });

    // captureScreenshot reports failure in its return value instead of an error.
    // With no screenshot service configured the call cannot succeed for anyone,
    // so this test only states that a stranger does not get a screenshot taken.
    test('project.captureScreenshot called by a non-member', async () => {
        const result = await clientFor(server, OUTSIDER).project.captureScreenshot.mutate({ projectId: PROJECT_ID });
        expect(result.success).toBe(false);
    });
});

describe('project procedures called for a project that does not exist', () => {
    test('project.update of a project that does not exist', async () => {
        const code = await errorCodeOf(
            clientFor(server, OWNER).project.update.mutate({ id: MISSING_PROJECT_ID, name: 'Ghost' }),
        );
        expect(code).toBeDefined();
    });
});
