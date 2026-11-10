// 抽帧检查：node scripts/stills.mjs <composition> <frame,frame,...> [scale]
// 只打包一次，比反复跑 `remotion still` 快
import { bundle } from '@remotion/bundler';
import { renderStill, selectComposition } from '@remotion/renderer';
import { mkdirSync } from 'node:fs';
import path from 'node:path';

const [id = 'Promo-zh', frames = '0', scale = '0.5'] = process.argv.slice(2);
const serveUrl = await bundle({ entryPoint: path.resolve('src/index.ts') });
const composition = await selectComposition({ serveUrl, id });
mkdirSync('out/stills', { recursive: true });
for (const frame of frames.split(',').map(Number)) {
  const output = `out/stills/${id}-${String(frame).padStart(4, '0')}.png`;
  await renderStill({ composition, serveUrl, output, frame, scale: Number(scale) });
  console.log(output);
}
