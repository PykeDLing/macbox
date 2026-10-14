// 检查构建出来的静态页面；没有先构建（dist/ 不存在）时跳过。CI 里在 pnpm build 之后运行
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { assert, describe, it } from 'vitest';

const dist = new URL('../dist/client/', import.meta.url);
const built = existsSync(new URL('index.html', dist));
const page = (path: string) => readFileSync(new URL(path, dist), 'utf8');
const base = `/${(process.env.BASE_PATH || '').replace(/^\/+|\/+$/g, '')}/`.replace('//', '/');
const body = (html: string) =>
  html
    .slice(html.indexOf('<body'))
    .replace(/<script[\s\S]*?<\/script>/g, ' ')
    .replace(/<[^>]+>/g, ' ');
const cjk = /[　-〿㐀-鿿＀-￯]+/g;

describe.skipIf(!built)('prerendered pages', () => {
  it('serves Chinese at the root and English under /en/', () => {
    const zh = page('index.html');
    const en = page('en/index.html');
    assert.match(zh, /<html lang="zh-CN"/);
    assert.match(en, /<html lang="en"/);
    assert.match(zh, /<title>MacBox — 把不放心的 Mac 软件装进盒子里<\/title>/);
    assert.match(en, /<title>MacBox — Run the Mac apps you don’t trust in a box<\/title>/);
    assert.include(body(zh), '不放心的软件');
  });

  it('keeps Chinese out of the English page, apart from the language names', () => {
    const found = new Set(body(page('en/index.html')).match(cjk));
    assert.deepStrictEqual([...found].sort(), ['中', '中文'].sort());
  });

  it('links the two languages to each other for search engines', () => {
    for (const path of ['index.html', 'en/index.html']) {
      const html = page(path);
      const alternates = [
        ...html.matchAll(/<link rel="alternate" hrefLang="([^"]+)" href="([^"]+)"/g),
      ];
      assert.deepStrictEqual(
        alternates.map(([, lang]) => lang),
        ['zh-CN', 'en', 'x-default'],
      );
      assert.match(html, /<link rel="canonical" href="https:\/\/[^"]+"/);
      const ld = /<script type="application\/ld\+json">([\s\S]*?)<\/script>/.exec(html);
      assert.strictEqual(JSON.parse(ld![1]!)['@type'], 'SoftwareApplication');
    }
  });

  it('prefixes every local asset with the deployment path', () => {
    for (const path of ['index.html', 'en/index.html', '404.html']) {
      const urls = [...page(path).matchAll(/(?:href|src)="(\/[^"]*)"/g)].map(([, url]) => url!);
      assert.isNotEmpty(urls);
      for (const url of urls) assert.isTrue(url.startsWith(base), `${path}: ${url}`);
    }
  });

  it('ships a 404 page that search engines skip', () => {
    assert.match(page('404.html'), /<meta name="robots" content="noindex"/);
  });

  it('bundles only the icon weights it uses', () => {
    // 每个图标只打包一种粗细，不会把 Phosphor 的六种粗细都带上
    const assets = readdirSync(new URL('assets/', dist)).filter((name) => name.endsWith('.js'));
    const code = assets.map((name) => page(`assets/${name}`)).join('\n');
    assert.notInclude(code, 'IconContext');
  });
});
