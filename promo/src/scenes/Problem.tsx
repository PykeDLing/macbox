import { AbsoluteFill, spring, useCurrentFrame, useVideoConfig } from 'remotion';
import { C, FONT, MONO, tw, easeInOut } from '../theme';
import { APP, APP_ID, useLang, useT } from '../strings';
import { AppIcon, Glyph } from '../ui';

/** 装完之后散落在系统里的东西。位置是相对画面中心的偏移；下一个镜头从同样的位置把它们收进盒子 */
export const LEFTOVERS: readonly {
  x: number;
  y: number;
  zh: string;
  en: string;
  mono?: boolean;
}[] = [
  {
    x: -560,
    y: -150,
    zh: `LaunchAgents/${APP_ID}.helper.plist`,
    en: `LaunchAgents/${APP_ID}.helper.plist`,
    mono: true,
  },
  {
    x: 560,
    y: -160,
    zh: 'Application Support/CloudDrive/',
    en: 'Application Support/CloudDrive/',
    mono: true,
  },
  { x: -610, y: 0, zh: '登录项 · 开机自启', en: 'Login item · launches at login' },
  { x: 600, y: -10, zh: `Caches/${APP_ID}/`, en: `Caches/${APP_ID}/`, mono: true },
  {
    x: -540,
    y: 150,
    zh: `Preferences/${APP_ID}.plist`,
    en: `Preferences/${APP_ID}.plist`,
    mono: true,
  },
  { x: 560, y: 150, zh: '后台服务 × 3', en: 'Background services × 3' },
  { x: -260, y: 285, zh: '钥匙串条目', en: 'Keychain items' },
  { x: 290, y: 290, zh: 'Cookies/ · WebKit/', en: 'Cookies/ · WebKit/', mono: true },
];

export const CENTER = { x: 960, y: 610 };

export const LeftoverChip = ({
  item,
  x,
  y,
  opacity = 1,
  scale = 1,
  glow = 0,
}: {
  item: (typeof LEFTOVERS)[number];
  x: number;
  y: number;
  opacity?: number;
  scale?: number;
  glow?: number;
}) => {
  const lang = useLang();
  return (
    <div
      style={{
        position: 'absolute',
        left: CENTER.x + x,
        top: CENTER.y + y,
        transform: `translate(-50%, -50%) scale(${scale})`,
        opacity,
        display: 'flex',
        alignItems: 'center',
        gap: 14,
        padding: '15px 26px 15px 20px',
        borderRadius: 999,
        whiteSpace: 'nowrap',
        background: `rgba(255,90,82,${0.1 + glow * 0.08})`,
        border: `1.5px solid rgba(255,90,82,${0.38 + glow * 0.4})`,
        boxShadow: `0 0 ${24 + glow * 30}px rgba(255,90,82,${0.1 + glow * 0.22})`,
        color: '#ffd9d6',
        fontFamily: item.mono ? MONO : FONT,
        fontSize: item.mono ? 23 : 27,
        fontWeight: item.mono ? 400 : 500,
      }}
    >
      <span style={{ width: 11, height: 11, borderRadius: 11, background: C.red, flex: 'none' }} />
      {item[lang]}
    </div>
  );
};

export const Problem = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = useT();
  const lang = useLang();

  const iconIn = spring({ frame: frame - 8, fps, config: { damping: 14, stiffness: 120 } });
  // 第 150 帧起把 App 拖进废纸篓
  const toTrash = tw(frame, 150, 178, 0, 1, easeInOut);
  const headlineSwap = tw(frame, 160, 176);
  const pulse = frame > 176 ? (Math.sin((frame - 176) / 7) + 1) / 2 : 0;

  const headline = (lines: readonly [string, string, string], opacity: number, dy: number) => (
    <div
      style={{
        position: 'absolute',
        top: 118,
        left: 0,
        right: 0,
        textAlign: 'center',
        fontSize: lang === 'zh' ? 104 : 88,
        fontWeight: 700,
        letterSpacing: lang === 'zh' ? 2 : -2,
        color: C.ink,
        opacity,
        transform: `translateY(${dy}px)`,
      }}
    >
      {lines[0]}
      <span style={{ color: C.red }}>{lines[1]}</span>
      {lines[2]}
    </div>
  );

  return (
    <AbsoluteFill>
      {headline(
        t(
          ['装一个软件，留下', '一堆东西', '。'],
          ['Install one app. Get ', 'a pile of leftovers', '.'],
        ),
        tw(frame, 14, 34) * (1 - headlineSwap),
        (1 - tw(frame, 14, 34)) * 30 - headlineSwap * 24,
      )}
      {headline(
        t(['删掉 App，它们', '还在', '。'], ['Delete the app. They ', 'stay', '.']),
        headlineSwap,
        (1 - headlineSwap) * 24,
      )}

      {LEFTOVERS.map((item, i) => {
        const p = spring({
          frame: frame - 52 - i * 8,
          fps,
          config: { damping: 15, stiffness: 90 },
        });
        return (
          <LeftoverChip
            key={item.zh}
            item={item}
            x={item.x * p}
            y={item.y * p}
            opacity={Math.min(1, p * 1.6)}
            scale={0.5 + p * 0.5}
            glow={pulse}
          />
        );
      })}

      {/* App 原来待的位置，拖走以后留一个虚线框 */}
      <div
        style={{
          position: 'absolute',
          left: CENTER.x - 100,
          top: CENTER.y - 100,
          width: 200,
          height: 200,
          borderRadius: 48,
          border: `2px dashed rgba(255,255,255,${0.22 * toTrash})`,
        }}
      />
      <div
        style={{
          position: 'absolute',
          left: CENTER.x,
          top: CENTER.y,
          transform: `translate(-50%, -50%) translate(${toTrash * 0}px, ${toTrash * 330}px) scale(${iconIn * (1 - toTrash * 0.75)})`,
          opacity: 1 - tw(frame, 168, 180),
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          gap: 18,
        }}
      >
        <AppIcon kind="cloud" size={176} />
        <div style={{ fontSize: 30, color: C.ink, fontWeight: 500, whiteSpace: 'nowrap' }}>
          {APP[lang]}
        </div>
      </div>

      {/* 废纸篓 */}
      <div
        style={{
          position: 'absolute',
          left: CENTER.x,
          top: CENTER.y + 380,
          transform: `translate(-50%, -50%) scale(${0.8 + tw(frame, 140, 156) * 0.2 + tw(frame, 172, 180) * 0.12 - tw(frame, 180, 192) * 0.12})`,
          opacity: tw(frame, 140, 156) * (1 - tw(frame, 196, 212)),
          display: 'flex',
          alignItems: 'center',
          gap: 14,
          color: C.ink2,
          fontSize: 26,
        }}
      >
        <Glyph name="trash" size={52} color={C.ink2} stroke={1.6} />
        {t('移到废纸篓', 'Move to Trash')}
      </div>
    </AbsoluteFill>
  );
};
