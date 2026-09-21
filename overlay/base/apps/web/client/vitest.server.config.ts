import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Node-only vitest config for the server side (the tRPC API). The default
// vitest.config.ts runs Storybook tests in a browser, and the repository's unit
// tests run under `bun test`, which the AppMap recorder cannot instrument. This
// config runs the tests under test/server with plain Node against a PostgreSQL
// database, so they can be recorded with appmap-node:
//
//   npx appmap-node npx vitest run --config vitest.server.config.ts
//
// The database URL comes from SUPABASE_DATABASE_URL and defaults to the local
// Supabase database. The other values only satisfy the env schema in src/env.ts.
const dirname = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
    resolve: {
        alias: {
            '@': path.join(dirname, 'src'),
            '~': path.join(dirname, 'src'),
            // @onlook/ai declares only a "module" entry, which vite does not read here.
            '@onlook/ai': path.join(dirname, '../../../packages/ai/src/index.ts'),
        },
    },
    test: {
        name: 'server',
        environment: 'node',
        include: ['test/server/**/*.test.ts'],
        fileParallelism: false,
        testTimeout: 30000,
        hookTimeout: 30000,
        env: {
            SUPABASE_DATABASE_URL:
                process.env.SUPABASE_DATABASE_URL ??
                'postgresql://postgres:postgres@127.0.0.1:54322/postgres',
            CSB_API_KEY: process.env.CSB_API_KEY ?? 'test',
            SUPABASE_SERVICE_ROLE_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY ?? 'test',
            OPENROUTER_API_KEY: process.env.OPENROUTER_API_KEY ?? 'test',
            NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321',
            NEXT_PUBLIC_SUPABASE_ANON_KEY: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? 'test',
        },
    },
});
