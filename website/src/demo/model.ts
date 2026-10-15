// 首屏演示窗口的数据。文字、状态标签和行为照着 App 做：运行报告、联网开关、兼容性提示、虚拟 Mac、删除后移到废纸篓
import type { Pair } from '../lib/i18n';

export type BlockKind =
  'autostart' | 'service' | 'system' | 'personal' | 'privacy' | 'notify' | 'control' | 'network';

export const blockLabels: Record<BlockKind, Pair> = {
  autostart: ['注册开机自启动', 'Register to open at login'],
  service: ['注册后台服务', 'Register a background service'],
  system: ['写入系统目录', 'Write to system folders'],
  personal: ['写入你的个人文件夹', 'Write to your personal folders'],
  privacy: ['读取私人数据', 'Read private data'],
  notify: ['发送通知', 'Send notifications'],
  control: ['控制其他 App', 'Control other apps'],
  network: ['联网', 'Access the network'],
};

// 和 App 里的 suggestsVirtualMac 一致：被挡下这两类，退出后建议改用虚拟 Mac
export const severeKinds: ReadonlySet<BlockKind> = new Set(['service', 'system']);

export type AppGlyph =
  'cloud' | 'download' | 'meeting' | 'music' | 'driver' | 'camera' | 'password' | 'archive';
export type Tint = 'g1' | 'g2' | 'g3' | 'g4' | 'g5';
export type Runtime = 'native' | 'vm';
/** 打开中、运行中、退出中都算“在运行”；添加、打开、退出的过程中控件不能用 */
export type AppStatus = 'idle' | 'adding' | 'launching' | 'running' | 'quitting';

export interface Block {
  kind: BlockKind;
  n: number;
  /** 刚出现的一条，播一次弹出动画 */
  fresh: boolean;
}

/**
 * 一次运行的报告。写了哪些文件、改了哪些设置要等退出后对比才知道；连了哪些服务器、启动了哪些程序
 * 边运行边记（演示里按 report.ts 里这个应用的记录依次“看到”）。被拦下的行为就是应用的 blocks
 */
export interface Report {
  running: boolean;
  /** 这次运行时关着「允许联网」 */
  offline: boolean;
  /** 什么时候运行的（演示里只写个大概） */
  when: Pair;
  /** 看到了前几个服务器、前几个程序 */
  servers: number;
  programs: number;
}

export interface DemoApp {
  id: string;
  name: Pair;
  glyph: AppGlyph;
  tint: Tint;
  /** 应用数据大小，MB */
  size: number;
  /** 在本机隔离里运行时，依次试图做、然后被挡下的事 */
  script: readonly BlockKind[];
  runtime: Runtime;
  status: AppStatus;
  /** 详情面板 › 网络 ›「允许联网」关着，下次打开时生效 */
  offline: boolean;
  /** 最近一次在本机隔离中运行的报告；没运行过时为 null */
  report: Report | null;
  blocks: Block[];
  restore: Pair | null;
  fresh: boolean;
  removing: boolean;
}

export type Page = 'all' | 'running' | 'vm' | 'settings';
export type VMState = 'asleep' | 'waking' | 'running';
export type Policy = 'ask' | 'auto';

export interface Toast {
  id: number;
  icon: 'vm' | 'trash' | 'done';
  text: Pair;
}

export interface DemoState {
  apps: DemoApp[];
  /** “添加应用”从这里取；删掉的应用也放回这里，可以再加回来 */
  spare: DemoApp[];
  page: Page;
  query: string;
  selected: string | null;
  vm: VMState;
  policy: Policy;
  spotlight: boolean;
  /** 正在提示“可能无法正常使用”的应用 */
  alert: string | null;
  /** 正在看完整运行报告的应用 */
  report: string | null;
  toast: Toast | null;
  /** 点“切换过去”时图标跳一下；n 每次加一，让动画重新播放 */
  hop: { id: string; n: number } | null;
}

function app(
  id: string,
  name: Pair,
  glyph: AppGlyph,
  tint: Tint,
  size: number,
  script: readonly BlockKind[],
  more: Partial<DemoApp> = {},
): DemoApp {
  return {
    id,
    name,
    glyph,
    tint,
    size,
    script,
    runtime: 'native',
    status: 'idle',
    offline: false,
    report: null,
    blocks: [],
    restore: null,
    fresh: false,
    removing: false,
    ...more,
  };
}

export function initialState(): DemoState {
  return {
    apps: [
      app(
        'drive',
        ['某某网盘', 'Cloud Drive'],
        'cloud',
        'g1',
        294,
        ['autostart', 'privacy', 'notify', 'privacy', 'privacy'],
        {
          status: 'running',
          restore: ['昨天', 'Yesterday'],
          report: {
            running: true,
            offline: false,
            when: ['今天 9:41', 'Today, 9:41 AM'],
            servers: 3,
            programs: 1,
          },
          blocks: [
            { kind: 'autostart', n: 1, fresh: false },
            { kind: 'notify', n: 1, fresh: false },
            { kind: 'privacy', n: 3, fresh: false },
          ],
        },
      ),
      app('dl', ['下载工具', 'Downloader'], 'download', 'g3', 128, [
        'autostart',
        'personal',
        'notify',
      ]),
      app(
        'meet',
        ['会议软件', 'Meetings'],
        'meeting',
        'g2',
        512,
        ['control', 'privacy', 'notify'],
        {
          restore: ['3 天前', '3 days ago'],
          // 上次在本机隔离里运行留下的报告
          report: {
            running: false,
            offline: false,
            when: ['3 天前 · 42 分钟', '3 days ago · 42 minutes'],
            servers: 4,
            programs: 2,
          },
          blocks: [
            { kind: 'control', n: 1, fresh: false },
            { kind: 'privacy', n: 2, fresh: false },
            { kind: 'notify', n: 1, fresh: false },
          ],
        },
      ),
      app('music', ['音乐播放器', 'Music Player'], 'music', 'g5', 86, ['notify', 'control']),
      app(
        'driver',
        ['驱动工具', 'Driver Utility'],
        'driver',
        'g4',
        42,
        ['system', 'autostart', 'service'],
        {
          runtime: 'vm',
        },
      ),
    ],
    spare: [
      app('shot', ['截图工具', 'Screen Capture'], 'camera', 'g1', 36, ['autostart', 'privacy']),
      app('keys', ['密码小工具', 'Password Helper'], 'password', 'g3', 18, ['privacy', 'control']),
      app('zip', ['压缩工具', 'Archiver'], 'archive', 'g2', 12, ['personal', 'notify']),
    ],
    page: 'all',
    query: '',
    selected: 'drive',
    vm: 'asleep',
    policy: 'ask',
    spotlight: true,
    alert: null,
    report: null,
    toast: null,
    hop: null,
  };
}

export const isLive = (a: DemoApp) =>
  a.status === 'launching' || a.status === 'running' || a.status === 'quitting';
export const isLocked = (a: DemoApp) => a.status !== 'idle';
export const isSevere = (a: DemoApp) => a.blocks.some((b) => severeKinds.has(b.kind));

/** 应用库当前要显示的应用：“运行中”页只列在运行的，搜索时按中英文名一起匹配 */
export function visibleApps(state: DemoState) {
  const q = state.query.trim().toLowerCase();
  return state.apps.filter(
    (a) =>
      (state.page !== 'running' || isLive(a)) &&
      (!q || `${a.name[0]} ${a.name[1]}`.toLowerCase().includes(q)),
  );
}
