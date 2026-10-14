// 中文版在根路径，英文版在 /en/。两个版本渲染同一套组件，文字用 t('中文', 'English') 挑
export type Locale = 'zh' | 'en';
export type Pair = readonly [zh: string, en: string];

export const localeOf = (path: string): Locale =>
  path === '/en' || path.startsWith('/en/') ? 'en' : 'zh';
export const homePath = (locale: Locale) => (locale === 'en' ? '/en/' : '/');
export const htmlLang = (locale: Locale) => (locale === 'en' ? 'en' : 'zh-CN');
export const otherLocale = (locale: Locale): Locale => (locale === 'en' ? 'zh' : 'en');

/** t('中文', 'English')；也可以传两段 JSX */
export const translate =
  (locale: Locale) =>
  <Zh, En = Zh>(zh: Zh, en: En): Zh | En =>
    locale === 'en' ? en : zh;
export const pick = (locale: Locale, pair: Pair) => (locale === 'en' ? pair[1] : pair[0]);

/** 去掉部署路径前缀（如 /macbox），得到站内路径 */
export function pathWithoutBase(pathname: string, base: string) {
  const prefix = base.replace(/\/$/, '');
  return prefix && (pathname === prefix || pathname.startsWith(`${prefix}/`))
    ? pathname.slice(prefix.length) || '/'
    : pathname;
}
