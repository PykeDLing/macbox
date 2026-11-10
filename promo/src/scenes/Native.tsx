import { AbsoluteFill, spring, useCurrentFrame, useVideoConfig } from 'remotion';
import { C, tw } from '../theme';
import { APP, useLang, useT } from '../strings';
import {
  AppIcon,
  type AppKind,
  ChapterCopy,
  Glyph,
  Hi,
  MacBoxIcon,
  Reveal,
  RIGHT,
  Stage,
  TrafficLights,
} from '../ui';

const DESK = { w: RIGHT.w, h: 620 };
const DOCK: readonly (AppKind | 'macbox')[] = [
  'folder',
  'compass',
  'mail',
  'cloud',
  'music',
  'macbox',
];
const ICON = 62;
const GAP = 16;
const dockW = DOCK.length * ICON + (DOCK.length - 1) * GAP + 36;
const dockLeft = (DESK.w - dockW) / 2;
const cloudCenterX = dockLeft + 18 + 3 * (ICON + GAP) + ICON / 2;

/** 一块示意的 Mac 桌面：盒子里的应用在程序坞里弹跳、开窗，也能从聚焦找到 */
export const Native = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = useT();
  const lang = useLang();

  const bounce =
    frame >= 16 && frame < 58
      ? Math.abs(Math.sin(((frame - 16) / 14) * Math.PI)) * 26 * (1 - (frame - 16) / 42)
      : 0;
  const running = tw(frame, 34, 44);
  const win = spring({ frame: frame - 46, fps, config: { damping: 16, stiffness: 120 } });
  const upload = tw(frame, 70, 170, 0.12, 0.86, (x) => x);

  const spot = tw(frame, 104, 116);
  const typed = APP[lang].slice(
    0,
    Math.max(0, Math.round(tw(frame, 114, 132, 0, APP[lang].length, (x) => x))),
  );
  const result = tw(frame, 134, 144);

  return (
    <AbsoluteFill>
      <ChapterCopy
        index={2}
        tag={t('使用', 'USE')}
        title={t(['和普通 App', '没有两样。'], ['Feels like', 'any other app.'])}
      >
        <Reveal at={28}>
          {t(
            <>原生窗口、程序坞、聚焦，都在。</>,
            <>Native windows, the Dock, Spotlight. All there.</>,
          )}
        </Reveal>
        <Reveal at={40}>
          {t(
            <>点链接、双击文件，也交给盒子里的它。</>,
            <>Links and files open in the boxed app, too.</>,
          )}
        </Reveal>
        <Reveal at={56} style={{ marginTop: 34 }}>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 18 }}>
            <span style={{ fontSize: 76, fontWeight: 700, color: C.ink, letterSpacing: -2 }}>
              ≈1.5%
            </span>
            <span style={{ fontSize: lang === 'zh' ? 30 : 26 }}>
              {t('沙盒的性能开销', 'sandbox overhead')}
            </span>
          </div>
        </Reveal>
      </ChapterCopy>

      <Stage height={DESK.h}>
        <div
          style={{
            position: 'relative',
            width: DESK.w,
            height: DESK.h,
            borderRadius: 26,
            overflow: 'hidden',
            border: `1px solid ${C.lineStrong}`,
            boxShadow: '0 60px 140px rgba(0,0,0,0.65)',
            background:
              'radial-gradient(700px 500px at 20% 15%, #35518f 0%, transparent 70%), radial-gradient(700px 520px at 85% 90%, #5a3a86 0%, transparent 70%), #141a33',
          }}
        >
          {/* 菜单栏 */}
          <div
            style={{
              position: 'absolute',
              left: 0,
              right: 0,
              top: 0,
              height: 36,
              background: 'rgba(0,0,0,0.28)',
              display: 'flex',
              alignItems: 'center',
              gap: 22,
              padding: '0 20px',
              fontSize: 15,
              color: 'rgba(255,255,255,0.86)',
            }}
          >
            <span style={{ fontWeight: 700, opacity: win }}>{APP[lang]}</span>
            {t(['文件', '编辑', '显示', '窗口'], ['File', 'Edit', 'View', 'Window']).map((item) => (
              <span key={item} style={{ opacity: win * 0.86 }}>
                {item}
              </span>
            ))}
          </div>

          {/* 应用自己的窗口，从程序坞里的图标处展开 */}
          <div
            style={{
              position: 'absolute',
              left: (DESK.w - 600) / 2,
              top: 78,
              width: 600,
              height: 372,
              borderRadius: 16,
              background: '#f6f6f8',
              boxShadow: '0 30px 80px rgba(0,0,0,0.5)',
              overflow: 'hidden',
              opacity: Math.min(1, win * 1.4),
              transform: `scale(${0.3 + win * 0.7})`,
              transformOrigin: `${cloudCenterX - (DESK.w - 600) / 2}px 470px`,
            }}
          >
            <div
              style={{
                height: 46,
                display: 'flex',
                alignItems: 'center',
                padding: '0 16px',
                gap: 14,
                borderBottom: '1px solid rgba(0,0,0,0.08)',
              }}
            >
              <TrafficLights size={13} />
              <span style={{ fontSize: 16, fontWeight: 600, color: '#1d1d1f' }}>{APP[lang]}</span>
            </div>
            <div style={{ display: 'flex', height: 326 }}>
              <div
                style={{
                  width: 150,
                  background: '#ececf0',
                  padding: 16,
                  display: 'flex',
                  flexDirection: 'column',
                  gap: 12,
                }}
              >
                {[72, 96, 60, 84].map((w, i) => (
                  <div
                    key={i}
                    style={{
                      height: 12,
                      width: w,
                      borderRadius: 6,
                      background: i === 0 ? '#2a74f0' : '#cfd1d8',
                    }}
                  />
                ))}
              </div>
              <div
                style={{
                  flex: 1,
                  padding: '18px 22px',
                  display: 'flex',
                  flexDirection: 'column',
                  gap: 16,
                }}
              >
                {[280, 220, 310, 190].map((w, i) => (
                  <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                    <div
                      style={{ width: 30, height: 30, borderRadius: 7, background: '#dfe7fb' }}
                    />
                    <div style={{ height: 12, width: w, borderRadius: 6, background: '#d9dbe2' }} />
                  </div>
                ))}
                <div style={{ marginTop: 'auto', marginBottom: 6 }}>
                  <div style={{ fontSize: 13, color: '#6e6e73', marginBottom: 8 }}>
                    {t('正在上传', 'Uploading')} · {Math.round(upload * 100)}%
                  </div>
                  <div style={{ height: 8, borderRadius: 8, background: '#dcdee5' }}>
                    <div
                      style={{
                        height: 8,
                        borderRadius: 8,
                        width: `${upload * 100}%`,
                        background: '#2a74f0',
                      }}
                    />
                  </div>
                </div>
              </div>
            </div>
          </div>

          {/* 聚焦 */}
          <div
            style={{
              position: 'absolute',
              left: (DESK.w - 560) / 2,
              top: 150,
              width: 560,
              borderRadius: 22,
              background: 'rgba(32,33,38,0.94)',
              border: '1px solid rgba(255,255,255,0.2)',
              boxShadow: '0 30px 90px rgba(0,0,0,0.6)',
              opacity: spot,
              transform: `scale(${0.95 + spot * 0.05})`,
              overflow: 'hidden',
            }}
          >
            <div
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 14,
                padding: '18px 22px',
                fontSize: 26,
                color: C.ink,
              }}
            >
              <Glyph name="search" size={28} color={C.ink2} />
              <span>
                {typed}
                <span style={{ opacity: frame % 20 < 10 ? 0.9 : 0, color: C.accent }}>|</span>
              </span>
            </div>
            <div
              style={{
                borderTop: '1px solid rgba(255,255,255,0.1)',
                padding: result > 0 ? '10px 12px 12px' : 0,
                height: result * 76,
                opacity: result,
              }}
            >
              <div
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: 14,
                  padding: '8px 12px',
                  borderRadius: 12,
                  background: 'rgba(61,139,255,0.85)',
                  color: '#fff',
                  fontSize: 20,
                }}
              >
                <AppIcon kind="cloud" size={36} />
                <span style={{ fontWeight: 600 }}>{APP[lang]}</span>
                <span style={{ marginLeft: 'auto', fontSize: 15, opacity: 0.85 }}>
                  {t('在盒子里打开', 'Opens in its box')}
                </span>
              </div>
            </div>
          </div>

          {/* 程序坞 */}
          <div
            style={{
              position: 'absolute',
              left: dockLeft,
              bottom: 18,
              width: dockW,
              height: ICON + 26,
              borderRadius: 26,
              background: 'rgba(255,255,255,0.16)',
              border: '1px solid rgba(255,255,255,0.22)',
              display: 'flex',
              alignItems: 'center',
              gap: GAP,
              padding: '0 18px',
            }}
          >
            {DOCK.map((kind) => (
              <div
                key={kind}
                style={{
                  position: 'relative',
                  transform: kind === 'cloud' ? `translateY(${-bounce}px)` : undefined,
                }}
              >
                {kind === 'macbox' ? (
                  <MacBoxIcon size={ICON} />
                ) : (
                  <AppIcon kind={kind} size={ICON} />
                )}
                {kind === 'cloud' || kind === 'macbox' ? (
                  <div
                    style={{
                      position: 'absolute',
                      left: ICON / 2 - 3,
                      bottom: -10 + (kind === 'cloud' ? -bounce * -1 : 0),
                      width: 6,
                      height: 6,
                      borderRadius: 6,
                      background: 'rgba(255,255,255,0.85)',
                      opacity: kind === 'cloud' ? running : 1,
                    }}
                  />
                ) : null}
              </div>
            ))}
          </div>
        </div>
      </Stage>
    </AbsoluteFill>
  );
};
