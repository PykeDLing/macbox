# MacBox 网站

MacBox 的产品网页，部署在 GitHub Pages：中文版在根路径，英文版在 `/en/`。

## 技术栈

- React 19 + TypeScript，TanStack Start / Router 在构建时把两个语言版本预渲染成静态 HTML
- Vite 构建；样式是普通 CSS（`src/styles/`），深色模式跟随系统
- Effect：演示窗口里的定时流程（`src/demo/store.ts`，按应用放在 FiberMap 里，退出时中断）、GitHub 最新发布的获取和 Schema 校验（`src/lib/release-fetch.ts`）、复制命令
- 图标来自 [Phosphor Icons](https://phosphoricons.com)（MIT），每个图标只打包用到的一种粗细（`src/components/icons.ts`）
- Vitest + `@effect/vitest`（演示窗口的时间线跑在 TestClock 上），Prettier 格式化

## 开发

需要 Node 26 和 pnpm 12（`npm i -g pnpm`）。

```bash
pnpm install
pnpm dev        # http://localhost:5173
pnpm test
pnpm build      # 输出到 dist/client/，构建时会做类型检查
pnpm format
```

页面上默认显示的版本号取自 `../Resources/Info.plist`，打开后再从 GitHub 取最新发布覆盖。
本地模拟 GitHub Pages 的项目路径：`BASE_PATH=/macbox pnpm build`，之后 `BASE_PATH=/macbox pnpm test` 会检查所有资源都带着这个前缀。

## 部署

推送到 `main` 且改动了 `website/`、`Resources/Info.plist` 或工作流时，`.github/workflows/pages.yml` 会检查格式、构建、测试并发布到 GitHub Pages。也可以在 Actions 页面手动运行。
仓库的 Pages 来源需要设为 **GitHub Actions**（Settings › Pages › Build and deployment › Source）。
