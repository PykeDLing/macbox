// 图标来自 Phosphor Icons（MIT，@phosphor-icons/core 里的 SVG）。只打包实际用到的那一种粗细，
// 外层 <svg> 在这里统一写，尺寸由 CSS 决定（默认跟字号一样大）
export function Icon({ svg, className }: { svg: string; className?: string }) {
  const inner = svg.slice(svg.indexOf('>') + 1, svg.lastIndexOf('</svg>'));
  return (
    <svg
      viewBox="0 0 256 256"
      width="1em"
      height="1em"
      fill="currentColor"
      className={className}
      aria-hidden="true"
      focusable="false"
      dangerouslySetInnerHTML={{ __html: inner }}
    />
  );
}
