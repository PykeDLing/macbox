import type { ReactNode } from 'react';
import { AbsoluteFill, spring, useCurrentFrame, useVideoConfig } from 'remotion';
import { C, MONO, tw, easeInOut } from '../theme';
import { APP, useLang, useT } from '../strings';
import {
  AppIcon,
  type AppKind,
  ChapterCopy,
  Check,
  Cursor,
  Glyph,
  Hi,
  Panel,
  Reveal,
  RIGHT,
  Stage,
  TrafficLights,
} from '../ui';

const WIN = {
  w: RIGHT.w,
  h: 620,
  side: 214,
  pad: 28,
  tileW: 204,
  tileH: 178,
  gap: 18,
  gridTop: 116,
};
const slot = (i: number) => ({
  x: WIN.side + WIN.pad + (i % 3) * (WIN.tileW + WIN.gap),
  y: WIN.gridTop + Math.floor(i / 3) * (WIN.tileH + WIN.gap),
});

const SideItem = ({
  glyph,
  label,
  active,
}: {
  glyph: 'grid' | 'play' | 'display' | 'gear';
  label: string;
  active?: boolean;
}) => (
  <div
    style={{
      display: 'flex',
      alignItems: 'center',
      gap: 10,
      padding: '8px 10px',
      borderRadius: 9,
      background: active ? 'rgba(61,139,255,0.22)' : 'transparent',
      color: active ? C.ink : C.ink2,
      fontSize: 19,
    }}
  >
    <Glyph name={glyph} size={20} color={C.accent} />
    {label}
  </div>
);

/** MacBox 主窗口的外壳：侧边栏加内容区 */
export const AppWindow = ({
  title,
  subtitle,
  children,
}: {
  title: string;
  subtitle: string;
  children?: ReactNode;
}) => {
  const t = useT();
  const group = (label: string) => (
    <div style={{ fontSize: 15, color: C.ink3, margin: '18px 10px 6px' }}>{label}</div>
  );
  return (
    <Panel width={WIN.w} height={WIN.h}>
      <div
        style={{
          position: 'absolute',
          left: 0,
          top: 0,
          bottom: 0,
          width: WIN.side,
          background: 'rgba(255,255,255,0.035)',
          borderRight: `1px solid ${C.line}`,
          padding: '20px 12px',
        }}
      >
        <div style={{ padding: '2px 8px 16px' }}>
          <TrafficLights />
        </div>
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 8,
            padding: '8px 10px',
            borderRadius: 9,
            background: C.fill,
            color: C.ink3,
            fontSize: 17,
          }}
        >
          <Glyph name="search" size={18} color={C.ink3} />
          {t('搜索应用', 'Search')}
        </div>
        {group(t('应用', 'Apps'))}
        <SideItem glyph="grid" label={t('全部应用', 'All Apps')} active />
        <SideItem glyph="play" label={t('运行中', 'Running')} />
        {group(t('运行环境', 'Runtimes'))}
        <SideItem glyph="display" label={t('虚拟 Mac', 'Virtual Mac')} />
        {group('MacBox')}
        <SideItem glyph="gear" label={t('设置', 'Settings')} />
      </div>
      <div style={{ position: 'absolute', left: WIN.side + WIN.pad, top: 26 }}>
        <div style={{ fontSize: 27, fontWeight: 700, color: C.ink }}>{title}</div>
        <div style={{ fontSize: 17, color: C.ink3, marginTop: 4 }}>{subtitle}</div>
      </div>
      {children}
    </Panel>
  );
};

const Tile = ({
  kind,
  name,
  badge,
  selected,
}: {
  kind: AppKind;
  name: string;
  badge: string;
  selected?: boolean;
}) => (
  <div
    style={{
      width: WIN.tileW,
      height: WIN.tileH,
      borderRadius: 18,
      background: 'rgba(255,255,255,0.045)',
      border: selected ? `2.5px solid ${C.accent}` : `1px solid ${C.line}`,
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      justifyContent: 'center',
      gap: 8,
    }}
  >
    <AppIcon kind={kind} size={66} />
    <div style={{ fontSize: 21, fontWeight: 600, color: C.ink, whiteSpace: 'nowrap' }}>{name}</div>
    <div style={{ fontSize: 16, color: C.ink3, display: 'flex', alignItems: 'center', gap: 6 }}>
      <Glyph name="box" size={16} color={C.ink3} />
      {badge}
    </div>
  </div>
);

export const Add = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = useT();
  const lang = useLang();

  // 安装包从窗口右上方拖到第三格
  const target = slot(2);
  const drag = tw(frame, 30, 76, 0, 1, easeInOut);
  const fileX = 760 + (target.x + 30 - 760) * drag;
  const fileY = -150 + (target.y + 6 + 150) * drag;
  const dropped = tw(frame, 78, 90);
  const hover = tw(frame, 56, 70) * (1 - tw(frame, 84, 96));

  const sheet = tw(frame, 86, 98) * (1 - tw(frame, 150, 162));
  const steps: readonly [string, number][] = [
    [t('取出里面的 App', 'Extract the app inside'), 104],
    [t('检查驱动、系统扩展、苹果沙盒', 'Check drivers, extensions, App Sandbox'), 120],
    [t('pkg 的安装脚本：不执行', 'pkg install scripts: never run'), 136],
  ];

  const tileIn = spring({ frame: frame - 158, fps, config: { damping: 14, stiffness: 130 } });
  const addMove = tw(frame, 150, 168, 0, 1, easeInOut);
  const addFrom = slot(2);
  const addTo = slot(3);
  const body = lang === 'zh' ? 34 : 30;

  return (
    <AbsoluteFill>
      <ChapterCopy
        index={1}
        tag={t('添加', 'ADD')}
        title={t(['拖进来，', '就装好了。'], ['Drop it in.', 'It’s installed.'])}
      >
        <Reveal at={28}>
          <div style={{ fontFamily: MONO, fontSize: body - 4, color: C.ink, letterSpacing: 1 }}>
            .dmg&nbsp;&nbsp;.app&nbsp;&nbsp;.pkg&nbsp;&nbsp;.zip
          </div>
        </Reveal>
        <Reveal at={40} style={{ marginTop: 18 }}>
          {t(
            <>
              只有几 MB 的在线安装器也能接手。
              <br />
              pkg 里的安装脚本<Hi>不会执行</Hi>。
            </>,
            <>
              Even tiny online installers work.
              <br />
              Install scripts in a pkg <Hi>never run</Hi>.
            </>,
          )}
        </Reveal>
      </ChapterCopy>

      <Stage height={WIN.h}>
        <AppWindow
          title={t('全部应用', 'All Apps')}
          subtitle={frame < 158 ? t('2 个应用', '2 apps') : t('3 个应用', '3 apps')}
        >
          {/* 拖到窗口上方时的高亮 */}
          <div
            style={{
              position: 'absolute',
              left: WIN.side + 12,
              top: 12,
              right: 12,
              bottom: 12,
              borderRadius: 18,
              border: `3px solid rgba(61,139,255,${hover * 0.9})`,
              background: `rgba(61,139,255,${hover * 0.07})`,
            }}
          />
          <div style={{ position: 'absolute', left: slot(0).x, top: slot(0).y }}>
            <Tile
              kind="download"
              name={t('下载工具', 'Downloader')}
              badge={t('本机隔离', 'Native Isolation')}
            />
          </div>
          <div style={{ position: 'absolute', left: slot(1).x, top: slot(1).y }}>
            <Tile
              kind="music"
              name={t('音乐播放器', 'Music Player')}
              badge={t('本机隔离', 'Native Isolation')}
            />
          </div>

          {/* “添加应用”格，新应用进来后挪到下一格 */}
          <div
            style={{
              position: 'absolute',
              left: addFrom.x + (addTo.x - addFrom.x) * addMove,
              top: addFrom.y + (addTo.y - addFrom.y) * addMove,
              width: WIN.tileW,
              height: WIN.tileH,
              borderRadius: 18,
              border: `1.5px dashed ${C.lineStrong}`,
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              justifyContent: 'center',
              gap: 12,
              color: C.ink2,
              fontSize: 20,
            }}
          >
            <div
              style={{
                width: 46,
                height: 46,
                borderRadius: 46,
                background: 'rgba(61,139,255,0.2)',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
              }}
            >
              <Glyph name="plus" size={24} color={C.accent} />
            </div>
            {t('添加应用', 'Add App')}
          </div>

          <div
            style={{
              position: 'absolute',
              left: target.x,
              top: target.y,
              opacity: Math.min(1, tileIn * 1.5),
              transform: `scale(${0.7 + tileIn * 0.3})`,
            }}
          >
            <Tile
              kind="cloud"
              name={APP[lang]}
              badge={t('本机隔离', 'Native Isolation')}
              selected
            />
          </div>

          {/* 添加过程 */}
          <div
            style={{
              position: 'absolute',
              left: WIN.side + (WIN.w - WIN.side - 560) / 2,
              top: 150,
              width: 560,
              borderRadius: 20,
              padding: '26px 30px 28px',
              background: '#26272c',
              border: `1px solid ${C.lineStrong}`,
              boxShadow: '0 30px 80px rgba(0,0,0,0.6)',
              opacity: sheet,
              transform: `scale(${0.94 + sheet * 0.06})`,
            }}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
              <AppIcon kind="cloud" size={46} />
              <div style={{ fontSize: 24, fontWeight: 600, color: C.ink }}>
                {t(`正在添加「${APP.zh}」`, `Adding “${APP.en}”`)}
              </div>
            </div>
            <div style={{ marginTop: 20, display: 'flex', flexDirection: 'column', gap: 14 }}>
              {steps.map(([label, at]) => {
                const done = tw(frame, at, at + 8);
                return (
                  <div
                    key={label}
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      gap: 12,
                      fontSize: 21,
                      color: done > 0.5 ? C.ink : C.ink3,
                    }}
                  >
                    <div style={{ width: 24, height: 24, position: 'relative' }}>
                      <div
                        style={{
                          position: 'absolute',
                          inset: 0,
                          borderRadius: 24,
                          border: `2px solid ${C.lineStrong}`,
                          opacity: 1 - done,
                        }}
                      />
                      <div
                        style={{
                          position: 'absolute',
                          inset: 0,
                          opacity: done,
                          transform: `scale(${0.5 + done * 0.5})`,
                        }}
                      >
                        <Check size={24} />
                      </div>
                    </div>
                    {label}
                  </div>
                );
              })}
            </div>
          </div>
        </AppWindow>

        {/* 被拖动的安装包和指针（画在窗口外层，才能从窗口外面进来） */}
        <div
          style={{
            position: 'absolute',
            left: fileX,
            top: fileY,
            opacity: tw(frame, 24, 34) * (1 - dropped),
            transform: `scale(${1 - dropped * 0.5}) rotate(${(1 - drag) * -6}deg)`,
          }}
        >
          <div
            style={{
              width: 144,
              padding: '16px 0 14px',
              borderRadius: 18,
              background: 'rgba(40,42,48,0.96)',
              border: `1px solid ${C.lineStrong}`,
              boxShadow: '0 24px 50px rgba(0,0,0,0.55)',
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              gap: 10,
            }}
          >
            <div
              style={{
                width: 84,
                height: 84,
                borderRadius: 16,
                background: 'linear-gradient(180deg, #f1f2f5, #c9ccd4)',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                boxShadow: 'inset 0 -6px 0 rgba(0,0,0,0.12)',
              }}
            >
              <AppIcon kind="cloud" size={44} />
            </div>
            <div style={{ fontSize: 15, color: C.ink, fontFamily: MONO }}>
              {t('网盘', 'Drive')}.dmg
            </div>
          </div>
        </div>
        {/* 松手以后指针让开，不挡着新出现的那一格 */}
        <div style={{ opacity: tw(frame, 18, 28) * (1 - tw(frame, 98, 112)) }}>
          <Cursor
            x={fileX + 96 + tw(frame, 84, 110, 0, 150, easeInOut)}
            y={fileY + 92 + tw(frame, 84, 110, 0, 190, easeInOut)}
            pressed={tw(frame, 26, 32) * (1 - tw(frame, 78, 84))}
          />
        </div>
      </Stage>
    </AbsoluteFill>
  );
};
