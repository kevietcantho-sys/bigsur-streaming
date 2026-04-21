import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication } from '@nestjs/common';
import request from 'supertest';

import { AppModule } from '../src/app.module';

const API_TOKEN = 'a'.repeat(64);

function setEnv(env: Record<string, string>) {
  for (const [k, v] of Object.entries(env)) process.env[k] = v;
}

describe('streaming-auth (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    setEnv({
      NODE_ENV: 'test',
      SIGN_API_TOKEN: API_TOKEN,
      STREAM_KEYS: 'studio1:secret1,studio2:secret2',
      BUNNY_TOKEN_KEY: 'bunny-secret',
      BUNNY_CDN_URL: 'https://stream.b-cdn.net',
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
  it('GET /health → 200 with stream count and cdn status', async () => {
    const r = await request(app.getHttpServer()).get('/health');
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ status: 'ok', streams: 2, cdn: 'configured' });
  });

  //─── /srs/publish ──────────────────────────────────────────────
  describe('POST /srs/publish', () => {
    it('allows valid stream+key', async () => {
      const r = await request(app.getHttpServer())
        .post('/srs/publish')
        .send({ stream: 'studio1', param: '?key=secret1' });
      expect(r.status).toBe(200);
      expect(r.body).toEqual({ code: 0, data: 'OK' });
    });

    it('denies wrong key', async () => {
      const r = await request(app.getHttpServer())
        .post('/srs/publish')
        .send({ stream: 'studio1', param: '?key=wrong' });
      expect(r.status).toBe(200);
      expect(r.body.code).toBe(403);
    });

    it('denies invalid stream name', async () => {
      const r = await request(app.getHttpServer())
        .post('/srs/publish')
        .send({ stream: 'bad/name', param: '?key=secret1' });
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

  //─── /sign ─────────────────────────────────────────────────────
  describe('POST /sign', () => {
    it('401 without Bearer token', async () => {
      const r = await request(app.getHttpServer())
        .post('/sign')
        .send({ stream: 'studio1' });
      expect(r.status).toBe(401);
    });

    it('401 with wrong token', async () => {
      const r = await request(app.getHttpServer())
        .post('/sign')
        .set('Authorization', 'Bearer wrongwrongwrongwrong')
        .send({ stream: 'studio1' });
      expect(r.status).toBe(401);
    });

    it('400 on invalid stream name', async () => {
      const r = await request(app.getHttpServer())
        .post('/sign')
        .set('Authorization', `Bearer ${API_TOKEN}`)
        .send({ stream: 'bad/name' });
      expect(r.status).toBe(400);
    });

    it('404 on unknown stream', async () => {
      const r = await request(app.getHttpServer())
        .post('/sign')
        .set('Authorization', `Bearer ${API_TOKEN}`)
        .send({ stream: 'ghost' });
      expect(r.status).toBe(404);
    });

    it('200 mints a signed URL', async () => {
      const r = await request(app.getHttpServer())
        .post('/sign')
        .set('Authorization', `Bearer ${API_TOKEN}`)
        .send({ stream: 'studio1', expires_in: 600 });
      expect(r.status).toBe(200);
      expect(r.body.url).toMatch(/^https:\/\/stream\.b-cdn\.net\/live\/studio1\.m3u8\?token=/);
      expect(typeof r.body.expires).toBe('number');
      expect(typeof r.body.expires_at).toBe('string');
    });

    it('clamps expires_in to configured bounds', async () => {
      const r = await request(app.getHttpServer())
        .post('/sign')
        .set('Authorization', `Bearer ${API_TOKEN}`)
        .send({ stream: 'studio1', expires_in: 999999 });
      expect(r.status).toBe(200);
      const nowSec = Math.floor(Date.now() / 1000);
      // maxExpires from default.yaml = 3600
      expect(r.body.expires - nowSec).toBeLessThanOrEqual(3600 + 2);
    });
  });
});

describe('streaming-auth — CDN not configured (503)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    setEnv({
      NODE_ENV: 'test',
      SIGN_API_TOKEN: API_TOKEN,
      STREAM_KEYS: 'studio1:secret1',
      BUNNY_TOKEN_KEY: '',
      BUNNY_CDN_URL: '',
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

  it('503 when Bunny not configured', async () => {
    const r = await request(app.getHttpServer())
      .post('/sign')
      .set('Authorization', `Bearer ${API_TOKEN}`)
      .send({ stream: 'studio1' });
    expect(r.status).toBe(503);
    expect(r.body.error).toBe('cdn_not_configured');
  });

  it('/health reports cdn: pending', async () => {
    const r = await request(app.getHttpServer()).get('/health');
    expect(r.body.cdn).toBe('pending');
  });
});
