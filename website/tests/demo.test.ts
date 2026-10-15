import { assert, describe, it } from '@effect/vitest';
import { Effect, Exit, Scope } from 'effect';
import { TestClock } from 'effect/testing';
import { initialState, visibleApps, type DemoState } from '../src/demo/model';
import { reportMarkdown } from '../src/demo/report';
import { createDemo } from '../src/demo/store';

const app = (state: DemoState, id: string) => {
  const found = state.apps.find((a) => a.id === id);
  assert.isDefined(found, `app ${id}`);
  return found!;
};
const blocks = (state: DemoState, id: string) =>
  app(state, id).blocks.map((b) => (b.n > 1 ? `${b.kind}×${b.n}` : b.kind));

// 演示窗口的时间线全部跑在 TestClock 上：推进多少时间，就发生多少事
describe('demo timeline', () => {
  it.effect('launches, then reports each blocked attempt in script order', () =>
    Effect.gen(function* () {
      const demo = createDemo();
      yield* demo.attach;
      demo.open('dl');
      assert.strictEqual(app(demo.getState(), 'dl').status, 'launching');
      yield* TestClock.adjust('799 millis');
      assert.strictEqual(app(demo.getState(), 'dl').status, 'launching');
      yield* TestClock.adjust('1 millis');
      assert.strictEqual(app(demo.getState(), 'dl').status, 'running');
      assert.deepStrictEqual(blocks(demo.getState(), 'dl'), []);
      yield* TestClock.adjust('1200 millis');
      assert.deepStrictEqual(blocks(demo.getState(), 'dl'), ['autostart']);
      yield* TestClock.adjust('2400 millis');
      assert.deepStrictEqual(blocks(demo.getState(), 'dl'), ['autostart', 'personal', 'notify']);
    }),
  );

  it.effect('counts repeated attempts on one line', () =>
    Effect.gen(function* () {
      const demo = createDemo();
      yield* demo.attach;
      demo.quit('drive');
      yield* TestClock.adjust('700 millis');
      demo.open('drive');
      yield* TestClock.adjust('800 millis');
      yield* TestClock.adjust('6000 millis');
      assert.deepStrictEqual(blocks(demo.getState(), 'drive'), [
        'autostart',
        'privacy×3',
        'notify',
      ]);
    }),
  );

  it.effect('quitting interrupts the rest of the launch script', () =>
    Effect.gen(function* () {
      const demo = createDemo();
      yield* demo.attach;
      demo.open('dl');
      yield* TestClock.adjust('2000 millis');
      assert.deepStrictEqual(blocks(demo.getState(), 'dl'), ['autostart']);
      demo.quit('dl');
      yield* TestClock.adjust('10 seconds');
      assert.strictEqual(app(demo.getState(), 'dl').status, 'idle');
      assert.deepStrictEqual(blocks(demo.getState(), 'dl'), ['autostart']);
    }),
  );

  it.effect('asks about the Virtual Mac after severe blocks, and Escape keeps Native', () =>
    Effect.gen(function* () {
      const demo = createDemo();
      yield* demo.attach;
      demo.setRuntime('driver', 'native');
      demo.open('driver');
      yield* TestClock.adjust('800 millis');
      yield* TestClock.adjust('3600 millis');
      demo.quit('driver');
      assert.isNull(demo.getState().alert);
      yield* TestClock.adjust('700 millis');
      assert.strictEqual(demo.getState().alert, 'driver');
      demo.resolveAlert(false);
      assert.isNull(demo.getState().alert);
      assert.strictEqual(app(demo.getState(), 'driver').runtime, 'native');
    }),
  );

  it.effect('switches automatically when the policy says so', () =>
    Effect.gen(function* () {
      const demo = createDemo();
      yield* demo.attach;
      demo.setPolicy('auto');
      demo.setRuntime('driver', 'native');
      demo.open('driver');
      yield* TestClock.adjust('5 seconds');
      demo.quit('driver');
      yield* TestClock.adjust('700 millis');
      assert.isNull(demo.getState().alert);
      assert.strictEqual(app(demo.getState(), 'driver').runtime, 'vm');
      assert.strictEqual(demo.getState().toast?.icon, 'vm');
      yield* TestClock.adjust('3200 millis');
      assert.isNull(demo.getState().toast);
    }),
  );

  it.effect('apps in the Virtual Mac wake it and are never blocked', () =>
    Effect.gen(function* () {
      const demo = createDemo();
      yield* demo.attach;
      demo.open('driver');
      assert.strictEqual(demo.getState().vm, 'waking');
      yield* TestClock.adjust('1100 millis');
      assert.strictEqual(demo.getState().vm, 'running');
      yield* TestClock.adjust('300 millis');
      assert.strictEqual(app(demo.getState(), 'driver').status, 'running');
      yield* TestClock.adjust('10 seconds');
      assert.deepStrictEqual(blocks(demo.getState(), 'driver'), []);
    }),
  );

  it.effect('deleting moves the app to the spare list and selects its neighbour', () =>
    Effect.gen(function* () {
      const demo = createDemo();
      yield* demo.attach;
      demo.remove('drive');
      assert.strictEqual(demo.getState().apps.length, 5, 'running apps cannot be deleted');
      demo.select('meet');
      demo.remove('meet');
      assert.isTrue(app(demo.getState(), 'meet').removing);
      yield* TestClock.adjust('250 millis');
      const state = demo.getState();
      assert.deepStrictEqual(
        state.apps.map((a) => a.id),
        ['drive', 'dl', 'music', 'driver'],
      );
      assert.strictEqual(state.selected, 'music');
      assert.strictEqual(state.spare[0]?.id, 'meet');
      assert.isNull(state.spare[0]?.restore ?? null);
      assert.strictEqual(state.toast?.icon, 'trash');
    }),
  );

  it.effect('adding takes the next spare app and installs it after a moment', () =>
    Effect.gen(function* () {
      const demo = createDemo();
      yield* demo.attach;
      demo.add();
      let state = demo.getState();
      assert.strictEqual(state.selected, 'shot');
      assert.strictEqual(app(state, 'shot').status, 'adding');
      assert.isTrue(app(state, 'shot').fresh);
      yield* TestClock.adjust('450 millis');
      assert.isFalse(app(demo.getState(), 'shot').fresh, 'the pop-in animation plays once');
      yield* TestClock.adjust('550 millis');
      state = demo.getState();
      assert.strictEqual(app(state, 'shot').status, 'idle');
      assert.strictEqual(state.toast?.icon, 'done');
    }),
  );

  it.effect('closing the scope stops every pending step', () =>
    Effect.gen(function* () {
      const demo = createDemo();
      const scope = yield* Scope.make();
      yield* demo.attach.pipe(Scope.provide(scope));
      demo.open('dl');
      yield* Scope.close(scope, Exit.void);
      yield* TestClock.adjust('10 seconds');
      assert.strictEqual(app(demo.getState(), 'dl').status, 'launching');
    }),
  );
});

describe('demo run report', () => {
  it.effect('records servers and programs as it runs, files and settings once it quits', () =>
    Effect.gen(function* () {
      const demo = createDemo();
      yield* demo.attach;
      assert.isNull(app(demo.getState(), 'dl').report, 'never run yet');
      demo.open('dl');
      assert.deepInclude(app(demo.getState(), 'dl').report!, {
        running: true,
        offline: false,
        servers: 0,
        programs: 0,
      });
      yield* TestClock.adjust('800 millis');
      yield* TestClock.adjust('1500 millis');
      assert.strictEqual(app(demo.getState(), 'dl').report?.servers, 1);
      yield* TestClock.adjust('10 seconds');
      assert.deepInclude(app(demo.getState(), 'dl').report!, { servers: 2, programs: 2 });
      demo.quit('dl');
      yield* TestClock.adjust('700 millis');
      assert.isFalse(app(demo.getState(), 'dl').report?.running);
    }),
  );

  it.effect('offline apps get each connection attempt blocked', () =>
    Effect.gen(function* () {
      const demo = createDemo();
      yield* demo.attach;
      demo.setNetwork('dl', false);
      demo.open('dl');
      demo.setNetwork('dl', true);
      assert.isTrue(app(demo.getState(), 'dl').offline, 'the switch is locked while running');
      yield* TestClock.adjust('800 millis');
      yield* TestClock.adjust('10 seconds');
      assert.deepStrictEqual(blocks(demo.getState(), 'dl'), [
        'autostart',
        'network×2',
        'personal',
        'notify',
      ]);
      assert.deepInclude(app(demo.getState(), 'dl').report!, { offline: true, servers: 0 });
    }),
  );

  it.effect('the Virtual Mac keeps the last Native Isolation report as it was', () =>
    Effect.gen(function* () {
      const demo = createDemo();
      yield* demo.attach;
      const before = app(demo.getState(), 'meet').report;
      demo.setRuntime('meet', 'vm');
      demo.open('meet');
      yield* TestClock.adjust('10 seconds');
      assert.strictEqual(app(demo.getState(), 'meet').report, before);
    }),
  );

  it('the full report opens only for apps that have one', () => {
    const demo = createDemo();
    demo.showReport('music');
    assert.isNull(demo.getState().report);
    demo.showReport('meet');
    assert.strictEqual(demo.getState().report, 'meet');
    demo.closeReport();
    assert.isNull(demo.getState().report);
  });

  it('copies as Markdown in the page language, marked as made up', () => {
    const meet = app(initialState(), 'meet');
    const en = reportMarkdown(meet, 'en');
    assert.include(en, '# Run report: Meetings');
    assert.include(en, 'made up');
    assert.include(en, '| ~/Library/Caches/com.example.meetings | 56 | 0 | 12 | 9.1 MB |');
    assert.include(en, '  - Added: `CameraID`, `MicrophoneID`, `LastMeetingID`');
    assert.include(en, '| This Mac (possibly a proxy) | 127.0.0.1:7890 | TCP |');
    assert.include(en, '| Read private data | 2 |');
    assert.isNull(en.match(/[\u3000-\u303f\u3400-\u9fff\uff00-\uffef]/));
    const zh = reportMarkdown(app(initialState(), 'drive'), 'zh');
    assert.include(zh, '# 「某某网盘」运行报告');
    assert.include(zh, '- 时间：今天 9:41（运行中）');
    assert.include(zh, '应用退出后统计。');
  });
});

describe('demo library filters', () => {
  it('matches Chinese and English names, case-insensitively', () => {
    const state = { ...initialState(), query: 'DRIVE' };
    assert.deepStrictEqual(
      visibleApps(state).map((a) => a.id),
      ['drive', 'driver'],
    );
    assert.deepStrictEqual(
      visibleApps({ ...state, query: '网盘' }).map((a) => a.id),
      ['drive'],
    );
  });

  it('lists launching, running and quitting apps on the Running page', () => {
    const state = initialState();
    const apps = state.apps.map((a) =>
      a.id === 'dl' ? { ...a, status: 'launching' as const } : a,
    );
    assert.deepStrictEqual(
      visibleApps({ ...state, apps, page: 'running' }).map((a) => a.id),
      ['drive', 'dl'],
    );
  });

  it('searching from the Virtual Mac or Settings page returns to the library', () => {
    const demo = createDemo();
    demo.nav('settings');
    demo.search('music');
    assert.strictEqual(demo.getState().page, 'all');
    demo.nav('running');
    demo.search('');
    assert.strictEqual(demo.getState().page, 'running');
  });
});
