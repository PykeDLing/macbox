import { assert, describe, it } from '@effect/vitest';
import { Effect, Fiber } from 'effect';
import { afterEach, vi } from 'vitest';
import { describeDmg, fallbackRelease } from '../src/lib/release';
import { fetchLatestRelease, parseRelease } from '../src/lib/release-fetch';

const dmg = {
  name: 'MacBox-0.3.0.dmg',
  size: 2_912_345,
  browser_download_url:
    'https://github.com/PykeDLing/macbox/releases/download/v0.3.0/MacBox-0.3.0.dmg',
  updated_at: '2026-10-01T00:00:00Z',
};
const release = {
  tag_name: 'v0.3.0',
  published_at: '2026-10-14T08:00:00Z',
  assets: [{ name: 'MacBox-0.3.0.dmg.sha256', size: 90, browser_download_url: 'https://x/y' }, dmg],
};

afterEach(() => vi.unstubAllGlobals());

describe('GitHub release parsing', () => {
  it('links the download button straight to the dmg', () => {
    const parsed = parseRelease(release);
    assert.strictEqual(parsed.version, 'v0.3.0');
    assert.strictEqual(parsed.download, dmg.browser_download_url);
    assert.strictEqual(parsed.dmg?.size, dmg.size);
    assert.strictEqual(parsed.dmg?.published.toISOString(), '2026-10-14T08:00:00.000Z');
  });

  it('keeps the release page link when the release has no dmg', () => {
    const parsed = parseRelease({ ...release, assets: [] });
    assert.strictEqual(parsed.version, 'v0.3.0');
    assert.strictEqual(parsed.download, fallbackRelease.download);
    assert.isNull(parsed.dmg);
  });

  it('skips malformed assets instead of discarding the release', () => {
    const parsed = parseRelease({ ...release, assets: [null, { name: 'x.dmg' }, dmg] });
    assert.strictEqual(parsed.download, dmg.browser_download_url);
  });

  it('falls back to the asset date, and hides the date when neither is valid', () => {
    assert.strictEqual(
      parseRelease({ ...release, published_at: null }).dmg?.published.toISOString(),
      '2026-10-01T00:00:00.000Z',
    );
    const undated = { ...dmg, updated_at: 'soon' };
    assert.isNull(parseRelease({ ...release, published_at: null, assets: [undated] }).dmg);
  });

  it.each([null, 'oops', {}, { tag_name: '' }, { tag_name: 'v1', assets: 'none' }])(
    'uses the built-in version for %j',
    (json) => assert.deepStrictEqual(parseRelease(json), fallbackRelease),
  );

  it('refuses download links that are not https', () => {
    const insecure = { ...dmg, browser_download_url: 'http://example.com/MacBox.dmg' };
    assert.strictEqual(
      parseRelease({ ...release, assets: [insecure] }).download,
      fallbackRelease.download,
    );
  });

  it('describes size and date like Finder, in both languages', () => {
    const info = { size: 2_912_345, published: new Date('2026-10-14T08:00:00Z') };
    assert.strictEqual(describeDmg(info, 'zh'), '2.9 MB · 2026年10月14日发布');
    assert.strictEqual(describeDmg(info, 'en'), '2.9 MB · Released Oct 14, 2026');
  });
});

describe('GitHub release request', () => {
  it.effect('decodes a successful response', () =>
    Effect.gen(function* () {
      vi.stubGlobal('fetch', async () => new Response(JSON.stringify(release)));
      const parsed = yield* fetchLatestRelease;
      assert.strictEqual(parsed.download, dmg.browser_download_url);
    }),
  );

  it.effect('fails with the reason when GitHub answers with an error status', () =>
    Effect.gen(function* () {
      vi.stubGlobal('fetch', async () => new Response('rate limited', { status: 403 }));
      const error = yield* Effect.flip(fetchLatestRelease);
      assert.strictEqual(error._tag, 'ReleaseError');
      assert.strictEqual(error._tag === 'ReleaseError' && error.reason, 'status');
    }),
  );

  it.effect('fails with the reason when the network is down', () =>
    Effect.gen(function* () {
      vi.stubGlobal('fetch', async () => {
        throw new TypeError('Failed to fetch');
      });
      const error = yield* Effect.flip(fetchLatestRelease);
      assert.strictEqual(error._tag === 'ReleaseError' && error.reason, 'network');
    }),
  );

  it.live('aborts the request when interrupted (the page went away)', () =>
    Effect.gen(function* () {
      let signal: AbortSignal | undefined;
      vi.stubGlobal('fetch', (_url: string, init: RequestInit) => {
        signal = init.signal ?? undefined;
        return new Promise(() => {});
      });
      const fiber = yield* Effect.forkChild(fetchLatestRelease);
      yield* Effect.yieldNow;
      assert.isFalse(signal?.aborted);
      yield* Fiber.interrupt(fiber);
      assert.isTrue(signal?.aborted);
    }),
  );
});
