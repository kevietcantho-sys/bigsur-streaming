import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication } from '@nestjs/common';
import { createHash } from 'node:crypto';
import request from 'supertest';

import { AppModule } from '../src/app.module';

// Tenant fixtures: two tenants exercise the per-tenant routing in one app.
const TENANT_A = 'acme';
const TENANT_B = 'wile';
const TOKEN_A = 'a'.repeat(64);
const TOKEN_B = 'b'.repeat(64);
const KEY_A = 'acme-publish-secret';
const KEY_B = 'wile-publish-secret';

function setEnv(env: Record<string, string>) {
  for (const [k, v] of Object.entries(env)) process.env[k] = v;
}

function clearTenantEnv() {
  for (const k of Object.keys(process.env)) {
    if (k.startsWith('SIGN_API_TOKEN_') || k.startsWith('PUBLISH_SIGN_KEY_')) {
      delete process.env[k];
    }
  }
}

function mintPublishParam(stream: string, ttlSec = 600, signKey = KEY_A) {
  const expires = Math.floor(Date.now() / 1000) + ttlSec;
  const txTime = expires.toString(16);
  const txSecret = createHash('md5').update(signKey + stream + txTime).digest('hex');
  return { param: `?txSecret=${txSecret}&txTime=${txTime}`, expires, txTime, txSecret };
}

describe('streaming-auth (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    clearTenantEnv();
    setEnv({
      NODE_ENV: 'test',
      [`SIGN_API_TOKEN_${TENANT_A.toUpperCase()}`]: TOKEN_A,
      [`SIGN_API_TOKEN_${TENANT_B.toUpperCase()}`]: TOKEN_B,
      [`PUBLISH_SIGN_KEY_${TENANT_A.toUpperCase()}`]: KEY_A,
      [`PUBLISH_SIGN_KEY_${TENANT_B.toUpperCase()}`]: KEY_B,
      BUNNY_TOKEN_KEY: 'bunny-secret',
      BUNNY_CDN_URL: 'https://stream.b-cdn.net',
      PUBLISH_DOMAIN: 'bspush.example.com',
      PUBLISH_APP: 'luckylive',
      LOG_LEVEL: 'error',
      // very high rate limit so tests don't trip throttling
      SIGN_RATE_TTL: '60000',
      SIGN_RATE_LIMIT: '10000',
    });

    const mod: TestingModule = await Test.createTestingModule({
      imports: [AppModule],
    }).compile();

    app = mod.createNestApplication();
    await app.init();
  });

  afterAll(async () => { await app.close(); });

  //─── /health ───────────────────────────────────────────────────
  it('GET /health → 200', async () => {
    const r = await request(app.getHttpServer()).get('/health');
    expect(r.status).toBe(200);
    expect(r.body.status).toBe('ok');
    expect(r.body.publish).toBe('configured');
  });

  //─── /srs/publish ──────────────────────────────────────────────
  describe('POST /srs/publish', () => {
    it('allows valid txSecret+txTime for tenant A stream', async () => {
      const stream = `${TENANT_A}__studio1`;
      const { param } = mintPublishParam(stream, 600, KEY_A);
      const r = await request(app.getHttpServer())
        .post('/srs/publish')
        .send({ stream, param });
      expect(r.status).toBe(200);
      expect(r.body).toEqual({ code: 0, data: 'OK' });
    });

    it('denies tenant A bearer signing tenant B stream (cross-tenant key swap)', async () => {
      // tenant B's stream signed with tenant A's key — must fail at SRS hook
      const stream = `${TENANT_B}__studio1`;
      const { param } = mintPublishParam(stream, 600, KEY_A);
      const r = await request(app.getHttpServer())
        .post('/srs/publish')
        .send({ stream, param });
      expect(r.status).toBe(200);
      expect(r.body.code).toBe(403);
    });

    it('denies wrong signature', async () => {
      const stream = `${TENANT_A}__studio1`;
      const { param } = mintPublishParam(stream, 600, 'not-the-real-key');
      const r = await request(app.getHttpServer())
        .post('/srs/publish')
        .send({ stream, param });
      expect(r.status).toBe(200);
      expect(r.body.code).toBe(403);
    });

    it('denies expired txTime', async () => {
      const stream = `${TENANT_A}__studio1`;
      const { param } = mintPublishParam(stream, -60, KEY_A);
      const r = await request(app.getHttpServer())
        .post('/srs/publish')
        .send({ stream, param });
      expect(r.status).toBe(200);
      expect(r.body.code).toBe(403);
    });

    it('denies missing signature', async () => {
      const r = await request(app.getHttpServer())
        .post('/srs/publish')
        .send({ stream: `${TENANT_A}__studio1`, param: '' });
      expect(r.status).toBe(200);
      expect(r.body.code).toBe(403);
    });

    it('denies stream without tenant prefix', async () => {
      const { param } = mintPublishParam('studio1', 600, KEY_A);
      const r = await request(app.getHttpServer())
        .post('/srs/publish')
        .send({ stream: 'studio1', param });
      expect(r.status).toBe(200);
      expect(r.body.code).toBe(403);
    });

    it('denies invalid stream name chars', async () => {
      const stream = 'acme__bad/name';
      const { param } = mintPublishParam(stream, 600, KEY_A);
      const r = await request(app.getHttpServer())
        .post('/srs/publish')
        .send({ stream, param });
      expect(r.status).toBe(200);
      expect(r.body.code).toBe(403);
    });
  });

  //─── /srs/unpublish ────────────────────────────────────────────
  it('POST /srs/unpublish → code 0', async () => {
    const r = await request(app.getHttpServer())
      .post('/srs/unpublish')
      .send({ stream: `${TENANT_A}__studio1` });
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ code: 0 });
  });

  // POST /sign (playback) was removed — clients sign BunnyCDN URLs locally
  // with their own (pull_zone, BUNNY_TOKEN_KEY) pair. Algorithm coverage
  // lives in src/modules/sign/bunny.service.spec.ts (kept as reference).

  //─── /sign/publish ─────────────────────────────────────────────
  describe('POST /sign/publish', () => {
    it('401 without Bearer token', async () => {
      const r = await request(app.getHttpServer())
        .post('/sign/publish')
        .send({ studio: 'LR-TEST-ABC' });
      expect(r.status).toBe(401);
    });

    it('401 with unknown bearer', async () => {
      const r = await request(app.getHttpServer())
        .post('/sign/publish')
        .set('Authorization', `Bearer ${'z'.repeat(64)}`)
        .send({ studio: 'studio1' });
      expect(r.status).toBe(401);
    });

    it('400 on invalid studio name', async () => {
      const r = await request(app.getHttpServer())
        .post('/sign/publish')
        .set('Authorization', `Bearer ${TOKEN_A}`)
        .send({ studio: 'bad/studio' });
      expect(r.status).toBe(400);
    });

    it('400 when studio contains tenant separator (__)', async () => {
      const r = await request(app.getHttpServer())
        .post('/sign/publish')
        .set('Authorization', `Bearer ${TOKEN_A}`)
        .send({ studio: 'wile__studio1' });
      expect(r.status).toBe(400);
    });

    it('200 mints a publish URL prefixed with the bearer tenant', async () => {
      const r = await request(app.getHttpServer())
        .post('/sign/publish')
        .set('Authorization', `Bearer ${TOKEN_A}`)
        .send({ studio: 'LR-MO11R4E8-B823D6', expires_in: 3600 });
      expect(r.status).toBe(200);
      expect(r.body.stream).toBe(`${TENANT_A}__LR-MO11R4E8-B823D6`);
      expect(r.body.url).toMatch(
        new RegExp(
          `^rtmp://bspush\\.example\\.com/luckylive/${TENANT_A}__LR-MO11R4E8-B823D6\\?txSecret=[0-9a-f]{32}&txTime=[0-9a-f]+$`,
        ),
      );
      expect(parseInt(r.body.txTime, 16)).toBe(r.body.expires);
    });

    it('tenant B bearer mints tenant B stream (isolation)', async () => {
      const r = await request(app.getHttpServer())
        .post('/sign/publish')
        .set('Authorization', `Bearer ${TOKEN_B}`)
        .send({ studio: 'studio1', expires_in: 3600 });
      expect(r.status).toBe(200);
      expect(r.body.stream).toBe(`${TENANT_B}__studio1`);
    });

    it('omits url_rtmps when PUBLISH_RTMPS_ENABLED is unset', async () => {
      const r = await request(app.getHttpServer())
        .post('/sign/publish')
        .set('Authorization', `Bearer ${TOKEN_A}`)
        .send({ studio: 'studio1', expires_in: 3600 });
      expect(r.status).toBe(200);
      expect(r.body.url_rtmps).toBeUndefined();
    });

    it('signature matches md5(tenant push key + stream + txTime)', async () => {
      const r = await request(app.getHttpServer())
        .post('/sign/publish')
        .set('Authorization', `Bearer ${TOKEN_A}`)
        .send({ studio: 'studio1', expires_in: 3600 });
      expect(r.status).toBe(200);
      const expected = createHash('md5')
        .update(KEY_A + `${TENANT_A}__studio1` + r.body.txTime)
        .digest('hex');
      expect(r.body.txSecret).toBe(expected);
    });

    it('tenant A signature does NOT verify against tenant B key', async () => {
      const r = await request(app.getHttpServer())
        .post('/sign/publish')
        .set('Authorization', `Bearer ${TOKEN_A}`)
        .send({ studio: 'studio1', expires_in: 3600 });
      expect(r.status).toBe(200);
      const wrong = createHash('md5')
        .update(KEY_B + `${TENANT_A}__studio1` + r.body.txTime)
        .digest('hex');
      expect(r.body.txSecret).not.toBe(wrong);
    });
  });
});

describe('streaming-auth — RTMPS enabled', () => {
  let app: INestApplication;

  beforeAll(async () => {
    clearTenantEnv();
    setEnv({
      NODE_ENV: 'test',
      [`SIGN_API_TOKEN_${TENANT_A.toUpperCase()}`]: TOKEN_A,
      [`PUBLISH_SIGN_KEY_${TENANT_A.toUpperCase()}`]: KEY_A,
      BUNNY_TOKEN_KEY: 'bunny-secret',
      BUNNY_CDN_URL: 'https://stream.b-cdn.net',
      PUBLISH_DOMAIN: 'bspush.example.com',
      PUBLISH_APP: 'luckylive',
      PUBLISH_RTMPS_ENABLED: 'true',
      PUBLISH_RTMPS_PORT: '1936',
      LOG_LEVEL: 'error',
      SIGN_RATE_TTL: '60000',
      SIGN_RATE_LIMIT: '10000',
    });
    const mod: TestingModule = await Test.createTestingModule({
      imports: [AppModule],
    }).compile();
    app = mod.createNestApplication();
    await app.init();
  });

  afterAll(async () => { await app.close(); });

  it('emits both url and url_rtmps with matching signature', async () => {
    const r = await request(app.getHttpServer())
      .post('/sign/publish')
      .set('Authorization', `Bearer ${TOKEN_A}`)
      .send({ studio: 'LR-RTMPS-001', expires_in: 3600 });
    expect(r.status).toBe(200);
    const stream = `${TENANT_A}__LR-RTMPS-001`;
    const query = `?txSecret=${r.body.txSecret}&txTime=${r.body.txTime}`;
    expect(r.body.url).toBe(`rtmp://bspush.example.com/luckylive/${stream}${query}`);
    expect(r.body.url_rtmps).toBe(`rtmps://bspush.example.com:1936/luckylive/${stream}${query}`);
  });
});

describe('streaming-auth — boot fails on tenant config mismatch', () => {
  it('rejects tenant with bearer but no push key', async () => {
    clearTenantEnv();
    setEnv({
      NODE_ENV: 'test',
      [`SIGN_API_TOKEN_${TENANT_A.toUpperCase()}`]: TOKEN_A,
      // PUBLISH_SIGN_KEY_ACME deliberately missing
      BUNNY_TOKEN_KEY: 'bunny-secret',
      BUNNY_CDN_URL: 'https://stream.b-cdn.net',
      PUBLISH_DOMAIN: 'bspush.example.com',
      PUBLISH_APP: 'luckylive',
      LOG_LEVEL: 'error',
      SIGN_RATE_TTL: '60000',
      SIGN_RATE_LIMIT: '10000',
    });

    const mod: TestingModule = await Test.createTestingModule({
      imports: [AppModule],
    }).compile();
    const app = mod.createNestApplication();
    await expect(app.init()).rejects.toThrow(/PUBLISH_SIGN_KEY_/);
    await app.close().catch(() => undefined);
  });
});
