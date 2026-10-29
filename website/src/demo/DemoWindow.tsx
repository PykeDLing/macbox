import {
  Fragment,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  useSyncExternalStore,
  type ReactNode,
  type RefObject,
} from 'react';
import { Effect, Exit, Fiber, Scope } from 'effect';
import { Icon } from '../components/Icon';
import { icons } from '../components/icons';
import { copyText } from '../lib/clipboard';
import { pick, translate, type Locale, type Pair } from '../lib/i18n';
import { appGlyphs } from './glyphs';
import {
  blockLabels,
  isLive,
  isLocked,
  isSevere,
  severeKinds,
  visibleApps,
  type DemoApp,
  type DemoState,
  type Page,
} from './model';
import {
  blockCount,
  caveats,
  fileTotals,
  formatBytes,
  programNote,
  reportMarkdown,
  seenPrograms,
  seenServers,
  serverPlace,
  serverTitle,
  settingsCount,
  traceOf,
} from './report';
import { createDemo, type DemoStore } from './store';

type T = ReturnType<typeof translate>;
interface ViewProps {
  s: DemoState;
  demo: DemoStore;
  t: T;
  locale: Locale;
}

const cls = (...names: (string | false | null | undefined)[]) => names.filter(Boolean).join(' ');

/** 状态在组件里；定时流程在挂载期间的作用域里运行，卸载（或 StrictMode 的模拟卸载）时全部中断 */
function useDemo() {
  const [store] = useState(() => createDemo());
  useEffect(() => {
    const scope = Effect.runSync(Scope.make());
    Effect.runSync(store.attach.pipe(Scope.provide(scope)));
    return () => {
      Effect.runFork(Scope.close(scope, Exit.void));
    };
  }, [store]);
  const state = useSyncExternalStore(store.subscribe, store.getState, store.getState);
  return [state, store] as const;
}

/**
 * 操作后控件可能消失（“打开”换成“切换过去”）或变成不可用（打开过程中）。
 * 焦点原本在这样的控件上时，挪到选中的卡片上（关掉完整报告时回到打开它的按钮），
 * 键盘用户不会突然回到页面开头
 */
function useFocusRescue(root: RefObject<HTMLDivElement | null>) {
  const before = useRef<Element | null>(null);
  // 渲染时 DOM 还没更新，这时的焦点就是操作前的位置
  if (typeof document !== 'undefined') {
    const active = document.activeElement;
    before.current = active && root.current?.contains(active) ? active : null;
  }
  useLayoutEffect(() => {
    const el = before.current;
    if (!el || !root.current) return;
    if (el.isConnected && !(el as HTMLButtonElement).disabled) return;
    // 已经移走的元素也还连着原来的父元素，看得出它在不在报告里
    root.current
      .querySelector<HTMLElement>(
        el.closest('.report') ? '.see-report' : '.alert button, .card.sel',
      )
      ?.focus({ preventScroll: true });
  });
}

/** 圆点的闪烁按真实时间对齐相位，新出现的点和已有的点一起闪 */
function Dot({ still = false }: { still?: boolean }) {
  const ref = useRef<HTMLElement>(null);
  useLayoutEffect(() => {
    if (ref.current && !still) ref.current.style.animationDelay = `-${Date.now() % 2400}ms`;
  }, [still]);
  return <i ref={ref} className="dot" style={still ? { animation: 'none' } : undefined} />;
}

function AppIcon({
  app,
  hop = false,
  small = false,
}: {
  app: DemoApp;
  hop?: boolean;
  small?: boolean;
}) {
  return (
    <span className={cls('ic', small && 'sm', app.tint, hop && 'hop')}>
      <Icon svg={appGlyphs[app.glyph]} />
    </span>
  );
}

function Tag({ app, t }: { app: DemoApp; t: T }) {
  if (app.status === 'running')
    return (
      <span className="tag run">
        <Dot />
        {t('运行中', 'Running')}
      </span>
    );
  const [tone, icon, label] =
    app.status !== 'idle'
      ? ['', icons.working, t('处理中…', 'Working…')]
      : app.runtime === 'vm'
        ? ['', icons.vm, t('虚拟 Mac', 'Virtual Mac')]
        : isSevere(app)
          ? ['warn', icons.warning, t('可能需要虚拟 Mac', 'May Need Virtual Mac')]
          : app.offline
            ? ['', icons.offline, t('本机隔离 · 不联网', 'Native Isolation · Offline')]
            : ['', icons.lock, t('本机隔离', 'Native Isolation')];
  return (
    <span className={cls('tag', tone)}>
      <Icon svg={icon} />
      {label}
    </span>
  );
}

function Empty({
  icon,
  title,
  text,
  children,
}: {
  icon: string;
  title: string;
  text: string;
  children?: ReactNode;
}) {
  return (
    <div className="empty">
      <Icon svg={icon} />
      <b>{title}</b>
      <p>{text}</p>
      {children}
    </div>
  );
}

function Segmented<V extends string>({
  label,
  value,
  options,
  disabled = false,
  onChange,
}: {
  label: string;
  value: V;
  options: readonly (readonly [V, string])[];
  disabled?: boolean;
  onChange: (value: V) => void;
}) {
  return (
    <div className="seg" role="radiogroup" aria-label={label}>
      {options.map(([option, text]) => (
        <button
          key={option}
          type="button"
          role="radio"
          aria-checked={option === value}
          className={option === value ? 'on' : undefined}
          disabled={disabled}
          onClick={() => onChange(option)}
        >
          {text}
        </button>
      ))}
    </div>
  );
}

// 新加的卡片在应用库里滚到看得见的位置；只滚应用库自己，不带着整页跳
function scrollIntoLibrary(el: HTMLElement) {
  const box = el.closest('.library');
  if (!box) return;
  const outer = box.getBoundingClientRect();
  const inner = el.getBoundingClientRect();
  if (inner.bottom > outer.bottom) box.scrollTop += inner.bottom - outer.bottom + 12;
  else if (inner.top < outer.top) box.scrollTop -= outer.top - inner.top + 12;
}

function Card({ app, s, demo, t, locale }: ViewProps & { app: DemoApp }) {
  const ref = useRef<HTMLButtonElement>(null);
  const selected = app.id === s.selected;
  const hop = s.hop?.id === app.id ? s.hop.n : 0;
  useEffect(() => {
    if (app.fresh && ref.current) scrollIntoLibrary(ref.current);
    // 只在卡片出现时滚一次
  }, []);
  return (
    <button
      ref={ref}
      type="button"
      className={cls('card', selected && 'sel', app.fresh && 'new', app.removing && 'gone')}
      aria-pressed={selected}
      onClick={() => demo.select(app.id)}
      onDoubleClick={() => {
        if (app.status === 'idle') demo.open(app.id);
        else if (app.status === 'running') demo.bringToFront(app.id);
      }}
    >
      {/* key 变化让图标重新挂载，“跳一下”的动画每次都从头播 */}
      <AppIcon key={hop} app={app} hop={hop > 0} />
      <span className="nm">{pick(locale, app.name)}</span>
      <Tag app={app} t={t} />
    </button>
  );
}

function Library(props: ViewProps) {
  const { s, demo, t } = props;
  const list = visibleApps(s);
  const query = s.query.trim();
  const total = s.apps.length;
  const running = s.apps.filter((a) => a.status === 'running').length;
  const header = (
    <>
      <h4>{s.page === 'running' ? t('运行中', 'Running') : t('全部应用', 'All Apps')}</h4>
      <div className="sub">
        {t(
          `${total} 个应用${running ? ` · ${running} 个运行中` : ''}`,
          `${total === 1 ? '1 app' : `${total} apps`}${running ? ` · ${running} running` : ''}`,
        )}
      </div>
    </>
  );
  if (!list.length && query)
    return (
      <>
        {header}
        <Empty
          icon={icons.emptySearch}
          title={t(`没有“${query}”的结果`, `No Results for “${query}”`)}
          text={t('请检查拼写或换个关键词。', 'Check the spelling or try a new search.')}
        />
      </>
    );
  if (!list.length && s.page === 'running')
    return (
      <>
        {header}
        <Empty
          icon={icons.emptyPlay}
          title={t('没有正在运行的应用', 'No Apps Running')}
          text={t(
            '在「全部应用」里双击一个应用即可打开。',
            'Double-click an app in “All Apps” to open it.',
          )}
        >
          <button type="button" className="pill" onClick={() => demo.nav('all')}>
            {t('查看全部应用', 'Show All Apps')}
          </button>
        </Empty>
      </>
    );
  return (
    <>
      {header}
      <div className="cards">
        {list.map((app) => (
          <Card key={app.id} app={app} {...props} />
        ))}
        {s.page === 'all' && !query && s.spare.length > 0 && (
          <button type="button" className="card add" onClick={demo.add}>
            <span className="plus">+</span>
            <span className="nm">{t('添加应用', 'Add App')}</span>
          </button>
        )}
      </div>
    </>
  );
}

function Inspector({ s, demo, t, locale }: ViewProps) {
  const app = s.apps.find((a) => a.id === s.selected);
  if (!app)
    return (
      <Empty
        icon={icons.cursorClick}
        title={t('未选择应用', 'No App Selected')}
        text={t(
          '单击卡片查看详情，双击打开。',
          'Click a card to see details. Double-click to open.',
        )}
      />
    );
  const locked = isLocked(app);
  const hop = s.hop?.id === app.id ? s.hop.n : 0;
  return (
    <>
      <div className="ins-a">
        <div className="head">
          <AppIcon key={hop} app={app} hop={hop > 0} />
          <div>
            <div className="ttl">{pick(locale, app.name)}</div>
            <Tag app={app} t={t} />
          </div>
        </div>
        <div className="acts">
          {app.status === 'running' ? (
            <>
              <button type="button" className="act pri" onClick={() => demo.bringToFront(app.id)}>
                <Icon svg={icons.arrowUpRight} />
                {t('切换过去', 'Switch to App')}
              </button>
              <button type="button" className="act" onClick={() => demo.quit(app.id)}>
                {t('退出', 'Quit')}
              </button>
            </>
          ) : (
            <button
              type="button"
              className="act pri wide"
              disabled={locked}
              onClick={() => demo.open(app.id)}
            >
              <Icon svg={icons.play} />
              {t('打开', 'Open')}
            </button>
          )}
        </div>
        {app.runtime === 'native' && isSevere(app) && (
          <button
            type="button"
            className="hint"
            disabled={locked}
            onClick={() => demo.setRuntime(app.id, 'vm')}
          >
            <Icon svg={icons.warning} />
            {t('软件不正常？改用虚拟 Mac 运行', 'Not working right? Run in Virtual Mac instead')}
          </button>
        )}
        <div className="ins-h">{t('运行环境', 'Runtime')}</div>
        <Segmented
          label={t('运行环境', 'Runtime')}
          value={app.runtime}
          options={[
            ['native', t('本机隔离', 'Native')],
            ['vm', t('虚拟 Mac', 'Virtual Mac')],
          ]}
          disabled={locked}
          onChange={(runtime) => demo.setRuntime(app.id, runtime)}
        />
      </div>
      <ReportSummary app={app} demo={demo} t={t} locale={locale} />
      <div className="ins-b">
        {app.runtime === 'native' && (
          <>
            <div className="ins-h">{t('网络', 'Network')}</div>
            <div className="set-row">
              {t('允许联网', 'Allow Network Access')}
              <button
                type="button"
                className="switch"
                role="switch"
                aria-checked={!app.offline}
                disabled={locked}
                onClick={() => demo.setNetwork(app.id, app.offline)}
              >
                <span className="sr-only">{t('允许联网', 'Allow Network Access')}</span>
              </button>
            </div>
            <p className="ins-note">
              {app.offline
                ? t(
                    '应用连不上任何服务器，在本机上的代理也连不上；它显示的网页也打不开，用网页做的界面会是空白。登录、同步、更新都用不了。',
                    'The app can’t reach any server, not even a proxy on this Mac. Web pages it shows won’t load either, so parts built from web pages stay blank. Signing in, syncing and updates won’t work.',
                  )
                : t(
                    '关掉后，应用连不上任何服务器，在本机上的代理也连不上。下次打开时生效。',
                    'When off, the app can’t reach any server, not even a proxy on this Mac. Takes effect the next time it opens.',
                  )}
            </p>
          </>
        )}
        <div className="ins-data">
          <div className="ins-h">{t('数据', 'Data')}</div>
          <div className="row">
            {t('应用数据', 'App Data')}
            <b>{app.size} MB</b>
          </div>
          <div className="row">
            {t('还原点', 'Restore Point')}
            <b>{app.restore ? pick(locale, app.restore) : t('无', 'None')}</b>
          </div>
        </div>
        <button
          type="button"
          className="danger"
          disabled={locked}
          onClick={() => demo.remove(app.id)}
        >
          {t('删除应用…', 'Delete App…')}
        </button>
      </div>
    </>
  );
}

/** 详情面板里的运行报告：这次（或上次）运行的概要和拦截记录，完整的在单独的面板里 */
function ReportSummary({ app, demo, t, locale }: Omit<ViewProps, 's'> & { app: DemoApp }) {
  const report = app.report;
  const trace = traceOf(app.id);
  const total = blockCount(app);
  const counted = (value: string) =>
    report?.running ? t('退出后统计', 'Counted after quitting') : value;
  const files = fileTotals(trace);
  const settings = settingsCount(trace);
  return (
    <div className="ins-r">
      <div className="ins-h">{t('运行报告', 'Run Report')}</div>
      {app.runtime === 'vm' ? (
        <p className="ins-note">
          {t(
            '在虚拟 Mac 里运行，和你的 Mac 完全分开。运行报告只记在本机隔离中的运行。',
            'Runs in the Virtual Mac, fully separate from your Mac. Run reports only cover runs in Native Isolation.',
          )}
        </p>
      ) : !report ? (
        <p className="ins-note">
          {t(
            '打开应用后，这里会记下它写了哪些文件、改了哪些设置、连了哪些服务器、启动了哪些程序，以及哪些行为被拦下，可以导出分享。',
            'Once you open the app, this records which files it writes, which settings it changes, which servers it contacts, which programs it launches and what gets blocked. You can export and share it.',
          )}
        </p>
      ) : (
        <>
          <p className="ins-note">
            {report.running
              ? t('正在运行，边运行边记录。', 'Running. Recording as it goes.')
              : t(`上次运行：${report.when[0]}`, `Last run: ${report.when[1]}`)}
          </p>
          <div className="ins-rows">
            <div className="row">
              {t('写入文件', 'Files Written')}
              <b>
                {counted(
                  t(
                    `${files.count} 个 · ${formatBytes(files.bytes)}`,
                    `${files.count} · ${formatBytes(files.bytes)}`,
                  ),
                )}
              </b>
            </div>
            <div className="row">
              {t('改动设置', 'Settings Changed')}
              <b>{counted(t(`${settings} 项`, `${settings}`))}</b>
            </div>
            <div className="row">
              {t('连接服务器', 'Servers Contacted')}
              <b>
                {report.offline
                  ? t('不联网', 'Offline')
                  : t(`${report.servers} 个`, `${report.servers}`)}
              </b>
            </div>
            <div className="row">
              {t('启动程序', 'Programs Launched')}
              <b>{t(`${report.programs} 个`, `${report.programs}`)}</b>
            </div>
          </div>
          {total > 0 && (
            <>
              <div className={cls('blocked-sum', isSevere(app) && 'warn')}>
                <Icon svg={icons.hand} />
                {report.running
                  ? t(
                      `本次已拦截 ${total} 次越界行为`,
                      total === 1
                        ? 'Blocked 1 out-of-bounds attempt this session'
                        : `Blocked ${total} out-of-bounds attempts this session`,
                    )
                  : t(
                      `拦截了 ${total} 次越界行为`,
                      total === 1
                        ? 'Blocked 1 out-of-bounds attempt'
                        : `Blocked ${total} out-of-bounds attempts`,
                    )}
              </div>
              {app.blocks.map((block) => (
                <div key={block.kind} className={cls('blocked', block.fresh && 'new')}>
                  <Icon svg={icons.blocked} />
                  <span>
                    {pick(locale, blockLabels[block.kind])}
                    {block.n > 1 ? ` ×${block.n}` : ''}
                  </span>
                </div>
              ))}
            </>
          )}
          <button type="button" className="see-report" onClick={() => demo.showReport(app.id)}>
            {t('查看完整报告…', 'View Full Report…')}
          </button>
        </>
      )}
    </div>
  );
}

function VirtualMacPage({ s, demo, t, locale }: ViewProps) {
  const vmApps = s.apps.filter((a) => a.runtime === 'vm');
  return (
    <>
      <h4>{t('虚拟 Mac', 'Virtual Mac')}</h4>
      <div className="sub">
        {t('所有需要它的应用共用一台', 'Shared by every app that needs it')}
      </div>
      <div className="vm-card">
        <span className="ic g4">
          <Icon svg={icons.vm} />
        </span>
        <div className="vm-info">
          <b>{t('虚拟 Mac', 'Virtual Mac')}</b>
          {s.vm === 'running' ? (
            <span className="tag run">
              <Dot />
              {t('运行中', 'Running')} · macOS 26
            </span>
          ) : s.vm === 'waking' ? (
            <span className="tag">
              <Icon svg={icons.working} />
              {t('正在唤醒…', 'Waking…')}
            </span>
          ) : (
            <span className="tag">
              <Dot still />
              {t('睡眠中', 'Asleep')} · macOS 26
            </span>
          )}
        </div>
        {s.vm === 'running' ? (
          <button type="button" className="act" disabled={vmApps.some(isLive)} onClick={demo.sleep}>
            {t('睡眠', 'Sleep')}
          </button>
        ) : (
          <button
            type="button"
            className="act pri"
            disabled={s.vm === 'waking'}
            onClick={demo.wake}
          >
            <Icon svg={icons.play} />
            {t('唤醒', 'Wake')}
          </button>
        )}
      </div>
      <p className="ins-note">
        {t(
          '本机隔离容纳不了的应用（需要驱动、系统服务等）在虚拟 Mac 中运行。所有这类应用共用一台，只在需要时设置。',
          'Apps that Native Isolation can’t contain (ones that need drivers, system services and so on) run in a Virtual Mac. All such apps share a single one, which is set up only when needed.',
        )}
      </p>
      <div className="ins-h">{t('使用虚拟 Mac 的应用', 'Apps in the Virtual Mac')}</div>
      {vmApps.length ? (
        vmApps.map((app) => (
          <button
            key={app.id}
            type="button"
            className="list-row"
            onClick={() => demo.reveal(app.id)}
          >
            <AppIcon app={app} small />
            <span className="nm">{pick(locale, app.name)}</span>
            <Tag app={app} t={t} />
          </button>
        ))
      ) : (
        <p className="ins-note">
          {t('还没有应用使用虚拟 Mac。', 'No apps use the Virtual Mac yet.')}
        </p>
      )}
      <div className="ins-h">{t('资源', 'Resources')}</div>
      <div className="row">
        {t('内存', 'Memory')}
        <b>6 GB</b>
      </div>
      <div className="row">
        {t('磁盘', 'Disk')}
        <b>{t('约 30 GB', 'About 30 GB')}</b>
      </div>
    </>
  );
}

const facts: readonly (readonly [string, string, string])[] = [
  [
    icons.house,
    '应用看到的是盒子里的主目录：设置、缓存、登录状态都存在 MacBox 里',
    'The app sees the box as its home folder: settings, caches and sign-ins are stored in MacBox',
  ],
  [
    icons.key,
    '每个应用一个独立钥匙串，不会写进你的「登录」钥匙串',
    'Each app gets its own keychain and never writes to your “login” keychain',
  ],
  [
    icons.hand,
    '阻止写入系统目录、注册开机自启动和后台服务、发送通知、遥控其他 App',
    'Blocks writing to system folders, registering login items and background services, sending notifications and controlling other apps',
  ],
  [
    icons.eye,
    '阻止读取邮件、信息、Safari、其他应用的数据和 SSH 密钥',
    'Blocks reading Mail, Messages, Safari, other apps’ data and SSH keys',
  ],
  [
    icons.shield,
    '运行时守卫：MacBox 打开期间，盒子里的程序一旦在沙盒外被启动，立即结束',
    'Runtime guard: while MacBox is open, any program from a box launched outside the sandbox is ended immediately',
  ],
];

function SettingsPage({
  s,
  demo,
  t,
  locale,
  onLanguage,
}: ViewProps & { onLanguage: (locale: Locale) => void }) {
  return (
    <>
      <h4>{t('设置', 'Settings')}</h4>
      <div className="sub">MacBox</div>
      <div className="group">
        <div className="group-h">{t('语言', 'Language')}</div>
        <div className="box">
          <div className="set-row">
            {t('界面语言', 'Display Language')}
            {/* 界面语言就是这个网页的语言，切换后整页一起换 */}
            <Segmented
              label={t('界面语言', 'Display Language')}
              value={locale}
              options={[
                ['zh', '简体中文'],
                ['en', 'English'],
              ]}
              onChange={onLanguage}
            />
          </div>
        </div>
      </div>
      <div className="group">
        <div className="group-h">{t('兼容性', 'Compatibility')}</div>
        <div className="box">
          <div className="set-row">
            {t('出现兼容性问题时', 'When an App Has Compatibility Issues')}
            <Segmented
              label={t('出现兼容性问题时', 'When an App Has Compatibility Issues')}
              value={s.policy}
              options={[
                ['ask', t('询问我', 'Ask Me')],
                ['auto', t('自动改用虚拟 Mac', 'Switch Automatically')],
              ]}
              onChange={demo.setPolicy}
            />
          </div>
        </div>
      </div>
      <div className="group">
        <div className="group-h">{t('新添加的应用', 'New Apps')}</div>
        <div className="box">
          <div className="set-row">
            {t('在聚焦中显示', 'Show in Spotlight')}
            <button
              type="button"
              className="switch"
              role="switch"
              aria-checked={s.spotlight}
              onClick={demo.toggleSpotlight}
            >
              <span className="sr-only">{t('在聚焦中显示', 'Show in Spotlight')}</span>
            </button>
          </div>
          <p className="ins-note">
            {t(
              '启动器放在 ~/Applications/MacBox，打开时由 MacBox 在隔离中启动真正的应用。',
              'Launchers go in ~/Applications/MacBox and open the real app in isolation through MacBox.',
            )}
          </p>
        </div>
      </div>
      <div className="group">
        <div className="group-h">{t('本机隔离会做什么', 'What Native Isolation Does')}</div>
        <ul className="facts">
          {facts.map(([icon, zh, en]) => (
            <li key={en}>
              <Icon svg={icon} />
              <span>{t(zh, en)}</span>
            </li>
          ))}
        </ul>
      </div>
    </>
  );
}

function AlertSheet({ app, demo, t, locale }: Omit<ViewProps, 's'> & { app: DemoApp }) {
  const first = useRef<HTMLButtonElement>(null);
  useEffect(() => first.current?.focus({ preventScroll: true }), []);
  const reasons = app.blocks
    .filter((b) => severeKinds.has(b.kind))
    .map((b) => pick(locale, blockLabels[b.kind]));
  return (
    <div className="sheet">
      <div
        className="alert"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="demo-alert-title"
        aria-describedby="demo-alert-text"
      >
        <AppIcon app={app} />
        <b id="demo-alert-title">
          {t(
            `「${app.name[0]}」在本机隔离中可能无法正常使用`,
            `“${app.name[1]}” may not work properly in Native Isolation`,
          )}
        </b>
        <p>
          {reasons.map((reason, i) => (
            <Fragment key={reason}>
              {i > 0 && <br />}
              {reason}
            </Fragment>
          ))}
        </p>
        <p id="demo-alert-text">
          {t(
            '改用虚拟 Mac 运行可以获得完整功能。',
            'Run it in a Virtual Mac to get full functionality.',
          )}
        </p>
        <div className="alert-btns">
          <button
            ref={first}
            type="button"
            className="act pri"
            onClick={() => demo.resolveAlert(true)}
          >
            {t('改用虚拟 Mac', 'Use Virtual Mac')}
          </button>
          <button type="button" className="act" onClick={() => demo.resolveAlert(false)}>
            {t('继续使用本机隔离', 'Keep Native Isolation')}
          </button>
        </div>
      </div>
    </div>
  );
}

type CopyState = 'idle' | 'done' | 'failed';

/** 报告里的一节：标题，下面一行行列出来 */
function ReportSection({
  icon,
  title,
  children,
}: {
  icon: string;
  title: string;
  children: ReactNode;
}) {
  return (
    <div className="rs">
      <h5>
        <Icon svg={icon} />
        {title}
      </h5>
      {children}
    </div>
  );
}

/** 一行：标题、说明（可选）、右边的数字 */
function ReportRow({
  title,
  detail,
  trailing,
  warn = false,
}: {
  title: string;
  detail?: string | null;
  trailing?: string | null;
  warn?: boolean;
}) {
  return (
    <div className="rr">
      <div>
        <span className={warn ? 'warn' : undefined}>{title}</span>
        {detail && <small>{detail}</small>}
      </div>
      {trailing && <b>{trailing}</b>}
    </div>
  );
}

/** 完整的运行报告，照着 App 的报告窗口；“拷贝文字”真的会拷贝一份 Markdown */
function ReportSheet({ app, demo, t, locale }: Omit<ViewProps, 's'> & { app: DemoApp }) {
  const done = useRef<HTMLButtonElement>(null);
  const body = useRef<HTMLDivElement>(null);
  const [copied, setCopied] = useState<CopyState>('idle');
  const copying = useRef<Fiber.Fiber<void> | null>(null);
  useEffect(() => {
    done.current?.focus({ preventScroll: true });
    // 手机上窗口比屏幕高，面板不一定在眼前
    done.current?.closest('.report')?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    return () => {
      if (copying.current) Effect.runFork(Fiber.interrupt(copying.current));
    };
  }, []);
  const report = app.report;
  if (!report) return null;

  const text = (value: string | Pair) => (typeof value === 'string' ? value : pick(locale, value));
  const trace = traceOf(app.id);
  const files = fileTotals(trace);
  const servers = seenServers(report, trace);
  const programs = seenPrograms(report, trace);
  const total = blockCount(app);
  const later = t('应用退出后统计。', 'Counted after the app quits.');
  const stats: readonly (readonly [string, string, boolean?])[] = [
    [report.running ? '–' : `${files.count}`, t('写入文件', 'Files Written')],
    [report.running ? '–' : `${settingsCount(trace)}`, t('改动设置', 'Settings Changed')],
    [report.offline ? t('断网', 'Off') : `${servers.length}`, t('连接服务器', 'Servers')],
    [`${programs.length}`, t('启动程序', 'Programs')],
    [`${total}`, t('被拦下', 'Blocked'), isSevere(app)],
  ];

  const copy = () => {
    if (copying.current) Effect.runFork(Fiber.interrupt(copying.current));
    copying.current = Effect.runFork(
      copyText(reportMarkdown(app, locale)).pipe(
        Effect.tap((ok) =>
          Effect.sync(() => {
            setCopied(ok ? 'done' : 'failed');
            // 拷贝不了就选中报告正文，用户直接按 ⌘C
            if (!ok && body.current) window.getSelection()?.selectAllChildren(body.current);
          }),
        ),
        Effect.andThen(Effect.sleep('1600 millis')),
        Effect.andThen(Effect.sync(() => setCopied('idle'))),
      ),
    );
  };

  return (
    <div className="sheet">
      <div className="report" role="dialog" aria-modal="true" aria-labelledby="demo-report-title">
        <div className="report-body" ref={body}>
          <div className="report-head">
            <AppIcon app={app} />
            <div>
              <b id="demo-report-title">
                {t(`「${app.name[0]}」运行报告`, `Run Report: ${app.name[1]}`)}
              </b>
              <span className="when">{pick(locale, report.when)}</span>
              <div className="rtags">
                <span className="rtag">
                  <Icon svg={report.offline ? icons.offline : icons.online} />
                  {report.offline ? t('不联网', 'Offline') : t('允许联网', 'Network Allowed')}
                </span>
                <span className="rtag">
                  <Icon svg={icons.download} />
                  {t('共享「下载」', 'Downloads Shared')}
                </span>
                {report.running && (
                  <span className="rtag run">
                    <Dot />
                    {t('运行中，记录中', 'Running, recording')}
                  </span>
                )}
              </div>
            </div>
          </div>
          <div className="stats">
            {stats.map(([value, label, warn]) => (
              <div key={label}>
                <b className={warn ? 'warn' : undefined}>{value}</b>
                <span>{label}</span>
              </div>
            ))}
          </div>

          <ReportSection icon={icons.reportFiles} title={t('写入的文件', 'Files Written')}>
            {report.running ? (
              <p className="rp">{later}</p>
            ) : !trace.files.length ? (
              <p className="rp">{t('没有写入文件。', 'No files were written.')}</p>
            ) : (
              <>
                <p className="rp">
                  {t(
                    `新建 ${files.created}、修改 ${files.modified}、删除 ${files.deleted}，共 ${formatBytes(files.bytes)}。路径是应用眼里的位置，实际都写进了 MacBox 的盒子（「下载」除外）。`,
                    `${files.created} created, ${files.modified} modified, ${files.deleted} deleted, ${formatBytes(files.bytes)} in total. Paths are where the app thinks it wrote; everything actually went into the MacBox box (except Downloads).`,
                  )}
                </p>
                {trace.files.map((a) => (
                  <ReportRow
                    key={a.path}
                    title={a.path}
                    detail={[
                      a.created ? t(`新建 ${a.created}`, `${a.created} created`) : null,
                      a.modified ? t(`修改 ${a.modified}`, `${a.modified} modified`) : null,
                      a.deleted ? t(`删除 ${a.deleted}`, `${a.deleted} deleted`) : null,
                    ]
                      .filter(Boolean)
                      .join(t('、', ', '))}
                    trailing={formatBytes(a.bytes)}
                  />
                ))}
              </>
            )}
          </ReportSection>

          <ReportSection icon={icons.reportSettings} title={t('修改的设置', 'Settings Changed')}>
            {report.running ? (
              <p className="rp">{later}</p>
            ) : !trace.prefs.length ? (
              <p className="rp">{t('没有改动偏好设置。', 'No preferences were changed.')}</p>
            ) : (
              <>
                <p className="rp">
                  {t(
                    '只记设置项的名字，不记内容。运行时借给系统，退出后都收回了盒子里。',
                    'Only the names of the settings are recorded, not their values. They were lent to the system while the app ran and returned to the box afterwards.',
                  )}
                </p>
                {trace.prefs.map((change) => (
                  <ReportRow
                    key={change.domain}
                    title={change.domain}
                    detail={[
                      change.added.length
                        ? t(`新增 ${change.added.length} 项：`, `${change.added.length} added: `) +
                          change.added.join(t('、', ', '))
                        : null,
                      change.changed.length
                        ? t(
                            `修改 ${change.changed.length} 项：`,
                            `${change.changed.length} changed: `,
                          ) + change.changed.join(t('、', ', '))
                        : null,
                    ]
                      .filter(Boolean)
                      .join('\n')}
                  />
                ))}
              </>
            )}
          </ReportSection>

          <ReportSection icon={icons.reportServers} title={t('连接的服务器', 'Servers Contacted')}>
            {report.offline ? (
              <p className="rp">
                {t('这次运行不允许联网。', 'Network access was blocked for this run.')}
              </p>
            ) : !servers.length ? (
              <p className="rp">
                {report.running
                  ? t('还没有看到网络连接。', 'No network connections seen yet.')
                  : t('没有看到网络连接。', 'No network connections were seen.')}
              </p>
            ) : (
              servers.map((server) => (
                <ReportRow
                  key={`${server.address}:${server.port}`}
                  title={text(serverTitle(server))}
                  detail={`${text(serverPlace(server))} · ${server.transport.toUpperCase()}`}
                />
              ))
            )}
          </ReportSection>

          <ReportSection icon={icons.reportPrograms} title={t('启动的程序', 'Programs Launched')}>
            {!programs.length ? (
              <p className="rp">{t('没有看到启动程序。', 'No program launches were seen.')}</p>
            ) : (
              programs.map((path) => {
                const note = programNote(path);
                return <ReportRow key={path} title={path} detail={note && pick(locale, note)} />;
              })
            )}
          </ReportSection>

          <ReportSection icon={icons.reportBlocked} title={t('被拦下的行为', 'Blocked Attempts')}>
            {!app.blocks.length ? (
              <p className="rp">
                {t('没有记录到被拦下的行为。', 'No blocked attempts were recorded.')}
              </p>
            ) : (
              app.blocks.map((block) => (
                <ReportRow
                  key={block.kind}
                  title={pick(locale, blockLabels[block.kind])}
                  trailing={block.n > 1 ? `×${block.n}` : null}
                  warn={severeKinds.has(block.kind)}
                />
              ))
            )}
          </ReportSection>

          <p className="report-note">{pick(locale, caveats)}</p>
        </div>
        <div className="report-bar">
          <button type="button" className={cls('act', copied === 'done' && 'ok')} onClick={copy}>
            {copied === 'done' ? (
              <>
                <Icon svg={icons.check} />
                {t('已拷贝', 'Copied')}
              </>
            ) : copied === 'failed' ? (
              t('按 ⌘C 拷贝', 'Press ⌘C to Copy')
            ) : (
              t('拷贝文字', 'Copy as Text')
            )}
          </button>
          <span className="sr-only" role="status">
            {copied === 'done' ? t('报告已拷贝到剪贴板', 'Report copied to the clipboard') : ''}
          </span>
          <button ref={done} type="button" className="act pri" onClick={demo.closeReport}>
            {t('完成', 'Done')}
          </button>
        </div>
      </div>
    </div>
  );
}

const toastIcons = { vm: icons.vm, trash: icons.trash, done: icons.done } as const;

function NavItem({
  page,
  icon,
  label,
  extra,
  s,
  demo,
}: {
  page: Page;
  icon: string;
  label: string;
  extra?: ReactNode;
  s: DemoState;
  demo: DemoStore;
}) {
  const on = s.page === page;
  return (
    <button
      type="button"
      className={cls('sb-i', on && 'on')}
      aria-current={on ? 'page' : undefined}
      onClick={() => demo.nav(page)}
    >
      <Icon svg={icon} />
      {label}
      {extra}
    </button>
  );
}

/** 首屏可以操作的 MacBox 窗口 */
export function DemoWindow({
  locale,
  onLanguage,
}: {
  locale: Locale;
  onLanguage: (locale: Locale) => void;
}) {
  const t = translate(locale);
  const [s, demo] = useDemo();
  const root = useRef<HTMLDivElement>(null);
  useFocusRescue(root);
  const view: ViewProps = { s, demo, t, locale };
  const wide = s.page === 'vm' || s.page === 'settings';
  const alertApp = s.apps.find((a) => a.id === s.alert);
  const reportApp = s.apps.find((a) => a.id === s.report);
  // 提示框、完整报告打开时，窗口其余部分暂时不能操作，键盘焦点也进不去
  const blocked = Boolean(alertApp || reportApp);
  return (
    <div
      ref={root}
      className={cls('window', 'live', wide && 'wide')}
      role="group"
      aria-label={t('可以操作的 MacBox 演示窗口', 'Interactive MacBox demo window')}
      onKeyDown={(event) => {
        if (event.key !== 'Escape') return;
        if (alertApp) demo.resolveAlert(false);
        else if (reportApp) demo.closeReport();
      }}
    >
      <aside className="sidebar" inert={blocked}>
        <span className="dots" aria-hidden="true">
          <i />
          <i />
          <i />
        </span>
        <label className="search">
          <Icon svg={icons.search} />
          <input
            type="search"
            autoComplete="off"
            spellCheck={false}
            placeholder={t('搜索应用', 'Search Apps')}
            aria-label={t('搜索应用', 'Search Apps')}
            value={s.query}
            onChange={(event) => demo.search(event.target.value)}
          />
        </label>
        <div className="sb-h">{t('应用', 'Apps')}</div>
        <NavItem
          page="all"
          icon={icons.squares}
          label={t('全部应用', 'All Apps')}
          extra={<span className="sb-n">{s.apps.length}</span>}
          s={s}
          demo={demo}
        />
        <NavItem
          page="running"
          icon={icons.playCircle}
          label={t('运行中', 'Running')}
          extra={<span className="sb-n">{s.apps.filter(isLive).length}</span>}
          s={s}
          demo={demo}
        />
        <div className="sb-h">{t('运行环境', 'Runtime')}</div>
        <NavItem
          page="vm"
          icon={icons.desktop}
          label={t('虚拟 Mac', 'Virtual Mac')}
          extra={s.vm === 'running' ? <Dot /> : null}
          s={s}
          demo={demo}
        />
        <div className="sb-h">MacBox</div>
        <NavItem
          page="settings"
          icon={icons.gear}
          label={t('设置', 'Settings')}
          s={s}
          demo={demo}
        />
      </aside>
      <div
        className="library"
        inert={blocked}
        onClick={(event) => {
          // 点应用库的空白处取消选择，和 App 一样
          if (!wide && s.selected && !(event.target as Element).closest('button, input'))
            demo.select(null);
        }}
      >
        {s.page === 'vm' ? (
          <VirtualMacPage {...view} />
        ) : s.page === 'settings' ? (
          <SettingsPage {...view} onLanguage={onLanguage} />
        ) : (
          <Library {...view} />
        )}
      </div>
      <aside className="inspector" inert={blocked}>
        {!wide && <Inspector {...view} />}
      </aside>
      {alertApp && <AlertSheet app={alertApp} demo={demo} t={t} locale={locale} />}
      {reportApp && <ReportSheet app={reportApp} demo={demo} t={t} locale={locale} />}
      {s.toast && (
        <div key={s.toast.id} className="toast" role="status">
          <Icon svg={toastIcons[s.toast.icon]} />
          {pick(locale, s.toast.text)}
        </div>
      )}
    </div>
  );
}
