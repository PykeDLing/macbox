import { AbsoluteFill, useCurrentFrame } from 'remotion';
import { C, tw } from '../theme';
import { useLang, useT } from '../strings';
import { Glyph, Reveal } from '../ui';

/** 三个数字，加上还原点和虚拟 Mac；最后一行说清楚它防的是什么 */
export const Numbers = () => {
  const frame = useCurrentFrame();
  const t = useT();
  const lang = useLang();

  const stats: readonly [string, string, string][] = [
    [
      '≈1.5%',
      t('沙盒的性能开销', 'sandbox overhead'),
      t('原生运行，不是虚拟机', 'Runs natively. Not a VM.'),
    ],
    [
      '50 ms',
      t('检查一次新进程', 'between process checks'),
      t('在沙盒外启动的，立即结束', 'Anything outside the sandbox is stopped'),
    ],
    [
      '0',
      t('开机自启和后台服务', 'login items or daemons'),
      t('盒子里的应用注册不了', 'Boxed apps can’t register them'),
    ],
  ];
  const extras: readonly ['box' | 'display', string, string][] = [
    [
      'box',
      t('还原点', 'Restore points'),
      t(
        'APFS 克隆，几乎不占空间，一键回到之前',
        'APFS clones, almost no space. Roll back in a click.',
      ),
    ],
    [
      'display',
      t('虚拟 Mac 兜底', 'Virtual Mac fallback'),
      t('需要驱动、系统扩展的应用放进去', 'For apps that need drivers or system extensions'),
    ],
  ];

  return (
    <AbsoluteFill style={{ padding: '0 120px' }}>
      <div
        style={{
          position: 'absolute',
          left: 120,
          right: 120,
          top: 216,
          display: 'grid',
          gridTemplateColumns: 'repeat(3, 1fr)',
          gap: 40,
        }}
      >
        {stats.map(([value, label, note], i) => (
          <Reveal key={value} at={8 + i * 12} dy={40}>
            <div style={{ borderTop: `2px solid ${C.lineStrong}`, paddingTop: 30 }}>
              <div
                style={{
                  fontSize: 168,
                  fontWeight: 700,
                  letterSpacing: -6,
                  lineHeight: 1,
                  color: C.ink,
                  fontVariantNumeric: 'tabular-nums',
                }}
              >
                {value}
              </div>
              <div
                style={{
                  fontSize: lang === 'zh' ? 38 : 34,
                  fontWeight: 600,
                  color: C.ink,
                  marginTop: 22,
                }}
              >
                {label}
              </div>
              <div style={{ fontSize: lang === 'zh' ? 27 : 24, color: C.ink2, marginTop: 10 }}>
                {note}
              </div>
            </div>
          </Reveal>
        ))}
      </div>

      <div
        style={{
          position: 'absolute',
          left: 120,
          right: 120,
          top: 668,
          display: 'grid',
          gridTemplateColumns: '1fr 1fr',
          gap: 40,
        }}
      >
        {extras.map(([glyph, title, text], i) => (
          <Reveal key={title} at={56 + i * 10}>
            <div
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 24,
                padding: '28px 32px',
                borderRadius: 24,
                background: C.fill,
                border: `1px solid ${C.line}`,
              }}
            >
              <div
                style={{
                  width: 72,
                  height: 72,
                  borderRadius: 20,
                  background: 'rgba(61,139,255,0.16)',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  flex: 'none',
                }}
              >
                <Glyph name={glyph} size={40} color={C.accent} stroke={1.8} />
              </div>
              <div>
                <div style={{ fontSize: 34, fontWeight: 700, color: C.ink }}>{title}</div>
                <div style={{ fontSize: lang === 'zh' ? 25 : 22, color: C.ink2, marginTop: 6 }}>
                  {text}
                </div>
              </div>
            </div>
          </Reveal>
        ))}
      </div>

      <div
        style={{
          position: 'absolute',
          left: 120,
          right: 120,
          top: 902,
          textAlign: 'center',
          fontSize: lang === 'zh' ? 28 : 25,
          color: C.ink3,
          opacity: tw(frame, 86, 102),
        }}
      >
        {t(
          '本机隔离防的是乱写、乱留、乱读，不是恶意软件。来路可疑的软件，请用虚拟 Mac。',
          'Native Isolation stops stray writes, leftovers and stray reads, not malware. For anything suspicious, use the Virtual Mac.',
        )}
      </div>
    </AbsoluteFill>
  );
};
