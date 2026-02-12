import { createHash, timingSafeEqual } from 'crypto';
import type Koa from 'koa';

import { createLogger } from '../../log/index.js';

const log = createLogger('json-rpc:api-key-auth');

/**
 * Computes the SHA-256 hash of a string and returns it as a hex string.
 * @param input - The input string to hash.
 * @returns The hex-encoded SHA-256 hash.
 */
export function sha256HexHash(input: string): string {
  return createHash('sha256').update(input).digest('hex');
}

/**
 * Creates a Koa middleware that enforces API key authentication on all requests
 * except the health check endpoint (GET /status).
 *
 * The API key can be provided via the `x-api-key` header or the `Authorization: Bearer <key>` header.
 * Comparison is done by hashing the provided key with SHA-256 and comparing against the stored hash.
 *
 * @param apiKeyHash - The SHA-256 hex hash of the expected API key.
 * @returns A Koa middleware that rejects requests without a valid API key.
 */
export function getApiKeyAuthMiddleware(
  apiKeyHash: string,
): (ctx: Koa.Context, next: () => Promise<void>) => Promise<void> {
  const expectedHashBuf = Buffer.from(apiKeyHash, 'hex');

  return async (ctx: Koa.Context, next: () => Promise<void>) => {
    // Allow health check through without auth
    if (ctx.path === '/status' && ctx.method === 'GET') {
      return next();
    }

    const providedKey = ctx.get('x-api-key') || ctx.get('authorization')?.replace(/^Bearer\s+/i, '');
    if (!providedKey) {
      log.warn(`Rejected admin RPC request from ${ctx.ip}: missing API key`);
      ctx.status = 401;
      ctx.body = {
        jsonrpc: '2.0',
        id: null,
        error: { code: -32000, message: 'Unauthorized: invalid or missing API key' },
      };
      return;
    }

    const providedHashBuf = Buffer.from(sha256HexHash(providedKey), 'hex');
    if (expectedHashBuf.length !== providedHashBuf.length || !timingSafeEqual(expectedHashBuf, providedHashBuf)) {
      log.warn(`Rejected admin RPC request from ${ctx.ip}: invalid API key`);
      ctx.status = 401;
      ctx.body = {
        jsonrpc: '2.0',
        id: null,
        error: { code: -32000, message: 'Unauthorized: invalid or missing API key' },
      };
      return;
    }

    await next();
  };
}
