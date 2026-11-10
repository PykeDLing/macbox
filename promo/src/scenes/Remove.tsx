import { AbsoluteFill, useCurrentFrame } from 'remotion';
import { C, MONO, tw, easeInOut } from '../theme';
import { APP, useLang, useT } from '../strings';
import { AppIcon, ChapterCopy, Check, Cursor, Glyph, Hi, Panel, Reveal, RIGHT, Stage } from '../ui';

const H = 640;
const CARD = { w: 560, h: 500 };

/** 盒子里有什么 → 点「删除应用」→ 整个盒子进废纸篓 → 系统里什么也没多 */
export const Remove = () => {
  const frame = useCurrentFrame();
  const t = useT();
  const lang = useLang();

  const inside: readonly [string, string][] = [
    ['App/', t('应用本身', 'The app itself')],
    ['Home/', t('文件、缓存、Cookie', 'Files, caches, cookies')],
    ['Prefs/', t('偏好设置', 'Preferences')],
    [t('钥匙串', 'Keychain'), t('凭证、设备 ID', 'Credentials, device IDs')],
    [t('还原点', 'Restore points'), t('APFS 克隆快照', 'APFS clone snapshots')],
  ];
  const clean: readonly [string, string][] = [
    [t('登录项、后台服务', 'Login items, daemons'), t('没有新增', 'None added')],
    ['Application Support', t('没有新增', 'None added')],
    [t('偏好设置', 'Preferences'), t('已原样换回', 'Restored as they were')],
    [t('「登录」钥匙串', 'Login keychain'), t('没有新增', 'None added')],
  ];

  const cursorP = tw(frame, 34, 60, 0, 1, easeInOut);
  const click = tw(frame, 62, 66) * (1 - tw(frame, 68, 74));
  const toss = tw(frame, 76, 108, 0, 1, easeInOut);
  const cardLeft = (RIGHT.w - CARD.w) / 2;
  const cardTop = (H - CARD.h) / 2;
  const trashWobble =
    frame > 104 && frame < 124 ? Math.sin((frame - 104) / 2.2) * (1 - (frame - 104) / 20) * 8 : 0;
  const after = tw(frame, 112, 128);

  return (
    <AbsoluteFill>
      <ChapterCopy
        index={5}
        tag={t('删除', 'DELETE')}
        title={t(['删掉盒子，', '一起带走。'], ['Delete the box.', 'It all goes along.'])}
      >
        <Reveal at={28}>
          {t(
            <>
              文件、偏好设置、钥匙串条目都在盒子里，
              <br />
              删除时<Hi>一起移到废纸篓</Hi>。
            </>,
            <>
              Files, preferences and keychain items live in the box, and{' '}
              <Hi>go to the Trash with it</Hi>.
            </>,
          )}
        </Reveal>
        <Reveal at={120} style={{ marginTop: 22 }}>
          <div style={{ fontSize: lang === 'zh' ? 25 : 23, color: C.ink3 }}>
            {t(
              '存进「下载」和你允许写入的文件夹的文件会留下。',
              'Files saved to Downloads and folders you allowed are kept.',
            )}
          </div>
        </Reveal>
      </ChapterCopy>

      <Stage height={H}>
        <Panel width={RIGHT.w} height={H}>
          {/* 删除之后：系统里什么也没多 */}
          <div
            style={{
              position: 'absolute',
              left: 70,
              right: 70,
              top: 56,
              opacity: after,
              transform: `translateY(${(1 - after) * 24}px)`,
            }}
          >
            <div style={{ fontSize: 38, fontWeight: 700, color: C.ink }}>
              {t('你的 Mac', 'Your Mac')}
            </div>
            <div style={{ fontSize: 21, color: C.ink3, marginTop: 6, fontFamily: MONO }}>
              ~/Library
            </div>
            <div style={{ marginTop: 26 }}>
              {clean.map(([label, status], i) => {
                const p = tw(frame, 124 + i * 10, 138 + i * 10);
                return (
                  <div
                    key={label}
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      gap: 16,
                      height: 96,
                      borderTop: `1px solid ${C.line}`,
                      opacity: p,
                    }}
                  >
                    <div style={{ transform: `scale(${0.4 + p * 0.6})` }}>
                      <Check size={38} />
                    </div>
                    <span style={{ fontSize: 29, color: C.ink }}>{label}</span>
                    <span
                      style={{ marginLeft: 'auto', fontSize: 24, color: C.green, fontWeight: 600 }}
                    >
                      {status}
                    </span>
                  </div>
                );
              })}
            </div>
          </div>

          {/* 废纸篓 */}
          <div
            style={{
              position: 'absolute',
              right: 44,
              bottom: 36,
              opacity: tw(frame, 56, 70) * (1 - tw(frame, 126, 140)),
              transform: `rotate(${trashWobble}deg) scale(${1 + tw(frame, 96, 106) * 0.15 - tw(frame, 106, 116) * 0.15})`,
            }}
          >
            <Glyph name="trash" size={84} color={C.ink2} stroke={1.4} />
          </div>

          {/* 盒子里有什么 */}
          <div
            style={{
              position: 'absolute',
              left: cardLeft + toss * 250,
              top: cardTop + toss * 250,
              width: CARD.w,
              height: CARD.h,
              boxSizing: 'border-box',
              borderRadius: 26,
              padding: '26px 30px',
              background: 'rgba(48,209,88,0.06)',
              border: '2px dashed rgba(48,209,88,0.6)',
              opacity: 1 - tw(frame, 96, 108),
              transform: `scale(${1 - toss * 0.86}) rotate(${toss * 8}deg)`,
            }}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
              <AppIcon kind="cloud" size={60} />
              <div>
                <div style={{ fontSize: 27, fontWeight: 700, color: C.ink }}>{APP[lang]}</div>
                <div
                  style={{
                    fontSize: 18,
                    color: C.green,
                    marginTop: 3,
                    display: 'flex',
                    alignItems: 'center',
                    gap: 6,
                  }}
                >
                  <Glyph name="box" size={16} color={C.green} />
                  {t('这个盒子里有', 'In this box')}
                </div>
              </div>
            </div>
            <div style={{ marginTop: 16 }}>
              {inside.map(([name, what], i) => (
                <div
                  key={name}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    height: 52,
                    borderTop: `1px solid ${C.line}`,
                    opacity: tw(frame, 12 + i * 5, 26 + i * 5),
                  }}
                >
                  <span
                    style={{
                      fontFamily: MONO,
                      fontSize: 21,
                      color: C.ink,
                      width: lang === 'zh' ? 140 : 200,
                    }}
                  >
                    {name}
                  </span>
                  <span style={{ fontSize: 21, color: C.ink2 }}>{what}</span>
                </div>
              ))}
            </div>
            <div
              style={{
                marginTop: 16,
                height: 52,
                borderRadius: 13,
                background: `rgba(255,90,82,${0.16 + click * 0.3})`,
                border: `1px solid rgba(255,90,82,0.5)`,
                color: C.red,
                fontSize: 21,
                fontWeight: 600,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                transform: `scale(${1 - click * 0.03})`,
              }}
            >
              {t('删除应用…', 'Delete App…')}
            </div>
          </div>

          <div style={{ opacity: tw(frame, 30, 38) * (1 - tw(frame, 76, 86)) }}>
            <Cursor
              x={760 + (cardLeft + CARD.w / 2 + 40 - 760) * cursorP}
              y={120 + (cardTop + CARD.h - 62 - 120) * cursorP}
              pressed={click}
            />
          </div>
        </Panel>
      </Stage>
    </AbsoluteFill>
  );
};
