// 演示窗口里的运行报告：每个应用运行一次会留下什么（虚构的，域名都用保留的 .example，地址用文档专用网段），
// 以及照着 App 的 RunReport 写的统计和导出文字
import { pick, type Locale, type Pair } from '../lib/i18n';
import { repository } from '../lib/site';
import { blockLabels, type DemoApp, type Report } from './model';

/** 写入的一处位置，路径是应用眼里的样子 */
export interface FileArea {
  path: string;
  created: number;
  modified: number;
  deleted: number;
  bytes: number;
}

/** 改动的一个偏好设置域：只有键名，没有内容 */
export interface PrefChange {
  domain: string;
  added: readonly string[];
  changed: readonly string[];
}

export interface Server {
  /** 反向解析出的名字；解析不出时为 null */
  name: string | null;
  address: string;
  port: number;
  transport: 'tcp' | 'udp' | 'quic';
}

export interface Trace {
  bundle: string;
  files: readonly FileArea[];
  prefs: readonly PrefChange[];
  /** 运行中依次看到的连接 */
  servers: readonly Server[];
  /** 运行中依次启动的程序 */
  programs: readonly string[];
}

const area = (path: string, created: number, modified: number, deleted: number, bytes: number) => ({
  path,
  created,
  modified,
  deleted,
  bytes,
});
const server = (
  name: string | null,
  address: string,
  port: number,
  transport: Server['transport'] = 'tcp',
): Server => ({ name, address, port, transport });

const traces: Record<string, Trace> = {
  drive: {
    bundle: 'com.example.clouddrive',
    files: [
      area('~/Library/Application Support/CloudDrive', 38, 12, 0, 61_200_000),
      area('~/Library/Caches/com.example.clouddrive', 104, 9, 31, 23_900_000),
      area('~/Library/WebKit/com.example.clouddrive', 17, 4, 0, 2_300_000),
      area('~/Library/HTTPStorages/com.example.clouddrive', 2, 3, 0, 148_000),
    ],
    prefs: [
      {
        domain: 'com.example.clouddrive',
        added: ['DeviceID', 'LastLoginUser', 'SyncFolderPath'],
        changed: ['LaunchCount', 'NSWindow Frame Main'],
      },
    ],
    servers: [
      server('api.drive.example', '203.0.113.10', 443, 'quic'),
      server(null, '198.51.100.24', 443),
      server('upload-03.drive.example', '203.0.113.37', 443),
      server('log.analytics.example', '203.0.113.80', 443),
      server('cdn-12.drive.example', '203.0.113.140', 443, 'quic'),
    ],
    programs: ['CloudDrive.app/Contents/MacOS/SyncHelper', '/usr/sbin/ioreg', '/usr/sbin/sysctl'],
  },
  dl: {
    bundle: 'com.example.downloader',
    files: [
      area('~/Library/Application Support/Downloader', 12, 4, 0, 3_400_000),
      area('~/Library/Caches/com.example.downloader', 9, 0, 2, 1_100_000),
    ],
    prefs: [
      {
        domain: 'com.example.downloader',
        added: ['DownloadFolder', 'MaxConnections'],
        changed: ['LastUpdateCheck'],
      },
    ],
    servers: [
      server('api.downloader.example', '203.0.113.55', 443),
      server(null, '198.51.100.7', 6881, 'udp'),
    ],
    programs: ['Downloader.app/Contents/MacOS/dl-engine', '/usr/bin/curl'],
  },
  meet: {
    bundle: 'com.example.meetings',
    files: [
      area('~/Library/Application Support/Meetings', 21, 8, 0, 14_800_000),
      area('~/Library/Caches/com.example.meetings', 56, 0, 12, 9_100_000),
      area('~/Library/Logs/Meetings', 3, 2, 0, 512_000),
    ],
    prefs: [
      {
        domain: 'com.example.meetings',
        added: ['CameraID', 'MicrophoneID', 'LastMeetingID'],
        changed: ['NSWindow Frame Main'],
      },
    ],
    servers: [
      server('zone2.meet.example', '203.0.113.91', 8801, 'udp'),
      server('api.meet.example', '203.0.113.92', 443),
      // 系统设置了代理时，应用先连本机上的代理端口
      server(null, '127.0.0.1', 7890),
      server(null, '198.51.100.61', 443, 'quic'),
    ],
    programs: ['Meetings.app/Contents/MacOS/AudioHelper', '/usr/sbin/system_profiler'],
  },
  music: {
    bundle: 'com.example.musicplayer',
    files: [
      area('~/Library/Application Support/MusicPlayer', 6, 3, 0, 820_000),
      area('~/Library/Caches/com.example.musicplayer', 212, 0, 40, 48_600_000),
    ],
    prefs: [
      {
        domain: 'com.example.musicplayer',
        added: ['LastTrack', 'Volume'],
        changed: ['EqualizerPreset'],
      },
    ],
    servers: [
      server('lyrics.music.example', '203.0.113.120', 443),
      server('img.music.example', '203.0.113.121', 443, 'quic'),
    ],
    programs: [],
  },
  driver: {
    bundle: 'com.example.driverutility',
    files: [area('~/Library/Application Support/DriverUtility', 2, 1, 0, 36_000)],
    prefs: [{ domain: 'com.example.driverutility', added: ['DeviceSerial'], changed: [] }],
    servers: [server('update.driver.example', '203.0.113.150', 443)],
    programs: ['DriverUtility.app/Contents/MacOS/InstallHelper', '/usr/sbin/ioreg'],
  },
  shot: {
    bundle: 'com.example.screencapture',
    files: [area('~/Library/Application Support/ScreenCapture', 4, 2, 0, 260_000)],
    prefs: [
      { domain: 'com.example.screencapture', added: ['SaveLocation', 'Shortcut'], changed: [] },
    ],
    servers: [server('telemetry.capture.example', '203.0.113.170', 443)],
    programs: ['/usr/bin/sw_vers'],
  },
  keys: {
    bundle: 'com.example.passwordhelper',
    files: [area('~/Library/Application Support/PasswordHelper', 3, 1, 0, 92_000)],
    prefs: [
      { domain: 'com.example.passwordhelper', added: ['VaultPath'], changed: ['LockTimeout'] },
    ],
    servers: [server('sync.passwords.example', '203.0.113.180', 443)],
    programs: ['/usr/sbin/scutil'],
  },
  zip: {
    bundle: 'com.example.archiver',
    files: [
      area('~/Library/Application Support/Archiver', 1, 1, 0, 12_000),
      area('~/Library/Caches/com.example.archiver', 5, 0, 5, 3_800_000),
    ],
    prefs: [{ domain: 'com.example.archiver', added: ['LastFolder'], changed: [] }],
    servers: [],
    programs: ['Archiver.app/Contents/Resources/unrar'],
  },
};

const nothing: Trace = {
  bundle: 'com.example.app',
  files: [],
  prefs: [],
  servers: [],
  programs: [],
};
export const traceOf = (id: string): Trace => traces[id] ?? nothing;

// ByteCountFormatter（.file）的写法：1 KB = 1000 字节，KB 取整，MB 一位小数
export function formatBytes(bytes: number) {
  if (bytes < 1000) return `${bytes} bytes`;
  if (bytes < 1_000_000) return `${Math.round(bytes / 1000)} KB`;
  if (bytes < 1_000_000_000) return `${(bytes / 1_000_000).toFixed(1)} MB`;
  return `${(bytes / 1_000_000_000).toFixed(2)} GB`;
}

export function fileTotals(trace: Trace) {
  const sum = (of: (a: FileArea) => number) => trace.files.reduce((n, a) => n + of(a), 0);
  const created = sum((a) => a.created);
  const modified = sum((a) => a.modified);
  const deleted = sum((a) => a.deleted);
  return {
    created,
    modified,
    deleted,
    count: created + modified + deleted,
    bytes: sum((a) => a.bytes),
  };
}

export const settingsCount = (trace: Trace) =>
  trace.prefs.reduce((n, p) => n + p.added.length + p.changed.length, 0);

export const blockCount = (app: DemoApp) => app.blocks.reduce((n, b) => n + b.n, 0);

/** 报告里已经看到的服务器、程序 */
export const seenServers = (report: Report, trace: Trace) =>
  report.offline ? [] : trace.servers.slice(0, report.servers);
export const seenPrograms = (report: Report, trace: Trace) =>
  trace.programs.slice(0, report.programs);

const isLoopback = (s: Server) => s.address === '127.0.0.1' || s.address === '::1';

/** 列表里显示的名字：反向解析出的名字，没有时按地址说明 */
export const serverTitle = (s: Server): string | Pair =>
  s.name ?? (isLoopback(s) ? ['本机（可能是代理）', 'This Mac (possibly a proxy)'] : s.address);

/** 跟在名字旁边的：名字已经是地址了就只写端口 */
export const serverPlace = (s: Server): string | Pair =>
  s.name === null && !isLoopback(s)
    ? [`端口 ${s.port}`, `port ${s.port}`]
    : `${s.address}:${s.port}`;

/** 这个程序能做什么（和 App 里的说明一致） */
export function programNote(path: string): Pair | null {
  if (path.startsWith('~/'))
    return [
      '应用放在主目录里的程序（下载或解压出来的）',
      'A program the app put in its home folder (downloaded or unpacked)',
    ];
  if (!path.startsWith('/')) return ['应用自己的程序', 'The app’s own program'];
  return systemNotes[path] ?? null;
}

const systemNotes: Record<string, Pair> = {
  '/usr/sbin/ioreg': [
    '读取硬件信息，可以拿到序列号、硬件 UUID',
    'Reads hardware info, which can include the serial number and hardware UUID',
  ],
  '/usr/sbin/system_profiler': [
    '读取系统和硬件的详细信息',
    'Reads detailed system and hardware info',
  ],
  '/usr/sbin/sysctl': [
    '读取系统参数（型号、处理器等）',
    'Reads system parameters (model, processor and so on)',
  ],
  '/usr/sbin/scutil': [
    '读取系统配置（电脑名称、代理、DNS）',
    'Reads system configuration (computer name, proxies, DNS)',
  ],
  '/usr/bin/sw_vers': ['读取 macOS 版本', 'Reads the macOS version'],
  '/usr/bin/curl': ['下载或上传数据', 'Downloads or uploads data'],
};

/** 报告记不全的地方（App 的 RunReport.caveats） */
export const caveats: Pair = [
  '说明：连接是定时看一眼得到的，很短的连接可能没看到；服务器名字来自反向解析，常常是云服务商的机器名；设置了代理时，经由代理的连接只显示为连到代理。启动的程序、被拦下的行为、在共享的「下载」和可以写入的文件夹里写的文件来自系统日志，系统繁忙时会漏记，这些文件也没有大小。系统共用的临时文件夹不在统计之内。',
  'Notes: connections are sampled periodically, so very short ones may be missed; server names come from reverse DNS and are often cloud providers’ machine names; with a proxy, connections through it only show up as connections to the proxy. Program launches, blocked attempts and files written to the shared Downloads folder or the folders it can write to come from the system log and can be missed when the system is busy, and those files have no sizes. Shared system temporary folders aren’t counted.',
];

/** “拷贝文字”拷贝的 Markdown，格式照着 App 的 RunReport.markdown()，开头注明是网页上的演示 */
/** 英文按单复数：“1 file written”“2 files written”（同 App 的 RunReport.summaryLine） */
const english = (count: number, one: string, many: string) =>
  `${count} ${count === 1 ? one : many}`;

export function reportMarkdown(app: DemoApp, locale: Locale) {
  const report = app.report;
  if (!report) return '';
  const zh = locale === 'zh';
  const t = (cn: string, en: string) => (zh ? cn : en);
  const text = (value: string | Pair) => (typeof value === 'string' ? value : pick(locale, value));
  const name = pick(locale, app.name);
  const trace = traceOf(app.id);
  const files = fileTotals(trace);
  const keys = (list: readonly string[]) => list.map((k) => `\`${k}\``).join(t('、', ', '));
  const servers = seenServers(report, trace);
  const programs = seenPrograms(report, trace);
  const blocked = blockCount(app);
  const lines: string[] = [];
  const add = (...more: string[]) => lines.push(...more);

  add(
    t(`# 「${name}」运行报告`, `# Run report: ${name}`),
    '',
    t(
      '> 这份报告来自 MacBox 网页上的演示，应用和数据都是虚构的。',
      '> This report comes from the demo on the MacBox website. The app and its data are made up.',
    ),
    '',
    t(
      `- 时间：${report.when[0]}${report.running ? '（运行中）' : ''}`,
      `- Time: ${report.when[1]}${report.running ? ' (running)' : ''}`,
    ),
    t(`- 应用：${name}（${trace.bundle}）`, `- App: ${name} (${trace.bundle})`),
    t(
      `- 网络：${report.offline ? '已断开' : '允许'}；「下载」文件夹：共享`,
      `- Network: ${report.offline ? 'blocked' : 'allowed'}; Downloads folder: shared`,
    ),
    t(
      `- 由 MacBox 隔离运行并记录：${repository}`,
      `- Run in isolation and recorded by MacBox: ${repository}`,
    ),
    '',
    t('**概要**：', '**Summary**: ') +
      [
        report.running
          ? null
          : t(`写入 ${files.count} 个文件`, english(files.count, 'file written', 'files written')),
        report.running
          ? null
          : t(
              `改了 ${settingsCount(trace)} 项设置`,
              english(settingsCount(trace), 'setting changed', 'settings changed'),
            ),
        report.offline
          ? t('已断网', 'offline')
          : t(
              `连接 ${servers.length} 个服务器`,
              english(servers.length, 'server contacted', 'servers contacted'),
            ),
        t(
          `启动 ${programs.length} 个程序`,
          english(programs.length, 'program launched', 'programs launched'),
        ),
        t(`拦下 ${blocked} 次`, english(blocked, 'attempt blocked', 'attempts blocked')),
      ]
        .filter(Boolean)
        .join(' · '),
  );

  add('', t('## 写入的文件', '## Files written'), '');
  if (report.running) add(t('应用退出后统计。', 'Counted after the app quits.'));
  else if (!trace.files.length) add(t('没有写入文件。', 'No files were written.'));
  else {
    add(
      t(
        `新建 ${files.created}、修改 ${files.modified}、删除 ${files.deleted}，共 ${formatBytes(files.bytes)}。路径是应用眼里的位置，实际都在 MacBox 的盒子里（「下载」除外）。`,
        `${files.created} created, ${files.modified} modified, ${files.deleted} deleted, ${formatBytes(files.bytes)} in total. Paths are where the app thinks it wrote; everything actually went into the MacBox box (except Downloads).`,
      ),
      '',
      t(
        '| 位置 | 新建 | 修改 | 删除 | 大小 |',
        '| Location | Created | Modified | Deleted | Size |',
      ),
      '| --- | ---: | ---: | ---: | ---: |',
      ...trace.files.map(
        (a) =>
          `| ${a.path} | ${a.created} | ${a.modified} | ${a.deleted} | ${formatBytes(a.bytes)} |`,
      ),
    );
  }

  add('', t('## 修改的设置', '## Settings changed'), '');
  if (report.running) add(t('应用退出后统计。', 'Counted after the app quits.'));
  else if (!trace.prefs.length) add(t('没有改动偏好设置。', 'No preferences were changed.'));
  for (const change of report.running ? [] : trace.prefs) {
    add(`- \`${change.domain}\``);
    if (change.added.length) add(t('  - 新增：', '  - Added: ') + keys(change.added));
    if (change.changed.length) add(t('  - 修改：', '  - Changed: ') + keys(change.changed));
  }

  add('', t('## 连接的服务器', '## Servers contacted'), '');
  if (report.offline) add(t('这次运行不允许联网。', 'Network access was blocked for this run.'));
  else if (!servers.length) add(t('没有看到网络连接。', 'No network connections were seen.'));
  else
    add(
      t('| 服务器 | 地址 | 协议 |', '| Server | Address | Protocol |'),
      '| --- | --- | --- |',
      ...servers.map(
        (s) =>
          `| ${text(serverTitle(s))} | ${s.address}:${s.port} | ${s.transport.toUpperCase()} |`,
      ),
    );

  add('', t('## 启动的程序', '## Programs launched'), '');
  if (!programs.length) add(t('没有看到启动程序。', 'No program launches were seen.'));
  else
    add(
      t('| 程序 | 说明 |', '| Program | Note |'),
      '| --- | --- |',
      ...programs.map((p) => `| ${p} | ${text(programNote(p) ?? '')} |`),
    );

  add('', t('## 被拦下的行为', '## Blocked attempts'), '');
  if (!app.blocks.length) add(t('没有记录到被拦下的行为。', 'No blocked attempts were recorded.'));
  else
    add(
      t('| 行为 | 次数 |', '| Attempt | Times |'),
      '| --- | ---: |',
      ...app.blocks.map((b) => `| ${pick(locale, blockLabels[b.kind])} | ${b.n} |`),
    );

  add('', '---', '', pick(locale, caveats));
  return lines.join('\n') + '\n';
}
