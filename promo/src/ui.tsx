import type { CSSProperties, ReactNode } from 'react';
import { AbsoluteFill, Img, staticFile, useCurrentFrame } from 'remotion';
import { C, FONT, MONO, tw } from './theme';
import { useLang } from './strings';

/** 第 at 帧起淡入并上移到位 */
export const Reveal = ({
  at,
  dur = 18,
  dy = 26,
  children,
  style,
}: {
  at: number;
  dur?: number;
  dy?: number;
  children: ReactNode;
  style?: CSSProperties;
}) => {
  const frame = useCurrentFrame();
  const p = tw(frame, at, at + dur);
  return (
    <div style={{ opacity: p, transform: `translateY(${(1 - p) * dy}px)`, ...style }}>
      {children}
    </div>
  );
};

/** 正文里强调的短语 */
export const Hi = ({ children, color = C.ink }: { children: ReactNode; color?: string }) => (
  <span style={{ color, fontWeight: 600 }}>{children}</span>
);

// ───────── 图形 ─────────

type GlyphName =
  | 'cloud'
  | 'download'
  | 'music'
  | 'video'
  | 'folder'
  | 'mail'
  | 'message'
  | 'compass'
  | 'key'
  | 'power'
  | 'lock'
  | 'search'
  | 'trash'
  | 'wifi'
  | 'plus'
  | 'box'
  | 'grid'
  | 'display'
  | 'gear'
  | 'play';

export const Glyph = ({
  name,
  size = 24,
  color = 'currentColor',
  stroke = 2,
}: {
  name: GlyphName;
  size?: number;
  color?: string;
  stroke?: number;
}) => {
  const s = {
    fill: 'none',
    stroke: color,
    strokeWidth: stroke,
    strokeLinecap: 'round' as const,
    strokeLinejoin: 'round' as const,
  };
  const paths: Record<GlyphName, ReactNode> = {
    cloud: (
      <path
        d="M7 18.5a4.5 4.5 0 0 1-.6-8.96A6 6 0 0 1 18 8.5a5 5 0 0 1-.5 10H7Z"
        fill={color}
        stroke="none"
      />
    ),
    download: <path d="M12 4v11m0 0-4.5-4.5M12 15l4.5-4.5M5 19.5h14" {...s} />,
    music: (
      <>
        <path d="M9.5 17.5V6.5l9-2v11" {...s} />
        <circle cx="7" cy="17.5" r="2.5" fill={color} />
        <circle cx="16" cy="15.5" r="2.5" fill={color} />
      </>
    ),
    video: (
      <>
        <rect x="3" y="7" width="12" height="10" rx="2.5" fill={color} />
        <path d="M15.5 11 21 8v8l-5.5-3Z" fill={color} />
      </>
    ),
    folder: (
      <path
        d="M3 7.5A1.5 1.5 0 0 1 4.5 6H9l2 2.2h8.5A1.5 1.5 0 0 1 21 9.7v7.8a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5v-10Z"
        {...s}
      />
    ),
    mail: (
      <>
        <rect x="3" y="5.5" width="18" height="13" rx="2.5" {...s} />
        <path d="m4 7.5 8 6 8-6" {...s} />
      </>
    ),
    message: (
      <path
        d="M12 4.5c-5 0-8.5 3-8.5 7 0 2.2 1.1 4.1 2.9 5.4L5.5 20l3.8-1.6c.9.2 1.8.3 2.7.3 5 0 8.5-3 8.5-7.2S17 4.5 12 4.5Z"
        {...s}
      />
    ),
    compass: (
      <>
        <circle cx="12" cy="12" r="8.5" {...s} />
        <path d="m15.5 8.5-2 5-5 2 2-5 5-2Z" fill={color} />
      </>
    ),
    key: (
      <>
        <circle cx="8" cy="12" r="3.5" {...s} />
        <path d="M11.5 12H21m-3 0v3m-3.5-3v2" {...s} />
      </>
    ),
    power: (
      <>
        <path d="M12 3.5v8" {...s} />
        <path d="M6.8 6.8a7.5 7.5 0 1 0 10.4 0" {...s} />
      </>
    ),
    lock: (
      <>
        <rect x="5" y="10.5" width="14" height="10" rx="2.5" fill={color} />
        <path d="M8 10.5V8a4 4 0 0 1 8 0v2.5" {...s} />
      </>
    ),
    search: (
      <>
        <circle cx="10.5" cy="10.5" r="6" {...s} />
        <path d="m15 15 5 5" {...s} />
      </>
    ),
    trash: (
      <>
        <path d="M4 6.5h16M9.5 6.5V4.5h5v2M6.5 6.5l1 13h9l1-13" {...s} />
        <path d="M10 10.5v5.5m4-5.5v5.5" {...s} />
      </>
    ),
    wifi: (
      <>
        <path
          d="M3 9.5a13 13 0 0 1 18 0M6.5 13a8 8 0 0 1 11 0M9.8 16.3a3.5 3.5 0 0 1 4.4 0"
          {...s}
        />
        <circle cx="12" cy="19" r="1.2" fill={color} />
      </>
    ),
    plus: <path d="M12 5v14M5 12h14" {...s} />,
    box: (
      <>
        <path d="M3.5 8 12 3.5 20.5 8v8L12 20.5 3.5 16V8Z" {...s} />
        <path d="M3.5 8 12 12.5 20.5 8M12 12.5v8" {...s} />
      </>
    ),
    grid: (
      <>
        <rect x="4" y="4" width="6.5" height="6.5" rx="1.5" fill={color} />
        <rect x="13.5" y="4" width="6.5" height="6.5" rx="1.5" fill={color} />
        <rect x="4" y="13.5" width="6.5" height="6.5" rx="1.5" fill={color} />
        <rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.5" fill={color} />
      </>
    ),
    display: (
      <>
        <rect x="3" y="4.5" width="18" height="12" rx="2" {...s} />
        <path d="M8.5 20h7M12 16.5V20" {...s} />
      </>
    ),
    gear: (
      <>
        <circle cx="12" cy="12" r="3" {...s} />
        <path
          d="M12 3v2.5M12 18.5V21M3 12h2.5M18.5 12H21M5.6 5.6l1.8 1.8M16.6 16.6l1.8 1.8M5.6 18.4l1.8-1.8M16.6 7.4l1.8-1.8"
          {...s}
        />
      </>
    ),
    play: <path d="M8 5.5v13l11-6.5-11-6.5Z" fill={color} />,
  };
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" style={{ display: 'block', flex: 'none' }}>
      {paths[name]}
    </svg>
  );
};

const APP_TINTS = {
  cloud: ['#62b6ff', '#2a74f0'],
  download: ['#ffb14a', '#f0761c'],
  music: ['#ff7a8c', '#e8324f'],
  video: ['#6fdc7f', '#27a744'],
  folder: ['#9aa3b2', '#5d6675'],
  compass: ['#7cc7ff', '#3a86e8'],
  mail: ['#7fb2ff', '#3f6fe0'],
} as const;
export type AppKind = keyof typeof APP_TINTS;

/** 泛指的 App 图标：渐变圆角方块加一个白色图形 */
export const AppIcon = ({ kind, size = 72 }: { kind: AppKind; size?: number }) => {
  const [a, b] = APP_TINTS[kind];
  return (
    <div
      style={{
        width: size,
        height: size,
        borderRadius: size * 0.235,
        background: `linear-gradient(180deg, ${a}, ${b})`,
        boxShadow: `inset 0 ${size * 0.02}px 0 rgba(255,255,255,0.35), 0 ${size * 0.08}px ${size * 0.25}px rgba(0,0,0,0.35)`,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        flex: 'none',
      }}
    >
      <Glyph name={kind} size={size * 0.58} color="#fff" stroke={2.2} />
    </div>
  );
};

export const MacBoxIcon = ({ size = 72, style }: { size?: number; style?: CSSProperties }) => (
  <Img
    src={staticFile('icon.png')}
    style={{ width: size, height: size, display: 'block', ...style }}
  />
);

export const Check = ({ size = 28, color = C.green }: { size?: number; color?: string }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" style={{ display: 'block', flex: 'none' }}>
    <circle cx="12" cy="12" r="11" fill={color} />
    <path
      d="m7 12.5 3.3 3.3L17 9"
      fill="none"
      stroke="#fff"
      strokeWidth="2.4"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  </svg>
);

export const Blocked = ({ size = 28, color = C.red }: { size?: number; color?: string }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" style={{ display: 'block', flex: 'none' }}>
    <circle cx="12" cy="12" r="9.5" fill="none" stroke={color} strokeWidth="2.4" />
    <path d="m5.5 5.5 13 13" stroke={color} strokeWidth="2.4" strokeLinecap="round" />
  </svg>
);

export const Cursor = ({ x, y, pressed = 0 }: { x: number; y: number; pressed?: number }) => (
  <svg
    width={44}
    height={44}
    viewBox="0 0 24 24"
    style={{
      position: 'absolute',
      left: x,
      top: y,
      transform: `scale(${1 - pressed * 0.14})`,
      transformOrigin: '4px 3px',
      filter: 'drop-shadow(0 3px 6px rgba(0,0,0,0.5))',
    }}
  >
    <path
      d="M4 3v15.5l4.3-3.7 2.9 6.2 2.7-1.2-2.9-6.2H17L4 3Z"
      fill="#fff"
      stroke="#111"
      strokeWidth="1.2"
      strokeLinejoin="round"
    />
  </svg>
);

// ───────── 窗口、面板 ─────────

export const TrafficLights = ({ size = 14 }: { size?: number }) => (
  <div style={{ display: 'flex', gap: size * 0.6 }}>
    {['#ff5f57', '#febc2e', '#28c840'].map((color) => (
      <div
        key={color}
        style={{ width: size, height: size, borderRadius: size, background: color }}
      />
    ))}
  </div>
);

export const Panel = ({
  width,
  height,
  children,
  style,
}: {
  width: number;
  height: number;
  children?: ReactNode;
  style?: CSSProperties;
}) => (
  <div
    style={{
      position: 'relative',
      boxSizing: 'border-box',
      width,
      height,
      borderRadius: 26,
      background: C.panel,
      border: `1px solid ${C.lineStrong}`,
      boxShadow: '0 60px 140px rgba(0,0,0,0.65), 0 2px 8px rgba(0,0,0,0.5)',
      overflow: 'hidden',
      ...style,
    }}
  >
    {children}
  </div>
);

// ───────── 章节镜头的版式：左边文字，右边画面 ─────────

export const LEFT = { x: 120, w: 700 };
export const RIGHT = { x: 880, w: 920 };

export const ChapterCopy = ({
  index,
  tag,
  title,
  children,
}: {
  index: number;
  tag: string;
  title: readonly string[];
  children?: ReactNode;
}) => {
  const lang = useLang();
  return (
    <div
      style={{
        position: 'absolute',
        left: LEFT.x,
        width: LEFT.w,
        top: 0,
        bottom: 0,
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'center',
      }}
    >
      <Reveal at={4}>
        <div
          style={{
            fontFamily: MONO,
            fontSize: 26,
            letterSpacing: 3,
            color: C.accent,
            display: 'flex',
            alignItems: 'center',
            gap: 16,
          }}
        >
          <span>{String(index).padStart(2, '0')}</span>
          <span style={{ width: 44, height: 2, background: C.accent, opacity: 0.6 }} />
          <span style={{ fontFamily: FONT, letterSpacing: lang === 'zh' ? 6 : 2, fontWeight: 600 }}>
            {tag}
          </span>
        </div>
      </Reveal>
      <div
        style={{
          marginTop: 30,
          fontSize: lang === 'zh' ? 92 : 68,
          lineHeight: 1.14,
          fontWeight: 700,
          letterSpacing: lang === 'zh' ? 0 : -1.5,
          color: C.ink,
        }}
      >
        {title.map((line, i) => (
          <Reveal key={line} at={10 + i * 7}>
            <div style={{ whiteSpace: 'nowrap' }}>{line}</div>
          </Reveal>
        ))}
      </div>
      <div
        style={{
          marginTop: 40,
          fontSize: lang === 'zh' ? 34 : 30,
          lineHeight: 1.55,
          color: C.ink2,
        }}
      >
        {children}
      </div>
    </div>
  );
};

/** 右边画面的定位：垂直居中，进场时轻微放大到位 */
export const Stage = ({ height, children }: { height: number; children: ReactNode }) => {
  const frame = useCurrentFrame();
  const p = tw(frame, 6, 30);
  return (
    <div
      style={{
        position: 'absolute',
        left: RIGHT.x,
        top: (1080 - height) / 2,
        width: RIGHT.w,
        height,
        opacity: p,
        transform: `translateY(${(1 - p) * 40}px) scale(${0.96 + p * 0.04})`,
      }}
    >
      {children}
    </div>
  );
};

/** 贯穿全片的背景：深色底、细网格、缓慢移动的两团光 */
export const Backdrop = () => {
  const frame = useCurrentFrame();
  const drift = frame / 30;
  return (
    <AbsoluteFill style={{ background: C.bg }}>
      <AbsoluteFill
        style={{
          background: `radial-gradient(900px 620px at ${22 + Math.sin(drift * 0.21) * 6}% ${18 + Math.cos(drift * 0.17) * 5}%, rgba(61,139,255,0.16), transparent 70%), radial-gradient(1000px 700px at ${82 + Math.cos(drift * 0.19) * 5}% ${88 + Math.sin(drift * 0.23) * 5}%, rgba(120,130,150,0.13), transparent 70%)`,
        }}
      />
      <AbsoluteFill
        style={{
          backgroundImage:
            'linear-gradient(rgba(255,255,255,0.035) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.035) 1px, transparent 1px)',
          backgroundSize: '80px 80px',
          maskImage: 'radial-gradient(ellipse 75% 70% at 50% 50%, #000 30%, transparent 100%)',
          WebkitMaskImage:
            'radial-gradient(ellipse 75% 70% at 50% 50%, #000 30%, transparent 100%)',
        }}
      />
    </AbsoluteFill>
  );
};
