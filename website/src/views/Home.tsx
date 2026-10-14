import { useEffect, useLayoutEffect, useRef, type ReactNode } from 'react';
import { useNavigate } from '@tanstack/react-router';
import { DemoWindow } from '../demo/DemoWindow';
import { Icon } from '../components/Icon';
import { icons } from '../components/icons';
import { SiteNav } from '../components/SiteNav';
import { Terminal } from '../components/Terminal';
import { homePath, translate, type Locale } from '../lib/i18n';
import { rememberLanguage } from '../lib/language';
import { describeDmg, useLatestRelease } from '../lib/release';
import {
  href,
  isolationDetails,
  issuesPage,
  latestReleasePage,
  licensePage,
  releasesPage,
  repository,
} from '../lib/site';

/** 中文全角标点的字形只占左半边。确定落在行尾的标点收掉右边的空白，居中的文字才不会看着偏左 */
const Pe = ({ children }: { children: string }) => <span className="pe">{children}</span>;
/** 中文导语每句话各占一行（宽屏时），窄了再在标点处折行 */
const Ln = ({ children }: { children: ReactNode }) => <span className="ln">{children}</span>;

const problems: readonly (readonly [string, string, string, string, string])[] = [
  [
    icons.launchAtLogin,
    '开机自启',
    'Launch at login',
    '没打开它，它也在跑。登录项、助手程序，一个接一个。',
    'Running even when you never opened it. Login items and helpers pile up.',
  ],
  [
    icons.backgroundServices,
    '后台服务',
    'Background services',
    '悄悄注册的常驻进程，卸载 App 时往往不会一起删掉。',
    'Quietly registered daemons that usually survive deleting the app.',
  ],
  [
    icons.scatteredFiles,
    '散落各处的文件',
    'Files everywhere',
    '缓存、设置、钥匙串条目，分散在资源库的各个角落。',
    'Caches, preferences and keychain items scattered all over your Library.',
  ],
];

const features: readonly {
  icon: string;
  tint: string;
  wide?: boolean;
  title: readonly [string, string];
  text: readonly [string, string];
}[] = [
  {
    icon: icons.house,
    tint: 'g1',
    title: ['独立的主目录', 'Its own home folder'],
    text: [
      'App 看到的“主目录”在盒子里，Application Support、缓存、Cookie 都落在这里。',
      'The app’s home folder lives in the box, so Application Support, caches and cookies land there.',
    ],
  },
  {
    icon: icons.key,
    tint: 'g3',
    title: ['独立的钥匙串', 'Its own keychain'],
    text: [
      '每个盒子一个钥匙串，凭证和设备 ID 不会进你的「登录」钥匙串。',
      'Each box has a separate keychain. Credentials and device IDs never reach your login keychain.',
    ],
  },
  {
    icon: icons.swap,
    tint: 'g4',
    wide: true,
    title: ['偏好设置借出再收回', 'Preferences, lent and returned'],
    text: [
      '系统代写的设置沙盒挡不住，所以 MacBox 在启动前把盒子的设置整体借给系统，退出后完整收回，再把你本机原来的设置原样换回。全程先写日志，就算 MacBox 中途崩溃，下次启动也会恢复。',
      'A sandbox can’t stop settings written through the system, so MacBox lends the box’s preferences to the system at launch, takes them all back at quit, and restores yours exactly as they were. Every step is journaled first, so even a crash is recovered on next launch.',
    ],
  },
  {
    icon: icons.hand,
    tint: 'g5',
    wide: true,
    title: ['沙盒挡住乱写、乱读', 'A sandbox against stray writes and reads'],
    text: [
      '写入默认全部禁止，只放行盒子和系统临时目录（可选放行「下载」）。读不到邮件、信息、Safari、其他 App 的 Application Support 和容器、SSH 密钥；不能注册开机自启和后台服务、发通知、遥控其他 App。子进程自动继承。',
      'Writes are denied except to the box and system temp folders (and optionally Downloads). No reading Mail, Messages, Safari, other apps’ Application Support and containers, or SSH keys; no login items, background services, notifications or controlling other apps. Child processes inherit it all.',
    ],
  },
  {
    icon: icons.shield,
    tint: 'g2',
    title: ['运行时守卫', 'Runtime guard'],
    text: [
      '每 50 毫秒检查一次新进程。盒子里的程序一旦在沙盒外被启动，立即结束。',
      'Checks new processes every 50 ms. Anything from a box that starts outside the sandbox is stopped at once.',
    ],
  },
  {
    icon: icons.restore,
    tint: 'g1',
    title: ['还原点', 'Restore points'],
    text: [
      'APFS 克隆，几乎不占空间。一键回到之前的状态，或设为每次退出自动还原。',
      'APFS clones that take almost no space. Roll back in one click, or restore automatically every time you quit.',
    ],
  },
  {
    icon: icons.eye,
    tint: 'g3',
    wide: true,
    title: ['拦截记录', 'See what was blocked'],
    text: [
      '详情面板里列出本次运行被挡下的行为：自启、后台服务、读取私人数据……',
      'The details panel lists what was stopped this session: login items, background services, private data reads…',
    ],
  },
  {
    icon: icons.checked,
    tint: 'g2',
    wide: true,
    title: ['添加前先检查', 'Checked before it runs'],
    text: [
      '检查驱动、系统扩展、特权辅助程序和 Apple 公证，提前告诉你本机隔离装不装得下。',
      'Looks for drivers, system extensions, privileged helpers and notarization, and tells you up front whether it fits.',
    ],
  },
];

const verifyCommand = ['shasum -a 256 -c MacBox-*.dmg.sha256'];
const quarantineCommand = ['xattr -dr com.apple.quarantine /Applications/MacBox.app'];
const buildCommands = [
  'git clone https://github.com/PykeDLing/macbox.git',
  'cd macbox',
  './build.sh',
  'open build/MacBox.app',
];

/** 进入视口时淡入；同时进入的几块依次错开一点 */
function useReveal(root: React.RefObject<HTMLElement | null>) {
  useEffect(() => {
    const items = root.current?.querySelectorAll<HTMLElement>('.reveal') ?? [];
    if (!('IntersectionObserver' in window)) {
      items.forEach((el) => el.classList.add('in'));
      return;
    }
    const io = new IntersectionObserver(
      (entries) => {
        let n = 0;
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          const el = entry.target as HTMLElement;
          el.style.transitionDelay = `${Math.min(n++, 4) * 80}ms`;
          el.classList.add('in');
          io.unobserve(el);
        }
      },
      { rootMargin: '0px 0px -8% 0px' },
    );
    items.forEach((el) => io.observe(el));
    return () => io.disconnect();
  }, [root]);
}

/**
 * 切换语言：两种文字长短不同，换完页面会上下跳。切换前记下视口顶部附近的一块，
 * 切换后把它放回原来的位置
 */
function useLanguageSwitch(locale: Locale, root: React.RefObject<HTMLElement | null>) {
  const navigate = useNavigate();
  const anchor = useRef<{ index: number; top: number } | null>(null);

  const blocks = () =>
    Array.from(root.current?.querySelectorAll<HTMLElement>('header, section, .reveal') ?? []);
  const prepare = (next: Locale) => {
    rememberLanguage(next);
    if (next === locale) return;
    const navBottom = document.querySelector('.nav')?.getBoundingClientRect().bottom ?? 0;
    const list = blocks();
    const index = list.findIndex((el) => el.getBoundingClientRect().top >= navBottom);
    anchor.current = index >= 0 ? { index, top: list[index]!.getBoundingClientRect().top } : null;
  };
  useLayoutEffect(() => {
    const saved = anchor.current;
    anchor.current = null;
    const el = saved && blocks()[saved.index];
    if (saved && el)
      window.scrollBy({ top: el.getBoundingClientRect().top - saved.top, behavior: 'instant' });
    // 只在语言变化后对位
  }, [locale]);

  const switchTo = (next: Locale) => {
    prepare(next);
    if (next !== locale) void navigate({ to: homePath(next), replace: true, resetScroll: false });
  };
  return { prepare, switchTo };
}

export default function Home({ locale }: { locale: Locale }) {
  const t = translate(locale);
  const root = useRef<HTMLDivElement>(null);
  const release = useLatestRelease();
  const language = useLanguageSwitch(locale, root);
  useReveal(root);
  // 页面已经由脚本接管；<head> 里的兜底计时器看到这个标记就不再撤掉 .js
  useEffect(() => document.documentElement.classList.add('js', 'hydrated'), []);

  const download = (label: ReactNode) => (
    <a className="btn btn-primary" href={release.download}>
      <Icon svg={icons.download} />
      {label}
    </a>
  );

  return (
    <div ref={root}>
      <a className="skip" href="#main">
        {t('跳到正文', 'Skip to content')}
      </a>
      <SiteNav locale={locale} onLanguage={language.prepare} />

      <header className="hero">
        <div className="wrap">
          <img
            className="hero-icon"
            src={href('/icon-320.png')}
            srcSet={`${href('/icon-320.png')} 2x, ${href('/icon.png')} 3x`}
            width={152}
            height={152}
            alt="MacBox"
            fetchPriority="high"
          />
          <p className="eyebrow">
            {t(
              '免费 · 开源 · 为 Apple Silicon 打造',
              'Free · Open source · Built for Apple Silicon',
            )}
          </p>
          <h1>
            {t(
              <>
                不放心的软件<Pe>，</Pe>
                <br />
                装进盒子里用<Pe>。</Pe>
              </>,
              'Run the apps you don’t trust in a box.',
            )}
          </h1>
          <p className="lede">
            {t(
              <>
                <Ln>
                  像普通 App 一样打开，有自己的窗口，待在程序坞里<Pe>。</Pe>
                </Ln>
                <Ln>
                  但它写下的文件、设置和钥匙串会留在盒子里{'⁠'}——删掉盒子，你的 Mac 干干净净
                  <Pe>。</Pe>
                </Ln>
              </>,
              'They open like any other app, with their own windows and a place in the Dock. But the files, settings and keychain items they write stay in the box. Delete the box and your Mac is clean.',
            )}
          </p>
          <div className="cta">
            {download(t('下载 MacBox', 'Download MacBox'))}
            <a className="btn btn-ghost" href={repository}>
              {t('在 GitHub 上查看 ›', 'View on GitHub ›')}
            </a>
          </div>
          <p className="meta">
            {release.version} ·{' '}
            {t(
              '需要 Apple Silicon（M 系列芯片）和 macOS 26 或更新版本',
              'Requires a Mac with Apple silicon and macOS 26 or later',
            )}
          </p>
        </div>

        <div className="stage reveal">
          <DemoWindow locale={locale} onLanguage={language.switchTo} />
          <p className="try">
            {t(
              <>
                这个窗口可以操作：选中一个应用，打开、退出、切换运行环境或者删除试试<Pe>。</Pe>
              </>,
              'This window is live. Pick an app and try opening, quitting, switching runtimes or deleting it.',
            )}
          </p>
        </div>
      </header>

      <main id="main">
        <section>
          <div className="wrap">
            <div className="center reveal">
              <p className="kicker">{t('为什么需要它', 'Why MacBox')}</p>
              <h2>
                {t(
                  <>
                    装一个软件<Pe>，</Pe>
                    <br />
                    留下一堆东西<Pe>。</Pe>
                  </>,
                  'Install one app. Get a lot more than you asked for.',
                )}
              </h2>
              <p className="intro">
                {t(
                  <>
                    <Ln>
                      各种网盘、下载器、工具软件，装上之后往往在系统里到处留东西<Pe>。</Pe>
                    </Ln>
                    <Ln>
                      就算卸载了，这些东西也常常还在<Pe>。</Pe>
                    </Ln>
                  </>,
                  'Cloud drives, downloaders and all kinds of utilities tend to spread themselves across your system — and much of it stays behind even after you uninstall them.',
                )}
              </p>
            </div>
            <div className="mess reveal">
              {problems.map(([icon, zhTitle, enTitle, zh, en]) => (
                <div key={enTitle}>
                  <span className="mi">
                    <Icon svg={icon} />
                  </span>
                  <h3>{t(zhTitle, enTitle)}</h3>
                  <p>{t(zh, en)}</p>
                </div>
              ))}
            </div>
            <div className="verdict reveal">
              {t(
                <>
                  MacBox 让它们照常工作——只是哪儿也去不了<Pe>。</Pe>
                </>,
                'MacBox lets them work as usual. They just can’t get out.',
              )}
            </div>
          </div>
        </section>

        <section id="how">
          <div className="wrap">
            <div className="reveal">
              <p className="kicker">{t('怎么用', 'How it works')}</p>
              <h2>
                {t('拖进来，打开，用完删掉。', 'Drop it in. Open it. Delete it when you’re done.')}
              </h2>
            </div>
            <div className="steps">
              <div className="step reveal">
                <h3>{t('拖进来', 'Drop it in')}</h3>
                <p>
                  {t(
                    '把下载的安装包拖进 MacBox。MacBox 会取出里面的 App，pkg 的安装脚本不会执行。只有几 MB、打开后再联网下载的在线安装器也能处理。',
                    'Drag a downloaded installer into MacBox and it pulls out the app. Installer scripts in a .pkg never run. Even tiny online installers that download the real app work.',
                  )}
                </p>
                <div className="chips">
                  <span>.dmg</span>
                  <span>.app</span>
                  <span>.pkg</span>
                  <span>.zip</span>
                </div>
              </div>
              <div className="step reveal">
                <h3>{t('照常打开', 'Use it normally')}</h3>
                <p>
                  {t(
                    '在 MacBox 里双击，或者从聚焦打开。它有自己的窗口和程序坞图标，用起来和普通 App 没有区别，性能也几乎没有损失。',
                    'Double-click it in MacBox, or open it from Spotlight. It gets its own windows and Dock icon, and runs at essentially native speed.',
                  )}
                </p>
              </div>
              <div className="step reveal">
                <h3>{t('删掉就干净', 'Delete it, clean')}</h3>
                <p>
                  {t(
                    '删除盒子，应用连同它的全部数据一起移到废纸篓。它的设置和数据不会留在系统里（系统临时目录除外），后悔了也能从废纸篓找回。',
                    'Delete the box and the app goes to the Trash together with all of its data. Nothing else is left behind (apart from system temp files) — and you can still put it back.',
                  )}
                </p>
              </div>
            </div>
          </div>
        </section>

        <section id="features">
          <div className="wrap">
            <div className="reveal">
              <p className="kicker">{t('特性', 'Features')}</p>
              <h2>
                {t(
                  <>
                    看不见的隔离，
                    <br />
                    一层一层做到位。
                  </>,
                  'Isolation you don’t notice, built layer by layer.',
                )}
              </h2>
            </div>
            <div className="grid">
              {features.map((feature) => (
                <div
                  key={feature.title[1]}
                  className={feature.wide ? 'feat wide reveal' : 'feat reveal'}
                >
                  <div className={`fi ${feature.tint}`}>
                    <Icon svg={feature.icon} />
                  </div>
                  <h3>{t(...feature.title)}</h3>
                  <p>{t(...feature.text)}</p>
                </div>
              ))}
            </div>
          </div>
        </section>

        <section id="modes">
          <div className="wrap">
            <div className="reveal">
              <p className="kicker">{t('两种运行环境', 'Two runtimes')}</p>
              <h2>
                {t(
                  <>
                    大多数应用用本机隔离，
                    <br />
                    剩下的交给虚拟 Mac。
                  </>,
                  'Native Isolation for most apps. A Virtual Mac for the rest.',
                )}
              </h2>
            </div>
            <div className="modes">
              <div className="mode primary reveal">
                <span className="badge">{t('默认', 'Default')}</span>
                <h3>{t('本机隔离', 'Native Isolation')}</h3>
                <dl>
                  <dt>{t('体验', 'Feel')}</dt>
                  <dd>
                    {t(
                      '原生窗口、程序坞、聚焦，和普通 App 一样',
                      'Native windows, Dock and Spotlight — just like any app',
                    )}
                  </dd>
                  <dt>{t('性能', 'Speed')}</dt>
                  <dd>{t('原生，沙盒开销约 1.5%', 'Native; about 1.5% sandbox overhead')}</dd>
                  <dt>{t('空间', 'Space')}</dt>
                  <dd>{t('只有应用本身和它的数据', 'Just the app and its data')}</dd>
                  <dt>{t('适用', 'For')}</dt>
                  <dd>{t('绝大多数应用', 'The vast majority of apps')}</dd>
                </dl>
              </div>
              <div className="mode reveal">
                <span className="badge">{t('后备', 'Fallback')}</span>
                <h3>{t('虚拟 Mac', 'Virtual Mac')}</h3>
                <dl>
                  <dt>{t('体验', 'Feel')}</dt>
                  <dd>{t('一整块独立的 macOS 桌面', 'A complete, separate macOS desktop')}</dd>
                  <dt>{t('性能', 'Speed')}</dt>
                  <dd>
                    {t(
                      '接近原生，默认分配 4–8 GB 内存（可调整）',
                      'Near native; 4–8 GB of memory by default (adjustable)',
                    )}
                  </dd>
                  <dt>{t('空间', 'Space')}</dt>
                  <dd>
                    {t(
                      '约 30 GB，所有需要它的应用共用一台',
                      'About 30 GB, shared by every app that needs it',
                    )}
                  </dd>
                  <dt>{t('适用', 'For')}</dt>
                  <dd>
                    {t(
                      '需要驱动、系统服务、系统扩展的应用',
                      'Apps that need drivers, system services or extensions',
                    )}
                  </dd>
                </dl>
              </div>
            </div>
            <p className="note reveal">
              {t(
                '虚拟 Mac 不会默认安装。添加应用时检查到它需要驱动或系统扩展，或者运行时它被挡住了写系统目录、安装系统服务，MacBox 会建议你改用虚拟 Mac。随时可以在详情面板里切换。',
                'The Virtual Mac isn’t installed by default. If an app turns out to need a driver or system extension — at import or while running — MacBox suggests switching, and you can change runtimes any time in the details panel.',
              )}
            </p>
          </div>
        </section>

        <section>
          <div className="wrap honest">
            <div className="reveal">
              <p className="kicker">{t('坦白说', 'To be clear')}</p>
              <h2>
                {t('它防的是乱写、乱留、乱读，不是恶意软件。', 'It stops mess, not malware.')}
              </h2>
              <p className="intro">
                {t(
                  '本机隔离和你的 Mac 共用内核和用户身份。来路可疑的软件，请用虚拟 Mac。',
                  'Native Isolation shares the kernel and your user account with your Mac. For software from a source you truly don’t trust, use the Virtual Mac.',
                )}
              </p>
            </div>
            <ul className="reveal">
              <li>
                <strong>{t('会被挡住的功能', 'Features that won’t work')}</strong>
                {t(
                  '：开机自启、通知、访达扩展、需要驱动的功能。',
                  ': launch at login, notifications, Finder extensions and anything that needs a driver.',
                )}
              </li>
              <li>
                <strong>
                  {t('「本次已拦截」是尽力而为', '“Blocked This Session” is best effort')}
                </strong>
                {t(
                  '：它来自系统日志，系统会限流。没有记录不代表没有被拦截。',
                  ': it comes from the system log, which is rate-limited. No entry doesn’t mean nothing was blocked.',
                )}
              </li>
              <li>
                <strong>{t('系统临时目录可写', 'System temp folders stay writable')}</strong>
                {t(
                  '：很多系统框架依赖它们，App 可以在这里留下文件。',
                  ': many frameworks rely on them, so apps can leave files there.',
                )}
              </li>
              <li>
                <strong>{t('MacBox 本身需要你信任', 'MacBox itself needs your trust')}</strong>
                {t(
                  '：它要替盒子准备环境、收回设置，不在沙盒里运行。所以它完全开源，你可以自己构建。',
                  ': it prepares each box and returns its settings, so it can’t be sandboxed. That’s why it’s fully open source — build it yourself if you like.',
                )}
              </li>
              <li>
                <strong>{t('其他已知限制', 'Other known limits')}</strong>
                {t(
                  '：App 包内的 XPC 服务会被守卫结束，依赖它们的功能不可用；使用 Data Protection 钥匙串的 App，条目不会进盒子钥匙串；其他 App 的偏好设置仍可能被读到。',
                  ': XPC services bundled inside an app are stopped by the guard, so features that rely on them won’t work; apps that use the Data Protection keychain don’t get their items in the box keychain; other apps’ preferences can still be read. ',
                )}
                <a href={isolationDetails}>{t('完整说明', 'Full details (in Chinese)')}</a>
              </li>
            </ul>
          </div>
        </section>

        <section id="download">
          <div className="wrap">
            <div className="install reveal">
              <div className="side">
                <img
                  src={href('/icon-320.png')}
                  srcSet={`${href('/icon-320.png')} 2x, ${href('/icon.png')} 3x`}
                  width={150}
                  height={150}
                  alt=""
                  loading="lazy"
                />
                <div>
                  {download(
                    <>
                      {t('下载', 'Download')} <span>{release.version}</span>
                    </>,
                  )}
                </div>
                {/* 大小和发布日期从 GitHub 取到后才显示 */}
                {release.dmg && <p className="meta">{describeDmg(release.dmg, locale)}</p>}
                <p className="meta">
                  <a href={releasesPage}>{t('全部版本', 'All releases')}</a>
                </p>
              </div>
              <div>
                <p className="kicker">{t('下载与安装', 'Download & install')}</p>
                <h2>{t('三步装好。', 'Up and running in three steps.')}</h2>
                <div className="req">
                  <span>Apple Silicon</span>
                  <span>{t('macOS 26 或更新', 'macOS 26 or later')}</span>
                  <span>{t('中文 / English', 'English / 中文')}</span>
                </div>
                <ol>
                  <li>
                    {t(
                      <>
                        下载 <code>MacBox-版本.dmg</code>，打开后把 <strong>MacBox</strong>{' '}
                        拖到「应用程序」（Applications）。想校验下载是否完整，可以从
                        <a href={latestReleasePage}>发布页</a>下载对应的 <code>.sha256</code>{' '}
                        文件，放在同一个文件夹里运行：
                      </>,
                      <>
                        Download <code>MacBox-version.dmg</code>, open it and drag{' '}
                        <strong>MacBox</strong> to Applications. To verify the download, get the
                        matching <code>.sha256</code> file from the{' '}
                        <a href={latestReleasePage}>release page</a>, put it in the same folder and
                        run:
                      </>,
                    )}
                    <Terminal lines={verifyCommand} locale={locale} />
                  </li>
                  <li>
                    {t(
                      <>
                        <strong>第一次打开</strong>：MacBox 还没有经过 Apple 公证，macOS 会提示
                        Apple 无法验证“MacBox”是否包含恶意软件。点「完成」，然后到{' '}
                        <strong>系统设置 › 隐私与安全性</strong>，在页面底部点{' '}
                        <strong>仍要打开</strong>，再输入密码确认。也可以在终端里去掉下载标记：
                      </>,
                      <>
                        <strong>First launch</strong>: MacBox isn’t notarized yet, so macOS says
                        Apple could not verify that it’s free of malware. Click Done, then go to{' '}
                        <strong>System Settings › Privacy &amp; Security</strong>, click{' '}
                        <strong>Open Anyway</strong> near the bottom and confirm with your password.
                        Or remove the download flag in Terminal:
                      </>,
                    )}
                    <Terminal lines={quarantineCommand} locale={locale} />
                  </li>
                  <li>
                    {t(
                      <>
                        把下载的 <code>.dmg</code> 拖进 MacBox，开始使用。
                      </>,
                      <>
                        Drag a downloaded <code>.dmg</code> into MacBox and you’re set.
                      </>,
                    )}
                  </li>
                </ol>
              </div>
            </div>
          </div>
        </section>

        <section>
          <div className="wrap oss">
            <div className="reveal">
              <p className="kicker">{t('开源', 'Open source')}</p>
              <h2>{t('每一行代码都公开。', 'Every line is public.')}</h2>
              <p className="intro">
                {t(
                  'MacBox 以 MIT 许可证开源。不想运行下载的二进制文件，可以自己从源码构建——只需要 Command Line Tools（Swift 6.4 或更新）。',
                  'MacBox is MIT-licensed. If you’d rather not run a downloaded binary, build it from source — the Command Line Tools (Swift 6.4 or later) are all you need.',
                )}
              </p>
              <a className="btn btn-ghost" href={repository}>
                <Icon svg={icons.github} />
                PykeDLing/macbox ›
              </a>
            </div>
            <div className="reveal">
              <Terminal lines={buildCommands} locale={locale} />
            </div>
          </div>
        </section>
      </main>

      <footer>
        <div className="wrap">
          <span className="dots" aria-hidden="true">
            <i />
            <i />
            <i />
          </span>
          <span>© 2026 PykeDLing</span>
          <div className="foot-links">
            <a href={licensePage}>{t('MIT 许可证', 'MIT License')}</a>
            <a href={issuesPage}>{t('反馈问题', 'Report an Issue')}</a>
            <a href={repository}>GitHub</a>
          </div>
        </div>
      </footer>
    </div>
  );
}
