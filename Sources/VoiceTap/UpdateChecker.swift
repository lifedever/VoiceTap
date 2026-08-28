import AppKit

/// 通过 GitHub Releases 检查并**自动安装**新版本。
///
/// 机制沿用 TabFlick / PasteMemo 的更新器：下载当前架构的 DMG → 校验字节数 →
/// 挂载 → 用 shell 脚本**原地替换 .app 的内容**（保持 bundle 路径与身份，
/// 「输入监控 / 辅助功能」授权跟着 bundle ID 走，不会丢）→ 重新启动。
///
/// 脚本里删除/拷贝资源 bundle 一律 glob，绝不写死名字 —— updater 脚本是编译进
/// **当前**版本的，一旦写死某个 bundle 名发出去，将来新增 SPM 依赖时旧 updater
/// 会漏拷新 bundle，而且已装旧版的用户没法远程修复（PasteMemo issue #38）。
@MainActor
final class UpdateChecker {

    private static let lastCheckKey = "lastUpdateCheck"
    private static let skippedKey = "skippedUpdateVersion"
    /// 每小时对一次账，到期才真的查
    private static let tickInterval: TimeInterval = 3600

    static var releasesPage: URL {
        URL(string: "https://github.com/\(AppInfo.repo)/releases/latest")!
    }

    var onLog: ((String) -> Void)?

    private var isChecking = false
    private var isDownloading = false
    private var downloadTask: URLSessionDownloadTask?
    private var downloadDelegate: DownloadDelegate?
    private var downloadCancelled = false
    private var periodicTimer: Timer?
    private var progress: ProgressWindow?

    var currentVersion: String { AppInfo.version }

    // MARK: - 检查

    func check(userInitiated: Bool) {
        guard !isChecking, !isDownloading else { return }
        isChecking = true

        Task {
            let result = await fetchLatest()
            isChecking = false
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

            switch result {
            case .failure(let message):
                log("检查更新失败：\(message)")
                if userInitiated { presentFailure(message) }

            case .success(let release):
                if isNewer(release.version, than: currentVersion) {
                    log("发现新版本 \(release.version)")
                    // 自动检查尊重「跳过此版本」；手动检查永远弹
                    let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
                    if userInitiated || release.version != skipped {
                        presentAvailable(release)
                    }
                } else {
                    log("已是最新版本 \(currentVersion)")
                    if userInitiated { presentUpToDate() }
                }
            }
        }
    }

    func startPeriodicChecks() {
        periodicTimer?.invalidate()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        periodicTimer = timer

        // 启动后稍等再对账，别抢启动窗口
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.checkIfDue()
        }
    }

    private func checkIfDue() {
        guard Settings.shared.autoCheckUpdates else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 86_400 else { return }
        check(userInitiated: false)
    }

    // MARK: - 网络

    private struct Latest {
        let version: String
        /// 当前架构的 DMG 资产；发布时漏传该架构的包时为 nil，降级到发布页
        let assetURL: URL?
        let assetSize: Int64
    }

    private enum FetchResult {
        case success(Latest)
        case failure(String)
    }

    private func fetchLatest() async -> FetchResult {
        let url = URL(string: "https://api.github.com/repos/\(AppInfo.repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 一个 release 都还没发时 GitHub 返回 404，这不是错误
            if code == 404 {
                return .success(Latest(version: "0.0.0", assetURL: nil, assetSize: 0))
            }
            guard code == 200 else { return .failure("GitHub 返回 \(code)") }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                return .failure("无法解析发布信息")
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

            // 找当前架构的 DMG，资产名形如 VoiceTap-0.2.0-arm64.dmg
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "x86_64"
            #endif
            var assetURL: URL?
            var assetSize: Int64 = 0
            if let assets = json["assets"] as? [[String: Any]],
               let asset = assets.first(where: {
                   let name = $0["name"] as? String ?? ""
                   return name.contains(arch) && name.hasSuffix(".dmg")
               }) {
                assetURL = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
                assetSize = (asset["size"] as? NSNumber)?.int64Value ?? 0
            }
            return .success(Latest(version: version, assetURL: assetURL, assetSize: assetSize))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// 逐段比较数字版本号。字符串比较会把 "0.10.0" 判成小于 "0.9.0"。
    private func isNewer(_ remote: String, than current: String) -> Bool {
        let a = remote.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - 下载

    private func startDownload(_ latest: Latest) {
        guard let url = latest.assetURL, !isDownloading else { return }
        isDownloading = true
        downloadCancelled = false

        let window = ProgressWindow(version: latest.version) { [weak self] in
            self?.cancelDownload()
        }
        window.show()
        progress = window

        let delegate = DownloadDelegate(
            expectedSize: latest.assetSize,
            onProgress: { [weak self] value in
                Task { @MainActor in self?.progress?.update(value) }
            },
            onFinish: { [weak self] result in
                Task { @MainActor in self?.downloadFinished(result) }
            }
        )
        downloadDelegate = delegate
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    func cancelDownload() {
        downloadCancelled = true
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        closeProgress()
    }

    private func downloadFinished(_ result: DownloadResult) {
        isDownloading = false
        downloadTask = nil
        closeProgress()

        switch result {
        case .success(let fileURL):
            installAndRestart(from: fileURL)
        case .failure(let message):
            guard !downloadCancelled else { return }   // 用户主动取消，别再弹错误
            presentInstallFailure(message)
        }
    }

    private func closeProgress() {
        progress?.close()
        progress = nil
    }

    // MARK: - 安装

    private func installAndRestart(from dmg: URL) {
        let destApp = Bundle.main.bundlePath
        // swift run 之类的非 .app 环境没有可替换的 bundle，别把 .build 目录搅了
        guard destApp.hasSuffix(".app") else {
            NSWorkspace.shared.open(dmg)
            return
        }

        guard let mountPoint = Self.mountDMG(at: dmg.path) else {
            presentInstallFailure("更新包无法打开")
            return
        }
        let sourceApp = "\(mountPoint)/\(AppInfo.name).app"
        guard FileManager.default.fileExists(atPath: sourceApp) else {
            Self.detachDMG(mountPoint)
            presentInstallFailure("更新包内容不完整")
            return
        }

        // 只替换内容、不动 .app 目录本身：bundle 的路径与身份保持不变，
        // 权限授权（跟 bundle ID 走）得以保住。
        // _CodeSignature 必须和它封印的内容一起换，否则签名校验从此失败。
        let script = """
        #!/bin/bash
        sleep 2
        rm -rf "\(destApp)/Contents/MacOS" "\(destApp)/Contents/Resources" "\(destApp)/Contents/_CodeSignature"
        rm -rf "\(destApp)"/*.bundle
        cp -R "\(sourceApp)/Contents/MacOS" "\(destApp)/Contents/MacOS"
        cp -R "\(sourceApp)/Contents/Resources" "\(destApp)/Contents/Resources"
        cp "\(sourceApp)/Contents/Info.plist" "\(destApp)/Contents/Info.plist"
        if [ -d "\(sourceApp)/Contents/_CodeSignature" ]; then
            cp -R "\(sourceApp)/Contents/_CodeSignature" "\(destApp)/Contents/_CodeSignature"
        fi
        for b in "\(sourceApp)"/*.bundle; do
            [ -d "$b" ] && cp -R "$b" "\(destApp)/"
        done
        hdiutil detach "\(mountPoint)" -quiet 2>/dev/null
        xattr -dr com.apple.quarantine "\(destApp)" 2>/dev/null
        open "\(destApp)"
        rm -f "$0"
        """

        do {
            let scriptPath = NSTemporaryDirectory() + "voicetap_update.sh"
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            let process = Process()
            // 用 bash 显式执行。脚本按 bash 语义写的（未匹配的 glob 原样传递），
            // 换 zsh 跑会因 nomatch 直接报错中断，app 会停在拆了一半的状态。
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath]
            try process.run()
            log("更新器已启动，正在替换并重启")
            NSApp.terminate(nil)
        } catch {
            Self.detachDMG(mountPoint)
            NSWorkspace.shared.open(dmg)
        }
    }

    private static func mountDMG(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", path, "-nobrowse", "-noverify"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = output.components(separatedBy: "\n").first(where: { $0.contains("/Volumes/") }),
              let range = line.range(of: "/Volumes/") else { return nil }
        return String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
    }

    private static func detachDMG(_ mountPoint: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint, "-quiet"]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - 提示

    private func activate() { NSApp.activate(ignoringOtherApps: true) }

    private func presentAvailable(_ latest: Latest) {
        activate()
        let alert = NSAlert()
        alert.messageText = "有新版本 \(latest.version)"

        if latest.assetURL != nil {
            alert.informativeText = "当前版本 \(currentVersion)。点「下载并安装」后 "
                + "\(AppInfo.name) 会自动完成更新并重新启动。"
            alert.addButton(withTitle: "下载并安装")
            alert.addButton(withTitle: "稍后")
            alert.addButton(withTitle: "跳过此版本")
            switch alert.runModal() {
            case .alertFirstButtonReturn: startDownload(latest)
            case .alertThirdButtonReturn:
                UserDefaults.standard.set(latest.version, forKey: Self.skippedKey)
            default: break
            }
        } else {
            // 这一版的 release 缺当前架构的 DMG，退回发布页手动下载
            alert.informativeText = "当前版本 \(currentVersion)。这一版没有找到适配本机的安装包，"
                + "请前往发布页手动下载。"
            alert.addButton(withTitle: "前往下载")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(Self.releasesPage)
            }
        }
    }

    private func presentUpToDate() {
        activate()
        let alert = NSAlert()
        alert.messageText = "已是最新版本"
        alert.informativeText = "当前版本 \(currentVersion)。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func presentFailure(_ message: String) {
        activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "检查更新失败"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func presentInstallFailure(_ message: String) {
        activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "自动更新失败"
        alert.informativeText = message + "\n\n可以前往发布页手动下载安装。"
        alert.addButton(withTitle: "前往下载")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.releasesPage)
        }
    }

    private func log(_ message: String) { onLog?(message) }
}

// MARK: - 进度窗口

/// 纯 AppKit，跟项目其余部分保持一致
@MainActor
private final class ProgressWindow {

    private let window: NSWindow
    private let bar = NSProgressIndicator()
    private let percentLabel = NSTextField(labelWithString: "0%")
    private let onCancel: () -> Void

    init(version: String, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
            styleMask: [.titled],      // 不给关闭按钮，取消走窗口里的按钮
            backing: .buffered,
            defer: false
        )
        window.title = "软件更新"
        window.isReleasedWhenClosed = false

        let content = NSView()

        let title = NSTextField(labelWithString: "正在下载 \(AppInfo.name) \(version)…")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.translatesAutoresizingMaskIntoConstraints = false

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelAction))
        cancel.bezelStyle = .rounded
        cancel.translatesAutoresizingMaskIntoConstraints = false

        for view in [title, bar, percentLabel, cancel] as [NSView] { content.addSubview(view) }

        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 340),

            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            percentLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            percentLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            cancel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            cancel.centerYAnchor.constraint(equalTo: percentLabel.centerYAnchor),

            content.bottomAnchor.constraint(equalTo: cancel.bottomAnchor, constant: 20),
        ])

        window.contentView = content
        // 先布局定尺寸再居中，反过来会以近零尺寸居中后向右下展开
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func update(_ value: Double) {
        bar.doubleValue = value
        percentLabel.stringValue = "\(Int(value * 100))%"
    }

    func close() {
        window.orderOut(nil)
    }

    @objc private func cancelAction() { onCancel() }
}

// MARK: - 下载代理

private enum DownloadResult: Sendable {
    case success(URL)
    case failure(String)
}

/// URLSession 的回调不在主线程，单独一个类接住，回主线程只传数据。
///
/// `@unchecked Sendable`：`finished` 是可变状态，但 URLSession 的 delegate 回调
/// 都投递到同一个串行 delegate queue，不会并发进入，因此无需额外加锁。
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let expectedSize: Int64
    private let onProgress: @Sendable (Double) -> Void
    private let onFinish: @Sendable (DownloadResult) -> Void
    /// 成功路径已经回调过，didCompleteWithError 的 nil error 不再重复回调
    private var finished = false

    init(expectedSize: Int64,
         onProgress: @escaping @Sendable (Double) -> Void,
         onFinish: @escaping @Sendable (DownloadResult) -> Void) {
        self.expectedSize = expectedSize
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceTap-update.dmg")
        try? FileManager.default.removeItem(at: dest)

        // location 是系统临时文件，回调返回后立即被删，必须先挪走
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            finished = true
            onFinish(.failure(error.localizedDescription))
            return
        }

        // 校验字节数：CDN 截断、连接中断的包不能进安装环节
        if expectedSize > 0,
           let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
           let fileSize = attrs[.size] as? Int64,
           fileSize != expectedSize {
            try? FileManager.default.removeItem(at: dest)
            finished = true
            onFinish(.failure("下载不完整（\(fileSize)/\(expectedSize) 字节）"))
            return
        }

        finished = true
        onFinish(.success(dest))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : max(expectedSize, 1)
        onProgress(Double(totalBytesWritten) / Double(total))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        guard let error, !finished else { return }
        finished = true
        onFinish(.failure(error.localizedDescription))
    }
}
