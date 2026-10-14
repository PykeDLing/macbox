import { assert, describe, it } from 'vitest';
import { homePath, localeOf, pathWithoutBase, translate } from '../src/lib/i18n';

describe('locale paths', () => {
  it.each([
    ['/', 'zh'],
    ['/404/', 'zh'],
    ['/en', 'en'],
    ['/en/', 'en'],
    ['/english/', 'zh'],
  ] as const)('%s is %s', (path, locale) => assert.strictEqual(localeOf(path), locale));

  it('strips the deployment prefix only at a path boundary', () => {
    assert.strictEqual(pathWithoutBase('/macbox/en/', '/macbox/'), '/en/');
    assert.strictEqual(pathWithoutBase('/macbox', '/macbox/'), '/');
    assert.strictEqual(pathWithoutBase('/macboxes/', '/macbox/'), '/macboxes/');
    assert.strictEqual(pathWithoutBase('/en/', '/'), '/en/');
  });

  it('maps each locale to its home page and text', () => {
    assert.strictEqual(homePath('zh'), '/');
    assert.strictEqual(homePath('en'), '/en/');
    assert.strictEqual(translate('zh')('中文', 'English'), '中文');
    assert.strictEqual(translate('en')('中文', 'English'), 'English');
  });
});
