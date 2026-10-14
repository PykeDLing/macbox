import type { Locale } from './i18n';

export const languageKey = 'macbox-lang';

export function rememberLanguage(locale: Locale) {
  try {
    localStorage.setItem(languageKey, locale);
  } catch {
    // 存不了就只对这次访问生效
  }
}

/** 脚本迟迟没有接管页面时（网络慢、被拦截），去掉 .js 标记，让等着淡入的内容直接显示 */
export const hydrationGraceMs = 4000;

/**
 * 在 <head> 里、绘制前运行：
 * - 给 <html> 加 .js，只在脚本能运行时才把淡入的内容先藏起来；
 * - 中文首页（根路径）按“记住的选择 > 浏览器语言”决定要不要换到英文版。
 * 只有根路径会跳转：直接打开 /en/ 的人看到的就是英文，分享出去的链接不会被改语言。
 */
export const languageScript = (base: string) =>
  `(()=>{const d=document.documentElement;d.classList.add('js');setTimeout(()=>{d.classList.contains('hydrated')||d.classList.remove('js')},${hydrationGraceMs});const b=${JSON.stringify(base)};if(location.pathname.replace(/index\\.html$/,'')!==b)return;let s=null;try{s=localStorage.getItem(${JSON.stringify(languageKey)})}catch{}if(s==='en'||(s!=='zh'&&!/^zh/i.test(navigator.language||''))){d.style.visibility='hidden';location.replace(b+'en/'+location.search+location.hash)}})()`;
