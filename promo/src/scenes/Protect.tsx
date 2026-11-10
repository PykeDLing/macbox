import { AbsoluteFill, useCurrentFrame } from 'remotion';
import { C, MONO, tw, easeInOut } from '../theme';
import { APP, useLang, useT } from '../strings';
import { AppIcon, ChapterCopy, Glyph, Hi, Panel, Reveal, RIGHT, Stage } from '../ui';

const H = 640;
const ROW = { x: 470, w: 414, h: 62, gap: 10, top: 34 };
const WALL_X = 408;
const BOX = { x: 40, y: 122, w: 268, h: 250 };

/** 盒子里的应用伸手去够私人数据，被沙盒这堵墙挡住；最后把联网也关掉 */
export const Protect = () => {
  const frame = useCurrentFrame();
  const t = useT();
  const lang = useLang();

  const items: readonly [
    'mail' | 'message' | 'compass' | 'key' | 'lock' | 'power',
    string,
    string,
  ][] = [
    ['mail', t('邮件', 'Mail'), t('读不到', 'Can’t read')],
    ['message', t('信息', 'Messages'), t('读不到', 'Can’t read')],
    ['compass', t('Safari 与 Cookie', 'Safari & cookies'), t('读不到', 'Can’t read')],
    ['key', t('SSH · GPG · AWS 密钥', 'SSH · GPG · AWS keys'), t('读不到', 'Can’t read')],
    ['lock', t('「登录」钥匙串', 'Login keychain'), t('不进去', 'Untouched')],
    ['power', t('开机自启、后台服务', 'Login items, daemons'), t('不能注册', 'Can’t register')],
  ];
  const rowY = (i: number) => ROW.top + i * (ROW.h + ROW.gap) + ROW.h / 2;
  const boxCY = BOX.y + BOX.h / 2;

  const off = tw(frame, 138, 152, 0, 1, easeInOut);

  return (
    <AbsoluteFill>
      <ChapterCopy
        index={4}
        tag={t('隔离', 'ISOLATION')}
        title={t(['碰不到', '你的私人数据。'], ['Your private data', 'stays out of reach.'])}
      >
        <Reveal at={28}>
          {t(
            <>
              邮件、信息、Safari、密钥和凭证，<Hi color={C.green}>读不到</Hi>。
            </>,
            <>
              Mail, Messages, Safari, keys and credentials: <Hi color={C.green}>unreadable</Hi>.
            </>,
          )}
        </Reveal>
        <Reveal at={40}>
          {t('也不能注册开机自启和后台服务。', 'No login items. No background services.')}
        </Reveal>
        <Reveal at={130} style={{ marginTop: 18 }}>
          {t(
            <>
              还可以<Hi>按应用断网</Hi>。
            </>,
            <>
              And you can <Hi>cut the network per app</Hi>.
            </>,
          )}
        </Reveal>
      </ChapterCopy>

      <Stage height={H}>
        <Panel width={RIGHT.w} height={H}>
          {/* 盒子 */}
          <div
            style={{
              position: 'absolute',
              left: BOX.x,
              top: BOX.y,
              width: BOX.w,
              height: BOX.h,
              borderRadius: 26,
              border: `2px dashed rgba(48,209,88,0.6)`,
              background: 'rgba(48,209,88,0.06)',
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              justifyContent: 'center',
              gap: 12,
            }}
          >
            <AppIcon kind="cloud" size={96} />
            <div style={{ fontSize: 23, fontWeight: 600, color: C.ink, whiteSpace: 'nowrap' }}>
              {APP[lang]}
            </div>
            <div
              style={{
                fontSize: 17,
                color: C.green,
                display: 'flex',
                alignItems: 'center',
                gap: 6,
              }}
            >
              <Glyph name="box" size={17} color={C.green} />
              {t('在盒子里运行', 'Running in its box')}
            </div>
          </div>

          {/* 沙盒这堵墙 */}
          <div
            style={{
              position: 'absolute',
              left: WALL_X - 2,
              top: 26,
              height: 436,
              width: 4,
              borderRadius: 4,
              background: `linear-gradient(180deg, transparent, ${C.accent} 12%, ${C.accent} 88%, transparent)`,
              boxShadow: `0 0 26px rgba(61,139,255,0.7)`,
              opacity: tw(frame, 10, 26),
            }}
          />
          <div
            style={{
              position: 'absolute',
              left: BOX.x,
              width: BOX.w,
              top: BOX.y + BOX.h + 20,
              textAlign: 'center',
              fontFamily: MONO,
              fontSize: 17,
              letterSpacing: 1,
              color: C.accent,
              opacity: tw(frame, 14, 30),
            }}
          >
            Seatbelt sandbox
          </div>

          {/* 伸出去的手 */}
          <svg width={RIGHT.w} height={H} style={{ position: 'absolute', left: 0, top: 0 }}>
            {items.map((_, i) => {
              const start = 26 + i * 13;
              const p = tw(frame, start, start + 14, 0, 1, easeInOut);
              const fade = 1 - tw(frame, start + 22, start + 40);
              const x0 = BOX.x + BOX.w;
              const y0 = boxCY + (i - 2.5) * 22;
              const x = x0 + (WALL_X - 8 - x0) * p;
              const y = y0 + (rowY(i) - y0) * p;
              const hit =
                tw(frame, start + 13, start + 17) * (1 - tw(frame, start + 30, start + 44));
              return (
                <g key={i}>
                  <path
                    d={`M ${x0} ${y0} L ${x} ${y}`}
                    stroke={C.red}
                    strokeWidth={2.5}
                    strokeDasharray="2 9"
                    strokeLinecap="round"
                    opacity={fade * 0.9}
                  />
                  <circle cx={x} cy={y} r={6} fill={C.red} opacity={fade * (p > 0 ? 1 : 0)} />
                  <g
                    opacity={hit}
                    transform={`translate(${WALL_X}, ${rowY(i)}) scale(${0.6 + hit * 0.4})`}
                  >
                    <circle r={17} fill={C.panel} stroke={C.red} strokeWidth={2.5} />
                    <path
                      d="M -6 -6 L 6 6 M 6 -6 L -6 6"
                      stroke={C.red}
                      strokeWidth={3}
                      strokeLinecap="round"
                    />
                  </g>
                </g>
              );
            })}
          </svg>

          {/* 墙外面：你的东西 */}
          {items.map(([glyph, label, status], i) => {
            const safe = tw(frame, 26 + i * 13 + 14, 26 + i * 13 + 24);
            return (
              <div
                key={label}
                style={{
                  position: 'absolute',
                  left: ROW.x,
                  top: ROW.top + i * (ROW.h + ROW.gap),
                  width: ROW.w,
                  height: ROW.h,
                  boxSizing: 'border-box',
                  borderRadius: 16,
                  background: C.fill,
                  border: `1px solid rgba(48,209,88,${0.1 + safe * 0.4})`,
                  display: 'flex',
                  alignItems: 'center',
                  gap: 14,
                  padding: '0 16px',
                  opacity: tw(frame, 8 + i * 3, 22 + i * 3),
                }}
              >
                <Glyph name={glyph} size={26} color={C.ink2} stroke={1.8} />
                <span
                  style={{ fontSize: lang === 'zh' ? 22 : 19, color: C.ink, whiteSpace: 'nowrap' }}
                >
                  {label}
                </span>
                <span
                  style={{
                    marginLeft: 'auto',
                    display: 'flex',
                    alignItems: 'center',
                    gap: 6,
                    fontSize: 17,
                    fontWeight: 600,
                    color: C.green,
                    opacity: safe,
                    whiteSpace: 'nowrap',
                  }}
                >
                  <Glyph name="lock" size={17} color={C.green} />
                  {status}
                </span>
              </div>
            );
          })}

          {/* 联网开关 */}
          <div
            style={{
              position: 'absolute',
              left: 40,
              right: 36,
              bottom: 34,
              height: 84,
              boxSizing: 'border-box',
              borderRadius: 18,
              background: C.fill,
              border: `1px solid ${C.line}`,
              display: 'flex',
              alignItems: 'center',
              gap: 16,
              padding: '0 24px',
              opacity: tw(frame, 116, 130),
              transform: `translateY(${(1 - tw(frame, 116, 130)) * 20}px)`,
            }}
          >
            <Glyph name="wifi" size={30} color={off > 0.5 ? C.ink3 : C.accent} />
            <div>
              <div style={{ fontSize: 22, fontWeight: 600, color: C.ink }}>
                {t('允许联网', 'Allow Network Access')}
              </div>
              <div style={{ fontSize: 17, color: C.ink3, marginTop: 2, opacity: off }}>
                {t(
                  '本机代理、域名解析也一起挡住',
                  'Local proxies and DNS lookups are blocked, too',
                )}
              </div>
            </div>
            <div
              style={{
                marginLeft: 'auto',
                width: 68,
                height: 40,
                borderRadius: 40,
                background: off > 0.5 ? 'rgba(255,255,255,0.18)' : C.green,
                position: 'relative',
                flex: 'none',
              }}
            >
              <div
                style={{
                  position: 'absolute',
                  top: 4,
                  left: 32 - off * 28,
                  width: 32,
                  height: 32,
                  borderRadius: 32,
                  background: '#fff',
                  boxShadow: '0 2px 6px rgba(0,0,0,0.35)',
                }}
              />
            </div>
          </div>
        </Panel>
      </Stage>
    </AbsoluteFill>
  );
};
