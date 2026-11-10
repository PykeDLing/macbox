import { Easing, interpolate } from 'remotion';

export const FPS = 30;
export const W = 1920;
export const H = 1080;

/** 配色：深色舞台，盒子里的东西用绿，漏到盒子外、被拦下的用红，强调用蓝 */
export const C = {
  bg: '#08090b',
  ink: '#f4f5f7',
  ink2: '#a6abb4',
  ink3: '#6d727b',
  line: 'rgba(255,255,255,0.10)',
  lineStrong: 'rgba(255,255,255,0.18)',
  panel: '#17181b',
  panel2: '#1f2024',
  fill: 'rgba(255,255,255,0.06)',
  accent: '#3d8bff',
  red: '#ff5a52',
  amber: '#febc2e',
  green: '#30d158',
};

// 用系统字体：渲染在 macOS 上做，苹方和 SF 都在；换到别的系统渲染要改这里
export const FONT =
  '-apple-system, BlinkMacSystemFont, "SF Pro Display", "PingFang SC", "Helvetica Neue", sans-serif';
export const MONO = '"SF Mono", ui-monospace, Menlo, monospace';

export const easeOut = Easing.bezier(0.16, 1, 0.3, 1);
export const easeInOut = Easing.bezier(0.65, 0, 0.35, 1);

/** 从第 a 帧到第 b 帧，值从 from 变到 to，两头钳住 */
export const tw = (
  frame: number,
  a: number,
  b: number,
  from = 0,
  to = 1,
  easing: (t: number) => number = easeOut,
) =>
  interpolate(frame, [a, b], [from, to], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing,
  });

/** 每个镜头的长度（帧）；相邻镜头交叠 TRANSITION 帧 */
export const TRANSITION = 12;
export const SCENES = {
  problem: 240,
  idea: 170,
  add: 200,
  native: 190,
  report: 210,
  protect: 200,
  remove: 200,
  numbers: 160,
  end: 180,
} as const;
export type SceneName = keyof typeof SCENES;
export const SCENE_ORDER = Object.keys(SCENES) as SceneName[];

export const TOTAL_FRAMES =
  SCENE_ORDER.reduce((sum, name) => sum + SCENES[name], 0) - (SCENE_ORDER.length - 1) * TRANSITION;

/** 镜头在整片里开始的帧（交叠开始的那一帧） */
export const sceneStart = (name: SceneName) => {
  let at = 0;
  for (const scene of SCENE_ORDER) {
    if (scene === name) return at;
    at += SCENES[scene] - TRANSITION;
  }
  return at;
};
