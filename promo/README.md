# MacBox 宣传片

用 [Remotion](https://www.remotion.dev) 写的 55 秒宣传片：1920×1080、30 fps、没有声音，中文和英文各一版。

分镜在 `src/scenes/`，一个文件一个镜头，顺序和长度在 `src/theme.ts` 的 `SCENES` 里：

| 镜头 | 内容 |
| --- | --- |
| `Problem` | 装一个软件，留下一堆东西；删掉 App，它们还在 |
| `Idea` | 散落的东西收进盒子，盒子变成 MacBox |
| `Add` | 01 拖进来就装好 |
| `Native` | 02 和普通 App 没有两样（程序坞、窗口、聚焦） |
| `Report` | 03 运行报告 |
| `Protect` | 04 碰不到私人数据，按应用断网 |
| `Remove` | 05 删掉盒子，一起带走 |
| `Numbers` | ≈1.5%、50 ms、0，还原点和虚拟 Mac |
| `End` | 片尾 |

## 用法

需要 Node 26。第一次渲染时 Remotion 会自己下载 Chrome Headless Shell（约 140 MB，放在 `node_modules/.remotion/`）。

```bash
npm install
npm run studio      # 在浏览器里预览、拖时间轴
npm run render      # out/macbox-promo-zh.mp4，约一分钟
npm run render:en   # out/macbox-promo-en.mp4
npm run site        # 两版都重新渲染，连同封面图一起放进 ../website/public/media/
node scripts/stills.mjs Promo-zh 120,372,900 0.5   # 抽几帧到 out/stills/ 检查画面
```

- 文字都在各个镜头里，`t('中文', 'English')` 两种写在一起；片子里“不放心的软件”叫「某某网盘」，不点名真实产品
- 所有动画都由帧号算出来（`tw()`、`spring()`），不要用 CSS 的 transition / animation，渲染时不会动
- 字体用的是系统自带的苹方和 SF，所以要在 macOS 上渲染；换到别的系统要先在 `src/theme.ts` 里换字体
- 网站首页放的就是这两个视频（`website/public/media/`）。改了镜头长度以后，网页上按章节跳转的时间点（`website/src/lib/film.ts`）要跟着改，网站的测试会核对
- Remotion 对个人和小团队免费，公司使用的条件见 <https://www.remotion.dev/license>
