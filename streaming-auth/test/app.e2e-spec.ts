import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication } from '@nestjs/common';
import { createHash } from 'node:crypto';
import request from 'supertest';

import { AppModule } from '../src/app.module';

const API_TOKEN = 'a'.repeat(64);
const PUBLISH_SIGN_KEY = 'publish-secret';

function setEnv(env: Record<string, string>) {
  for (const [k, v] of Object.entries(env)) process.env[k] = v;
}

function mintPublishParam(stream: string, ttlSec = 600, signKey = PUBLISH_SIGN_KEY) {
  const expires = Math.floor(Date.now() / 1000) + ttlSec;
  const txTime = expires.toString(16);
  const txSecret = createHash('md5').update(signKey + stream + txTime).digest('hex');
  return { param: `?txSecret=${txSecret}&txTime=${txTime}`, expires, txTime, txSecret };
}

describe('streaming-auth (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    setEnv({
      NODE_ENV: 'test',
      SIGN_API_TOKEN: API_TOKEN,
      BUNNY_TOKEN_KEY: 'bunny-secret',
      BUNNY_CDN_URL: 'https://stream.b-cdn.net',
      PUBLISH_DOMAIN: 'bspush.example.com',
      PUBLISH_APP: 'luckylive',
      PUBLISH_SIGN_KEY,
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
  it('GET /health → 200 with cdn + publish status', async () => {
    const r = await request(app.getHttpServer()).get('/health');
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ status: 'ok', cdn: 'configured', publish: 'configured' });
  });

  //─── /srs/publish ──────────────────────────────────────────────
  describe('POST /srs/publish', () => {
    it('allows valid txSecret+txTime', async () => {
      const { param } = mintPublishParam('studio1');
      const r = await request(app.getHttpServer())
        .post('/srs/publish')
        .send({ stream: 'studio1', param });
      expect(r.status).toBe(200);
      expect(r.body).toEqual({ code: 0, data: 'OK' });
    });

    it('denies wrong signature', async () => {
      const { param } = mintPublishParam('studio1', 600, 'not-the-real-key');
      const r = await request(app.getHttpServer())
        .post('/srs/publish')
        .send({ stream: 'studio1', param });
      expect(r.status).toBe(200);
      expect(r.body.code).toBe(403);
    });

    it('denies expired txTime', async () => {
      const { param } = mintPublishParam('studio1', -60);
      const r = await request(app.getHttpServer())
        .post('/srs/publish')
        .send({ stream: 'studio1', param });
      expect(r.status).toBe(200);
      expect(r.body.code).toBe(403);
    });

    it('denies missing signature', async () => {
      const r = await request(app.getHttpServer())
        .post('/srs/publish')
        .send({ stream: 'studio1', param: '' });
      expect(r.status).toBe(200);
      expect(r.body.code).toBe(403);
    });

    it('denies invalid stream name', async () => {
      const { param } = mintPublishParam('bad/name');
      const r = await request(app.getHttpServer())
        .post('/srs/publish')
        .send({ stream: 'bad/name', param });
      expect(r.status).toBe(200);
      expect(r.body.code).toBe(403);
    });
  });

  //─── /srs/unpublish ────────────────────────────────────────────
  it('POST /srs/unpublish → code 0', async () => {
    const r = await request(app.getHttpServer())
      .post('/srs/unpublish')
      .send({ stream: 'studio1' });
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

    it('400 on invalid studio name', async () => {
      const r = await request(app.getHttpServer())
        .post('/sign/publish')
        .set('Authorization', `Bearer ${API_TOKEN}`)
        .send({ studio: 'bad/studio' });
      expect(r.status).toBe(400);
    });

    it('200 mints a publish URL', async () => {
      const r = await request(app.getHttpServer())
        .post('/sign/publish')
        .set('Authorization', `Bearer ${API_TOKEN}`)
        .send({ studio: 'LR-MO11R4E8-B823D6', expires_in: 3600 });
      expect(r.status).toBe(200);
      expect(r.body.url).toMatch(
        /^rtmp:\/\/bspush\.example\.com\/luckylive\/LR-MO11R4E8-B823D6\?txSecret=[0-9a-f]{32}&txTime=[0-9a-f]+$/,
      );
      expect(r.body.stream).toBe('LR-MO11R4E8-B823D6');
      expect(typeof r.body.expires).toBe('number');
      // txTime is hex-encoded unix seconds at expiry
      expect(parseInt(r.body.txTime, 16)).toBe(r.body.expires);
    });

    it('omits url_rtmps when PUBLISH_RTMPS_ENABLED is unset', async () => {
      const r = await request(app.getHttpServer())
        .post('/sign/publish')
        .set('Authorization', `Bearer ${API_TOKEN}`)
        .send({ studio: 'studio1', expires_in: 3600 });
      expect(r.status).toBe(200);
      expect(r.body.url_rtmps).toBeUndefined();
    });

    it('signature matches md5(signKey + stream + txTime)', async () => {
      const r = await request(app.getHttpServer())
        .post('/sign/publish')
        .set('Authorization', `Bearer ${API_TOKEN}`)
        .send({ studio: 'studio1', expires_in: 3600 });
      expect(r.status).toBe(200);
      const expected = createHash('md5')
        .update(PUBLISH_SIGN_KEY + 'studio1' + r.body.txTime)
        .digest('hex');
      expect(r.body.txSecret).toBe(expected);
    });
  });
});

describe('streaming-auth — RTMPS enabled', () => {
  let app: INestApplication;

  beforeAll(async () => {
    setEnv({
      NODE_ENV: 'test',
      SIGN_API_TOKEN: API_TOKEN,
      BUNNY_TOKEN_KEY: 'bunny-secret',
      BUNNY_CDN_URL: 'https://stream.b-cdn.net',
      PUBLISH_DOMAIN: 'bspush.example.com',
      PUBLISH_APP: 'luckylive',
      PUBLISH_SIGN_KEY,
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
      .set('Authorization', `Bearer ${API_TOKEN}`)
      .send({ studio: 'LR-RTMPS-001', expires_in: 3600 });
    expect(r.status).toBe(200);
    const query = `?txSecret=${r.body.txSecret}&txTime=${r.body.txTime}`;
    expect(r.body.url).toBe(`rtmp://bspush.example.com/luckylive/LR-RTMPS-001${query}`);
    expect(r.body.url_rtmps).toBe(`rtmps://bspush.example.com:1936/luckylive/LR-RTMPS-001${query}`);
  });
});

// "CDN not configured" describe block was removed alongside POST /sign —
// the playback signer is no longer wired into the app, so there is no
// runtime path that returns 503 cdn_not_configured anymore. /health may
// still report `cdn: pending` cosmetically; that surface lives in the
// health controller and is exercised by its own checks.
