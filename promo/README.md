# MacBox 宣传片

用 [Remotion](https://www.remotion.dev) 写的 55 秒宣传片：1920×1080、30 fps，带一段原创配乐，中文和英文各一版。

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
npm run bgm         # 只重新生成配乐 public/bgm.wav（渲染和预览之前会自动跑）
npm run render      # out/macbox-promo-zh.mp4，约一分钟
npm run render:en   # out/macbox-promo-en.mp4
npm run site        # 两版都重新渲染，连同封面图一起放进 ../website/public/media/
node scripts/stills.mjs Promo-zh 120,372,900 0.5   # 抽几帧到 out/stills/ 检查画面
```

- 文字都在各个镜头里，`t('中文', 'English')` 两种写在一起；片子里“不放心的软件”叫「某某网盘」，不点名真实产品
- 所有动画都由帧号算出来（`tw()`、`spring()`），不要用 CSS 的 transition / animation，渲染时不会动
- 字体用的是系统自带的苹方和 SF，所以要在 macOS 上渲染；换到别的系统要先在 `src/theme.ts` 里换字体
- 网站首页放的就是这两个视频（`website/public/media/`）。改了镜头长度以后，网页上按章节跳转的时间点（`website/src/lib/film.ts`）要跟着改，网站的测试会核对
- 配乐不是素材，是 `scripts/bgm.mjs` 逐个采样算出来的（合成器、鼓、混响都在这一个文件里，随机数固定种子，每次结果一样），所以 `public/bgm.wav` 不进仓库。`node scripts/bgm.mjs --stats` 会打印各轨和各段的电平
- Remotion 对个人和小团队免费，公司使用的条件见 <https://www.remotion.dev/license>

## 配乐

氛围电子打底，副歌进 trap 的鼓组：合成器铺底、中音区的 FM 键盘动机（D4 – C5，一小节两三个音）、808 滑音低音、半拍感的拍手、带滚奏的踩镲。A 小调 / C 大调，F – Am – C – G 四小节一轮，整首约 -16 LUFS。旋律声部都留在中低音区，高频只有踩镲和拍手。

一小节正好 47 帧（约 153 BPM），第 0 小节从第 20 帧开始，这样每个镜头淡入完的那一帧都落在小节线上：

| 小节 | 镜头 | 音乐 |
| --- | --- | --- |
| 0 – 4.5 | `Problem` | 没有鼓，悬着的和弦，零零散散、音高有点飘的低音越来越多 |
| 4.5 – 8 | `Idea` | 落地一声，音归到调上，动机第一次出现；最后一小节蓄势 |
| 8 – 12 | `Add` | 鼓和 808 进来 |
| 12 – 16 | `Native` | 滑音合成器把动机连起来唱，踩镲滚奏变多 |
| 16 – 20 | `Report` | 低音区的闷音脉冲，像一条条记录 |
| 20 – 24 | `Protect` | 铺底压暗，808 更重、滑音更多 |
| 24 – 28 | `Remove` | 点下删除后鼓停，滤波跟着盒子往下扫；四个对勾各配一个往上走的音；再蓄势 |
| 28 – 31 | `Numbers` | 全部乐器 |
| 31 – | `End` | 落在 C 上，键盘把 C 和弦慢慢走完 |

改了镜头长度，这张表和 `scripts/bgm.mjs` 里的编曲要跟着重排。
