// 演示窗口的状态和操作。界面通过 subscribe / getState 读状态（useSyncExternalStore）；
// 需要等一会儿才发生的事（打开要时间、运行中陆续被拦截、连上服务器、提示几秒后消失）都是 Effect fiber，
// 按 key 放在一个 FiberMap 里：同一个 key 再运行会中断上一个（退出应用就中断它还没走完的启动和拦截流程），
// 作用域关闭时全部中断，页面卸载后不会再有定时器回调改状态。
import { Duration, Effect, FiberMap, type Fiber, type Scope } from 'effect';
import type { Pair } from '../lib/i18n';
import {
  initialState,
  isLocked,
  isSevere,
  type BlockKind,
  type DemoApp,
  type DemoState,
  type Page,
  type Policy,
  type Runtime,
  type Toast,
} from './model';
import { traceOf } from './report';

type Run = (key: string, effect: Effect.Effect<void>) => Fiber.Fiber<void, never>;

export interface DemoStore {
  getState(): DemoState;
  subscribe(listener: () => void): () => void;
  /** 在当前作用域里准备好运行定时流程的 FiberMap；作用域关闭时中断所有流程 */
  readonly attach: Effect.Effect<void, never, Scope.Scope>;
  nav(page: Page): void;
  select(id: string | null): void;
  /** 从虚拟 Mac 页的列表跳到应用库里的这个应用 */
  reveal(id: string): void;
  search(query: string): void;
  open(id: string): void;
  quit(id: string): void;
  bringToFront(id: string): void;
  remove(id: string): void;
  add(): void;
  setRuntime(id: string, runtime: Runtime): void;
  /** 详情面板 › 网络 ›「允许联网」 */
  setNetwork(id: string, allowed: boolean): void;
  showReport(id: string): void;
  closeReport(): void;
  wake(): void;
  sleep(): void;
  resolveAlert(useVirtualMac: boolean): void;
  setPolicy(policy: Policy): void;
  toggleSpotlight(): void;
}

// 时长和 App 里的节奏大致相当，演示时不至于等太久
export const timing = {
  launch: Duration.millis(800),
  launchInVM: Duration.millis(1400),
  blockEvery: Duration.millis(1200),
  serverEvery: Duration.millis(1500),
  programEvery: Duration.millis(2600),
  quit: Duration.millis(700),
  wake: Duration.millis(1100),
  add: Duration.millis(1000),
  removeFade: Duration.millis(250),
  toast: Duration.millis(3200),
  hop: Duration.millis(700),
  fresh: Duration.millis(450),
} as const;

export function createDemo(state: DemoState = initialState()): DemoStore {
  const listeners = new Set<() => void>();
  let run: Run | null = null;
  let toastId = 0;

  const set = (next: DemoState) => {
    state = next;
    listeners.forEach((listener) => listener());
  };
  const update = (change: (s: DemoState) => Partial<DemoState>) =>
    set({ ...state, ...change(state) });
  const find = (id: string) => state.apps.find((a) => a.id === id);
  const updateApp = (id: string, change: (a: DemoApp) => Partial<DemoApp>) =>
    update((s) => ({ apps: s.apps.map((a) => (a.id === id ? { ...a, ...change(a) } : a)) }));
  const fork = (key: string, effect: Effect.Effect<void>) => {
    run?.(key, effect);
  };
  const after = (duration: Duration.Duration, change: () => void) =>
    Effect.sleep(duration).pipe(Effect.andThen(Effect.sync(change)));

  // 刚出现的卡片和拦截条目播完动画后去掉标记，切换页面重新出现时不再重播
  const settleFresh = () =>
    fork(
      'fresh',
      after(timing.fresh, () =>
        update((s) => ({
          apps: s.apps.map((a) =>
            a.fresh || a.blocks.some((b) => b.fresh)
              ? { ...a, fresh: false, blocks: a.blocks.map((b) => ({ ...b, fresh: false })) }
              : a,
          ),
        })),
      ),
    );

  const toast = (icon: Toast['icon'], text: Pair) => {
    const id = ++toastId;
    update(() => ({ toast: { id, icon, text } }));
    fork(
      'toast',
      after(timing.toast, () => update(() => ({ toast: null }))),
    );
  };

  const addBlock = (id: string, kind: BlockKind) => {
    updateApp(id, (a) => ({
      blocks: a.blocks.some((b) => b.kind === kind)
        ? a.blocks.map((b) => (b.kind === kind ? { ...b, n: b.n + 1 } : b))
        : [...a.blocks, { kind, n: 1, fresh: true }],
    }));
    settleFresh();
  };

  const wake = () => {
    if (state.vm !== 'asleep') return;
    update(() => ({ vm: 'waking' }));
    fork(
      'vm',
      after(timing.wake, () => update(() => ({ vm: 'running' }))),
    );
  };

  // 运行报告陆续“看到”这个应用连上的服务器、启动的程序
  const see = (id: string, what: 'servers' | 'programs') =>
    updateApp(id, (a) => (a.report ? { report: { ...a.report, [what]: a.report[what] + 1 } } : {}));

  // 每隔一会儿做一件事，做完为止
  const every = <A>(interval: Duration.Duration, items: readonly A[], step: (item: A) => void) =>
    Effect.forEach(items, (item) => after(interval, () => step(item)), { discard: true });

  // 本机隔离里运行时，App 试图越界的行为一条条被挡下；同时陆续连上服务器、启动程序。
  // 不联网时连不上，每次尝试都记成被拦下的“联网”
  const launch = (app: DemoApp) =>
    Effect.gen(function* () {
      yield* Effect.sleep(app.runtime === 'vm' ? timing.launchInVM : timing.launch);
      updateApp(app.id, () => ({ status: 'running' }));
      if (app.runtime !== 'native') return;
      const trace = traceOf(app.id);
      yield* Effect.all(
        [
          every(timing.blockEvery, app.script, (kind) => addBlock(app.id, kind)),
          every(timing.serverEvery, trace.servers, () =>
            app.offline ? addBlock(app.id, 'network') : see(app.id, 'servers'),
          ),
          every(timing.programEvery, trace.programs, () => see(app.id, 'programs')),
        ],
        { concurrency: 'unbounded', discard: true },
      );
    });

  const afterQuit = (id: string) => {
    // 退出后报告才统计写了哪些文件、改了哪些设置
    updateApp(id, (a) => ({
      status: 'idle',
      report: a.report && a.runtime === 'native' ? { ...a.report, running: false } : a.report,
    }));
    const app = find(id);
    if (!app || app.runtime !== 'native' || !isSevere(app)) return;
    if (state.policy === 'auto') {
      updateApp(id, () => ({ runtime: 'vm' }));
      toast('vm', [
        '检测到兼容性问题，已按设置改用虚拟 Mac 运行。',
        'Compatibility issues were found. Switched to Virtual Mac as set.',
      ]);
    } else {
      update(() => ({ alert: id }));
    }
  };

  const removeNow = (id: string) => {
    const index = state.apps.findIndex((a) => a.id === id);
    const app = state.apps[index];
    if (!app) return;
    const apps = state.apps.filter((a) => a.id !== id);
    const next = apps[Math.min(index, apps.length - 1)];
    update((s) => ({
      apps,
      // 再加回来是个新盒子：没有报告、还原点，联网照默认打开
      spare: [
        { ...app, removing: false, blocks: [], restore: null, report: null, offline: false },
        ...s.spare,
      ],
      selected: next ? next.id : null,
    }));
    // 和 App 的删除确认一致：默认共享「下载」，存进那里的文件不在盒子里
    toast('trash', [
      `「${app.name[0]}」和它的全部数据已移到废纸篓。它存进「下载」的文件会保留。`,
      `“${app.name[1]}” and all its data were moved to the Trash. Files it saved to Downloads stay.`,
    ]);
  };

  return {
    getState: () => state,
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    attach: Effect.gen(function* () {
      const runtime: Run = yield* FiberMap.makeRuntime<never, string, never, void>();
      run = runtime;
      yield* Effect.addFinalizer(() =>
        Effect.sync(() => {
          if (run === runtime) run = null;
        }),
      );
    }),

    nav: (page) => update(() => ({ page })),
    select: (id) => update(() => ({ selected: id })),
    reveal: (id) => update(() => ({ page: 'all', query: '', selected: id })),
    search: (query) =>
      update((s) => ({
        query,
        page: s.page === 'all' || s.page === 'running' ? s.page : 'all',
      })),

    open(id) {
      const app = find(id);
      if (!app || app.status !== 'idle' || app.removing) return;
      // 在本机隔离中运行，每次开一份新报告；虚拟 Mac 里的不记
      updateApp(id, (a) =>
        a.runtime === 'native'
          ? {
              status: 'launching',
              blocks: [],
              report: {
                running: true,
                offline: a.offline,
                when: ['刚才', 'Just now'],
                servers: 0,
                programs: 0,
              },
            }
          : { status: 'launching' },
      );
      if (app.runtime === 'vm') wake();
      fork(`app:${id}`, launch(app));
    },
    quit(id) {
      if (find(id)?.status !== 'running') return;
      updateApp(id, () => ({ status: 'quitting' }));
      // 同一个 key：中断还没走完的启动和拦截流程
      fork(
        `app:${id}`,
        after(timing.quit, () => afterQuit(id)),
      );
    },
    bringToFront(id) {
      update((s) => ({ hop: { id, n: (s.hop?.n ?? 0) + 1 } }));
      fork(
        'hop',
        after(timing.hop, () => update(() => ({ hop: null }))),
      );
    },
    remove(id) {
      const app = find(id);
      if (!app || isLocked(app) || app.removing) return;
      updateApp(id, () => ({ removing: true }));
      fork(
        `app:${id}`,
        after(timing.removeFade, () => removeNow(id)),
      );
    },
    add() {
      const [app, ...spare] = state.spare;
      if (!app) return;
      update((s) => ({
        spare,
        apps: [...s.apps, { ...app, status: 'adding', fresh: true }],
        selected: app.id,
      }));
      settleFresh();
      fork(
        `app:${app.id}`,
        after(timing.add, () => {
          updateApp(app.id, () => ({ status: 'idle' }));
          toast('done', [
            `「${app.name[0]}」已安装到 MacBox。`,
            `“${app.name[1]}” was installed in MacBox.`,
          ]);
        }),
      );
    },
    setRuntime(id, runtime) {
      const app = find(id);
      if (app && !isLocked(app)) updateApp(id, () => ({ runtime }));
    },
    // 和 App 一样，运行时不能改，下次打开时生效
    setNetwork(id, allowed) {
      const app = find(id);
      if (app && !isLocked(app)) updateApp(id, () => ({ offline: !allowed }));
    },
    showReport(id) {
      if (find(id)?.report) update(() => ({ report: id }));
    },
    closeReport: () => update(() => ({ report: null })),
    wake,
    sleep: () => update(() => ({ vm: 'asleep' })),
    resolveAlert(useVirtualMac) {
      const id = state.alert;
      if (!id) return;
      if (useVirtualMac) updateApp(id, () => ({ runtime: 'vm' }));
      update(() => ({ alert: null }));
    },
    setPolicy: (policy) => update(() => ({ policy })),
    toggleSpotlight: () => update((s) => ({ spotlight: !s.spotlight })),
  };
}
