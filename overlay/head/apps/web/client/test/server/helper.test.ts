import { describe, expect, test } from 'vitest';
import { extractCsbPort } from '@/server/api/routers/project/helper';
import type { Frame } from '@onlook/db';

// Unit test for the one pure helper in the project router. It is the first
// recording the AppMap setup makes, and it stays as an ordinary test.
function frame(url: string | null): Frame {
    return { url } as unknown as Frame;
}

describe('extractCsbPort', () => {
    test('reads the port from the first CodeSandbox preview url', () => {
        expect(extractCsbPort([frame(null), frame('https://abc123-3000.csb.app/')])).toBe(3000);
    });

    test('returns null when no frame has a preview url', () => {
        expect(extractCsbPort([])).toBeNull();
        expect(extractCsbPort([frame(null), frame('https://example.com')])).toBeNull();
    });
});
