import { runInNewContext } from 'node:vm';
import { assert, describe, it } from 'vitest';
import { hydrationGraceMs, languageKey, languageScript } from '../src/lib/language';

function visit(
  path: string,
  { browser = 'zh-CN', saved = null as string | null, blocked = false, base = '/macbox/' } = {},
) {
  const [pathname, search = ''] = path.split('?');
  const [query, hash = ''] = search.split('#');
  const root = { classes: new Set<string>(), style: { visibility: '' } };
  const timers: (() => void)[] = [];
  let redirect: string | null = null;
  runInNewContext(languageScript(base), {
    document: {
      documentElement: {
        classList: {
          add: (name: string) => root.classes.add(name),
          remove: (name: string) => root.classes.delete(name),
          contains: (name: string) => root.classes.has(name),
        },
        style: root.style,
      },
    },
    location: {
      pathname,
      search: query ? `?${query}` : '',
      hash: hash ? `#${hash}` : '',
      replace: (url: string) => (redirect = url),
    },
    navigator: { language: browser },
    get localStorage() {
      if (blocked) throw new Error('Storage blocked');
      return { getItem: (key: string) => (key === languageKey ? saved : null) };
    },
    setTimeout: (fn: () => void, ms: number) => {
      assert.strictEqual(ms, hydrationGraceMs);
      timers.push(fn);
    },
  });
  return { root, redirect, timers };
}

describe('language before first paint', () => {
  it.each([
    { browser: 'zh-CN', saved: null, expected: null },
    { browser: 'zh-TW', saved: null, expected: null },
    { browser: 'en-US', saved: null, expected: '/macbox/en/' },
    { browser: 'ja-JP', saved: null, expected: '/macbox/en/' },
    { browser: 'en-US', saved: 'zh', expected: null },
    { browser: 'zh-CN', saved: 'en', expected: '/macbox/en/' },
  ])('$browser with saved $saved → $expected', ({ browser, saved, expected }) => {
    const { redirect, root } = visit('/macbox/', { browser, saved });
    assert.strictEqual(redirect, expected);
    assert.strictEqual(root.style.visibility, expected ? 'hidden' : '');
  });

  it('keeps the query string and the section anchor', () => {
    assert.strictEqual(
      visit('/macbox/?ref=x#download', { browser: 'en' }).redirect,
      '/macbox/en/?ref=x#download',
    );
  });

  it('treats index.html as the Chinese home page', () => {
    assert.strictEqual(visit('/macbox/index.html', { browser: 'en' }).redirect, '/macbox/en/');
  });

  it('never redirects pages other than the Chinese home page', () => {
    assert.isNull(visit('/macbox/en/', { saved: 'zh' }).redirect);
    assert.isNull(visit('/macbox/404/', { browser: 'en' }).redirect);
  });

  it('works at the site root and with storage blocked', () => {
    assert.strictEqual(visit('/', { base: '/', browser: 'en' }).redirect, '/en/');
    assert.strictEqual(visit('/', { base: '/', browser: 'en', blocked: true }).redirect, '/en/');
    assert.isNull(visit('/', { base: '/', browser: 'zh', blocked: true }).redirect);
  });

  it('shows hidden content again if the page never hydrates', () => {
    const late = visit('/macbox/en/');
    assert.isTrue(late.root.classes.has('js'));
    late.timers.forEach((fn) => fn());
    assert.isFalse(late.root.classes.has('js'));

    const hydrated = visit('/macbox/en/');
    hydrated.root.classes.add('hydrated');
    hydrated.timers.forEach((fn) => fn());
    assert.isTrue(hydrated.root.classes.has('js'));
  });
});
