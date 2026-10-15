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
import { Effect, Exit, Scope } from 'effect';
import { Icon } from '../components/Icon';
import { icons } from '../components/icons';
import { pick, translate, type Locale } from '../lib/i18n';
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
 * 焦点原本在这样的控件上时，挪到选中的卡片上，键盘用户不会突然回到页面开头
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
    root.current
      .querySelector<HTMLElement>('.alert button, .card.sel')
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
      <div className="ins-b">
        <div className="ins-h">{t('本次已拦截', 'Blocked This Session')}</div>
        {app.blocks.length ? (
          app.blocks.map((block) => (
            <div key={block.kind} className={cls('blocked', block.fresh && 'new')}>
              <Icon svg={icons.blocked} />
              <span>
                {pick(locale, blockLabels[block.kind])}
                {block.n > 1 ? ` ×${block.n}` : ''}
              </span>
            </div>
          ))
        ) : (
          <p className="ins-note">
            {app.runtime === 'vm'
              ? t(
                  '在虚拟 Mac 里运行，和你的 Mac 完全分开。',
                  'Runs in the Virtual Mac, fully separate from your Mac.',
                )
              : isLive(app)
                ? t('暂时没有越界行为。', 'Nothing out of bounds yet.')
                : t('打开后，被挡下的行为会列在这里。', 'Open it to see what gets blocked.')}
          </p>
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
  // 提示框打开时，窗口其余部分暂时不能操作，键盘焦点也进不去
  const blocked = Boolean(alertApp);
  return (
    <div
      ref={root}
      className={cls('window', 'live', wide && 'wide')}
      role="group"
      aria-label={t('可以操作的 MacBox 演示窗口', 'Interactive MacBox demo window')}
      onKeyDown={(event) => {
        if (event.key === 'Escape' && alertApp) demo.resolveAlert(false);
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
      {s.toast && (
        <div key={s.toast.id} className="toast" role="status">
          <Icon svg={toastIcons[s.toast.icon]} />
          {pick(locale, s.toast.text)}
        </div>
      )}
    </div>
  );
}
