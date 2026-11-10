import { AbsoluteFill, useCurrentFrame } from 'remotion';
import { C, MONO, tw } from '../theme';
import { APP, useLang, useT } from '../strings';
import { AppIcon, Blocked, ChapterCopy, Hi, Panel, Reveal, RIGHT, Stage } from '../ui';

const H = 650;

/** 一份运行报告：四个数字跳出来，被拦下的行为一条条列出 */
export const Report = () => {
  const frame = useCurrentFrame();
  const t = useT();
  const lang = useLang();

  const stats: readonly [number, string][] = [
    [128, t('写入文件', 'Files written')],
    [12, t('改动设置', 'Settings changed')],
    [9, t('连接服务器', 'Servers contacted')],
    [3, t('启动程序', 'Programs launched')],
  ];
  const blocked: readonly [string, string][] = [
    [t('注册开机自启动', 'Register a login item'), '~/Library/LaunchAgents'],
    [t('读取 SSH 密钥', 'Read SSH keys'), '~/.ssh'],
    [t('连接 ssh-agent', 'Connect to ssh-agent'), 'SSH_AUTH_SOCK'],
    [t('读取 Safari 数据', 'Read Safari data'), '~/Library/Safari'],
    [t('用 Apple 事件控制其他 App', 'Control other apps with Apple events'), ''],
  ];
  const shown = blocked.filter((_, i) => frame >= 92 + i * 13).length;

  return (
    <AbsoluteFill>
      <ChapterCopy
        index={3}
        tag={t('运行报告', 'RUN REPORT')}
        title={t(['看得见', '它做了什么。'], ['See what', 'it actually did.'])}
      >
        <Reveal at={28}>
          {t(
            <>
              写了哪些文件、改了哪些设置、
              <br />
              连了哪些服务器、<Hi color={C.red}>哪些行为被拦下</Hi>。
            </>,
            <>
              Files written, settings changed,
              <br />
              servers contacted, and <Hi color={C.red}>what was blocked</Hi>.
            </>,
          )}
        </Reveal>
        <Reveal at={44} style={{ marginTop: 18 }}>
          {t(
            '每次运行一份，可以存成 Markdown 或图片。',
            'One per run. Save it as Markdown or an image.',
          )}
        </Reveal>
      </ChapterCopy>

      <Stage height={H}>
        <Panel width={RIGHT.w} height={H} style={{ padding: '30px 36px' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 18 }}>
            <AppIcon kind="cloud" size={58} />
            <div>
              <div style={{ fontSize: 26, fontWeight: 700, color: C.ink }}>{APP[lang]}</div>
              <div style={{ fontSize: 19, color: C.ink3, marginTop: 3 }}>
                {t(
                  '运行报告 · 今天 14:32 · 运行了 12 分钟',
                  'Run report · Today 14:32 · Ran for 12 min',
                )}
              </div>
            </div>
            <div style={{ marginLeft: 'auto', display: 'flex', gap: 10 }}>
              {['Markdown', t('图片', 'Image')].map((label) => (
                <div
                  key={label}
                  style={{
                    padding: '8px 16px',
                    borderRadius: 10,
                    background: C.fill,
                    border: `1px solid ${C.line}`,
                    color: C.ink2,
                    fontSize: 16,
                  }}
                >
                  {label}
                </div>
              ))}
            </div>
          </div>

          <div
            style={{
              display: 'grid',
              gridTemplateColumns: 'repeat(4, 1fr)',
              gap: 14,
              marginTop: 26,
            }}
          >
            {stats.map(([value, label], i) => {
              const p = tw(frame, 30 + i * 6, 76 + i * 6);
              return (
                <div
                  key={label}
                  style={{
                    padding: '18px 20px',
                    borderRadius: 16,
                    background: C.fill,
                    border: `1px solid ${C.line}`,
                    opacity: tw(frame, 24 + i * 6, 38 + i * 6),
                  }}
                >
                  <div
                    style={{
                      fontSize: 50,
                      fontWeight: 700,
                      color: C.ink,
                      letterSpacing: -1,
                      fontVariantNumeric: 'tabular-nums',
                    }}
                  >
                    {Math.round(value * p)}
                  </div>
                  <div
                    style={{
                      fontSize: lang === 'zh' ? 19 : 16,
                      color: C.ink2,
                      marginTop: 2,
                      whiteSpace: 'nowrap',
                    }}
                  >
                    {label}
                  </div>
                </div>
              );
            })}
          </div>

          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 12,
              marginTop: 30,
              opacity: tw(frame, 80, 92),
            }}
          >
            <div style={{ fontSize: 22, fontWeight: 600, color: C.ink }}>
              {t('被拦下的行为', 'Blocked')}
            </div>
            <div
              style={{
                minWidth: 30,
                height: 30,
                padding: '0 9px',
                borderRadius: 30,
                background: 'rgba(255,90,82,0.18)',
                color: C.red,
                fontSize: 17,
                fontWeight: 700,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
              }}
            >
              {shown}
            </div>
          </div>

          <div style={{ marginTop: 12 }}>
            {blocked.map(([label, where], i) => {
              const p = tw(frame, 92 + i * 13, 106 + i * 13);
              return (
                <div
                  key={label}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 14,
                    height: 58,
                    borderTop: i === 0 ? 'none' : `1px solid ${C.line}`,
                    opacity: p,
                    transform: `translateX(${(1 - p) * 30}px)`,
                  }}
                >
                  <Blocked size={24} />
                  <span style={{ fontSize: 23, color: C.ink }}>{label}</span>
                  <span
                    style={{ marginLeft: 'auto', fontFamily: MONO, fontSize: 18, color: C.ink3 }}
                  >
                    {where}
                  </span>
                </div>
              );
            })}
          </div>
        </Panel>
      </Stage>
    </AbsoluteFill>
  );
};
