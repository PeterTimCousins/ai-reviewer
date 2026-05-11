import AppKit
import Foundation

struct AppConfig: Codable {
    var repoPath: String
    var reportsPath: String
    var maxParallelReviews: Int
    var pollIntervalSeconds: Int
    var codexHome: String
    var reviewCachePath: String
    let maxSnapshotBytes: Int?

    var snapshotByteLimit: Int {
        max(1, maxSnapshotBytes ?? 200_000)
    }
}

func defaultConfig() -> AppConfig {
    AppConfig(
        repoPath: "",
        reportsPath: "tmp_docs/reviews",
        maxParallelReviews: 1,
        pollIntervalSeconds: 10,
        codexHome: "~/.codex",
        reviewCachePath: "~/Library/Caches/com.ai-reviewer",
        maxSnapshotBytes: 200_000
    )
}

struct ChangedFile: Codable {
    let status: String
    let path: String
    let oldPath: String?
    let snapshotPath: String?
    let snapshotBytes: Int?
    let snapshotCapped: Bool
}

struct BundleManifest: Codable {
    let schemaVersion: Int
    let commit: String
    let shortCommit: String
    let branch: String
    let createdAt: String
    let changedFiles: [ChangedFile]
}

enum Command: String {
    case validate
    case watch
    case materializeHead = "materialize-head"
}

enum AIReviewerError: Error, CustomStringConvertible {
    case missingArgument(String)
    case unreadableConfig(String)
    case invalidConfig(String)
    case invalidPath(String)
    case missingPath(String)
    case commandFailed(String)
    case unableToWrite(String)

    var description: String {
        switch self {
        case .missingArgument(let message):
            return message
        case .unreadableConfig(let path):
            return "Unable to read config at \(path)"
        case .invalidConfig(let message):
            return "Invalid config: \(message)"
        case .invalidPath(let message):
            return "Invalid path: \(message)"
        case .missingPath(let path):
            return "Missing path: \(path)"
        case .commandFailed(let message):
            return message
        case .unableToWrite(let path):
            return "Unable to write: \(path)"
        }
    }
}

func usage() -> String {
    """
    Usage:
      ai-reviewer-watcher validate --config <path>
      ai-reviewer-watcher watch --config <path>
      ai-reviewer-watcher materialize-head --config <path>
    """
}

func expandedPath(_ path: String) -> String {
    NSString(string: path).expandingTildeInPath
}

func loadConfig(path: String) throws -> AppConfig {
    let expanded = expandedPath(path)
    guard let data = FileManager.default.contents(atPath: expanded) else {
        throw AIReviewerError.unreadableConfig(expanded)
    }

    do {
        return try JSONDecoder().decode(AppConfig.self, from: data)
    } catch {
        throw AIReviewerError.invalidConfig(error.localizedDescription)
    }
}

func saveConfig(_ config: AppConfig, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(config)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

func defaultAppConfigURL() -> URL {
    FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.ai-reviewer/config.json")
}

func runGitData(repoPath: String, arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", repoPath] + arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
        let message = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        throw AIReviewerError.commandFailed(message.isEmpty ? "git exited with status \(process.terminationStatus)" : message)
    }

    return output
}

func runGit(repoPath: String, arguments: [String]) throws -> String {
    let data = try runGitData(repoPath: repoPath, arguments: arguments)
    let output = String(data: data, encoding: .utf8) ?? ""
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

func repoURL(config: AppConfig) -> URL {
    URL(fileURLWithPath: expandedPath(config.repoPath))
}

func reportsURL(config: AppConfig) -> URL {
    repoURL(config: config).appendingPathComponent(config.reportsPath)
}

func cacheURL(config: AppConfig) -> URL {
    URL(fileURLWithPath: expandedPath(config.reviewCachePath))
}

func validatePaths(config: AppConfig) throws {
    let repoPath = repoURL(config: config).path
    let reportsPath = reportsURL(config: config).path
    let headLogPath = repoURL(config: config).appendingPathComponent(".git/logs/HEAD").path

    for path in [repoPath, reportsPath, headLogPath] {
        guard FileManager.default.fileExists(atPath: path) else {
            throw AIReviewerError.missingPath(path)
        }
    }
}

func validationSummary(config: AppConfig) throws -> String {
    try validatePaths(config: config)

    let repoPath = repoURL(config: config).path
    let head = try runGit(repoPath: repoPath, arguments: ["rev-parse", "--short", "HEAD"])
    let branch = try runGit(repoPath: repoPath, arguments: ["branch", "--show-current"])

    return """
    AI Reviewer
    repo: \(repoPath)
    reports: \(reportsURL(config: config).path)
    cache: \(cacheURL(config: config).path)
    codexHome: \(expandedPath(config.codexHome))
    head: \(head)
    branch: \(branch.isEmpty ? "(detached)" : branch)
    maxParallelReviews: \(config.maxParallelReviews)
    pollIntervalSeconds: \(config.pollIntervalSeconds)
    maxSnapshotBytes: \(config.snapshotByteLimit)
    """
}

func validate(config: AppConfig) throws {
    print(try validationSummary(config: config))
}

func watch(config: AppConfig) throws -> Never {
    try validate(config: config)

    let repoPath = repoURL(config: config).path
    let interval = max(1, config.pollIntervalSeconds)
    var lastHead = try runGit(repoPath: repoPath, arguments: ["rev-parse", "HEAD"])

    print("watching: \(repoPath)")
    print("initialHead: \(lastHead)")

    while true {
        Thread.sleep(forTimeInterval: TimeInterval(interval))

        do {
            let head = try runGit(repoPath: repoPath, arguments: ["rev-parse", "HEAD"])
            if head != lastHead {
                print("headChanged: \(lastHead) -> \(head)")
                lastHead = head
            }
        } catch {
            fputs("watch warning: \(error)\n", stderr)
        }
    }
}

func parseChangedFiles(repoPath: String, commit: String) throws -> [(status: String, path: String, oldPath: String?)] {
    let output = try runGit(repoPath: repoPath, arguments: ["diff-tree", "--no-commit-id", "--name-status", "-r", "-M", commit])

    return output
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let status = parts.first else {
                return (status: "?", path: String(line), oldPath: nil)
            }

            if status.hasPrefix("R"), parts.count >= 3 {
                return (status: status, path: parts[2], oldPath: parts[1])
            }

            return (status: status, path: parts.dropFirst().joined(separator: "\t"), oldPath: nil)
        }
}

func safeRelativePath(_ path: String) throws -> String {
    guard !path.isEmpty,
          !path.hasPrefix("/"),
          !path.split(separator: "/").contains("..")
    else {
        throw AIReviewerError.invalidPath(path)
    }

    return path
}

func writeData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        throw AIReviewerError.unableToWrite(url.path)
    }
}

func materializeSnapshot(repoPath: String, commit: String, path: String, snapshotsURL: URL, byteLimit: Int) throws -> (relativePath: String, bytes: Int, capped: Bool)? {
    let statusPath = try safeRelativePath(path)
    let data: Data

    do {
        data = try runGitData(repoPath: repoPath, arguments: ["show", "\(commit):\(statusPath)"])
    } catch {
        return nil
    }

    let capped = data.count > byteLimit
    let outputData = capped ? data.prefix(byteLimit) : data[...]
    let relativeSnapshotPath = "snapshots/\(statusPath)"
    let snapshotURL = snapshotsURL.appendingPathComponent(statusPath)
    try writeData(Data(outputData), to: snapshotURL)

    return (relativeSnapshotPath, outputData.count, capped)
}

func materializeHead(config: AppConfig) throws {
    try validatePaths(config: config)

    let repoPath = repoURL(config: config).path
    let branch = try runGit(repoPath: repoPath, arguments: ["branch", "--show-current"])
    let commit = try runGit(repoPath: repoPath, arguments: ["rev-parse", "HEAD"])
    let shortCommit = try runGit(repoPath: repoPath, arguments: ["rev-parse", "--short", "HEAD"])

    let bundleURL = cacheURL(config: config)
        .appendingPathComponent("bundles")
        .appendingPathComponent(commit)
    let snapshotsURL = bundleURL.appendingPathComponent("snapshots")

    if FileManager.default.fileExists(atPath: bundleURL.path) {
        try FileManager.default.removeItem(at: bundleURL)
    }
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

    let commitText = try runGitData(repoPath: repoPath, arguments: ["show", "--no-patch", "--format=fuller", commit])
    try writeData(commitText, to: bundleURL.appendingPathComponent("commit.txt"))

    let diff = try runGitData(repoPath: repoPath, arguments: ["show", "--format=", "--find-renames", "--patch", commit])
    try writeData(diff, to: bundleURL.appendingPathComponent("diff.patch"))

    let changedFiles = try parseChangedFiles(repoPath: repoPath, commit: commit).map { changed -> ChangedFile in
        let snapshot: (relativePath: String, bytes: Int, capped: Bool)?
        if changed.status.hasPrefix("D") {
            snapshot = nil
        } else {
            snapshot = try materializeSnapshot(
                repoPath: repoPath,
                commit: commit,
                path: changed.path,
                snapshotsURL: snapshotsURL,
                byteLimit: config.snapshotByteLimit
            )
        }

        return ChangedFile(
            status: changed.status,
            path: changed.path,
            oldPath: changed.oldPath,
            snapshotPath: snapshot?.relativePath,
            snapshotBytes: snapshot?.bytes,
            snapshotCapped: snapshot?.capped ?? false
        )
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601

    let changedFilesData = try encoder.encode(changedFiles)
    try writeData(changedFilesData, to: bundleURL.appendingPathComponent("changed-files.json"))

    let manifest = BundleManifest(
        schemaVersion: 1,
        commit: commit,
        shortCommit: shortCommit,
        branch: branch.isEmpty ? "(detached)" : branch,
        createdAt: ISO8601DateFormatter().string(from: Date()),
        changedFiles: changedFiles
    )
    let manifestData = try encoder.encode(manifest)
    try writeData(manifestData, to: bundleURL.appendingPathComponent("bundle.json"))

    print("materialized: \(bundleURL.path)")
    print("commit: \(shortCommit)")
    print("changedFiles: \(changedFiles.count)")
}

func parseCommand(_ args: [String]) throws -> (Command, String) {
    guard args.count == 4,
          let command = Command(rawValue: args[1]),
          args[2] == "--config"
    else {
        throw AIReviewerError.missingArgument(usage())
    }

    return (command, args[3])
}

@MainActor
final class SettingsAppDelegate: NSObject, NSApplicationDelegate {
    private let configURL = defaultAppConfigURL()
    private var window: NSWindow?

    private let repoField = NSTextField()
    private let reportsField = NSTextField()
    private let cacheField = NSTextField()
    private let codexHomeField = NSTextField()
    private let pollIntervalField = NSTextField()
    private let maxParallelField = NSTextField()
    private let maxSnapshotField = NSTextField()
    private let statusField = NSTextField(labelWithString: "Idle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        buildWindow()
        loadConfigIntoFields()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit AI Reviewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 430),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Reviewer"
        window.minSize = NSSize(width: 680, height: 390)

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        root.addArrangedSubview(title)

        root.addArrangedSubview(row(label: "Repository", field: repoField, buttonTitle: "Choose", action: #selector(chooseRepository)))
        root.addArrangedSubview(row(label: "Reports Path", field: reportsField))
        root.addArrangedSubview(row(label: "Cache Path", field: cacheField))
        root.addArrangedSubview(row(label: "Codex Home", field: codexHomeField))
        root.addArrangedSubview(row(label: "Poll Seconds", field: pollIntervalField))
        root.addArrangedSubview(row(label: "Max Parallel", field: maxParallelField))
        root.addArrangedSubview(row(label: "Max Snapshot Bytes", field: maxSnapshotField))

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(button(title: "Save", action: #selector(saveSettings)))
        buttonRow.addArrangedSubview(button(title: "Validate", action: #selector(validateSettings)))
        buttonRow.addArrangedSubview(button(title: "Materialize HEAD", action: #selector(materializeHeadFromSettings)))
        buttonRow.addArrangedSubview(button(title: "Open Cache", action: #selector(openCache)))
        root.addArrangedSubview(buttonRow)

        statusField.lineBreakMode = .byWordWrapping
        statusField.maximumNumberOfLines = 5
        statusField.textColor = .secondaryLabelColor
        root.addArrangedSubview(statusField)

        window.contentView = NSView()
        window.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor)
        ])

        self.window = window
    }

    private func row(label: String, field: NSTextField, buttonTitle: String? = nil, action: Selector? = nil) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10

        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: 140).isActive = true

        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 430).isActive = true

        stack.addArrangedSubview(labelView)
        stack.addArrangedSubview(field)

        if let buttonTitle, let action {
            stack.addArrangedSubview(button(title: buttonTitle, action: action))
        }

        return stack
    }

    private func button(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func loadConfigIntoFields() {
        let config: AppConfig
        if FileManager.default.fileExists(atPath: configURL.path),
           let loaded = try? loadConfig(path: configURL.path) {
            config = loaded
            statusField.stringValue = "Loaded \(configURL.path)"
        } else {
            config = defaultConfig()
            statusField.stringValue = "New config"
        }

        repoField.stringValue = config.repoPath
        reportsField.stringValue = config.reportsPath
        cacheField.stringValue = config.reviewCachePath
        codexHomeField.stringValue = config.codexHome
        pollIntervalField.stringValue = "\(config.pollIntervalSeconds)"
        maxParallelField.stringValue = "\(config.maxParallelReviews)"
        maxSnapshotField.stringValue = "\(config.snapshotByteLimit)"
    }

    private func configFromFields() throws -> AppConfig {
        guard let pollInterval = Int(pollIntervalField.stringValue),
              let maxParallel = Int(maxParallelField.stringValue),
              let maxSnapshot = Int(maxSnapshotField.stringValue)
        else {
            throw AIReviewerError.invalidConfig("numeric settings must be valid integers")
        }

        return AppConfig(
            repoPath: repoField.stringValue,
            reportsPath: reportsField.stringValue,
            maxParallelReviews: max(1, maxParallel),
            pollIntervalSeconds: max(1, pollInterval),
            codexHome: codexHomeField.stringValue,
            reviewCachePath: cacheField.stringValue,
            maxSnapshotBytes: max(1, maxSnapshot)
        )
    }

    @objc private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            repoField.stringValue = url.path
        }
    }

    @objc private func saveSettings() {
        do {
            let config = try configFromFields()
            try saveConfig(config, to: configURL)
            statusField.stringValue = "Saved \(configURL.path)"
        } catch {
            statusField.stringValue = "\(error)"
        }
    }

    @objc private func validateSettings() {
        do {
            let config = try configFromFields()
            statusField.stringValue = try validationSummary(config: config)
        } catch {
            statusField.stringValue = "\(error)"
        }
    }

    @objc private func materializeHeadFromSettings() {
        do {
            let config = try configFromFields()
            try saveConfig(config, to: configURL)
            try materializeHead(config: config)
            statusField.stringValue = "Materialized HEAD into \(cacheURL(config: config).path)"
        } catch {
            statusField.stringValue = "\(error)"
        }
    }

    @objc private func openCache() {
        do {
            let config = try configFromFields()
            let url = cacheURL(config: config)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch {
            statusField.stringValue = "\(error)"
        }
    }
}

@MainActor
func runSettingsApp() {
    let app = NSApplication.shared
    let delegate = SettingsAppDelegate()
    app.delegate = delegate
    app.run()
}

if CommandLine.arguments.count == 1 {
    runSettingsApp()
} else {
    do {
        let (command, configPath) = try parseCommand(CommandLine.arguments)
        let config = try loadConfig(path: configPath)

        switch command {
        case .validate:
            try validate(config: config)
        case .watch:
            try watch(config: config)
        case .materializeHead:
            try materializeHead(config: config)
        }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}
