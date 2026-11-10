import { existsSync, readFileSync } from 'node:fs';
import { assert, describe, it } from 'vitest';
import { chapterAt, filmChapters, filmSeconds, timestamp } from '../src/lib/film';

describe('film chapters', () => {
  it('finds the chapter playing at a given time', () => {
    assert.strictEqual(chapterAt(0), 0);
    assert.strictEqual(chapterAt(12.8), 0);
    // 跳到一章的开头，浏览器给的时间可能差几毫秒
    assert.strictEqual(chapterAt(12.897), 1);
    assert.strictEqual(chapterAt(30), 3);
    assert.strictEqual(chapterAt(filmSeconds), filmChapters.length - 1);
  });

  it('writes times the way the player does', () => {
    assert.strictEqual(timestamp(0), '00:00');
    assert.strictEqual(timestamp(12.9), '00:12');
    assert.strictEqual(timestamp(61), '01:01');
  });

  it('has chapters in order, each with a title in both languages', () => {
    filmChapters.forEach((chapter, i) => {
      if (i > 0) assert.isAbove(chapter.start, filmChapters[i - 1]!.start);
      assert.isBelow(chapter.start, filmSeconds);
      assert.match(chapter.title[0], /[㐀-鿿]/);
      assert.notMatch(chapter.title[1], /[㐀-鿿]/);
    });
  });
});

// 章节的时间点要和宣传片工程里的镜头长度对得上；没有 promo/ 时跳过
const theme = new URL('../../promo/src/theme.ts', import.meta.url);
describe.skipIf(!existsSync(theme))('film chapters and the promo project', () => {
  const source = existsSync(theme) ? readFileSync(theme, 'utf8') : '';
  const fps = Number(/export const FPS = (\d+)/.exec(source)?.[1]);
  const transition = Number(/export const TRANSITION = (\d+)/.exec(source)?.[1]);
  const scenes = [
    .../export const SCENES = \{([\s\S]*?)\}/.exec(source)![1]!.matchAll(/(\w+): (\d+)/g),
  ].map(([, name, frames]) => [name!, Number(frames)] as const);

  it('start where their scenes start', () => {
    assert.isAbove(scenes.length, 0);
    let frame = 0;
    const starts = new Map<string, number>();
    for (const [name, frames] of scenes) {
      starts.set(name, frame / fps);
      frame += frames - transition;
    }
    for (const chapter of filmChapters) {
      assert.closeTo(chapter.start, starts.get(chapter.scene)!, 0.06, chapter.scene);
    }
    // 片长：最后一个镜头不再和下一个交叠
    assert.strictEqual(Math.floor((frame + transition) / fps), filmSeconds);
  });
});
