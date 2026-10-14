import { homePath, htmlLang, translate, type Locale } from './i18n';
import { absoluteUrl, latestReleasePage } from './site';

const titles = {
  zh: 'MacBox — 把不放心的 Mac 软件装进盒子里',
  en: 'MacBox — Run the Mac apps you don’t trust in a box',
} as const;

export const notFoundTitle = '页面不存在 · Page not found — MacBox';

/** 首页两个语言版本的 <head>：标题、描述、分享卡片、语言互链和结构化数据 */
export function homeHead(locale: Locale) {
  const t = translate(locale);
  const url = absoluteUrl(homePath(locale));
  const description = t(
    'MacBox 让不放心的 Mac 软件在隔离的盒子里运行：照常使用，它写下的文件、设置和钥匙串都留在盒子里。免费开源。',
    'MacBox runs the Mac apps you’re wary of in an isolated box: use them as usual while their files, settings and keychain items stay in the box. Free and open source.',
  );
  return {
    meta: [
      { title: titles[locale] },
      { name: 'description', content: description },
      { property: 'og:title', content: 'MacBox' },
      {
        property: 'og:description',
        content: t(
          '把不放心的 Mac 软件装进盒子里：照常使用，删掉就干干净净。',
          'Run the Mac apps you don’t trust inside a box. Delete the box and your Mac is clean.',
        ),
      },
      { property: 'og:url', content: url },
      { property: 'og:locale', content: htmlLang(locale).replace('-', '_') },
      { property: 'og:image', content: absoluteUrl('/icon.png') },
      { property: 'og:image:width', content: '512' },
      { property: 'og:image:height', content: '512' },
      { property: 'og:image:alt', content: t('MacBox 图标', 'MacBox icon') },
      {
        'script:ld+json': {
          '@context': 'https://schema.org',
          '@type': 'SoftwareApplication',
          name: 'MacBox',
          url,
          inLanguage: htmlLang(locale),
          image: absoluteUrl('/icon.png'),
          description,
          applicationCategory: 'UtilitiesApplication',
          operatingSystem: 'macOS 26 or later (Apple silicon)',
          downloadUrl: latestReleasePage,
          license: 'https://opensource.org/licenses/MIT',
          offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
        },
      },
    ],
    links: [
      { rel: 'canonical', href: url },
      { rel: 'alternate', hrefLang: 'zh-CN', href: absoluteUrl('/') },
      { rel: 'alternate', hrefLang: 'en', href: absoluteUrl('/en/') },
      // 根路径会按浏览器语言转到对应版本，所以它就是默认入口
      { rel: 'alternate', hrefLang: 'x-default', href: absoluteUrl('/') },
    ],
  };
}
