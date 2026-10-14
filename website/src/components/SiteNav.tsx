import { useEffect, useState } from 'react';
import { Link } from '@tanstack/react-router';
import { homePath, translate, type Locale } from '../lib/i18n';
import { href, repository } from '../lib/site';

const sections = [
  ['how', '怎么用', 'How It Works'],
  ['features', '特性', 'Features'],
  ['modes', '运行环境', 'Runtimes'],
  ['download', '下载', 'Download'],
] as const;

export function SiteNav({
  locale,
  onLanguage,
}: {
  locale: Locale;
  /** 点语言开关、跳转之前调用：记下选择和滚动位置 */
  onLanguage: (locale: Locale) => void;
}) {
  const t = translate(locale);
  const [scrolled, setScrolled] = useState(false);
  const [current, setCurrent] = useState<string | null>(null);

  // 页面顶部时不画分隔线，滚动后才出现
  useEffect(() => {
    const update = () => setScrolled(window.scrollY > 4);
    update();
    window.addEventListener('scroll', update, { passive: true });
    return () => window.removeEventListener('scroll', update);
  }, []);

  // 导航高亮当前所在的版块
  useEffect(() => {
    if (!('IntersectionObserver' in window)) return;
    const visible = new Set<string>();
    const spy = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) visible.add(entry.target.id);
          else visible.delete(entry.target.id);
        }
        setCurrent(sections.find(([id]) => visible.has(id))?.[0] ?? null);
      },
      { rootMargin: '-45% 0px -54% 0px' },
    );
    for (const [id] of sections) {
      const el = document.getElementById(id);
      if (el) spy.observe(el);
    }
    return () => spy.disconnect();
  }, []);

  return (
    <nav className={scrolled ? 'nav scrolled' : 'nav'} aria-label={t('主导航', 'Main navigation')}>
      <div className="wrap">
        <a className="brand" href="#top">
          <img src={href('/favicon.png')} width={26} height={26} alt="" />
          MacBox
        </a>
        <div className="nav-links">
          {sections.map(([id, zh, en]) => (
            <a
              key={id}
              href={`#${id}`}
              className={id === 'download' ? 'keep' : undefined}
              aria-current={current === id ? 'true' : undefined}
            >
              {t(zh, en)}
            </a>
          ))}
          <a href={repository}>GitHub</a>
        </div>
        <div className="lang" role="group" aria-label="Language / 语言">
          {(
            [
              ['zh', '中', '简体中文'],
              ['en', 'EN', 'English'],
            ] as const
          ).map(([target, short, name]) => (
            <Link
              key={target}
              to={homePath(target)}
              replace
              resetScroll={false}
              hrefLang={target === 'en' ? 'en' : 'zh-CN'}
              lang={target === 'en' ? 'en' : 'zh-CN'}
              title={name}
              aria-label={name}
              aria-current={target === locale ? 'true' : undefined}
              onClick={() => onLanguage(target)}
            >
              {short}
            </Link>
          ))}
        </div>
      </div>
    </nav>
  );
}
