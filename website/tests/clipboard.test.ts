// @vitest-environment jsdom

import { assert, describe, it } from '@effect/vitest';
import { Effect } from 'effect';
import { afterEach, vi } from 'vitest';
import { copyText } from '../src/lib/clipboard';

const clipboard = (writeText?: (text: string) => Promise<void>) =>
  Object.defineProperty(navigator, 'clipboard', {
    value: writeText && { writeText },
    configurable: true,
  });
const execCommand = (result: boolean | 'throw') =>
  Object.defineProperty(document, 'execCommand', {
    configurable: true,
    value: vi.fn(() => {
      if (result === 'throw') throw new Error('not allowed');
      return result;
    }),
  });

afterEach(() => {
  clipboard(undefined);
  vi.restoreAllMocks();
});

describe('copy command', () => {
  it.effect('uses the Clipboard API when it works', () =>
    Effect.gen(function* () {
      const written: string[] = [];
      clipboard(async (text) => void written.push(text));
      execCommand(false);
      assert.isTrue(yield* copyText('./build.sh'));
      assert.deepStrictEqual(written, ['./build.sh']);
      assert.strictEqual(vi.mocked(document.execCommand).mock.calls.length, 0);
    }),
  );

  it.effect('falls back to a hidden selection when the API is refused, and cleans up', () =>
    Effect.gen(function* () {
      clipboard(() => Promise.reject(new Error('denied')));
      execCommand(true);
      assert.isTrue(yield* copyText('xattr -dr'));
      assert.deepStrictEqual(vi.mocked(document.execCommand).mock.calls, [['copy']]);
      assert.strictEqual(document.querySelectorAll('textarea').length, 0);
    }),
  );

  it.effect('reports failure when neither way works', () =>
    Effect.gen(function* () {
      execCommand('throw');
      assert.isFalse(yield* copyText('shasum'));
      assert.strictEqual(document.querySelectorAll('textarea').length, 0);
    }),
  );
});
