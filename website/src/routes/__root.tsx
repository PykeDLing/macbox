import { createRootRoute, HeadContent, Outlet, Scripts, useLocation } from '@tanstack/react-router';
import type { ReactNode } from 'react';
import NotFound from '../views/NotFound';
import { htmlLang, localeOf, pathWithoutBase } from '../lib/i18n';
import { languageScript } from '../lib/language';
import { notFoundTitle } from '../lib/head';
import { href } from '../lib/site';
import '../styles/global.css';

export const Route = createRootRoute({
  // 没有匹配到任何页面时只剩根路由，标题用 404 的
  head: ({ matches }) => ({
    meta: [
      { title: matches.length > 1 ? 'MacBox' : notFoundTitle },
      { charSet: 'utf-8' },
      { name: 'viewport', content: 'width=device-width, initial-scale=1' },
      { name: 'color-scheme', content: 'light dark' },
      { property: 'og:site_name', content: 'MacBox' },
      { property: 'og:type', content: 'website' },
      { name: 'twitter:card', content: 'summary' },
    ],
    links: [
      { rel: 'icon', type: 'image/png', href: href('/favicon.png') },
      { rel: 'apple-touch-icon', href: href('/icon.png') },
      { rel: 'preconnect', href: 'https://api.github.com', crossOrigin: 'anonymous' },
    ],
  }),
  shellComponent: Document,
  component: Outlet,
  notFoundComponent: NotFound,
});

function Document({ children }: { children: ReactNode }) {
  const locale = useLocation({
    select: (location) => localeOf(pathWithoutBase(location.pathname, import.meta.env.BASE_URL)),
  });
  return (
    // 脚本会在 <html> 上加 .js / .hydrated，和服务端渲染的不一样
    <html lang={htmlLang(locale)} suppressHydrationWarning>
      <head>
        <HeadContent />
        {/* 同名 meta 会被 HeadContent 去重，两种配色的 theme-color 直接写在这里 */}
        <meta name="theme-color" content="#f5f5f7" media="(prefers-color-scheme: light)" />
        <meta name="theme-color" content="#000000" media="(prefers-color-scheme: dark)" />
        <script dangerouslySetInnerHTML={{ __html: languageScript(import.meta.env.BASE_URL) }} />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  );
}
