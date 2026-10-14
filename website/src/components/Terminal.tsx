import { Fragment, useEffect, useRef, useState } from 'react';
import { Effect, Fiber } from 'effect';
import { Icon } from './Icon';
import { icons } from './icons';
import { copyText } from '../lib/clipboard';
import { translate, type Locale } from '../lib/i18n';

type CopyState = 'idle' | 'done' | 'failed';

/** 终端样式的命令块；标题栏放复制按钮，命令再长也不会被按钮挡住 */
export function Terminal({ lines, locale }: { lines: readonly string[]; locale: Locale }) {
  const t = translate(locale);
  const pre = useRef<HTMLPreElement>(null);
  const [state, setState] = useState<CopyState>('idle');
  const running = useRef<Fiber.Fiber<void> | null>(null);
  useEffect(
    () => () => {
      if (running.current) Effect.runFork(Fiber.interrupt(running.current));
    },
    [],
  );

  const copy = () => {
    if (running.current) Effect.runFork(Fiber.interrupt(running.current));
    running.current = Effect.runFork(
      copyText(lines.join('\n')).pipe(
        Effect.tap((ok) =>
          Effect.sync(() => {
            setState(ok ? 'done' : 'failed');
            // 复制不了就选中命令，用户直接按 ⌘C
            if (!ok && pre.current) window.getSelection()?.selectAllChildren(pre.current);
          }),
        ),
        Effect.andThen(Effect.sleep('1600 millis')),
        Effect.andThen(Effect.sync(() => setState('idle'))),
      ),
    );
  };

  return (
    <div className="term">
      <div className="term-bar">
        <span className="dots" aria-hidden="true">
          <i />
          <i />
          <i />
        </span>
        <button type="button" className={state === 'done' ? 'copy ok' : 'copy'} onClick={copy}>
          {state === 'done' ? (
            <>
              <Icon svg={icons.check} />
              {t('已复制', 'Copied')}
            </>
          ) : state === 'failed' ? (
            t('按 ⌘C 复制', 'Press ⌘C')
          ) : (
            <>
              <Icon svg={icons.copy} />
              {t('复制', 'Copy')}
            </>
          )}
        </button>
        <span className="sr-only" role="status">
          {state === 'done' ? t('已复制到剪贴板', 'Copied to clipboard') : ''}
        </span>
      </div>
      <pre className="cmd" ref={pre}>
        {lines.map((line, i) => (
          <Fragment key={i}>
            {i > 0 && '\n'}
            <span className="p">$ </span>
            {line}
          </Fragment>
        ))}
      </pre>
    </div>
  );
}
