import { Effect } from 'effect';

// 剪贴板 API 不可用（非 HTTPS、部分 App 内置浏览器）或被拒绝时的退路
const copyWithSelection = (text: string) =>
  Effect.sync(() => {
    // 选中文字要先把焦点给临时的 textarea，拷完还给原来的按钮，键盘操作（比如 Esc 关掉报告）才接得上
    const focused = document.activeElement;
    const area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.position = 'fixed';
    area.style.opacity = '0';
    document.body.appendChild(area);
    area.select();
    try {
      return document.execCommand('copy');
    } catch {
      return false;
    } finally {
      area.remove();
      if (focused instanceof HTMLElement) focused.focus({ preventScroll: true });
    }
  });

/**
 * 复制文字，成功与否用 true / false 表示：先用剪贴板 API，不行再用 execCommand。
 * 两种都失败时由调用方选中文字，让用户自己按 ⌘C
 */
export const copyText = (text: string) =>
  Effect.tryPromise(() => {
    if (!navigator.clipboard?.writeText) throw new Error('Clipboard API unavailable');
    return navigator.clipboard.writeText(text);
  }).pipe(
    Effect.as(true),
    Effect.catch(() => copyWithSelection(text)),
  );
