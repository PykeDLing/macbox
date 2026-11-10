import type { ReactNode } from 'react';
import { AbsoluteFill, Audio, staticFile, useCurrentFrame } from 'remotion';
import { linearTiming, TransitionSeries } from '@remotion/transitions';
import { fade } from '@remotion/transitions/fade';
import {
  C,
  FONT,
  MONO,
  SCENES,
  SCENE_ORDER,
  type SceneName,
  sceneStart,
  TOTAL_FRAMES,
  TRANSITION,
  tw,
} from './theme';
import { type Lang, LangContext } from './strings';
import { Backdrop, MacBoxIcon } from './ui';
import { Problem } from './scenes/Problem';
import { Idea } from './scenes/Idea';
import { Add } from './scenes/Add';
import { Native } from './scenes/Native';
import { Report } from './scenes/Report';
import { Protect } from './scenes/Protect';
import { Remove } from './scenes/Remove';
import { Numbers } from './scenes/Numbers';
import { End } from './scenes/End';

const SCENE_VIEWS: Record<SceneName, () => ReactNode> = {
  problem: Problem,
  idea: Idea,
  add: Add,
  native: Native,
  report: Report,
  protect: Protect,
  remove: Remove,
  numbers: Numbers,
  end: End,
};

const CHAPTERS: readonly SceneName[] = ['add', 'native', 'report', 'protect', 'remove'];

/** 贯穿章节镜头的角标：左上角标志，右上角第几章，底部进度 */
const Hud = () => {
  const frame = useCurrentFrame();
  const from = sceneStart('add');
  const until = sceneStart('end');
  const visible = tw(frame, from + 4, from + 20) * (1 - tw(frame, until, until + TRANSITION));
  const chapter = CHAPTERS.reduce(
    (n, name, i) => (frame >= sceneStart(name) + TRANSITION / 2 ? i + 1 : n),
    1,
  );
  const inChapters = 1 - tw(frame, sceneStart('numbers'), sceneStart('numbers') + TRANSITION);

  return (
    <AbsoluteFill style={{ opacity: visible }}>
      <div
        style={{
          position: 'absolute',
          left: 64,
          top: 48,
          display: 'flex',
          alignItems: 'center',
          gap: 14,
        }}
      >
        <MacBoxIcon size={52} />
        <span style={{ fontSize: 28, fontWeight: 700, color: C.ink }}>MacBox</span>
      </div>
      <div
        style={{
          position: 'absolute',
          right: 64,
          top: 58,
          display: 'flex',
          alignItems: 'center',
          gap: 12,
          opacity: inChapters,
        }}
      >
        {CHAPTERS.map((name, i) => (
          <div
            key={name}
            style={{
              width: i + 1 === chapter ? 44 : 12,
              height: 6,
              borderRadius: 6,
              background:
                i + 1 === chapter
                  ? C.accent
                  : i + 1 < chapter
                    ? 'rgba(255,255,255,0.5)'
                    : 'rgba(255,255,255,0.18)',
            }}
          />
        ))}
        <span style={{ fontFamily: MONO, fontSize: 20, color: C.ink3, marginLeft: 8 }}>
          {String(chapter).padStart(2, '0')} / {String(CHAPTERS.length).padStart(2, '0')}
        </span>
      </div>
    </AbsoluteFill>
  );
};

export const Promo = ({ lang }: { lang: Lang }) => {
  const frame = useCurrentFrame();
  return (
    <LangContext.Provider value={lang}>
      <AbsoluteFill style={{ fontFamily: FONT, color: C.ink, WebkitFontSmoothing: 'antialiased' }}>
        {/* 配乐由 scripts/bgm.mjs 算出来，小节线对着镜头的切换；淡入淡出已经做在文件里 */}
        <Audio src={staticFile('bgm.wav')} />
        <Backdrop />
        <TransitionSeries>
          {SCENE_ORDER.flatMap((name, i) => {
            const View = SCENE_VIEWS[name];
            const scene = (
              <TransitionSeries.Sequence key={name} durationInFrames={SCENES[name]}>
                <View />
              </TransitionSeries.Sequence>
            );
            if (i === 0) return [scene];
            return [
              <TransitionSeries.Transition
                key={`${name}-in`}
                presentation={fade()}
                timing={linearTiming({ durationInFrames: TRANSITION })}
              />,
              scene,
            ];
          })}
        </TransitionSeries>
        <Hud />
        {/* 整片的进度，贴在最底下一条细线 */}
        <div
          style={{
            position: 'absolute',
            left: 0,
            bottom: 0,
            height: 4,
            width: `${(frame / (TOTAL_FRAMES - 1)) * 100}%`,
            background: C.accent,
            opacity: 0.7,
          }}
        />
        {/* 开头从黑里淡入，结尾淡出到黑 */}
        <AbsoluteFill
          style={{
            background: '#000',
            opacity: Math.max(1 - tw(frame, 0, 12), tw(frame, TOTAL_FRAMES - 14, TOTAL_FRAMES - 1)),
          }}
        />
      </AbsoluteFill>
    </LangContext.Provider>
  );
};
