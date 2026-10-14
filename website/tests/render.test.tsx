import { renderToString } from 'react-dom/server';
import { assert, describe, it } from 'vitest';
import { DemoWindow } from '../src/demo/DemoWindow';
import type { Locale } from '../src/lib/i18n';

const text = (locale: Locale) =>
  renderToString(<DemoWindow locale={locale} onLanguage={() => {}} />)
    .replace(/<[^>]+>/g, ' ')
    .replace(/&[a-z#0-9]+;/g, ' ');
const cjk = /[　-〿㐀-鿿＀-￯]+/g;

describe('demo window text', () => {
  it('renders the English demo without any Chinese', () => {
    assert.deepStrictEqual(text('en').match(cjk), null);
  });

  it('renders the Chinese demo with the app’s Chinese labels', () => {
    const zh = text('zh');
    for (const label of ['全部应用', '运行中', '虚拟 Mac', '本次已拦截', '某某网盘']) {
      assert.include(zh, label);
    }
  });
});
