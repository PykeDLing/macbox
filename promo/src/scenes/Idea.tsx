import { AbsoluteFill, spring, useCurrentFrame, useVideoConfig } from 'remotion';
import { C, tw, easeInOut } from '../theme';
import { useLang, useT } from '../strings';
import { MacBoxIcon } from '../ui';
import { CENTER, LEFTOVERS, LeftoverChip } from './Problem';

/** 散落的东西一个个收进盒子，盒子变成 MacBox */
export const Idea = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = useT();
  const lang = useLang();

  const iconIn = spring({ frame: frame - 14, fps, config: { damping: 13, stiffness: 110 } });
  const lift = tw(frame, 78, 104, 0, 1, easeInOut);
  // 每收进一个，盒子外圈亮一下
  const lastLanding = LEFTOVERS.reduce((latest, _, i) => {
    const landed = 22 + i * 6 + 22;
    return frame >= landed ? landed : latest;
  }, -100);
  const ring = 1 - tw(frame, lastLanding, lastLanding + 14);

  return (
    <AbsoluteFill>
      {LEFTOVERS.map((item, i) => {
        const p = tw(frame, 22 + i * 6, 22 + i * 6 + 22, 0, 1, easeInOut);
        return (
          <LeftoverChip
            key={item.zh}
            item={item}
            x={item.x * (1 - p)}
            y={item.y * (1 - p)}
            scale={1 - p * 0.8}
            opacity={1 - tw(frame, 22 + i * 6 + 14, 22 + i * 6 + 22)}
          />
        );
      })}

      <div
        style={{
          position: 'absolute',
          left: CENTER.x,
          top: CENTER.y - lift * 190,
          transform: `translate(-50%, -50%) scale(${iconIn * (1 + ring * 0.04)})`,
        }}
      >
        <div
          style={{
            position: 'absolute',
            inset: -30,
            borderRadius: 110,
            border: `3px solid rgba(48,209,88,${ring * 0.7})`,
            boxShadow: `0 0 ${60 * ring}px rgba(48,209,88,${ring * 0.5})`,
            transform: `scale(${1 + (1 - ring) * 0.12})`,
          }}
        />
        <MacBoxIcon size={340} style={{ filter: 'drop-shadow(0 40px 70px rgba(0,0,0,0.6))' }} />
      </div>

      <div
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          top: 640,
          textAlign: 'center',
        }}
      >
        <div
          style={{
            fontSize: lang === 'zh' ? 112 : 92,
            fontWeight: 700,
            letterSpacing: lang === 'zh' ? 2 : -2,
            color: C.ink,
            opacity: tw(frame, 88, 108),
            transform: `translateY(${(1 - tw(frame, 88, 108)) * 30}px)`,
          }}
        >
          {t('不放心的软件，装进盒子里用。', 'Run the apps you don’t trust in a box.')}
        </div>
        <div
          style={{
            marginTop: 28,
            fontSize: lang === 'zh' ? 40 : 36,
            color: C.ink2,
            opacity: tw(frame, 108, 128),
            transform: `translateY(${(1 - tw(frame, 108, 128)) * 24}px)`,
          }}
        >
          {t(
            '像普通 App 一样打开。删掉盒子，不在你的 Mac 上乱留东西。',
            'They open like any other app. Delete the box, and they leave no mess on your Mac.',
          )}
        </div>
      </div>
    </AbsoluteFill>
  );
};
