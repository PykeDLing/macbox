// 首屏演示窗口的数据。文字、状态标签和行为照着 App 做：拦截记录、兼容性提示、虚拟 Mac、删除后移到废纸篓
import type { Pair } from '../lib/i18n';

export type BlockKind =
  'autostart' | 'service' | 'system' | 'personal' | 'privacy' | 'notify' | 'control';

export const blockLabels: Record<BlockKind, Pair> = {
  autostart: ['注册开机自启动', 'Register to open at login'],
  service: ['注册后台服务', 'Register a background service'],
  system: ['写入系统目录', 'Write to system folders'],
  personal: ['写入你的个人文件夹', 'Write to your personal folders'],
  privacy: ['读取私人数据', 'Read private data'],
  notify: ['发送通知', 'Send notifications'],
  control: ['控制其他 App', 'Control other apps'],
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
