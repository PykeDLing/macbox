import { readFileSync } from 'node:fs';
import { defineConfig } from 'vite';
import { tanstackStart } from '@tanstack/react-start/plugin/vite';
import react from '@vitejs/plugin-react';

// 部署在 GitHub Pages 的项目路径下（/macbox/）时由工作流传入；本地开发是根路径
const basePath = `/${(process.env.BASE_PATH || '').replace(/^\/+|\/+$/g, '')}/`.replace('//', '/');
// canonical、og:image 这类地址必须是完整网址；工作流传入 Pages 的实际地址，绑定自定义域名后自动跟着变
const siteUrl = `${(process.env.SITE_URL || 'https://pykedling.github.io/macbox').replace(/\/+$/, '')}/`;

// 网页上显示的默认版本号直接取 App 的 Info.plist，发版时不用另外改网页；
// 页面打开后还会从 GitHub 取最新发布覆盖它
const plist = readFileSync(new URL('../Resources/Info.plist', import.meta.url), 'utf8');
const appVersion = /<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/.exec(
  plist,
)?.[1];
if (!appVersion) throw new Error('Resources/Info.plist has no CFBundleShortVersionString.');

export default defineConfig({
  base: basePath,
  define: {
    'import.meta.env.APP_VERSION': JSON.stringify(appVersion),
    'import.meta.env.SITE_URL': JSON.stringify(siteUrl),
  },
  plugins: [
    tanstackStart({
      pages: ['/', '/en/', '/404/'].map((path) => ({ path })),
      prerender: {
        enabled: true,
        autoStaticPathsDiscovery: false,
        crawlLinks: false,
        failOnError: true,
        autoSubfolderIndex: true,
      },
    }),
    react(),
  ],
});
