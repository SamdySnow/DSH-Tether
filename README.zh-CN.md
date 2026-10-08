# Tether

[English](README.md) · 简体中文

一个为 **DeepSeek Harness** CLI 打造的轻量原生 macOS 伴侣应用。它会替你启动
`npx @deepseek-ai/dsh web`，把服务的终端输出显示在一个真正的窗口里，并在右上角常驻
一个菜单栏图标 —— 想停止服务时不必再去翻终端。

*Tether* —— 拴住某物的那根线，也是 harness（挽具）一词的组成部分。这个应用把 DSH
服务拴在菜单栏上。

目标平台为 **macOS 27**，并使用了该系统中真正新增的 API（已对照 macOS 27.0 SDK
验证 —— 见 [macOS 27 新特性](#macos-27-新特性)）。

## 功能一览

| 需求 | 实现位置 |
|---|---|
| 启动时自动拉起服务 | `AppModel.performInitialStartIfNeeded()`，由控制台窗口的 `.task` 触发 |
| 显示后台终端的桌面窗口 | `Views/ConsoleView.swift` |
| 菜单栏图标、点击展开、一键停止 | `Views/StatusMenu.swift`（`MenuBarExtra`） |
| 自定义端口 | `SettingsStore.port`，可在工具栏和「设置」中编辑 |
| 在「设置」中更换应用图标 | `Core/IconManager.swift` + `IconSettingsPane` |
| 随包携带的应用图标 | 由 `Scripts/make-icon.swift` 从 `Sources/bitmap/` 生成 |

![icon](Resources/AppIcon.icns)

## 应用图标

包内图标是**生成产物**，不纳入版本控制。`Scripts/make-icon.swift` 把源位图渲染成
`.iconset`，再由 `iconutil` 打包为 `Resources/AppIcon.icns`。只要相关文件有变化，
`Scripts/build-app.sh` 都会重新生成它，因此美术资源始终是唯一的真实来源。

### 源图片是自动发现的，不是硬编码的

优先级顺序：

1. `Resources/icon.png` —— 直接提供的、已完成的 1024×1024 图标。
2. `Sources/bitmap/` 中的任意图片（`.png`、`.PNG`、`.jpg`、`.jpeg`、`.heic`、
   `.tif`、`.tiff`、`.bmp`）。
3. `ICON_SOURCE=/path/to/image.png` 会覆盖前两者。

这是有意为之。该路径曾被硬编码为 `IMG_2124.PNG`；当美术资源换成 `IMG_2,124.png`
后，脚本什么都没找到却默不作声，继续打包旧图标 —— 从现象上看，这更像「图标不对」
而不是「构建没跑起来」。重新生成也会在**源文件名**变化时触发（记录在
`Resources/.icon-source` 中），而源文件缺失时会打印警告，而不是被静默跳过。构建过程
始终会输出 `Generating AppIcon.icns from <file>` 或 `Icon up to date (<file>)`。

### macOS **不会**替你圆角化应用图标

这是实测结论，不是假设。提取 Apple 自家 `Calculator.app` 的图标并读取其原始像素：

```
Calculator 256   corner(0,0) alpha=0   edge-middle alpha=0    transparent 33.01%
```

四个角在**文件里就是透明的**，也就是说 Apple 把圆角形状烘焙进了美术资源本身。因此
一张方形、满幅的图片在 Dock 里会渲染成一个硬邦邦的方块，在 macOS 上显得格格不入。
生成器会自行应用这个形状。

把随包图标与 Apple 的图标按同样指标比较：

| | 角落 alpha | 边中 alpha | 透明占比 |
|---|---|---|---|
| 随包图标（`full`） | 0（圆角） | 255（填满） | 4.11% |
| Apple Calculator | 0（圆角） | 0（内缩） | 33.01% |

两者都带圆角，印证了形状必须存在于文件中。差别在于覆盖范围：本应用让美术填满图标，
而 Apple 的美术是内缩的、自带留白。想贴近 Apple 的比例，用
`ICON_GEOMETRY=inset`。

### 裁剪

**裁剪默认开启**，它会去掉源图四周的透明边框，让*可见*的美术填满图标。对于不透明、
边到边的图片，这一步是无操作。若美术本就该带着自己的留白悬浮，用 `ICON_TRIM=0` 关闭。

如果源图已经自带 macOS 风格的圆角并留有透明外缘（即常规的 macOS 图标导出），请使用
`ICON_TRIM=0 ICON_GEOMETRY=sharp`：裁剪会先切到美术边界、再重新圆角，结果会变成
双重圆角。

### 几何

```sh
ICON_GEOMETRY=full  ./Scripts/build-app.sh   # default: artwork fills the icon
ICON_GEOMETRY=inset ./Scripts/build-app.sh   # Apple's stock layout (824/1024, transparent margin)
ICON_GEOMETRY=sharp ./Scripts/build-app.sh   # fills the icon, square corners

ICON_TRIM=0         ./Scripts/build-app.sh   # keep the source's transparent border
ICON_SOURCE=/x.png  ./Scripts/build-app.sh   # use a specific source
```

圆角按 Apple 的 squircle 比例（185.4 / 824，取自标准图标几何）计算，让结果读起来像
macOS 图标，而不是贴上去的方块。

非正方形的源图会等比缩放至填满并居中裁剪，绝不会被压扁。

Finder 按 bundle 路径缓存图标，所以如果旧图标不消失，执行 `killall Finder`。注意
macOS 在屏幕上绘制应用图标时会额外加上自己的展示内边距，因此满幅图标在 Dock 和
Finder 中依然会看起来稍微内缩；那点间距来自系统，不是文件本身。

### 运行时更换图标

`设置 → 应用图标` 可以更改 Dock 和应用切换器中的图标，而不触碰 bundle。macOS 不会
持久化这个覆盖，因此该选择以安全作用域书签（security-scoped bookmark）保存，并在每
次启动时重新应用 —— `AppModel.bootstrap()` 调用 `IconManager.applyStoredIcon()`
正是出于这个原因。

## 构建

```sh
./Scripts/build-app.sh          # produces dist/Tether.app
open dist/Tether.app
```

只构建、不打包：

```sh
swift build
```

### 重要：请使用 Xcode 的工具链

`Scripts/build-app.sh` 会自动把 `DEVELOPER_DIR` 指向 Xcode。这不是装点门面 —— 而是
**必须的**：

> SwiftUI 宏插件（`libSwiftUIMacros.dylib`）随 Xcode 分发，*不*包含在裸的
> Command Line Tools 中。仅用 CLT 构建会失败并报
> `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
> for macro 'State()'`。

如果你手动构建并遇到该错误，给命令加上前缀：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

## 服务是如何启动的

应用直接运行 npm CLI 的 JavaScript 入口，而不是依赖 `npx` 这个 shell 垫片：

```sh
/usr/local/bin/node \
  /usr/local/lib/node_modules/npm/bin/npx-cli.js \
  --yes --package=@deepseek-ai/dsh@latest -- dsh web --port 8787
```

这里有三个细节很重要：

1. **`--package=<spec> --`** 让参数路由变得毫无歧义，`--port` 不会被误读为 npm 自身
   的选项。
2. **`--port` 属于 web 应用，不属于启动器。** 按 DSH 的 README，`dsh --profile web
   --port 8080` 能生效，是因为启动器会把所有它不认识的参数交给已启动的 profile。
3. **`node <npx-cli.js>`** 既避免依赖 `npx` 垫片本身可执行，也绕开了
   `#!/usr/bin/env node` 在 Finder 启动的 app 所继承的 `PATH` 中解析不到的问题。

### PATH 与 Node 发现

从 Finder 启动的 GUI app 几乎不会从登录 shell 继承任何东西，因此即使装好了 `node`
通常也看不见。`ExecutionTargetResolver` 会直接搜索 Homebrew、`/usr/local`、Volta、
fnm、asdf 和 nvm 的常见位置。可以用 `DSH_HARNESS_NODE` 覆盖：

```sh
DSH_HARNESS_NODE=/path/to/node open dist/Tether.app
```

### 停止服务

`npx` 意味着你生成的进程只是整条进程链的根。只对根发信号，真正的服务器仍会占着端口，
所以 `ProcessTree` 通过 `ps` 遍历所有后代并整棵树发信号 —— 先 `SIGTERM`，8 秒宽限期
后再 `SIGKILL`。停止之后，应用会等到套接字真正释放才报告空闲状态，这样立刻重启不会
撞上端口检查。

用 **Quit and Stop Service** 退出时会先停掉整棵进程树，因此不会留下孤儿服务器。

#### 如果应用被强行杀死

强制退出、崩溃或 `kill -9` 都不会给应用清理的机会，DSH 进程树会被重新挂到
`launchd` 之下继续运行并继续占用端口。这无法在进程内避免，所以应用绕开了它：

- 启动时把子进程的 pid 和命令行记入 `UserDefaults`。
- 下次启动时检查该 pid，如果它确实是孤儿，就终止它。

在发出任何信号之前必须同时满足两道校验，因为进程 id 会被回收，误杀一个无关进程远比
泄漏一个进程糟糕：

1. **是孤儿** —— 该进程必须已被重新托管（`ppid == 1`）。如果它仍有存活的父进程，说明
   它属于某个正在运行的应用，不该由我们收割。
2. **形态相符** —— 它的命令行必须看起来是针对所记录端口的 DSH web 启动。

记录的命令行无法逐字比对，因为 npm 的 exec 层会重写子进程的 argv：进程自报为
`npm exec dsh web --port <n>`，而不是最初启动的 `node …/npx-cli.js …` 形式。校验因此
基于形态加端口。成功收割会在控制台报告：

```
[app] terminating orphaned DSH from a previous run (pid 11395)
```

#### 释放服务器仍占用的端口

终止记录的 pid 并不总能释放端口：真正的 `dsh web` 服务器可能位于该 pid 所辖的进程树
之外，于是仍有东西在监听。与其报告一个用户无从下手的冲突，应用选择自己释放端口 ——
但**仅当所有监听者看起来都是 DSH**：

```
[app] port 8789 still held by 1 leftover DSH process(es); releasing
```

如果任何监听者不是 DSH，就不会发出任何信号，应用会如实说明：

```
[app] port 8789 is held by a non-DSH process; leaving it alone
```

这个区分很重要，因为你可能有意在自己的终端里跑着 `dsh web`，而误杀一个碰巧占用该
端口的无关工具，远比报告冲突糟糕。

#### 干净退出不算失败

如果服务器以状态码 0 退出 —— 被外部停止，或收到了它能处理的信号 —— 应用报告
`Stopped`，而不是 `Failed`。只有非零退出码或致命信号才被视为错误。

## 重命名与迁移

这个应用此前叫 `DSHHarness`，bundle identifier 为 `dev.deepseek.dshharness`。它有两处
问题：该 identifier 声明了一个本项目并不拥有的域名，读起来像是 DeepSeek 的官方产品；
而数据文件夹名被硬编码在四个不同的地方。

现在应用名为 `Tether`（`dev.tether.dsh`）。任何改名都会在用户背后搬动数据，因此两项
迁移都是自动的，且只运行一次：

| 项目 | 位置 | 为什么重要 |
|---|---|---|
| 数据文件夹 | `AppPaths.migrateLegacyDataIfNeeded()` 把 `Application Support/DSHHarness` 移到 `…/Tether` | 热装环境下 npm 缓存超过 1 GB；把它遗落会迫使完整重新下载 |
| 偏好设置 | `PreferencesMigration.migrateIfNeeded()` 从旧 `UserDefaults` 域复制自有键 | 新 bundle identifier 会得到全新的域，端口、语言和图标选择都会静默重置 |

两项迁移都是刻意的一次性操作，且绝不会覆盖用户已在当前位置设好的值。数据移动失败是
非致命的，结果只是冷缓存而已。

路径现在集中在一处 —— `AppPaths`，所以将来的改名只需改一处，而不是四处。

## 状态与文件

应用管理的一切都位于 `~/Library/Application Support/Tether` 之下：

| 路径 | 用途 |
|---|---|
| `Workspace/` | DSH 进程的工作目录（其工作区根） |
| `DSHHome/` | `DSH_HOME`，隔离存放，应用状态绝不与你的 CLI profile 混在一起 |
| `NpmCache/` | 私有 npm 缓存，root 所有的共享缓存无法破坏启动 |
| `dsh-web.log` | 每次运行的完整记录，跨启动追加 |

偏好设置存放在 `UserDefaults` 的 `dsh.*` 键下。

## macOS 27 新特性

以下内容均对照 macOS 27.0 SDK 的 SwiftUI `.swiftinterface` 核实，而非假设。有两个
看似新增的候选项在核查后不得不**否决**：

- `reorderContainer(for:isEnabled:move:)` —— **macOS 27.0**。用于启动预设窗口
  （`Views/PresetsView.swift`）的拖拽重排，结果持久化到 `UserDefaults`。它的闭包给出
  `ReorderDifference<ItemID, CollectionID>`，会被转换为新的顺序。该类型不是
  `Sendable`，因此是同步消费的。
- `TabsPickerStyle` / `.pickerStyle(.tabs)` —— **macOS 27.0**。用作设置中的分区分段
  切换，在更老系统上回退到 `.segmented`。
- `DialogSeverity` —— **macOS 13**，不是 27。否决。
- `backgroundExtensionEffect()`、`ToolbarSpacer`、`safeAreaBar(edge:…)`、
  `labelIconToTitleSpacing` —— **macOS 26**，不是 27。否决。
- `glassEffect(_:in:)` —— 该 SDK 中**不存在**（零处出现）。否决。

两个 macOS 27 API 都有条件判断保护，因此在其他地方应用会退化为普通列表和分段控件，
而不是加载失败。

同样来自 macOS 27 API、经核实但此处未使用：`Document` 协议族（`ReadableDocument` /
`WritableDocument` / `DocumentReader` / `DocumentWriter`）、`NavigationTransition` 的
`AnyNavigationTransition`、`URLDocumentConfiguration`，以及
`ToolbarItemVisibilityPriority`。

## 控制台渲染

DSH 会给输出着色。与其显示字面的 `ESC[32m` 文本，`Support/ANSIParser.swift` 会把 SGR
子集（16 色、256 色、24 位真彩色，外加粗体/暗色/斜体/下划线）转换为
`AttributedString`。解析在每行到达时进行且只做一次，因此重绘时不会重新解析整份记录。
转义序列在搜索、复制和导出时会被剥离。

自动滚动会在你本就处于底部时钉住底部；向上滚动即解除钉住，并显示 **Follow Output**
按钮以便恢复。

## 运行时替换应用图标

macOS 从 bundle 的 `CFBundleIconFile` 绘制 Dock 图标，而该值在已签名的 bundle 中无法
在运行时改写。受支持的途径是 `NSApplication.applicationIconImage`，应用会在
**设置 → 应用图标** 中根据你选的图片设置它。系统不会持久化这个覆盖，因此选择会以
安全作用域书签保存，并在每次启动时重新应用。磁盘上的 bundle 从不被修改，代码签名
因此保持完好。

## 菜单栏

该条目显示一个终端字形加当前端口，不打开任何东西也能读出状态。菜单依次包含：状态、
**Show Console**、Open in Browser、Copy Service URL、**Restart / Stop Service**、端口
子菜单（含「自动挑选空闲端口」）、Settings，以及 **Quit and Stop Service**。

关闭控制台窗口不会退出应用（`applicationShouldTerminateAfterLastWindowClosed` 返回
`false`），因为菜单栏条目才是重点 —— 服务会继续运行，直到你停止它。

## 目录结构

```
Sources/Tether/
  App/
    TetherApp.swift         scenes, menu bar item, menu commands
    AppModel.swift         main-actor bridge between actor and SwiftUI
  Core/
    DSHService.swift       actor owning the child process + output
    ExecutionTarget.swift  finds Node and npm's npx entry point
    SettingsStore.swift    persisted preferences
    Localization.swift     AppLanguage, string keys, translations
    IconManager.swift      runtime app icon
    LaunchAtLogin.swift    SMAppService wrapper
    DSHConfiguration.swift npm specifier and extra arguments
    LogEntry.swift         one parsed transcript line
  Support/
    ANSIParser.swift       SGR -> AttributedString
    ConsoleTheme.swift     dark-surface palette + keyword highlighting
    ServiceEndpoint.swift  parses DSH's authenticated startup URL
    PortProbe.swift        port availability and readiness checks
    ProcessTree.swift      recursive process termination
    NpxLock.swift          clears abandoned npx package-cache locks
Scripts/
    build-app.sh           builds and assembles dist/Tether.app
    make-icon.swift        renders the source bitmap into a macOS .icns
    check-macos27-api.sh   lists macOS 27-gated SDK declarations
  Views/
    ConsoleView.swift      the terminal window
    SettingsView.swift     General / App Icon / Diagnostics
    StatusMenu.swift       menu bar item and pull-down
    PresetsView.swift      reorderable presets (macOS 27)
```

## 故障排查：`ECOMPROMISED` / `Lock compromised`

如果控制台出现

```
npm error code ECOMPROMISED
npm error Lock compromised
```

原因是 npx 的包缓存锁，与 DSH 无关。`npx --package=…` 会在 npm 缓存下解析包，并用
咨询锁（`libnpmexec/lib/with-lock.js`）守护它 —— 该锁实现为一个目录，其修改时间每秒
刷新一次，超过 60s 即视为过期。在 `npx` 持有锁时把它杀掉，锁会留在原处，下一次运行
会立刻中止。

应用在每次启动时清理废弃的锁（`Support/NpxLock.swift`），并在记录中报告清理了多少个。
如果你自己启动 DSH，请避免同时对同一 specifier 发起两次 `npx` 解析。

## 故障排查：npm `EEXIST` / `EACCES: permission denied, mkdir …`

较早的构建与你的命令行 npm 共用 `~/.npm/_cacache`。如果该缓存中含有 `root` 所有的
条目 —— 任何 `sudo npm …` 之后都会如此 —— npm 就无法在其中创建文件，并报出误导性的
错误：

```
npm error code EEXIST
npm error syscall mkdir
npm error EACCES: permission denied, mkdir '/Users/…/.npm/_cacache/content-v2/sha512/1d/a0'
npm error File exists: …
```

这**没有 root 就无法恢复**，所以应用不再使用共享缓存。它保有自己的缓存目录
`~/Library/Application Support/Tether/NpmCache`，并通过 `npm_config_cache` 传入 —— 这
也意味着应用永远不会扰动你自己的 npm 状态。

可以这样检查共享缓存是否受影响：

```sh
find ~/.npm/_cacache ! -user "$(whoami)" 2>/dev/null | wc -l
```

结果非零表示某些条目属于其他用户。修复它需要以 root 执行 `chown -R`，所以只有在你
清楚这些文件为何属于 root 时才动手；否则就别管它，让本应用用自己的缓存。

## 带登录态的 URL

DSH 启动时会打印一个带认证信息的 URL：

```
dsh web: http://127.0.0.1:8787/?token=ayMiNWn6lD_qNb9aIn4VU6_2Pf5VLSltYzKfWKepTmw
```

`token` 查询项是必需的，因此裸的 `http://127.0.0.1:<port>/` 并不等价。应用会从输出中
捕获这个已公布的 URL（`Support/ServiceEndpoint.swift`），并用于 **Open in Browser**
和 **Copy Service URL**。工具栏和菜单中显示的地址刻意省略了 token，因为它是凭据，而
那个字符串会显示在屏幕上。

## 控制台外观

控制台是深色表面，这决定了 `Support/ConsoleTheme.swift` 中的两条规则：

- 默认文字接近白色。使用系统标签颜色会在系统处于浅色模式时产生黑底黑字，输出完全不
  可读。
- ANSI 的「黑色」（`ESC[30m`）被映射为可见的灰色。工具在假设浅色终端的前提下用它表示
  次要文字；照字面理解它会在深色背景上消失。任何在本背景下亮度低到无法阅读的颜色都会
  被自动提亮，包括 256 色和真彩色值。

除了进程自身的着色，`KeywordHighlighter` 还会按类别给关键词着色 —— 错误、警告、成功、
信息、URL、路径、数字 —— 让输出的形态一眼可辨。它**只作用于未携带明确颜色的文本**，
因为已经挑好颜色的进程比启发式规则更懂。默认使用 `NSRegularExpression`；定义
`USE_SWIFT_REGEX` 编译条件可以改用 Swift 的 `Regex` 实现。

## 语言

支持英文和简体中文，可在 **设置 → 通用 → 语言** 中切换，并持久化到 `UserDefaults` 的
`dsh.language` 下。

语言在首次启动时从系统解析一次（`zh*` → 中文，否则英文），随后存为具体选择，而不是
「跟随系统」开关。这样选择器始终显示实际生效的语言，并且当系统语言之后发生变化时，
界面不会在你脚下悄悄改变。

`Core/Localization.swift` 保存了机制和全部字符串：

- `AppLanguage` —— 各语言都用其自身文字命名，这样读不懂另一种语言的人也能读懂选择器。
- `Loc` —— 每个字符串一个符号键。用符号而非「英文即键」，是因为相同的英文词在翻译时
  应当有分道扬镳的自由。
- `entries` —— 英文与中文并排存放，这样编辑译文时源文永远在视野内。

两个值得知道的细节：

- **占位符一律是 `%@`，绝不用 `%d`。** `String(format:)` 会把 `%d` 按整数读取，因此
  传给它一个 `String` 会当作指针解引用，渲染出 `port 1687781658` 这样的垃圾。由于该
  API 接受 `CVarArg`，编译器抓不到这个错误，于是类型被规范化掉了：每个数值参数都在
  调用点字符串化，每个占位符都是 `%@`。
- **缺失的键回退到英文**，因此空缺会退化为可读文本，而不是显示原始键名。

视图通过 `AppModel.string(_:)` 读取字符串，该调用会触碰可观察的 `settings.language`
—— 正是这个访问让语言变化时整个界面重新渲染。服务层运行在 actor 上，无法访问那个
store，所以它使用 `L10n.text(_:)`，直接读取已存储的语言。

覆盖率：122 个键，并通过一次校验确认没有重复、没有任一表缺失的键、两种语言之间没有
占位符不匹配。

**控制台中的技术性输出永不翻译。** 进程输出、路径、URL 和 npm 错误都按原文显示 ——
翻译它们只会让 bug 报告更难复现。只有应用自己的消息和界面外壳会被本地化。

### 验证本地化改动

```sh
# Duplicate keys, orphan keys, and %-placeholder mismatches between languages:
# (see the validation described above; run it after editing the entries table)
```

想在不点选选择器的情况下检查每种语言的界面：

```sh
defaults write dev.tether.dsh dsh.language -string en        # or zh-Hans
```

## 故障排查：构建看起来卡住了

`swift build` 会对 `.build` 加**排他锁**。如果已有另一个 SwiftPM 任务在跑（例如
VS Code 的 "Resolve Package Dependencies"），第二次构建会阻塞在这把锁上，看起来就像
卡死。同一时间只能有一个构建。

检查与清理：

```sh
pgrep -fl 'swift-build|swiftpm|swift-frontend'   # anything running?
ls -l .build/.lock                               # lock present?
```

请杀掉游离的任务，而不要在构建仍持有锁时删除锁文件。

## 限制

- 应用不会自己打开 DSH 的 web 界面；由服务器决定它提供什么。**Open in Browser** 指向
  `http://127.0.0.1:<port>/`。
- **冷启动非常慢。** 依据 npm 自身的调试日志在首次运行时测得：

  | 指标 | 数值 |
  |---|---|
  | 解析期间的 manifest 请求数 | **1333+** |
  | 解析出的不同包数 | **312** |
  | 成功启动后的私有缓存体积 | **1.2 GB** |

  npm 会先解析完整个 300+ 包的依赖图，再下载第一个 tarball，因此在冷缓存下会有好几分钟
  的 registry 往返，而控制台里几乎没有内容。就绪轮询允许 30 分钟，启动期间工具栏会显示
  已用时间计数器。之后的运行会复用私有缓存。

  已端到端确认可用：应用启动 DSH，DSH 绑定端口，控制台记录 `[app] Running on <port>`。
- 如果首次运行被中断，再启动一次即可 —— `Support/NpxLock.swift` 会清理废弃的锁。
- `Launch at login` 需要真正的 `.app` bundle；从裸二进制运行时该开关被禁用并会给出
  说明。
- 已在 macOS 27.0.1 与来自 `/usr/local` 的 Node v24.20.0 上验证。其他 Node 布局由
  `ExecutionTargetResolver` 处理，但未经测试。
