<p align="center">
  <img src="Resources/icon/AppIcon-1024.png" width="160" alt="MacBox 图标">
</p>

<h1 align="center">MacBox</h1>

<p align="center">
  把不放心的 Mac 软件装进盒子里：照常使用，删掉盒子就干干净净。<br>
  <a href="https://github.com/PykeDLing/macbox/releases/latest"><b>下载最新版</b></a> · <a href="https://pykedling.github.io/macbox/">网站</a>
</p>

---

各种网盘、下载器、国产工具软件，装上之后往往在系统里到处留东西：开机自启、后台服务、散落各处的缓存和设置。
MacBox 让它们在隔离的“盒子”里运行：有自己的窗口，在程序坞和聚焦里，和普通 App 没有两样；它写下的文件、设置和钥匙串都留在盒子里，删掉盒子就干干净净（存进「下载」和你允许它写入的文件夹的文件除外）。

## 特色

- **像普通 App 一样用**：原生窗口、程序坞、聚焦都在，沙盒的性能开销约 1.5%
- **拖进来就能装**：`.dmg`、`.app`、`.pkg`、`.zip` 都行，只有几 MB、打开后再联网下载的在线安装器也能接手；pkg 里的安装脚本不会执行
- **删掉就干净**：应用的文件、偏好设置、钥匙串条目都落在盒子里，删除盒子就一起移到废纸篓
- **看得见它做了什么**：每次运行都有运行报告：写了哪些文件、改了哪些设置、连了哪些服务器、启动了哪些程序、哪些行为被拦下；可以存储为 Markdown 或图片
- **碰不到你的私人数据**：读不到邮件、信息、Safari、其他 App 的数据，以及 SSH、GPG、AWS 这类密钥和命令行工具的凭证；也不能注册开机自启和后台服务
- **按应用断网**：关掉「允许联网」后，连本机代理、域名解析一起挡住
- **还原点**：APFS 克隆快照，几乎不占空间；可以一键回到某个状态，或者每次退出自动还原
- **虚拟 Mac 兜底**：需要驱动、系统扩展，或者自带苹果沙盒的应用，放进内置的 macOS 虚拟机里运行
- 简体中文 / English 界面

## 安装

**系统要求**：Apple Silicon（M 系列芯片）的 Mac，macOS 26 或更新版本。

1. 从 [Releases](https://github.com/PykeDLing/macbox/releases/latest) 下载 `MacBox-<版本>.dmg`，打开后把 **MacBox** 拖到「应用程序」
2. **第一次打开**：MacBox 没有经过 Apple 公证，macOS 会提示无法验证它是否包含恶意软件。点「完成」，到 **系统设置 › 隐私与安全性** 页面底部点 **仍要打开**，输入密码确认即可。也可以在终端里去掉下载标记：

   ```bash
   xattr -dr com.apple.quarantine /Applications/MacBox.app
   ```

用同目录下的 `.sha256` 文件可以校验下载是否完整：`shasum -a 256 -c MacBox-<版本>.dmg.sha256`。0.4.2 之后的版本由 GitHub Actions 构建，附带构建来源证明，装了 [GitHub CLI](https://cli.github.com) 可以确认 dmg 出自这个仓库：`gh attestation verify MacBox-<版本>.dmg --repo PykeDLing/macbox`。

> MacBox 本身不在沙盒里运行（它要替盒子里的 App 准备环境、收回设置），所以需要你信任它。不想直接运行下载的二进制文件，可以[从源码构建](#开发)。

**卸载**：在 MacBox 里删除所有应用（启动器会一起删掉）并退出，然后删除 `/Applications/MacBox.app` 和 `~/Library/Application Support/MacBox/`（以及还在的话 `~/Applications/MacBox/`）。

## 使用

- **添加**：把安装包拖进窗口，或点「添加应用」。MacBox 取出里面的 App，检查它需不需要驱动、系统服务，是不是自带苹果沙盒
- **打开**：在 MacBox 里双击，或者从聚焦打开（启动器放在 `~/Applications/MacBox`）
- **详情面板**：兼容性检查、运行报告、运行环境、联网开关、数据和还原点都在这里
- **可以写入的文件夹**：应用默认只能写盒子和「下载」。要让它存到别的文件夹或外接硬盘，在详情面板 › 文件 里添加，重新打开应用后生效
- **退出**：「退出」和 ⌘Q 一样，应用可以先问你要不要存储；几秒后还没退出，旁边才会出现「强制退出」
- **语言**：在 设置 › 语言 里切换，默认跟随系统；和 Apple 自己的 App 一样，退出并重新打开 MacBox 后生效

## 两种运行环境

| | 本机隔离（默认） | 虚拟 Mac（后备） |
| --- | --- | --- |
| 体验 | 原生窗口、程序坞、聚焦，和普通 App 一样 | 一整块独立的 macOS 桌面 |
| 性能 | 原生（沙盒开销约 1.5%） | 接近原生，默认分配 4–8 GB 内存（可调整） |
| 空间 | 只有应用本身和它的数据 | 约 30 GB，所有需要它的应用共用一台 |
| 适用 | 绝大多数应用 | 需要驱动、系统服务、系统扩展的应用，自带苹果沙盒的应用 |

虚拟 Mac 不会默认安装。添加时检查出应用需要驱动、系统扩展，或者自带苹果沙盒（App Store 上的应用、微信等，套上 MacBox 的沙盒一启动就会被系统结束），以及运行时被挡住写系统目录、安装系统服务，MacBox 会建议改用虚拟 Mac。处理方式在 设置 › 兼容性 里选（询问我，或者自动改用虚拟 Mac），也可以在详情面板里随时切换。

## 工作原理

本机隔离不是虚拟机，而是几层 macOS 自带的机制叠在一起：

- **Seatbelt 沙盒**（`sandbox-exec`，子进程自动继承）：默认禁止一切写入，只放行盒子、临时目录、「下载」和你选的文件夹；挡住读取私人数据，连接 ssh-agent、gpg-agent 这类套接字，注册登录项和后台服务，发通知，用 Apple 事件控制其他 App
- **重定向主目录**（`HOME` + `CFFIXED_USER_HOME`）：Application Support、缓存、Cookie 都落在盒子里
- **每个盒子一个钥匙串**：凭证和设备 ID 不进你的「登录」钥匙串
- **偏好设置借出再收回**：cfprefsd 代写的设置沙盒挡不住，所以启动前把这些域整体换成盒子里的内容，退出后换回；先写日志再动系统，MacBox 崩溃后下次启动按日志恢复
- **运行时守卫 + App 平时上锁**：MacBox 打开期间每 50ms 检查新进程，盒子里的程序不在沙盒中就立即结束；MacBox 没开时，盒子里的 App 没有执行权限，从程序坞、聚焦都启动不了
- **运行报告**：文件按启动前后对比，被拦下的行为和启动的程序来自系统日志（`log stream`），连接由 `nettop` 定时采样

每一项具体放行和挡住了什么、崩溃后怎么收拾，见 [docs/how-it-works.md](docs/how-it-works.md)。

## 限制

本机隔离防的是“乱写、乱留、乱读”，**不是用来关恶意软件的**：它和你共用内核和用户身份，来路可疑的软件请用虚拟 Mac。

- **有些功能用不了**：开机自启、通知、访达扩展、需要驱动的功能；App 包内的 XPC 服务由系统直接启动，会被守卫结束
- **读取只挡私人数据**：邮件、密钥这类读不到，但「文稿」「桌面」等别处读得到，其他 App 的偏好设置也读得到
- **有些东西会留在盒子外**：`/private/tmp`、`/private/var/folders` 可写；ByHost 设置和不属于这个 App 的偏好设置域（厂商的更新程序、第三方 SDK 等）直接写进你真实的 `~/Library/Preferences`，运行报告会列出新出现的，后者可以收进盒子；用 Data Protection 钥匙串的 App，条目不进盒子钥匙串
- **守卫要 MacBox 开着**：MacBox 没开时只靠「App 平时上锁」；MacBox 异常退出后，App 一直保持可执行，直到下次打开 MacBox
- **运行报告是尽力而为**：拦截记录来自系统日志，内核会限流、去重；连接是定时采样，很短的连接会漏掉，服务器名字来自反向解析
- **断网挡不住系统代办的事**：让默认浏览器打开网址、iCloud 同步、推送通知等
- **同一个应用不能两份同时运行**（两个盒子，或者盒子和本机装的那份）：它们共用一组偏好设置

完整列表见 [docs/how-it-works.md](docs/how-it-works.md#限制)。

## 开发

需要 Apple Silicon Mac、macOS 26 及以上、Swift 6.4 及以上（Xcode 27，只装 Command Line Tools 也行）。

```bash
./build.sh                                              # 构建 build/MacBox.app（./build.sh debug 为调试构建）
MACBOX_DATA_ROOT=$(mktemp -d) swift test --no-parallel  # 测试，约四分钟
./scripts/package-dmg.sh                                # 打包 dist/MacBox-<版本>.dmg 和 .sha256
```

- `build.sh` 直接调用 `swiftc` 并做带 `com.apple.security.virtualization` entitlement 的 ad-hoc 签名；`Package.swift` 给 Xcode 和 `swift test` 用。两边的编译选项要保持一致
- 测试（Swift Testing）会真实地启动沙盒进程、创建钥匙串、读系统日志、挂载 dmg、读写偏好设置，但只用临时目录和 `dev.macboxtest.` 开头的域。生命周期测试只在设置了 `MACBOX_DATA_ROOT` 时运行；必须加 `--no-parallel`，并行时按时间判断的测试会失败
- 界面文字用 String Catalog：代码里写简体中文原文（视图里 `Text("添加应用")`，别处 `String(localized: "添加应用")`），英文译文和单复数在 `Resources/Localizable.xcstrings`。`./build.sh` 会把新用到的文字同步进去，在 Xcode 里打开它补上英文；测试会检查每句都有译文
- 不碰真实数据地手动试用：`open -n build/MacBox.app --env MACBOX_DATA_ROOT=/tmp/macbox-test`
- 版本号在 `Resources/Info.plist`；`Resources/icon/make_icns.sh` 从原图生成图标；网站在 [`website/`](website/README.md)
- CI：推送和 PR 都会编译 App、跑全部测试（[ci.yml](.github/workflows/ci.yml)）
- 发布：改好版本号后推送 `v<版本>` 标签，[release.yml](.github/workflows/release.yml) 会测试、打包、生成构建来源证明，建一个 Release 草稿，补上这一版的说明后手动发布

```
Sources/MacBox/
  App/          入口、窗口、URL（macbox://open/<id>）与文件打开
  Core/         路径、文件操作、子进程（ChildProcess）、命令行、进程表
  Box/          盒子模型、导入（dmg/pkg/zip/app 取出 App）、兼容性检查、运行报告
  Isolation/    沙盒规则、盒子钥匙串、偏好设置收回、拦截记录、连接采样、守卫、运行会话、启动器
  VirtualMac/   虚拟 Mac（Virtualization.framework）
  Views/        SwiftUI 界面
Tests/          Swift Testing 测试
scripts/        打包发布
```

设计文档：[实现细节、架构要点和数据目录](docs/how-it-works.md) · [引擎锁](docs/engine-lock.md) · [可以写入的文件夹](docs/writable-folders.md)

## 许可证

[MIT](LICENSE)
