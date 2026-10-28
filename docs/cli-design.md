# MacBox 命令行（CLI）设计方案

状态：草案（2026-10-28），第 1 步（引擎锁）已实现，其余还没有。

商业模式定为“App 免费，部分高级功能付费”。App 永远免费可用，所以 CLI 可以一直依赖 App：**MacBox.app 就是引擎，CLI 只是它的客户端**。不需要拆出单独的核心库，也不需要无界面的引擎进程。

## 0. 结论

- **只有一个所有者。** 同一个数据目录同一时间只有一个 MacBox 进程管理盒子：它持有 `engine.lock`，只有它能做启动收尾、运行守卫、借出偏好设置、给 App 上锁解锁、改动盒子。
- **CLI 是客户端。** CLI 经 Unix 域套接字请 MacBox.app 做事，自己不碰盒子。MacBox 没开时，先在后台把它拉起来。
- **操作结果回给发起方。** 从 CLI 发起的操作，结果和错误回给 CLI，不在 App 里弹窗、切页面。
- **付费检查放在引擎里。** 高级功能在 App 里（也就是引擎里）检查，CLI 绕不过去，而且只有一处检查。
- 引擎锁顺带修掉一个现有隐患：两个 MacBox 进程用同一个数据目录（见 §1）。

## 1. 为什么必须只有一个所有者

现在的代码默认整台机器上只有一个 MacBox 进程。好几样关键状态只在这个进程的内存里，第二个进程看不到：

| 状态 | 在哪里 | 第二个进程会怎样 |
| --- | --- | --- |
| 运行中的会话 | `EscapeGuard` 的内存（[EscapeGuard.swift:126](../Sources/MacBox/Isolation/EscapeGuard.swift#L126)） | 它的守卫不认识第一个进程启动的 App，当成逃逸进程，50ms 内结束 |
| 启动收尾第 1 步 | `BoxStore.recoverInterruptedSessions` | 一启动就 SIGKILL 所有盒子进程：正在运行的应用被强制结束，没存的内容丢失 |
| 启动收尾第 3 步 | 同上 | 看到 `.lease.json` 就收回：正在运行的应用的设置被换回本机，它之后写的设置落进你真实的偏好设置 |
| 启动收尾第 7 步 | 同上 | 给所有 App 上锁：正在运行的应用再启动辅助程序会失败 |
| `Box.activity` | 内存 | 两边都以为盒子空闲，可以同时打开、同时还原 |
| 虚拟 Mac | `AppPaths.virtualMac` | 两个进程可以同时启动同一台虚拟机、写同一块磁盘 |

在引擎锁之前，没有任何单实例保护。LaunchServices 一般不会给同一个 bundle id 开第二个实例，但 `open -n`、直接运行 `build/MacBox.app` 里的二进制、打开另一份拷贝（比如 `~/MacBox-Backups` 里的旧版），都会开出第二个实例。

## 2. 引擎锁（已实现）

- 文件 `<AppPaths.root>/engine.lock`：`open(O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600)`，再 `flock(LOCK_EX | LOCK_NB)`，一直持有到进程结束。
  - 进程退出时（包括崩溃、被强制结束）内核自动释放，不会留下过期的锁。
  - 必须带 `O_CLOEXEC`：盒子里的程序要是继承了这个描述符，MacBox 崩溃后锁还被它们占着，下次就启动不了。
- 文件内容是拿着锁的进程（pid、App 路径、版本），只用来告诉用户是哪个 MacBox；谁是所有者只看 flock。
- `BoxStore.start()` 第一件事就是拿锁，拿到了才读盒子、启动守卫、做收尾。拿不到时什么都不碰：
  - 窗口只显示“另一个 MacBox 正在管理这些盒子”，可以切过去或者退出；
  - 收到的打开请求（聚焦里的启动器、拖到程序坞图标上的安装包）转给正在管理盒子的那个 MacBox，然后退出。两个是同一个 App 包时不转发：LaunchServices 分不清该交给哪个实例。
- 同一个进程里重复拿锁，得到的是同一把锁（测试会在一个进程里先后建好几个 `BoxStore`）。
- 锁文件建不了、打不开时（数据目录权限不对等）照旧启动，和没有锁的旧版一样，不因此让 MacBox 用不了。
- 锁跟着数据目录走：`MACBOX_DATA_ROOT` 不同，锁也不同，测试实例和真实实例照样互不影响。
- 0.4.0 及更早的版本不拿锁。所以只有两边都是新版时才互相挡得住：发版后要尽快替换 /Applications 里的那份。

## 3. 控制通道

**Unix 域套接字 `<AppPaths.root>/engine.sock`，每行一条 JSON。** 服务端在 App 里，启动收尾开始后就开始监听，请求都先等 `ready()`。

- **不用 XPC：** XPC 要一个经 launchd 登记的服务（SMAppService、LaunchAgent），系统会弹出“已添加后台项目”，登录项里也会多出一项。这和“不留后台服务”的承诺正相反，也给用户多了一个要处理的提示。
- **不用 URL scheme：** 它是单向的，拿不到结果，也没法传进度。
- 套接字跟着数据目录走，测试实例自动隔离；可以直接用 `nc -U` 调试。
- 套接字只有持锁的进程会建：建之前先删掉旧的。有锁在，不会删到别人正在用的。
- 套接字必须放在盒子写不到的地方。系统临时目录不行：`/private/var/folders` 对盒子是可写的（[SandboxProfile.swift:16](../Sources/MacBox/Isolation/SandboxProfile.swift#L16)），盒子里的 App 能删掉套接字、换成自己的，冒充引擎。
- `sun_path` 最长 104 字节。`MACBOX_DATA_ROOT` 放得太深时直接报错说明原因，测试用短一点的路径。

### 3.1 安全：盒子里够不着

盒子里的 App 和 MacBox 是同一个用户，沙盒规则又是 `(allow default)`，**默认情况下它连得上这个套接字**。控制通道能打开盒子、开关联网、删除盒子，要是从盒子里够得着，就成了逃出盒子的路。所以设四层：

1. **沙盒规则：** 加上 `(deny network-outbound (remote unix-socket (path-literal "<真实路径>/engine.sock")))`。在 Seatbelt 里，连接 Unix 套接字算 network-outbound，不算读文件，`privateReads` 挡不住它。
2. **检查对端：** 收到连接后，用 `LOCAL_PEERTOKEN` 拿到审计令牌（pid 加 pidversion，不怕 pid 被重用）。在沙盒中的（`ProcessTable.isSandboxed`）或者属于某个会话的（`EscapeGuard.session(of:)`），直接断开。这一步要拿原始的 fd，所以用 POSIX socket，不用 Network.framework。
3. **文件权限：** 数据目录 0700，套接字 0600，别的用户连不上。
4. **公证以后：** 再校验对端签名的 Team ID。现在是 ad-hoc 签名，没有 Team ID，做不了。

**已有渠道的同类问题**（按规则推断，未实测）：`~/Applications/MacBox` 里启动器的 Info.plist，盒子里的 App 读得到，从中能拿到别的盒子的 ID；再执行 `open macbox://open/<id>`，就能打开别的盒子。被打开的盒子仍在自己的沙盒里，危害小。可以考虑让 `application(_:open:)` 从 Apple 事件里取出发送方的 pid（`keySenderPIDAttr`），做同样的对端检查。

### 3.2 协议

```jsonc
// 握手：双方报版本，协议版本不兼容时 CLI 明确说出需要哪个版本的 MacBox
→ {"id":1,"method":"hello","params":{"client":"macbox-cli","version":"0.5.0","protocol":1}}
← {"id":1,"result":{"version":"0.5.0","protocol":1,"dataRoot":"…"}}

// 普通请求
→ {"id":2,"method":"box.quit","params":{"box":"3F2A…"}}
← {"id":2,"result":{}}

// 有进度、要等的请求：先陆续发事件，最后一条是结果
→ {"id":3,"method":"box.import","params":{"files":["/Users/…/x.dmg"],"open":false}}
← {"id":3,"event":"progress","data":{"code":"import.extracting","file":"x.dmg"}}
← {"id":3,"result":{"outcomes":[{"file":"x.dmg","box":"…","needsVirtualMac":[]}]}}

// 错误：稳定的代码，加上生成时语言的说明
← {"id":4,"error":{"code":"box.busy","message":"「夸克网盘」正在处理其他操作，请稍候"}}
// 高级功能
← {"id":5,"error":{"code":"pro.required","message":"…"}}
```

方法和现有代码的对应：

| 方法 | 现有代码 |
| --- | --- |
| `hello`、`engine.status` | 新增 |
| `box.list`、`box.info` | `BoxStore.boxes`、`Box.activity`、`BoxConfig` |
| `box.import` | `BoxStore.importItems` / `makeBox`（要改成返回结果，见 §5） |
| `box.open`、`box.quit`、`box.forceQuit` | `Box.open` / `quit` / `forceQuit` |
| `box.watch` | 新增：`Box.activity` 变化的事件流，回到 idle 时结束 |
| `box.report` | `RunReport.load`、`markdown()` |
| `box.set` | `Box.config` 的 didSet（自动存盘、同步启动器） |
| `box.restorePoint.create/restore/delete`、`box.clearData`、`box.delete` | `Box` 和 `BoxStore` 里同名的方法 |
| `box.adoptPreference` | `Box.adoptStrayPreference` |

引擎同时支持当前协议版本和上一个版本。

## 4. 命令清单

**指定盒子：** 用名字（完全一致，不分大小写；同名的多份就是「夸克网盘 2」），或者 ID 的前缀（至少 4 位）。对不上或不唯一时以退出码 3 结束，并列出候选。

| 命令 | 作用 | 对应 |
| --- | --- | --- |
| `macbox list [--running]` | 名字、ID 前 8 位、运行环境、状态、联网 | `box.list` |
| `macbox info <盒子>` | 配置、兼容性问题、还原点、数据大小、最近的错误 | `box.info` |
| `macbox add <文件>… [--no-open] [--no-launcher]` | 添加应用；在线安装器默认像在 App 里一样直接运行 | `box.import` |
| `macbox open <盒子> [--wait] [--background]` | 打开；`--wait` 等这次运行结束，打印概要，退出码等于主进程的退出码 | `box.open`、`box.watch` |
| `macbox quit <盒子> [--force] [--wait]` | 请求退出，像 ⌘Q；`--force` 强制结束 | `box.quit` / `forceQuit` |
| `macbox report <盒子> [--all] [--markdown]` | 最近一次运行报告；`--all` 列出存着的 20 份 | `box.report` |
| `macbox set <盒子> <项> <值>` | `network on/off`、`downloads shared/private`、`launcher on/off`、`reset-on-quit on/off`、`runtime isolated/vm`、`name` | `box.set` |
| `macbox restore-point create\|restore\|delete <盒子>` | 还原点 | `box.restorePoint.*` |
| `macbox clear-data <盒子>` | 清除数据 | `box.clearData` |
| `macbox rm <盒子>` | 删除（移到废纸篓） | `box.delete` |
| `macbox prefs adopt <盒子> <域>` | 把报告里写在盒子外的设置收进盒子 | `box.adoptPreference` |
| `macbox doctor` | 引擎状态、版本、数据目录、没收回的借出、没上锁的 App、读不出的盒子 | `engine.status` |

第一版所有命令都走引擎，只读的也一样：CLI 不用自己解析 box.json，也就不用和 App 共用那些类型。MacBox 没开时先拉起来；以后嫌慢，再让只读命令直接读磁盘（`box.json` 和报告都是原子写入的）。

**第一版不做：**
- 虚拟 Mac 的子命令。`open` 一个设成虚拟 Mac 的盒子时，照常由 App 打开虚拟 Mac 的窗口。
- `macbox run`：见 §8。

**会丢数据的命令要确认**（`rm`、`clear-data`、`restore-point restore`、`quit --force`）：在终端里交互确认；不在终端里（管道、脚本）又没加 `-y/--yes` 的，以退出码 6 拒绝。和 App 的原则一样：默认不做会丢东西的事。

**输出：** 默认是给人看的文字，语言跟 MacBox 的设置走：读 `dev.pyke.MacBox` 域的 `AppleLanguages`，因为在 CLI 进程里“当前 App”是 macbox 自己。`--json` 输出稳定的字段和代码（带 `schema` 版本号），文字只出现在 `message` 里。路径像报告里那样写成 `~/Library/…`。

**退出码：** 0 成功；1 其他错误；2 用法错误；3 找不到盒子或者不唯一；4 盒子正忙或者有冲突（在运行、在维护、偏好设置冲突）；5 引擎不可用（启动不了、正在退出、版本不兼容）；6 需要确认；7 需要 Pro。`open --wait` 返回应用主进程的退出码。

### 4.1 MacBox 没开时

用 CLI 所在的那个 MacBox.app 执行 `open -g -j`（后台、隐藏），最多等 15 秒等套接字就绪。程序坞里会出现 MacBox 图标。这正好如实反映状态：MacBox 在运行，守卫也在运行。

### 4.2 `open` 怎么把应用切到前台

从终端运行时，前台是终端。直接经套接字请引擎启动应用的话，应用的窗口多半会留在终端后面：协作式激活要求前台的 App 主动让出前台（见 `Box.bringToFront`），而终端不会让。

所以 `open` 默认走和启动器一样的路。CLI 先经套接字登记这次打开，拿到一个一次性的令牌，再执行 `/usr/bin/open "macbox://open/<id>?request=<令牌>"`。LaunchServices 把 MacBox 叫到前台，MacBox 再把前台让给应用。结果和错误（比如偏好设置冲突）按令牌经套接字回给 CLI，不在 App 里弹窗。`--background` 只走套接字，不抢前台。

## 5. App 里要改的地方

不拆核心库，只在现有代码里把“结果呈现给谁”分开：

| 现在 | 问题 | 改成 |
| --- | --- | --- |
| `importItems` 把结果写进 `importStatus` / `importError` / `virtualMacOffers`，没有返回值 | CLI 拿不到结果 | 每个文件返回一个 `ImportOutcome`（盒子 / 需要虚拟 Mac / 错误），进度经回调传出；界面照旧显示，CLI 打印 |
| `reviewCompatibility` / `suggestVirtualMac` 直接把询问排进界面的队列 | 从 CLI 添加的应用，会在 App 里弹出询问 | 按发起方区分：界面发起的照旧询问；CLI 发起的把理由放进结果，按设置自动切换的那部分不变 |
| `Box` 里 4 处 `store?.reveal(self)` | 从 CLI 打开失败时，会弹出 App 窗口 | 带上发起方：CLI 发起的不切页面，错误回给 CLI |
| `Box.lastError` / `notice` 是生成时语言的文字 | `--json` 想要代码 | 协议先原样带在 `message` 里；以后像 box.json 那样换成代码 |
| 高级功能 | 还没有 | 在 `Box` / `BoxStore` 的入口检查，界面和 CLI 都经过这里 |

这次只是把呈现分开，不顺手做架构评审时搁置的 BoxStore 拆分（路由 / 退出协调 / 启动恢复）。

**CLI 的代码：** 协议类型（请求、响应、事件，纯 `Codable`）放在一个小模块 `MacBoxProtocol` 里，App 和 CLI 共用。CLI 只依赖它，再加上 swift-argument-parser（帮助、补全、参数校验）。

**构建：** `build.sh` 现在把 `Sources/MacBox` 下的所有文件交给一次 `swiftc`。多了 `MacBoxProtocol` 模块和 CLI 之后，改用 `swift build -c release`（Package.swift 里已经有同样的编译选项），再组装 .app。CLI 放进 `MacBox.app/Contents/Helpers/macbox`，和 App 一起签名。装进 PATH 有两种办法：在设置里加一个“安装命令行工具…”，建 `/usr/local/bin/macbox` 链接（要管理员密码）；或者以后的 Homebrew cask 用 `binary` 字段链接。改用 `swift build` 之后，要核对产物和签名与现在一致。

## 6. 测试

- **引擎锁（已有）：** 另一个进程拿着锁时拿不到，并读出是谁拿着；那个进程被 SIGKILL 后马上能拿到；同一个进程重复拿到的是同一把锁；描述符不会被子进程继承；`BoxStore` 拿不到锁时不读盒子、不做收尾，盒子里正在运行的程序不会被结束。
- **控制通道：** 在 `MACBOX_DATA_ROOT` 下启动引擎，用协议跑完 add → open --wait → quit → rm 的全流程，用 TestStub 当应用。
- **安全：** 用盒子的规则经 `sandbox-exec` 启动一个程序去连套接字，应该被拒（规则这一层）；去掉那条规则再试，对端检查也要拒（第二层）。
- **CLI 端到端：** 用真正的 `macbox` 二进制对测试数据目录运行；不在终端里时，会丢数据的命令没加 `--yes` 返回 6。
- 测试仍然用 `--no-parallel`；真实界面用 computer-use 驱动测试实例。

## 7. 步骤

1. ✅ `EngineLock` 和 App 启动时拿锁，第二个实例转发打开请求后退出。
2. 让操作结果回给发起方（§5 的前三行）。界面行为不变。
3. 套接字服务、协议、§3.1 的四层安全措施。
4. `macbox` CLI 的第一批命令：`list`、`info`、`open`、`quit`、`add`。到这里就有第一个能用的版本了。
5. 其余命令和 `doctor`。
6. 打包：放进 Helpers、加“安装命令行工具”、更新 README。

## 8. 待定

- **`macbox run -- <命令>`：在盒子里运行命令行程序**（来路不明的安装脚本、AI 代理）。引擎已经支持主程序不是 App 的情况（`IsolatedSession.terminate` 会给命令行程序的整个进程组发 SIGTERM）。还缺三样：
  - 终端输入输出：CLI 用 `SCM_RIGHTS` 把自己的 stdin、stdout、stderr 传给引擎，引擎用它们启动程序；
  - 把 Ctrl-C 等信号转发过去；
  - 一种没有 .app 的盒子：没有 App 文件夹、没有启动器、不用上锁。

  这是一个新的使用场景，要单独定范围。
- **哪些功能算高级功能：** 虚拟 Mac、还原点和退出时自动还原、报告导出都是候选。
- **公证：** 是收费的前提，也是 §3.1 里校验 Team ID 的前提。
- **`macbox://` 的来源检查**（§3.1 末尾）。
