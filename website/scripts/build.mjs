import { spawnSync } from 'node:child_process';
import { copyFile, rm } from 'node:fs/promises';

const run = (...args) => {
  const result = spawnSync(process.execPath, args, { stdio: 'inherit', env: process.env });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
};

await rm('dist', { recursive: true, force: true });
run('node_modules/vite/bin/vite.js', 'build');
run('node_modules/typescript/bin/tsc', '--noEmit');
// GitHub Pages 找不到路径时返回根目录的 404.html
await copyFile('dist/client/404/index.html', 'dist/client/404.html');
console.log('Static website ready in dist/client/.');
