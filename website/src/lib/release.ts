import { useEffect, useState } from 'react';
import { Effect, Fiber } from 'effect';
import { translate, type Locale } from './i18n';
import { appVersion, latestReleasePage } from './site';

export interface Release {
  version: string;
  /** 最新 dmg 的直接下载地址；发布里没有 dmg 时指向发布页 */
  download: string;
  dmg: { size: number; published: Date } | null;
}

/** 预渲染时和取不到 GitHub 数据时用：App 自己的版本号，下载按钮指向发布页 */
export const fallbackRelease: Release = {
  version: appVersion,
  download: latestReleasePage,
  dmg: null,
};

/** “12.3 MB · 2026年10月14日发布”；和访达一样按 1000 进位 */
export function describeDmg(dmg: NonNullable<Release['dmg']>, locale: Locale) {
  const t = translate(locale);
  const size = `${(dmg.size / 1e6).toFixed(1)} MB`;
  return t(
    `${size} · ${dmg.published.toLocaleDateString('zh-CN', { year: 'numeric', month: 'long', day: 'numeric' })}发布`,
    `${size} · Released ${dmg.published.toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: 'numeric' })}`,
  );
}

/** 页面打开后取一次最新发布；取不到就保留预渲染时的版本号和发布页链接 */
export function useLatestRelease() {
  const [release, setRelease] = useState(fallbackRelease);
  useEffect(() => {
    // 解析用到的 Schema 不小，放在单独的模块里，等页面能操作了再加载，不占首屏的脚本
    const fiber = Effect.runFork(
      Effect.tryPromise(() => import('./release-fetch')).pipe(
        Effect.flatMap((module) => module.fetchLatestRelease),
        Effect.tap((next) => Effect.sync(() => setRelease(next))),
        Effect.ignore,
      ),
    );
    return () => {
      Effect.runFork(Fiber.interrupt(fiber));
    };
  }, []);
  return release;
}
