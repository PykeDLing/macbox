import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import { useNavigate } from '@tanstack/react-router';
import { DemoWindow } from '../demo/DemoWindow';
import { Film, playFilmFromStart } from '../components/Film';
import { Icon } from '../components/Icon';
import { icons } from '../components/icons';
import { SiteNav } from '../components/SiteNav';
import { Terminal } from '../components/Terminal';
import { filmSeconds } from '../lib/film';
import { homePath, translate, type Locale, type Pair } from '../lib/i18n';
import { rememberLanguage } from '../lib/language';
import { describeDmg, useLatestRelease } from '../lib/release';
import {
  compatibilityList,
  href,
  howItWorks,
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

/** 片子和页面里那个“不放心的软件”，和演示窗口里的第一个应用同名 */
const sampleApp: Pair = ['某某网盘', 'Cloud Drive'];

// “为什么需要它”：直接装在 Mac 上时散落各处的东西（code 为 true 的一栏用等宽字）
const leftovers: readonly { where: Pair; code: boolean; what: Pair }[] = [
  {
    where: ['~/Library/LaunchAgents/', '~/Library/LaunchAgents/'],
    code: true,
    what: ['开机自启', 'Launch at login'],
  },
  {
    where: ['~/Library/Application Support/', '~/Library/Application Support/'],
    code: true,
    what: ['数据', 'Data'],
  },
  { where: ['~/Library/Caches/', '~/Library/Caches/'], code: true, what: ['缓存', 'Caches'] },
  {
    where: ['~/Library/Preferences/', '~/Library/Preferences/'],
    code: true,
    what: ['设置', 'Settings'],
  },
  { where: ['~/Library/Cookies/', '~/Library/Cookies/'], code: true, what: ['Cookie', 'Cookies'] },
  {
    where: ['「登录」钥匙串', 'Login keychain'],
    code: false,
    what: ['凭证、设备 ID', 'Credentials, device IDs'],
  },
  {
    where: ['后台服务', 'Background services'],
    code: false,
    what: ['常驻进程', 'Always running'],
  },
];
// 同样的东西装进盒子以后落在哪
const inTheBox: readonly { where: Pair; code: boolean; what: Pair }[] = [
  { where: ['App/', 'App/'], code: true, what: ['应用本身', 'The app itself'] },
  { where: ['Home/', 'Home/'], code: true, what: ['数据、缓存、Cookie', 'Data, caches, cookies'] },
  { where: ['Prefs/', 'Prefs/'], code: true, what: ['设置', 'Settings'] },
  {
    where: ['盒子自己的钥匙串', 'The box’s own keychain'],
    code: false,
    what: ['凭证、设备 ID', 'Credentials, device IDs'],
  },
];

// 特性里“碰不到你的私人数据”一格右边的清单
const outOfReach: readonly { what: Pair; status: Pair }[] = [
  { what: ['邮件、信息', 'Mail, Messages'], status: ['读不到', 'Can’t read'] },
  {
    what: ['Safari、Cookie、iCloud 云盘', 'Safari, cookies, iCloud Drive'],
    status: ['读不到', 'Can’t read'],
  },
  { what: ['其他 App 的数据', 'Other apps’ data'], status: ['读不到', 'Can’t read'] },
  { what: ['SSH · GPG · AWS 密钥', 'SSH · GPG · AWS keys'], status: ['读不到', 'Can’t read'] },
  { what: ['「登录」钥匙串', 'Login keychain'], status: ['不进去', 'Untouched'] },
  {
    what: ['开机自启、后台服务', 'Login items, background services'],
    status: ['不能注册', 'Can’t register'],
  },
];

// 运行报告一格里的示意数字，和宣传片里的一样
const reportStats: readonly [number, Pair][] = [
  [128, ['写入文件', 'Files written']],
  [12, ['改动设置', 'Settings changed']],
  [9, ['连接服务器', 'Servers contacted']],
  [3, ['启动程序', 'Programs launched']],
];
const reportBlocked: readonly [Pair, string][] = [
  [['注册开机自启动', 'Register a login item'], 'LaunchAgents'],
  [['读取 SSH 密钥', 'Read SSH keys'], '~/.ssh'],
  [['连接 ssh-agent', 'Connect to ssh-agent'], 'SSH_AUTH_SOCK'],
];

const numbers: readonly { value: string; label: Pair; note: Pair }[] = [
  {
    value: '≈1.5%',
    label: ['沙盒的性能开销', 'sandbox overhead'],
    note: ['原生运行，不是虚拟机', 'Runs natively, not in a virtual machine'],
  },
  {
    value: '50 ms',
    label: ['检查一次新进程', 'between process checks'],
    note: ['在沙盒外启动的，立即结束', 'Anything started outside the sandbox is stopped'],
  },
  {
    value: '0',
    label: ['开机自启和后台服务', 'login items or background services'],
    note: ['盒子里的应用注册不了', 'Apps in a box can’t register them'],
  },
  {
    value: 'MIT',
    label: ['每一行代码都公开', 'every line is public'],
    note: ['可以自己从源码构建', 'Build it from source yourself'],
  },
];

// “工作原理”：本机隔离叠在一起的几层
const layers: readonly { icon: string; tint: string; title: Pair; text: Pair }[] = [
  {
    icon: icons.hand,
    tint: 'g5',
    title: ['沙盒挡住乱写、乱读', 'A sandbox against stray writes and reads'],
    text: [
      '写入默认全部禁止，只放行盒子里 App 的主目录、App 本身、临时目录、「下载」和你给它加的文件夹；私人数据读不到。子进程自动继承。',
      'Writes are denied except to the app’s home folder in the box, the app itself, temp folders, Downloads and folders you add; private data can’t be read. Child processes inherit it all.',
    ],
  },
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
    title: ['偏好设置借出再收回', 'Preferences, lent and returned'],
    text: [
      '系统代写的设置沙盒挡不住，所以 MacBox 在启动前把盒子的设置整体借给系统，退出后完整收回，再把你本机原来的设置原样换回。全程先写日志，就算 MacBox 中途崩溃，下次启动也会恢复。',
      'A sandbox can’t stop settings written through the system, so MacBox lends the box’s preferences to the system at launch, takes them all back at quit, and restores yours exactly as they were. Every step is journaled first, so even a crash is recovered on next launch.',
    ],
  },
  {
    icon: icons.shield,
    tint: 'g2',
    title: ['运行时守卫，App 平时上锁', 'A runtime guard, and apps locked outside MacBox'],
    text: [
      'MacBox 打开期间，每 50 毫秒检查一次新进程，盒子里的程序一旦在沙盒外被启动，立即结束。不在 MacBox 里运行时，盒子里 App 的程序没有执行权限：即使 MacBox 没开，从程序坞、登录时自动重新打开都启动不了它。',
      'While MacBox is open, it checks new processes every 50 ms and stops anything from a box that starts outside the sandbox. When an app isn’t running in MacBox, its executables have no execute permission: even with MacBox closed, it can’t be started from the Dock or by reopening at login.',
    ],
  },
];

// “坦白说”：每条一个标题加一段说明，点开看
const limits: readonly { title: Pair; text: Pair }[] = [
  {
    title: ['会被挡住的功能', 'Features that won’t work'],
    text: [
      '开机自启、通知、访达扩展、需要驱动的功能。',
      'Launch at login, notifications, Finder extensions and anything that needs a driver.',
    ],
  },
  {
    title: ['MacBox 没开时没有守卫', 'No guard while MacBox is closed'],
    text: [
      '这时只靠「App 平时上锁」挡住直接打开。MacBox 在应用运行时异常退出的话，这个应用要等下次打开 MacBox 才重新上锁。',
      'Then only “Locked outside MacBox” keeps box apps from being opened directly. If MacBox quits unexpectedly while an app is running, that app stays unlocked until you next open MacBox.',
    ],
  },
  {
    title: ['两份不能同时运行', 'Two copies can’t run at once'],
    text: [
      '同一个应用的两份（两个盒子，或者盒子和直接装在 Mac 上的那份）共用一组偏好设置。MacBox 会拒绝同时打开，并告诉你先退出哪一个；但盒子运行期间再去打开本机那份，它拦不住，请避免。',
      'Two copies of the same app (in two boxes, or in a box and installed directly on your Mac) share one set of preferences. MacBox won’t open both, and tells you which one to quit first — but it can’t stop you from opening the copy on your Mac while the box is running, so please don’t.',
    ],
  },
  {
    title: ['有些偏好设置不进盒子', 'Some preferences stay outside the box'],
    text: [
      'MacBox 按 bundle ID 认定哪些偏好设置属于这个 App。认定范围以外的（厂商的更新程序、第三方 SDK、App Group 共享设置等）和“仅限本机”的 ByHost 设置，会直接写进你真实的 ~/Library/Preferences，删除盒子后仍然留着。',
      'MacBox decides which preferences belong to an app by its bundle ID. Anything outside that (a vendor’s updater, third-party SDKs, App Group shared settings and so on) and this-Mac-only ByHost settings are written straight to your real ~/Library/Preferences and stay after you delete the box.',
    ],
  },
  {
    title: ['运行报告是尽力而为', 'Run reports are best effort'],
    text: [
      '启动的程序、被拦下的行为、在共享的「下载」和可以写入的文件夹里写的文件来自系统日志，系统会限流，没有记录不代表没有发生。连接是定时看一眼得到的，很短的连接会漏掉；服务器名字来自反向解析，常常是云服务商的机器名；经由代理的连接只显示为连到本机上的代理。',
      'Launched programs, blocked attempts and files written to the shared Downloads folder or the folders it can write to come from the system log, which is rate-limited, so no entry doesn’t mean nothing happened. Connections are sampled periodically, so very short ones can be missed; server names come from reverse DNS and are often cloud providers’ machine names; connections through a proxy only show up as connections to the proxy on your Mac.',
    ],
  },
  {
    title: ['不联网挡不住由系统代办的事', 'Offline doesn’t cover what the system does for an app'],
    text: [
      '例如让你的默认浏览器打开一个网址（网址里可以带数据）、iCloud 同步、推送通知。',
      'For example, opening a link in your default browser (the link can carry data), iCloud sync or push notifications.',
    ],
  },
  {
    title: ['系统临时目录可写', 'System temp folders stay writable'],
    text: [
      '很多系统框架依赖它们，App 可以在这里留下文件，运行报告也不统计这里。',
      'Many frameworks rely on them, so apps can leave files there, and run reports don’t count them.',
    ],
  },
  {
    title: ['MacBox 本身需要你信任', 'MacBox itself needs your trust'],
    text: [
      '它要替盒子准备环境、收回设置，不在沙盒里运行。所以它完全开源，你可以自己构建。',
      'It prepares each box and returns its settings, so it can’t be sandboxed. That’s why it’s fully open source — build it yourself if you like.',
    ],
  },
  {
    title: ['其他已知限制', 'Other known limits'],
    text: [
      'App 包内的 XPC 服务会被守卫结束，依赖它们的功能不可用；使用 Data Protection 钥匙串的 App，条目不会进盒子钥匙串；其他 App 的偏好设置仍可能被读到。',
      'XPC services bundled inside an app are stopped by the guard, so features that rely on them won’t work; apps that use the Data Protection keychain don’t get their items in the box keychain; other apps’ preferences can still be read.',
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

/** 泛指的应用图标：和演示窗口里的图标一个画法 */
const AppGlyph = ({ svg, tint, running }: { svg: string; tint: string; running?: boolean }) => (
  <span className={running ? `ic app-ic ${tint} running` : `ic app-ic ${tint}`}>
    <Icon svg={svg} />
  </span>
);

/** 特性里“联网开关”一格：一个可以拨的开关，只是示意 */
function NetworkSwitch({ locale }: { locale: Locale }) {
  const t = translate(locale);
  const [online, setOnline] = useState(true);
  return (
    <div className="art art-net">
      <span>{t('允许联网', 'Allow Network Access')}</span>
      <button
        type="button"
        role="switch"
        aria-checked={online}
        aria-label={t('允许联网（示意）', 'Allow Network Access (demo)')}
        className="switch"
        onClick={() => setOnline((value) => !value)}
      />
      <small>
        {online
          ? t('应用可以连接服务器', 'The app can reach servers')
          : t('连不上任何服务器，本机上的代理也不行', 'No servers — not even a proxy on your Mac')}
      </small>
    </div>
  );
}

export default function Home({ locale }: { locale: Locale }) {
  const t = translate(locale);
  const p = (pair: Pair) => t(pair[0], pair[1]);
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

      <header className="hero" id="top">
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
                装进<span className="boxed">盒子</span>里用<Pe>。</Pe>
              </>,
              <>
                Run the apps you don’t trust in a <span className="boxed">box</span>.
              </>,
            )}
          </h1>
          <p className="lede">
            {t(
              <>
                <Ln>
                  像普通 App 一样打开，有自己的窗口，待在程序坞里<Pe>。</Pe>
                </Ln>
                <Ln>
                  但它的数据、设置和钥匙串
                  {/* 手机上从这里折行，第一行不只剩“但它的数据、” */}
                  <wbr />
                  留在盒子里{'⁠'}——删掉盒子，不在你的 Mac 上乱留东西
                  <Pe>。</Pe>
                </Ln>
              </>,
              'They open like any other app, with their own windows and a place in the Dock. But their data, settings and keychain items stay in the box. Delete the box, and they leave no mess on your Mac.',
            )}
          </p>
          <div className="cta">
            {download(t('下载 MacBox', 'Download MacBox'))}
            <a className="btn btn-ghost" href="#film" onClick={playFilmFromStart}>
              <Icon svg={icons.play} />
              {t(`看 ${filmSeconds} 秒介绍`, `Watch the ${filmSeconds}-second film`)}
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

        <Film locale={locale} />
      </header>

      <main id="main">
        <section id="try">
          <div className="wrap">
            <div className="center reveal">
              <p className="kicker">{t('亲手试试', 'Try it')}</p>
              <h2>{t('这个窗口可以操作。', 'This window is live.')}</h2>
              <p className="intro">
                {t(
                  '选中一个应用，打开、退出、查看运行报告、关掉联网、切换运行环境，或者删除试试。',
                  'Pick an app and try opening and quitting it, viewing its run report, turning off its network access, switching runtimes or deleting it.',
                )}
              </p>
            </div>
          </div>
          <div className="stage reveal">
            <DemoWindow locale={locale} onLanguage={language.switchTo} />
          </div>
        </section>

        <section id="why">
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

            <div className="compare">
              <figure className="pane pane-out reveal">
                <figcaption>
                  <i className="mark" />
                  {t('直接装在 Mac 上', 'Installed straight on your Mac')}
                </figcaption>
                <ul className="tree">
                  {leftovers.map((item) => (
                    <li key={item.where[1]}>
                      {item.code ? <code>{p(item.where)}</code> : <span>{p(item.where)}</span>}
                      <em>{p(item.what)}</em>
                    </li>
                  ))}
                </ul>
                <p className="pane-foot">
                  {t(
                    '卸载之后，这些东西也常常还在。',
                    'Much of it is still there after you uninstall.',
                  )}
                </p>
              </figure>

              <div className="arrow" aria-hidden="true">
                <Icon svg={icons.arrowUpRight} />
              </div>

              <figure className="pane pane-in reveal">
                <figcaption>
                  <i className="mark" />
                  {t('装进 MacBox 的盒子', 'In a MacBox box')}
                </figcaption>
                <div className="thebox">
                  <div className="thebox-head">
                    <AppGlyph svg={icons.cloud} tint="g1" />
                    <div>
                      <b>{p(sampleApp)}</b>
                      <small>{t('在盒子里运行', 'Running in its box')}</small>
                    </div>
                  </div>
                  <ul className="tree">
                    {inTheBox.map((item) => (
                      <li key={item.where[1]}>
                        {item.code ? <code>{p(item.where)}</code> : <span>{p(item.where)}</span>}
                        <em>{p(item.what)}</em>
                      </li>
                    ))}
                  </ul>
                </div>
                <p className="pane-foot">
                  {t(
                    '删除盒子，里面的一起移到废纸篓。',
                    'Delete the box, and everything in it goes to the Trash.',
                  )}
                </p>
              </figure>
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

        <section id="features">
          <div className="wrap">
            <div className="reveal">
              <p className="kicker">{t('特性', 'Features')}</p>
              <h2>
                {t(
                  <>
                    照常使用，
                    <br />
                    只是它出不了盒子。
                  </>,
                  'Business as usual. It just can’t leave the box.',
                )}
              </h2>
            </div>

            <div className="bento">
              <article className="tile span-3 reveal">
                <div className="tile-text">
                  <span className="num">01</span>
                  <h3>{t('拖进来，就装好了', 'Drop it in. It’s installed.')}</h3>
                  <p>
                    {t(
                      '把下载的安装包拖进 MacBox。MacBox 会取出里面的 App，pkg 的安装脚本不会执行。只有几 MB、打开后再联网下载的在线安装器也能处理。',
                      'Drag a downloaded installer into MacBox and it pulls out the app. Installer scripts in a .pkg never run. Even tiny online installers that download the real app work.',
                    )}
                  </p>
                </div>
                <div className="art art-types" aria-hidden="true">
                  <span>.dmg</span>
                  <span>.app</span>
                  <span>.pkg</span>
                  <span>.zip</span>
                </div>
              </article>

              <article className="tile span-3 reveal">
                <div className="tile-text">
                  <span className="num">02</span>
                  <h3>{t('和普通 App 没有两样', 'Just like any other app')}</h3>
                  <p>
                    {t(
                      '在 MacBox 里双击，或者从聚焦打开。它有自己的窗口和程序坞图标，性能也几乎没有损失。在浏览器里点链接、在访达里双击它的文件，也会交给盒子里的它。',
                      'Double-click it in MacBox, or open it from Spotlight. It gets its own windows and Dock icon, and runs at essentially native speed. Links you click in a browser and its files you double-click in Finder are handed to the boxed app, too.',
                    )}
                  </p>
                </div>
                <div className="art art-dock" aria-hidden="true">
                  <AppGlyph svg={icons.downloadApp} tint="g3" />
                  <AppGlyph svg={icons.meeting} tint="g2" />
                  <AppGlyph svg={icons.cloud} tint="g1" running />
                  <AppGlyph svg={icons.music} tint="g5" />
                  <img src={href('/favicon.png')} width={44} height={44} alt="" loading="lazy" />
                </div>
              </article>

              <article className="tile span-4 reveal">
                <div className="tile-text">
                  <span className="num">03</span>
                  <h3>{t('看得见它做了什么', 'See what it actually did')}</h3>
                  <p>
                    {t(
                      '每次在本机隔离中运行，MacBox 都记下它写了哪些文件、改了哪些设置（只记名字）、连了哪些服务器、启动了哪些程序、哪些行为被拦下。报告可以拷贝成文字、存储为 Markdown 或图片。',
                      'Each time an app runs in Native Isolation, MacBox records which files it wrote, which settings it changed (names only), which servers it contacted, which programs it launched and what was blocked. Copy the report as text, or save it as Markdown or an image.',
                    )}
                  </p>
                </div>
                <div className="art art-report" aria-hidden="true">
                  <div className="rstats">
                    {reportStats.map(([value, label]) => (
                      <div key={label[1]}>
                        <b>{value}</b>
                        <small>{p(label)}</small>
                      </div>
                    ))}
                  </div>
                  <ul>
                    {reportBlocked.map(([label, where]) => (
                      <li key={where}>
                        <Icon svg={icons.blocked} />
                        {p(label)}
                        <code>{where}</code>
                      </li>
                    ))}
                  </ul>
                </div>
              </article>

              <article className="tile span-2 reveal">
                <div className="tile-text">
                  <span className="num">04</span>
                  <h3>{t('联网开关', 'Network switch')}</h3>
                  <p>
                    {t(
                      '在详情面板里关掉「允许联网」，应用就连不上任何服务器，也查不了域名。',
                      'Turn off “Allow Network Access” in the details panel, and the app can’t reach any server or look up names.',
                    )}
                  </p>
                </div>
                <NetworkSwitch locale={locale} />
              </article>

              <article className="tile span-4 reveal">
                <div className="tile-text">
                  <span className="num">05</span>
                  <h3>{t('碰不到你的私人数据', 'Your private data stays out of reach')}</h3>
                  <p>
                    {t(
                      '读不到邮件、信息、Safari、其他 App 的数据，以及 SSH、GPG、AWS、Kubernetes 的密钥和命令行工具的凭证；不能注册开机自启和后台服务、发通知、遥控其他 App。别处照常读得到，例如文稿、桌面。',
                      'No reading Mail, Messages, Safari or other apps’ data, nor SSH, GPG, AWS or Kubernetes keys and command-line credentials. No login items, background services, notifications or controlling other apps. Everything else, such as Documents and Desktop, can still be read.',
                    )}
                  </p>
                </div>
                <ul className="art art-private" aria-hidden="true">
                  {outOfReach.map((item) => (
                    <li key={item.what[1]}>
                      {p(item.what)}
                      <span>
                        <Icon svg={icons.lock} />
                        {p(item.status)}
                      </span>
                    </li>
                  ))}
                </ul>
              </article>

              <article className="tile span-2 reveal">
                <div className="tile-text">
                  <span className="num">06</span>
                  <h3>{t('还原点', 'Restore points')}</h3>
                  <p>
                    {t(
                      'APFS 克隆，几乎不占空间，连同钥匙串一起保存。一键回到之前的状态，或设为每次退出自动还原。',
                      'APFS clones that take almost no space, keychain included. Roll back in one click, or restore automatically every time you quit.',
                    )}
                  </p>
                </div>
                <div className="art art-restore" aria-hidden="true">
                  <i />
                  <i />
                  <i />
                  <i className="now" />
                </div>
              </article>

              <article className="tile span-3 reveal">
                <div className="tile-text">
                  <span className="num">07</span>
                  <h3>{t('删掉盒子，一起带走', 'Delete the box, and it all goes along')}</h3>
                  <p>
                    {t(
                      '删除盒子，应用连同它的全部数据一起移到废纸篓，后悔了也能找回。「下载」默认共享，它存进那里的文件会保留，存进你给它的可以写入的文件夹里的也一样；系统临时目录里的文件和少数收不进盒子的偏好设置也会留下。',
                      'Delete the box and the app goes to the Trash together with all of its data — and you can still put it back. Downloads is shared by default, so files it saved there stay, as do files in any folders you let it write to, system temp files and a few preferences that can’t be kept in the box.',
                    )}
                  </p>
                </div>
              </article>

              <article className="tile span-3 reveal">
                <div className="tile-text">
                  <span className="num">08</span>
                  <h3>
                    {t(
                      '添加前先检查，装不下的交给虚拟 Mac',
                      'Checked first, with a Virtual Mac behind it',
                    )}
                  </h3>
                  <p>
                    {t(
                      '添加时检查驱动、系统扩展、特权辅助程序、苹果沙盒和 Apple 公证，提前告诉你本机隔离装不装得下；装不下的，放进内置的 macOS 虚拟机里运行。',
                      'At import, MacBox looks for drivers, system extensions, privileged helpers, the App Sandbox and notarization, and tells you up front whether Native Isolation fits. What doesn’t fit runs in the built-in macOS virtual machine.',
                    )}
                  </p>
                </div>
              </article>
            </div>

            <dl className="numbers reveal">
              {numbers.map((item) => (
                <div key={item.value}>
                  <dt>{item.value}</dt>
                  <dd>
                    {p(item.label)}
                    <small>{p(item.note)}</small>
                  </dd>
                </div>
              ))}
            </dl>
          </div>
        </section>

        <section id="how">
          <div className="wrap split">
            <div className="reveal">
              <p className="kicker">{t('工作原理', 'How it works')}</p>
              <h2>
                {t(
                  <>
                    不是虚拟机，
                    <br />
                    是几层系统机制叠在一起。
                  </>,
                  'Not a virtual machine. Layers of macOS itself.',
                )}
              </h2>
              <p className="intro">
                {t(
                  '本机隔离用的都是 macOS 自带的机制。每一层具体放行和挡住了什么、崩溃后怎么收拾，文档里都写着。',
                  'Native Isolation is built from mechanisms macOS already has. What each layer allows and blocks, and how a crash is cleaned up, is all written down.',
                )}
              </p>
              <p className="more">
                <a href={howItWorks}>
                  {t('阅读完整的工作原理 ›', 'Read how it works in full (in Chinese) ›')}
                </a>
              </p>
            </div>
            <ol className="layers">
              {layers.map((layer) => (
                <li key={layer.title[1]} className="reveal">
                  <span className={`fi ${layer.tint}`}>
                    <Icon svg={layer.icon} />
                  </span>
                  <h3>{p(layer.title)}</h3>
                  <p>{p(layer.text)}</p>
                </li>
              ))}
            </ol>
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
                      '需要驱动、系统服务、系统扩展的应用，自带苹果沙盒的应用',
                      'Apps that need drivers, system services or extensions, and apps that use the App Sandbox',
                    )}
                  </dd>
                </dl>
              </div>
            </div>
            <p className="note reveal">
              {t(
                '虚拟 Mac 不会默认安装。添加应用时检查到它需要驱动或系统扩展，或者运行时它被挡住了写系统目录、安装系统服务，MacBox 会建议你改用虚拟 Mac。自带苹果沙盒的应用（App Store 上的都是，官网下载的也有一部分）套上 MacBox 的沙盒后一启动就会被系统结束，所以 MacBox 不在本机隔离里启动它们，只能用虚拟 Mac；它们本来就被苹果的沙盒关在自己的容器里。安装包里只有驱动这类系统组件、没有 App 的，MacBox 会提出把它放进虚拟 Mac 安装。随时可以在详情面板里切换。',
                'The Virtual Mac isn’t installed by default. If an app turns out to need a driver or system extension — at import or while running — MacBox suggests switching. Apps that use Apple’s App Sandbox (every App Store app, and some downloads too) are ended by macOS as soon as they start inside MacBox’s sandbox, so MacBox won’t start them in Native Isolation; they need the Virtual Mac. Apple’s sandbox already confines them to their own containers. For an installer with only drivers or other system components and no app, MacBox offers to install it in the Virtual Mac. You can change runtimes any time in the details panel.',
              )}
            </p>
          </div>
        </section>

        <section id="limits">
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
              <p className="more">
                <a href={isolationDetails}>
                  {t('完整的限制列表 ›', 'The full list of limits (in Chinese) ›')}
                </a>
              </p>
            </div>
            <div className="limits reveal">
              {limits.map((limit, i) => (
                <details key={limit.title[1]} open={i === 0}>
                  <summary>{p(limit.title)}</summary>
                  <p>{p(limit.text)}</p>
                </details>
              ))}
            </div>
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
                        把下载的 <code>.dmg</code> 拖进 MacBox，开始使用。哪些应用实测能用，见
                        <a href={compatibilityList}>兼容清单</a>。
                      </>,
                      <>
                        Drag a downloaded <code>.dmg</code> into MacBox and you’re set. See the{' '}
                        <a href={compatibilityList}>compatibility list</a> (in Chinese) for apps
                        that have been tested.
                      </>,
                    )}
                  </li>
                </ol>
                <p className="upgrade">
                  {t(
                    <>
                      <strong>从旧版升级</strong>
                      ：退出 MacBox，用新版替换「应用程序」里的
                      MacBox，盒子和数据都会保留。新版同样要按第 2 步确认一次。从 0.3.0
                      之前的版本升级时，新版第一次打开会给盒子里的 App 上锁：程序坞里固定的盒子 App
                      图标从此不能直接打开，请从 MacBox 或聚焦里的启动器打开。
                    </>,
                    <>
                      <strong>Upgrading</strong>: quit MacBox and replace it in Applications with
                      the new version; your boxes and their data are kept. The new version needs to
                      be approved once, as in step 2. When you upgrade from a version before 0.3.0,
                      the first launch locks the apps in your boxes: Dock icons pinned for box apps
                      no longer open them directly, so open them from MacBox or their Spotlight
                      launcher.
                    </>,
                  )}
                </p>
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
