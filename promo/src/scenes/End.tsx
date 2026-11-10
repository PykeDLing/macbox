import { AbsoluteFill, spring, useCurrentFrame, useVideoConfig } from 'remotion';
import { C, MONO, tw } from '../theme';
import { useLang, useT } from '../strings';
import { MacBoxIcon, Reveal } from '../ui';

export const End = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = useT();
  const lang = useLang();
  const iconIn = spring({ frame: frame - 6, fps, config: { damping: 13, stiffness: 110 } });

  return (
    <AbsoluteFill style={{ alignItems: 'center' }}>
      <div style={{ marginTop: 150, transform: `scale(${iconIn})` }}>
        <MacBoxIcon size={280} style={{ filter: 'drop-shadow(0 40px 70px rgba(0,0,0,0.6))' }} />
      </div>
      <Reveal at={18}>
        <div
          style={{
            fontSize: 150,
            fontWeight: 700,
            letterSpacing: -4,
            color: C.ink,
            lineHeight: 1.1,
            marginTop: 6,
          }}
        >
          MacBox
        </div>
      </Reveal>
      <Reveal at={30}>
        <div
          style={{
            fontSize: lang === 'zh' ? 50 : 44,
            color: C.ink,
            marginTop: 14,
            fontWeight: 500,
          }}
        >
          {t('把不放心的 Mac 软件，装进盒子里。', 'Run the Mac apps you don’t trust in a box.')}
        </div>
      </Reveal>
      <Reveal at={46} style={{ marginTop: 48 }}>
        <div style={{ display: 'flex', gap: 16 }}>
          {[
            t('免费', 'Free'),
            t('开源 · MIT', 'Open source · MIT'),
            'Apple Silicon',
            t('macOS 26 或更新', 'macOS 26 or later'),
          ].map((label) => (
            <div
              key={label}
              style={{
                padding: '12px 26px',
                borderRadius: 999,
                border: `1px solid ${C.lineStrong}`,
                background: C.fill,
                fontSize: 28,
                color: C.ink2,
              }}
            >
              {label}
            </div>
          ))}
        </div>
      </Reveal>
      <div
        style={{
          marginTop: 44,
          padding: '18px 40px',
          borderRadius: 999,
          background: C.accent,
          color: '#fff',
          fontFamily: MONO,
          fontSize: 34,
          fontWeight: 600,
          opacity: tw(frame, 62, 78),
          transform: `translateY(${(1 - tw(frame, 62, 78)) * 20}px)`,
          boxShadow: '0 20px 60px rgba(61,139,255,0.4)',
        }}
      >
        github.com/PykeDLing/macbox
      </div>
    </AbsoluteFill>
  );
};
