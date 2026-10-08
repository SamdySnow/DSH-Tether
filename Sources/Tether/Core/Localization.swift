import Foundation

/// Language the interface is presented in.
///
/// Naming follows BCP-47, so the raw values can be handed straight to
/// `Locale(identifier:)`.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// Name of the language *in that language*, which is how language pickers
    /// conventionally present the choices — a reader looking for 简体中文 should
    /// not have to recognise the word "Chinese" in a language they cannot read.
    var endonym: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    /// Language used before the user has chosen one.
    ///
    /// Follows the system when it is one we speak, otherwise English, which is the
    /// more useful default for a developer tool's logs.
    static var systemDefault: AppLanguage {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    /// Language currently stored, falling back to `systemDefault`.
    static var stored: AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: DefaultsKey.language),
              let language = AppLanguage(rawValue: raw) else {
            return systemDefault
        }
        return language
    }
}

/// Every string the user can see.
///
/// Symbolic keys rather than English text as keys: several strings are identical
/// in English but should be free to diverge in translation ("Port" as a field
/// label versus a menu title, for example).
enum Loc: Sendable {
    // Window / scene titles
    case appName
    case launchPresetsTitle

    // Service status
    case statusStopped
    case statusStarting
    case statusStopping
    case statusFailed
    case statusRunningOn
    case statusFailedWithReason
    case statusRunningTooltip
    case statusStartingTooltip
    case statusStoppingTooltip
    case statusStoppedTooltip

    // Console
    case searchConsolePrompt
    case pidFormat
    case elapsedHelp
    case pidHelp
    case actionStart
    case actionStartHelp
    case actionRestart
    case actionRestartHelp
    case actionStop
    case actionStopHelp
    case actionOpen
    case followOutput
    case followOutputHelp
    case port
    case pickFreePortAutomaticallyHelp

    // Settings — panes
    case paneGeneral
    case paneIcon
    case paneDiagnostics
    case sectionLanguage

    // Settings — general
    case sectionService
    case pickFreePort
    case portRangeNote
    case toggleStartOnLaunch
    case applyPortAndRestart
    case servesAt
    case sectionPackage
    case npmSpecifier
    case inUse
    case useDefault
    case packageNote
    case sectionStartup
    case launchAtLogin
    case languageNote

    // Settings — icon
    case defaultApplicationIcon
    case iconCustomInUse
    case iconChoosePrompt
    case chooseImage
    case sectionNotes
    case iconNoteSignature
    case iconNoteFormats

    // Settings — diagnostics
    case sectionRuntime
    case labelStatus
    case labelServiceURL
    case labelProcess
    case labelNodeRuntime
    case notFound
    case sectionFiles
    case openDshWorkspace
    case revealLogFile
    case exportConsoleLog
    case diagnosticsNote
    case placeholderValue

    // Menu bar
    case menuShowConsole
    case menuOpenInBrowser
    case menuCopyServiceURL
    case menuRestartService
    case menuStopService
    case menuStartService
    case menuPort
    case menuCurrentPort
    case menuPickFreePort
    case menuStartWithApp
    case menuSettings
    case menuRevealWorkspace
    case menuQuitAndStop
    case serviceStoppedHeadline

    // Menu commands
    case commandShowLaunchPresets
    case menuServiceMenu
    case copyConsoleTranscript
    case clearConsole

    // Launch presets
    case reorderHint
    case reorderHintUnavailable
    case resetOrder
    case actionRun
    case presetOpenWebUI
    case presetCopyServiceURL
    case presetRevealWorkspace
    case presetRevealDshHome
    case presetRestartService

    // Launch at login
    case loginItemNeedsBundle
    case loginItemEnabled
    case loginItemNotRegistered
    case loginItemNotFound
    case loginItemRequiresApproval
    case loginItemUnknown

    // Icon errors
    case iconUseFailed
    case iconUnreadable

    // Service messages (written into the console transcript)
    case svcNodeNotFound
    case svcRuntime
    case svcWorkspace
    case svcDshHome
    case svcFirstRun
    case svcNpmCache
    case svcPortInUse
    case svcClearedLocks
    case svcRuntimeMissing
    case svcLaunchFailed
    case svcSendingSigterm
    case svcSendingSigkill
    case svcReadinessTimeout
    case svcTerminatedBySignal
    case svcExitedWithCode
    case svcProcessEnded
    case svcStartFailed
    case svcTerminatingOrphan
    case svcPortHeldByNonDsh
    case svcPortStillHeld
    case svcPortReleaseFailed
    case appAutoStartDisabled
    case exportLogPanelTitle

    // Node setup
    case nodeMissingTitle
    case nodeMissingMessage
    case nodeInstallAction
    case nodeInstallFromWebsite
    case notNow
    case homebrewMissingTitle
    case homebrewMissingMessage
    case openHomebrewWebsite
    case nodeInstalling
    case nodeInstalledTitle
    case nodeInstalledMessage
    case nodeInstallFailedTitle
    case nodeInstallFailedMessage
    case nodeInstallNotFound
    case ok
}

/// Resolves `Loc` keys to text.
///
/// Views read through `AppModel.string(_:)`, which touches the observable
/// `SettingsStore.language` and so re-renders on change. The service layer runs on
/// an actor with no access to that store, so it uses the overload that reads the
/// stored language directly — a fast, thread-safe `UserDefaults` read that is
/// accurate at the moment a message is produced.
enum L10n {

    static func text(_ key: Loc, _ language: AppLanguage) -> String {
        let table = language == .simplifiedChinese ? chinese : english
        // Falling back to English means a missing translation degrades to
        // something readable instead of leaking a raw key into the interface.
        return table[key] ?? english[key] ?? "?"
    }

    /// Reads the stored language. For contexts that cannot observe settings.
    static func text(_ key: Loc) -> String {
        text(key, AppLanguage.stored)
    }

    /// Substitutes `%@` / `%@` placeholders.
    ///
    /// Takes an array rather than varargs because Swift cannot forward a variadic
    /// parameter to another function; callers that want the terse form use the
    /// `AppModel.string(_:_:)` overloads.
    static func text(_ key: Loc, _ language: AppLanguage, _ arguments: [CVarArg]) -> String {
        let template = text(key, language)
        guard !arguments.isEmpty else { return template }
        return String(format: template, arguments: arguments)
    }

    /// Convenience for contexts that cannot observe settings.
    static func text(_ key: Loc, _ arguments: [CVarArg]) -> String {
        text(key, AppLanguage.stored, arguments)
    }

    private static let english: [Loc: String] = {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.english) })
    }()

    private static let chinese: [Loc: String] = {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.chinese) })
    }()
}

// MARK: - Translations

/// English and Chinese kept side by side, so a translation is never edited
/// without the source text in view.
private let entries: [(key: Loc, english: String, chinese: String)] = [
    // Window / scene titles
    // Window / scene titles.
    //
    // The window title is the app name now that they coincide; keeping a separate
    // key means the title can diverge again without touching call sites. The app
    // name itself is a product name, so it is identical in both languages.
    (.appName, "Tether", "Tether"),
    (.launchPresetsTitle, "Launch Presets", "启动预设"),

    // Service status
    (.statusStopped, "Stopped", "已停止"),
    (.statusStarting, "Starting…", "正在启动…"),
    (.statusStopping, "Stopping…", "正在停止…"),
    (.statusFailed, "Failed", "失败"),
    (.statusRunningOn, "Running on %@", "运行于 %@"),
    (.statusFailedWithReason, "Failed — %@", "失败 — %@"),
    (.statusRunningTooltip, "DSH is listening on port %@", "DSH 正在监听端口 %@"),
    (.statusStartingTooltip, "Waiting for the DSH server to accept connections",
     "正在等待 DSH 服务器接受连接"),
    (.statusStoppingTooltip, "Closing the DSH process tree", "正在关闭 DSH 进程树"),
    (.statusStoppedTooltip, "The service is stopped", "服务已停止"),

    // Console
    (.searchConsolePrompt, "Search console output", "搜索控制台输出"),
    (.pidFormat, "pid %@", "进程 %@"),
    (.elapsedHelp,
     "Time since this start attempt began. The first run downloads the DSH package tree and can take several minutes.",
     "本次启动已用时间。首次运行需要下载 DSH 依赖树，可能需要数分钟。"),
    (.pidHelp, "Process id of the DSH runtime", "DSH 运行时的进程 ID"),
    (.actionStart, "Start", "启动"),
    (.actionStartHelp, "Start the DSH web service", "启动 DSH Web 服务"),
    (.actionRestart, "Restart", "重启"),
    (.actionRestartHelp, "Stop and start the service on the current port",
     "在当前端口上停止并重新启动服务"),
    (.actionStop, "Stop", "停止"),
    (.actionStopHelp, "Stop the service and its child processes", "停止服务及其子进程"),
    (.actionOpen, "Open", "打开"),
    (.followOutput, "Follow Output", "跟随输出"),
    (.followOutputHelp, "Scroll to the newest output and resume following",
     "滚动到最新输出并恢复跟随"),
    (.port, "Port", "端口"),
    (.pickFreePortAutomaticallyHelp, "Pick the next available port automatically",
     "自动选择下一个可用端口"),

    // Settings — panes
    (.paneGeneral, "General", "通用"),
    (.paneIcon, "App Icon", "应用图标"),
    (.paneDiagnostics, "Diagnostics", "诊断"),
    (.sectionLanguage, "Language", "语言"),

    // Settings — general
    (.sectionService, "Service", "服务"),
    (.pickFreePort, "Pick Free Port", "选取空闲端口"),
    (.portRangeNote,
     "Ports %@–%@. Changing the port while the service is running offers to restart it.",
     "端口范围 %@–%@。服务运行中修改端口时会提示重启。"),
    (.toggleStartOnLaunch, "Start service when the app opens", "打开应用时启动服务"),
    (.applyPortAndRestart, "Apply Port and Restart", "应用端口并重启"),
    (.servesAt, "Serves at %@", "服务地址 %@"),
    (.sectionPackage, "DSH Package", "DSH 软件包"),
    (.npmSpecifier, "npm specifier", "npm 标识符"),
    (.inUse, "In use: %@", "当前使用：%@"),
    (.useDefault, "Use Default", "使用默认值"),
    (.packageNote,
     "Leave empty to follow the latest release. Pin an exact version for reproducible or faster cold starts.",
     "留空表示跟随最新版本。指定确切版本可获得可复现或更快的冷启动。"),
    (.sectionStartup, "Startup", "启动项"),
    (.launchAtLogin, "Launch at login", "登录时启动"),
    (.languageNote,
     "Applies immediately. Technical output in the console is never translated.",
     "立即生效。控制台中的技术输出不会被翻译。"),

    // Settings — icon
    (.defaultApplicationIcon, "Default application icon", "默认应用图标"),
    (.iconCustomInUse, "This icon is applied to the Dock and the app switcher.",
     "该图标会应用到程序坞和应用切换器。"),
    (.iconChoosePrompt, "Choose an image to replace the application icon.",
     "选择一张图片来替换应用图标。"),
    (.chooseImage, "Choose Image…", "选择图片…"),
    (.sectionNotes, "Notes", "说明"),
    (.iconNoteSignature,
     "The bundle on disk is never modified, so the code signature stays intact. The choice is stored as a security-scoped bookmark and reapplied at every launch.",
     "磁盘上的应用包不会被修改，代码签名因此保持完整。所选图标会以安全作用域书签保存，并在每次启动时重新应用。"),
    (.iconNoteFormats,
     "An .icns file gives the sharpest result; PNG of at least 512×512 also works.",
     ".icns 文件效果最佳；至少 512×512 的 PNG 也可以。"),

    // Settings — diagnostics
    (.sectionRuntime, "Runtime", "运行时"),
    (.labelStatus, "Status", "状态"),
    (.labelServiceURL, "Service URL", "服务地址"),
    (.labelProcess, "Process", "进程"),
    (.labelNodeRuntime, "Node runtime", "Node 运行时"),
    (.notFound, "Not found", "未找到"),
    (.sectionFiles, "Files", "文件"),
    (.openDshWorkspace, "Open DSH Workspace", "打开 DSH 工作区"),
    (.revealLogFile, "Reveal Log File in Finder", "在访达中显示日志文件"),
    (.exportConsoleLog, "Export Console Log…", "导出控制台日志…"),
    (.diagnosticsNote,
     "The workspace folder is the working directory of the DSH process; DSH home is kept inside the app's container so app-managed state never mixes with your command-line profiles.",
     "工作区文件夹是 DSH 进程的工作目录；DSH home 保存在应用容器内，因此应用管理的状态不会与命令行的配置文件混淆。"),
    (.placeholderValue, "—", "—"),

    // Menu bar
    (.menuShowConsole, "Show Console", "显示控制台"),
    (.menuOpenInBrowser, "Open in Browser", "在浏览器中打开"),
    (.menuCopyServiceURL, "Copy Service URL", "复制服务地址"),
    (.menuRestartService, "Restart Service", "重启服务"),
    (.menuStopService, "Stop Service", "停止服务"),
    (.menuStartService, "Start Service", "启动服务"),
    (.menuPort, "Port", "端口"),
    (.menuCurrentPort, "Current: %@", "当前：%@"),
    (.menuPickFreePort, "Pick Free Port Automatically", "自动选取空闲端口"),
    (.menuStartWithApp, "Start Service with App", "随应用启动服务"),
    (.menuSettings, "Settings…", "设置…"),
    (.menuRevealWorkspace, "Reveal Workspace in Finder", "在访达中显示工作区"),
    (.menuQuitAndStop, "Quit and Stop Service", "退出并停止服务"),
    (.serviceStoppedHeadline, "Service stopped", "服务已停止"),

    // Menu commands
    (.commandShowLaunchPresets, "Show Launch Presets", "显示启动预设"),
    (.menuServiceMenu, "Service", "服务"),
    (.copyConsoleTranscript, "Copy Console Transcript", "复制控制台记录"),
    (.clearConsole, "Clear Console", "清空控制台"),

    // Launch presets
    (.reorderHint, "Drag a row to change the order. Double-click to run.",
     "拖动可调整顺序，双击即可运行。"),
    (.reorderHintUnavailable, "Double-click to run. Reordering requires macOS 27.",
     "双击即可运行。调整顺序需要 macOS 27。"),
    (.resetOrder, "Reset Order", "重置顺序"),
    (.actionRun, "Run", "运行"),
    (.presetOpenWebUI, "Open Web UI in Browser", "在浏览器中打开 Web 界面"),
    (.presetCopyServiceURL, "Copy Service URL", "复制服务地址"),
    (.presetRevealWorkspace, "Reveal Workspace in Finder", "在访达中显示工作区"),
    (.presetRevealDshHome, "Reveal DSH Home in Finder", "在访达中显示 DSH Home"),
    (.presetRestartService, "Restart Service", "重启服务"),

    // Launch at login
    (.loginItemNeedsBundle, "Available after the app is built as a .app bundle.",
     "需将应用构建为 .app 包后才可用。"),
    (.loginItemEnabled, "Enabled", "已启用"),
    (.loginItemNotRegistered, "Not registered", "未注册"),
    (.loginItemNotFound, "Service not found", "未找到服务"),
    (.loginItemRequiresApproval,
     "Waiting for approval in System Settings → General → Login Items",
     "等待在「系统设置 → 通用 → 登录项」中批准"),
    (.loginItemUnknown, "Unknown", "未知"),

    // Icon errors
    (.iconUseFailed, "Could not use that image: %@", "无法使用该图片：%@"),
    (.iconUnreadable, "The selected file is not a readable image.",
     "所选文件不是可读取的图片。"),

    // Service messages
    (.svcNodeNotFound, "Node.js not found. Install Node 20+ or set %@.",
     "未找到 Node.js。请安装 Node 20+，或设置 %@。"),
    (.svcRuntime, "runtime: %@", "运行时：%@"),
    (.svcWorkspace, "workspace: %@", "工作区：%@"),
    (.svcDshHome, "DSH_HOME: %@", "DSH_HOME：%@"),
    (.svcFirstRun, "first run: fetching the DSH package. This can take several minutes.",
     "首次运行：正在获取 DSH 软件包，可能需要数分钟。"),
    (.svcNpmCache, "npm cache: %@", "npm 缓存：%@"),
    (.svcPortInUse, "Port %@ is already in use. Pick another port in Settings.",
     "端口 %@ 已被占用。请在设置中选择其他端口。"),
    (.svcClearedLocks, "cleared %@ stale npx lock(s) from a previous run",
     "已清理 %@ 个上次运行遗留的 npx 锁"),
    (.svcRuntimeMissing, "Could not locate the DSH command runtime.",
     "无法找到 DSH 命令运行时。"),
    (.svcLaunchFailed, "Could not launch Node: %@", "无法启动 Node：%@"),
    (.svcSendingSigterm, "sending SIGTERM to pid %@ and descendants",
     "正在向进程 %@ 及其子进程发送 SIGTERM"),
    (.svcSendingSigkill, "did not exit in time; sending SIGKILL",
     "未及时退出，正在发送 SIGKILL"),
    (.svcReadinessTimeout,
     "The server did not start listening within %@s. Check the console output above.",
     "服务器未在 %@ 秒内开始监听。请查看上方的控制台输出。"),
    (.svcTerminatedBySignal, "terminated by signal %@", "被信号 %@ 终止"),
    (.svcExitedWithCode, "exited with code %@", "以代码 %@ 退出"),
    (.svcProcessEnded, "process %@", "进程 %@"),
    (.svcStartFailed, "DSH %@.", "DSH %@。"),
    (.svcTerminatingOrphan, "terminating orphaned DSH from a previous run (pid %@)",
     "正在终止上次运行遗留的 DSH（进程 %@）"),
    (.svcPortHeldByNonDsh, "port %@ is held by a non-DSH process; leaving it alone",
     "端口 %@ 被非 DSH 进程占用，不做处理"),
    (.svcPortStillHeld, "port %@ still held by %@ leftover DSH process(es); releasing",
     "端口 %@ 仍被 %@ 个遗留的 DSH 进程占用，正在释放"),
    (.svcPortReleaseFailed, "warning: could not release port %@",
     "警告：无法释放端口 %@"),
    (.appAutoStartDisabled, "automatic start is disabled in Settings",
     "设置中已禁用自动启动"),
    (.exportLogPanelTitle, "Export DSH Console Log", "导出 DSH 控制台日志"),

    // Node setup
    (.nodeMissingTitle, "Node.js is required", "需要 Node.js"),
    (.nodeMissingMessage,
     "Tether needs Node.js to run DSH. Would you like to install it with Homebrew?",
     "Tether 需要 Node.js 才能运行 DSH。是否使用 Homebrew 安装？"),
    (.nodeInstallAction, "Install Node.js", "安装 Node.js"),
    (.nodeInstallFromWebsite, "Install from Node.js Website…", "前往 Node.js 官网安装…"),
    (.notNow, "Not Now", "暂不安装"),
    (.homebrewMissingTitle, "Homebrew is not installed", "尚未安装 Homebrew"),
    (.homebrewMissingMessage,
     "Install Homebrew first, then try installing Node.js again.",
     "请先安装 Homebrew，然后重新尝试安装 Node.js。"),
    (.openHomebrewWebsite, "Open Homebrew Website", "打开 Homebrew 官网"),
    (.nodeInstalling, "Installing Node.js with Homebrew…", "正在使用 Homebrew 安装 Node.js…"),
    (.nodeInstalledTitle, "Node.js installed", "Node.js 已安装"),
    (.nodeInstalledMessage, "Node.js is ready to use.", "Node.js 已就绪。"),
    (.nodeInstallFailedTitle, "Could not install Node.js", "无法安装 Node.js"),
    (.nodeInstallFailedMessage, "Homebrew reported an error:\n%@",
     "Homebrew 返回错误：\n%@"),
    (.nodeInstallNotFound,
     "Homebrew finished, but Tether could not locate the Node.js/npm runtime.",
     "Homebrew 已完成安装，但 Tether 仍未找到可用的 Node.js/npm 运行时。"),
    (.ok, "OK", "好"),
]
