import type { Pair } from './i18n';

/**
 * 宣传片（仓库里的 promo/，用 Remotion 渲染）的章节：每章从第几秒开始。
 * 镜头的顺序和长度在 promo/src/theme.ts 的 SCENES 里，改了那边这里要跟着改；
 * tests/film.test.ts 会按那个文件重新算一遍来核对
 */
export const filmChapters: readonly { scene: string; start: number; title: Pair }[] = [
  { scene: 'problem', start: 0, title: ['留下一堆东西', 'The leftovers'] },
  { scene: 'add', start: 12.9, title: ['拖进来就装好', 'Drop it in'] },
  { scene: 'native', start: 19.1, title: ['和普通 App 一样', 'Like any app'] },
  { scene: 'report', start: 25.1, title: ['运行报告', 'Run reports'] },
  { scene: 'protect', start: 31.7, title: ['碰不到私人数据', 'Private data'] },
  { scene: 'remove', start: 37.9, title: ['删掉盒子', 'Delete the box'] },
  { scene: 'numbers', start: 44.2, title: ['几个数字', 'The numbers'] },
];

/** 片长（秒），写在按钮上 */
export const filmSeconds = 55;

/** 播放到 time 秒时正在放第几章 */
export function chapterAt(time: number) {
  let current = 0;
  filmChapters.forEach((chapter, i) => {
    // 跳到某一章时浏览器给的时间可能差几毫秒
    if (time >= chapter.start - 0.05) current = i;
  });
  return current;
}

/** 12.9 → “00:12”，和播放器进度条上的写法一样（不进位） */
export function timestamp(seconds: number) {
  const whole = Math.floor(seconds);
  return `${String(Math.floor(whole / 60)).padStart(2, '0')}:${String(whole % 60).padStart(2, '0')}`;
}
