import { sha256HexHash } from '@aztec/foundation/json-rpc/server';
import type { Logger } from '@aztec/foundation/log';

import { promises as fs } from 'fs';
import { mkdtemp, rm } from 'fs/promises';
import { tmpdir } from 'os';
import { join } from 'path';

import { type ResolveAdminApiKeyOptions, resolveAdminApiKey } from './admin_api_key_store.js';

/** Creates a minimal mock Logger that captures calls. */
function createMockLogger(): Logger & { calls: Record<string, string[]> } {
  const calls: Record<string, string[]> = { info: [], warn: [], error: [], debug: [], verbose: [], trace: [] };
  const noop = () => {};
  return {
    calls,
    info: (msg: string) => {
      calls.info.push(msg);
    },
    warn: (msg: string) => {
      calls.warn.push(msg);
    },
    error: (msg: string) => {
      calls.error.push(msg);
    },
    debug: (msg: string) => {
      calls.debug.push(msg);
    },
    verbose: (msg: string) => {
      calls.verbose.push(msg);
    },
    trace: (msg: string) => {
      calls.trace.push(msg);
    },
    fatal: noop,
    silent: noop,
    level: 'info' as const,
    isLevelEnabled: () => true,
    module: 'test',
    createChild: () => createMockLogger(),
    getBindings: () => ({}),
  } as any;
}

describe('resolveAdminApiKey', () => {
  let log: ReturnType<typeof createMockLogger>;
  let tempDir: string | undefined;

  beforeEach(() => {
    log = createMockLogger();
    tempDir = undefined;
  });

  afterEach(async () => {
    if (tempDir) {
      await rm(tempDir, { recursive: true, force: true });
    }
  });

  describe('opt-out (noAdminApiKey = true)', () => {
    it('returns undefined when auth is disabled', async () => {
      const result = await resolveAdminApiKey({ noAdminApiKey: true }, log);
      expect(result).toBeUndefined();
    });

    it('logs a warning about auth being disabled', async () => {
      await resolveAdminApiKey({ noAdminApiKey: true }, log);
      expect(log.calls.warn.some(m => m.includes('DISABLED'))).toBe(true);
    });
  });

  describe('ephemeral mode (no dataDirectory)', () => {
    it('returns a key resolution with rawKey and apiKeyHash', async () => {
      const result = await resolveAdminApiKey({}, log);
      expect(result).toBeDefined();
      expect(result!.rawKey).toBeDefined();
      expect(result!.apiKeyHash).toBeDefined();
    });

    it('returns rawKey that is a 64-char hex string', async () => {
      const result = await resolveAdminApiKey({}, log);
      expect(result!.rawKey).toMatch(/^[0-9a-f]{64}$/);
    });

    it('returns apiKeyHash that is SHA-256 of rawKey', async () => {
      const result = await resolveAdminApiKey({}, log);
      expect(result!.apiKeyHash).toBe(sha256HexHash(result!.rawKey!));
    });

    it('generates a different key each call', async () => {
      const result1 = await resolveAdminApiKey({}, log);
      const result2 = await resolveAdminApiKey({}, log);
      expect(result1!.rawKey).not.toBe(result2!.rawKey);
    });

    it('logs warnings about lack of persistence', async () => {
      await resolveAdminApiKey({}, log);
      expect(log.calls.warn.some(m => m.includes('cannot be persisted'))).toBe(true);
    });
  });

  describe('persistent mode (with dataDirectory)', () => {
    let opts: ResolveAdminApiKeyOptions;

    beforeEach(async () => {
      tempDir = await mkdtemp(join(tmpdir(), 'aztec-api-key-test-'));
      opts = { dataDirectory: tempDir };
    });

    it('generates a new key on first run', async () => {
      const result = await resolveAdminApiKey(opts, log);
      expect(result).toBeDefined();
      expect(result!.rawKey).toBeDefined();
      expect(result!.rawKey).toMatch(/^[0-9a-f]{64}$/);
      expect(result!.apiKeyHash).toBe(sha256HexHash(result!.rawKey!));
    });

    it('persists the hash to disk on first run', async () => {
      const result = await resolveAdminApiKey(opts, log);
      const hashFilePath = join(tempDir!, 'admin', 'api_key_hash');
      const storedHash = (await fs.readFile(hashFilePath, 'utf-8')).trim();
      expect(storedHash).toBe(result!.apiKeyHash);
    });

    it('sets restrictive permissions on the hash file', async () => {
      await resolveAdminApiKey(opts, log);
      const hashFilePath = join(tempDir!, 'admin', 'api_key_hash');
      const stat = await fs.stat(hashFilePath);
      // 0o600 = owner read/write only (numeric mode 384)
      expect(stat.mode & 0o777).toBe(0o600);
    });

    it('loads the stored hash on subsequent runs (no rawKey)', async () => {
      // First run, generates and persists
      const firstResult = await resolveAdminApiKey(opts, log);
      const firstHash = firstResult!.apiKeyHash;

      // Second run, loads from disk
      const secondLog = createMockLogger();
      const secondResult = await resolveAdminApiKey(opts, secondLog);

      expect(secondResult).toBeDefined();
      expect(secondResult!.apiKeyHash).toBe(firstHash);
      expect(secondResult!.rawKey).toBeUndefined(); // Not newly generated
    });

    it('logs that hash was loaded from disk on subsequent runs', async () => {
      await resolveAdminApiKey(opts, log);

      const secondLog = createMockLogger();
      await resolveAdminApiKey(opts, secondLog);
      expect(secondLog.calls.info.some(m => m.includes('loaded stored key hash from disk'))).toBe(true);
    });

    it('regenerates if stored hash is invalid (wrong length)', async () => {
      // Write an invalid hash
      const adminDir = join(tempDir!, 'admin');
      await fs.mkdir(adminDir, { recursive: true });
      await fs.writeFile(join(adminDir, 'api_key_hash'), 'tooshort', 'utf-8');

      const result = await resolveAdminApiKey(opts, log);
      expect(result).toBeDefined();
      expect(result!.rawKey).toBeDefined(); // Freshly generated
      expect(result!.apiKeyHash).toBe(sha256HexHash(result!.rawKey!));
      expect(log.calls.warn.some(m => m.includes('Invalid stored admin API key hash'))).toBe(true);
    });

    it('creates the admin subdirectory if it does not exist', async () => {
      await resolveAdminApiKey(opts, log);
      const adminDir = join(tempDir!, 'admin');
      const stat = await fs.stat(adminDir);
      expect(stat.isDirectory()).toBe(true);
    });
  });

  describe('reset (resetAdminApiKey = true)', () => {
    let opts: ResolveAdminApiKeyOptions;

    beforeEach(async () => {
      tempDir = await mkdtemp(join(tmpdir(), 'aztec-api-key-test-'));
      opts = { dataDirectory: tempDir, resetAdminApiKey: true };
    });

    it('generates a new key even when a valid hash already exists', async () => {
      // First run, normal generation
      const firstResult = await resolveAdminApiKey({ dataDirectory: tempDir }, log);
      const firstHash = firstResult!.apiKeyHash;

      // Second run with reset, should generate a new key
      const resetLog = createMockLogger();
      const resetResult = await resolveAdminApiKey(opts, resetLog);

      expect(resetResult).toBeDefined();
      expect(resetResult!.rawKey).toBeDefined(); // New raw key returned
      expect(resetResult!.apiKeyHash).not.toBe(firstHash); // Different hash
      expect(resetResult!.apiKeyHash).toBe(sha256HexHash(resetResult!.rawKey!));
    });

    it('overwrites the persisted hash file', async () => {
      // First run — normal generation
      await resolveAdminApiKey({ dataDirectory: tempDir }, log);
      const hashFilePath = join(tempDir!, 'admin', 'api_key_hash');
      const oldHash = (await fs.readFile(hashFilePath, 'utf-8')).trim();

      // Reset run
      const resetResult = await resolveAdminApiKey(opts, createMockLogger());
      const newHash = (await fs.readFile(hashFilePath, 'utf-8')).trim();

      expect(newHash).not.toBe(oldHash);
      expect(newHash).toBe(resetResult!.apiKeyHash);
    });

    it('logs a warning about the reset', async () => {
      const resetLog = createMockLogger();
      await resolveAdminApiKey(opts, resetLog);
      expect(resetLog.calls.warn.some(m => m.includes('reset requested'))).toBe(true);
    });

    it('works even when no hash file exists yet (first run with reset)', async () => {
      const resetLog = createMockLogger();
      const result = await resolveAdminApiKey(opts, resetLog);

      expect(result).toBeDefined();
      expect(result!.rawKey).toBeDefined();
      expect(result!.apiKeyHash).toBe(sha256HexHash(result!.rawKey!));
    });

    it('has no effect in ephemeral mode (always generates anyway)', async () => {
      const result = await resolveAdminApiKey({ resetAdminApiKey: true }, log);
      expect(result).toBeDefined();
      expect(result!.rawKey).toBeDefined();
    });
  });
});
