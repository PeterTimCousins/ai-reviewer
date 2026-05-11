import AppKit
import Foundation

struct AppConfig: Codable, Sendable {
    var repoPath: String
    var reportsPath: String
    var maxParallelReviews: Int
    var pollIntervalSeconds: Int
    var codexHome: String
    var reviewCachePath: String
    var maxSnapshotBytes: Int?
    var codexModel: String?
    var statePath: String?
    var reviewCurrentHeadOnStartup: Bool?

    var snapshotByteLimit: Int {
        max(1, maxSnapshotBytes ?? 200_000)
    }

    var shouldReviewCurrentHeadOnStartup: Bool {
        reviewCurrentHeadOnStartup ?? false
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
        maxSnapshotBytes: 200_000,
        codexModel: nil,
        statePath: nil,
        reviewCurrentHeadOnStartup: false
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

struct ReviewRecord: Codable {
    var sha: String
    var shortSha: String
    var reviewedAt: String
    var bundlePath: String
    var localReviewPath: String
    var copiedReportPath: String
}

struct ReviewFailureRecord: Codable {
    var sha: String
    var shortSha: String
    var failedAt: String
    var error: String
    var bundlePath: String?
    var localReviewPath: String?
}

struct ReviewState: Codable {
    var schemaVersion: Int
    var updatedAt: String?
    var lastSeenHead: String?
    var lastBundlePath: String?
    var lastReviewPath: String?
    var reviewed: [String: ReviewRecord]
    var failed: [String: ReviewFailureRecord]

    static func empty() -> ReviewState {
        ReviewState(
            schemaVersion: 1,
            updatedAt: nil,
            lastSeenHead: nil,
            lastBundlePath: nil,
            lastReviewPath: nil,
            reviewed: [:],
            failed: [:]
        )
    }
}

enum Command: String {
    case validate
    case watch
    case materializeHead = "materialize-head"
    case runCodex = "run-codex"
    case reviewHead = "review-head"
    case reviewOnce = "review-once"
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
      ai-reviewer-watcher run-codex --config <path> --bundle <sha-or-path>
      ai-reviewer-watcher review-head --config <path>
      ai-reviewer-watcher review-once --config <path>
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

func loadState(config: AppConfig) throws -> ReviewState {
    let url = stateURL(config: config)
    guard FileManager.default.fileExists(atPath: url.path) else {
        return .empty()
    }

    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(ReviewState.self, from: data)
}

func saveState(_ state: ReviewState, config: AppConfig) throws {
    var nextState = state
    nextState.updatedAt = isoNow()

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(nextState)
    let url = stateURL(config: config)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

func defaultAppConfigURL() -> URL {
    FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.ai-reviewer/config.json")
}

func appSupportURL() -> URL {
    FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.ai-reviewer")
}

func stateURL(config: AppConfig) -> URL {
    if let statePath = config.statePath, !statePath.isEmpty {
        return URL(fileURLWithPath: expandedPath(statePath))
    }

    return appSupportURL().appendingPathComponent("state.json")
}

func isoNow() -> String {
    ISO8601DateFormatter().string(from: Date())
}

func timestampForFilename() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
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

func bundlesURL(config: AppConfig) -> URL {
    cacheURL(config: config).appendingPathComponent("bundles")
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
    state: \(stateURL(config: config).path)
    codexHome: \(expandedPath(config.codexHome))
    head: \(head)
    branch: \(branch.isEmpty ? "(detached)" : branch)
    maxParallelReviews: \(config.maxParallelReviews)
    pollIntervalSeconds: \(config.pollIntervalSeconds)
    reviewCurrentHeadOnStartup: \(config.shouldReviewCurrentHeadOnStartup)
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
    if config.shouldReviewCurrentHeadOnStartup {
        do {
            _ = try reviewOnce(config: config)
        } catch {
            fputs("watch startup warning: \(error)\n", stderr)
        }
    }

    while true {
        Thread.sleep(forTimeInterval: TimeInterval(interval))

        do {
            let head = try runGit(repoPath: repoPath, arguments: ["rev-parse", "HEAD"])
            if head != lastHead {
                print("headChanged: \(lastHead) -> \(head)")
                _ = try reviewOnce(config: config)
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

func trashExistingItem(at url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return
    }

    var trashedURL: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
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

func materializeHead(config: AppConfig) throws -> URL {
    try validatePaths(config: config)

    let repoPath = repoURL(config: config).path
    let branch = try runGit(repoPath: repoPath, arguments: ["branch", "--show-current"])
    let commit = try runGit(repoPath: repoPath, arguments: ["rev-parse", "HEAD"])
    let shortCommit = try runGit(repoPath: repoPath, arguments: ["rev-parse", "--short", "HEAD"])

    let bundleURL = bundlesURL(config: config)
        .appendingPathComponent(commit)
    let snapshotsURL = bundleURL.appendingPathComponent("snapshots")

    try trashExistingItem(at: bundleURL)
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

    return bundleURL
}

func resolveBundleURL(config: AppConfig, bundle: String) throws -> URL {
    let candidate: URL
    if bundle.contains("/") || bundle.hasPrefix("~") {
        candidate = URL(fileURLWithPath: expandedPath(bundle))
    } else {
        let root = bundlesURL(config: config)
        let exact = root.appendingPathComponent(bundle)
        if FileManager.default.fileExists(atPath: exact.path) {
            candidate = exact
        } else {
            let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
            let matches = contents.filter { $0.hasPrefix(bundle) }
            guard matches.count == 1, let match = matches.first else {
                throw AIReviewerError.missingPath("bundle \(bundle) under \(root.path)")
            }
            candidate = root.appendingPathComponent(match)
        }
    }

    let standardizedCandidate = candidate.standardizedFileURL
    let standardizedRoot = bundlesURL(config: config).standardizedFileURL
    guard standardizedCandidate.path == standardizedRoot.path || standardizedCandidate.path.hasPrefix(standardizedRoot.path + "/") else {
        throw AIReviewerError.invalidPath("bundle must live under \(standardizedRoot.path)")
    }

    for name in ["bundle.json", "commit.txt", "diff.patch", "changed-files.json"] {
        let path = standardizedCandidate.appendingPathComponent(name).path
        guard FileManager.default.fileExists(atPath: path) else {
            throw AIReviewerError.missingPath(path)
        }
    }

    return standardizedCandidate
}

func runCodexPrompt(bundleURL: URL) -> String {
    """
    You are Codex running a read-only review against a local AI Reviewer bundle.

    Security boundary:
    - Your working directory is the local bundle directory.
    - Review only files in this bundle.
    - Do not access any path outside the current working directory.
    - Do not edit files, create files, run tests, install packages, or call network services.
    - The live source repository is intentionally not available.

    Bundle files:
    - bundle.json: commit metadata and changed-file manifest
    - commit.txt: commit metadata
    - diff.patch: patch for the reviewed commit
    - changed-files.json: changed files and snapshot metadata
    - snapshots/: capped post-commit file snapshots

    Review only the changes represented by this bundle. Do not report pre-existing
    issues unless this diff clearly makes them worse.

    Output format:
    REVIEW
    VERDICT: PASS or FAIL
    FINDINGS:
    - [score|category] path:line - concrete issue

    If there are no concrete issues, write:
    REVIEW
    VERDICT: PASS
    FINDINGS:
    - none
    """
}

func runCodex(config: AppConfig, bundleURL: URL) throws -> URL {
    let runRoot = cacheURL(config: config).appendingPathComponent("codex-runs")
    let runID = "\(bundleURL.lastPathComponent)-\(Int(Date().timeIntervalSince1970))"
    let runURL = runRoot.appendingPathComponent(runID)
    let homeURL = runURL.appendingPathComponent("home")
    let tmpURL = runURL.appendingPathComponent("tmp")
    let outputURL = bundleURL.appendingPathComponent("codex-review.md")
    let logURL = bundleURL.appendingPathComponent("codex.log")
    let prompt = runCodexPrompt(bundleURL: bundleURL)
    let reviewPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let logHandle = try FileHandle(forWritingTo: logURL)
    try logHandle.truncate(atOffset: 0)
    defer {
        try? logHandle.close()
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

    var arguments = [
        "-i",
        "HOME=\(homeURL.path)",
        "CODEX_HOME=\(expandedPath(config.codexHome))",
        "TMPDIR=\(tmpURL.path)",
        "PATH=\(reviewPath)",
        "USER=\(NSUserName())",
        "LOGNAME=\(NSUserName())",
        "SHELL=/bin/bash",
        "codex",
        "--ask-for-approval", "never",
        "exec",
        "--ignore-user-config",
        "--ignore-rules",
        "--skip-git-repo-check",
        "--cd", bundleURL.path,
        "--sandbox", "read-only",
        "--ephemeral",
        "--color", "never",
        "-c", "shell_environment_policy.inherit=none"
    ]

    if let model = config.codexModel, !model.isEmpty {
        arguments += ["--model", model]
    }

    arguments += ["--output-last-message", outputURL.path, "-"]
    process.arguments = arguments

    let inputPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = logHandle
    process.standardError = logHandle

    try process.run()
    inputPipe.fileHandleForWriting.write(Data(prompt.utf8))
    try inputPipe.fileHandleForWriting.close()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let logData = (try? Data(contentsOf: logURL)) ?? Data()
        let logText = String(data: logData, encoding: .utf8) ?? ""
        let tail = logText.split(separator: "\n").suffix(40).joined(separator: "\n")
        throw AIReviewerError.commandFailed("codex exited with status \(process.terminationStatus)\n\(tail)")
    }

    guard FileManager.default.fileExists(atPath: outputURL.path) else {
        throw AIReviewerError.missingPath(outputURL.path)
    }

    print("codexReview: \(outputURL.path)")
    print("codexLog: \(logURL.path)")
    return outputURL
}

func copyReportBack(config: AppConfig, reviewURL: URL, shortCommit: String) throws -> URL {
    let reportData = try Data(contentsOf: reviewURL)
    let reportsDirectory = reportsURL(config: config)
    try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)

    let reportURL = reportsDirectory.appendingPathComponent("\(shortCommit)-\(timestampForFilename()).md")
    try writeData(reportData, to: reportURL)
    print("copiedReport: \(reportURL.path)")
    return reportURL
}

func reviewOnce(config: AppConfig) throws -> URL? {
    try validatePaths(config: config)

    let repoPath = repoURL(config: config).path
    let commit = try runGit(repoPath: repoPath, arguments: ["rev-parse", "HEAD"])
    let shortCommit = try runGit(repoPath: repoPath, arguments: ["rev-parse", "--short", "HEAD"])
    var state = try loadState(config: config)
    state.lastSeenHead = commit

    if let reviewed = state.reviewed[commit] {
        state.lastBundlePath = reviewed.bundlePath
        state.lastReviewPath = reviewed.localReviewPath
        try saveState(state, config: config)
        print("alreadyReviewed: \(shortCommit)")
        print("copiedReport: \(reviewed.copiedReportPath)")
        return nil
    }

    var bundleURL: URL?
    var reviewURL: URL?

    do {
        let materializedBundleURL = try materializeHead(config: config)
        bundleURL = materializedBundleURL
        state.lastBundlePath = materializedBundleURL.path
        try saveState(state, config: config)

        let localReviewURL = try runCodex(config: config, bundleURL: materializedBundleURL)
        reviewURL = localReviewURL
        state.lastReviewPath = localReviewURL.path

        let copiedReportURL = try copyReportBack(config: config, reviewURL: localReviewURL, shortCommit: shortCommit)
        state.reviewed[commit] = ReviewRecord(
            sha: commit,
            shortSha: shortCommit,
            reviewedAt: isoNow(),
            bundlePath: materializedBundleURL.path,
            localReviewPath: localReviewURL.path,
            copiedReportPath: copiedReportURL.path
        )
        state.failed.removeValue(forKey: commit)
        try saveState(state, config: config)

        print("reviewed: \(shortCommit)")
        return copiedReportURL
    } catch {
        state.failed[commit] = ReviewFailureRecord(
            sha: commit,
            shortSha: shortCommit,
            failedAt: isoNow(),
            error: "\(error)",
            bundlePath: bundleURL?.path,
            localReviewPath: reviewURL?.path
        )
        try? saveState(state, config: config)
        throw error
    }
}

struct ParsedCommand {
    let command: Command
    let configPath: String
    let bundle: String?
}

func parseCommand(_ args: [String]) throws -> ParsedCommand {
    guard args.count >= 4,
          let command = Command(rawValue: args[1]),
          args[2] == "--config"
    else {
        throw AIReviewerError.missingArgument(usage())
    }

    switch command {
    case .validate, .watch, .materializeHead, .reviewHead, .reviewOnce:
        guard args.count == 4 else {
            throw AIReviewerError.missingArgument(usage())
        }
        return ParsedCommand(command: command, configPath: args[3], bundle: nil)
    case .runCodex:
        guard args.count == 6, args[4] == "--bundle" else {
            throw AIReviewerError.missingArgument(usage())
        }
        return ParsedCommand(command: command, configPath: args[3], bundle: args[5])
    }
}

struct WatcherUpdate: Sendable {
    let status: String
    let isRunning: Bool
    let lastHead: String?
    let lastReview: String?
    let lastError: String?
}

final class AppWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ai-reviewer.app-watcher", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var isRunning = false
    private var isReviewing = false
    private var lastHead: String?
    private var lastReview: String?
    private var lastError: String?

    func start(config: AppConfig, onUpdate: @escaping @Sendable (WatcherUpdate) -> Void) {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.isRunning = true
            self.isReviewing = false
            self.lastReview = nil
            self.lastError = nil
            self.send("Starting watcher...", onUpdate: onUpdate)

            do {
                try validatePaths(config: config)
                let repoPath = repoURL(config: config).path
                self.lastHead = try runGit(repoPath: repoPath, arguments: ["rev-parse", "HEAD"])
                self.send("Watching \(repoPath)", onUpdate: onUpdate)

                if config.shouldReviewCurrentHeadOnStartup {
                    self.reviewCurrentHead(config: config, reason: "Reviewing current HEAD on startup", onUpdate: onUpdate)
                }

                let interval = max(1, config.pollIntervalSeconds)
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
                timer.setEventHandler { [weak self] in
                    self?.poll(config: config, onUpdate: onUpdate)
                }
                self.timer = timer
                timer.resume()
            } catch {
                self.isRunning = false
                self.lastError = "\(error)"
                self.send("Watcher failed to start", onUpdate: onUpdate)
            }
        }
    }

    func stop(onUpdate: @escaping @Sendable (WatcherUpdate) -> Void) {
        queue.async {
            self.isRunning = false
            self.timer?.cancel()
            self.timer = nil
            let suffix = self.isReviewing ? " after current review finishes" : ""
            self.send("Watcher stopped\(suffix)", onUpdate: onUpdate)
        }
    }

    private func poll(config: AppConfig, onUpdate: @escaping @Sendable (WatcherUpdate) -> Void) {
        guard isRunning, !isReviewing else {
            return
        }

        do {
            let repoPath = repoURL(config: config).path
            let head = try runGit(repoPath: repoPath, arguments: ["rev-parse", "HEAD"])

            if lastHead == nil {
                lastHead = head
            }

            guard head != lastHead else {
                send("Watching for commits", onUpdate: onUpdate)
                return
            }

            let previousHead = lastHead
            lastHead = head
            reviewCurrentHead(
                config: config,
                reason: "HEAD changed \(short(previousHead)) -> \(short(head))",
                onUpdate: onUpdate
            )
        } catch {
            lastError = "\(error)"
            send("Watcher poll failed", onUpdate: onUpdate)
        }
    }

    private func reviewCurrentHead(config: AppConfig, reason: String, onUpdate: @escaping @Sendable (WatcherUpdate) -> Void) {
        guard isRunning else {
            return
        }

        isReviewing = true
        lastError = nil
        send(reason, onUpdate: onUpdate)

        do {
            if let reportURL = try reviewOnce(config: config) {
                lastReview = reportURL.path
                send("Review completed", onUpdate: onUpdate)
            } else {
                send("HEAD already reviewed", onUpdate: onUpdate)
            }
        } catch {
            lastError = "\(error)"
            send("Review failed", onUpdate: onUpdate)
        }

        isReviewing = false
    }

    private func send(_ status: String, onUpdate: @Sendable (WatcherUpdate) -> Void) {
        onUpdate(WatcherUpdate(
            status: status,
            isRunning: isRunning,
            lastHead: lastHead,
            lastReview: lastReview,
            lastError: lastError
        ))
    }

    private func short(_ sha: String?) -> String {
        guard let sha, !sha.isEmpty else {
            return "(none)"
        }

        return String(sha.prefix(7))
    }
}

@MainActor
final class SettingsAppDelegate: NSObject, NSApplicationDelegate {
    private let configURL = defaultAppConfigURL()
    private var window: NSWindow?
    private let appWatcher = AppWatcher()
    private var watcherRunning = false

    private let repoField = NSTextField()
    private let reportsField = NSTextField()
    private let cacheField = NSTextField()
    private let codexHomeField = NSTextField()
    private let codexModelField = NSTextField()
    private let statePathField = NSTextField()
    private let pollIntervalField = NSTextField()
    private let maxParallelField = NSTextField()
    private let maxSnapshotField = NSTextField()
    private let reviewStartupCheckbox = NSButton(checkboxWithTitle: "Review current HEAD when watcher starts", target: nil, action: nil)
    private let statusField = NSTextField(labelWithString: "Idle")
    private let watcherField = NSTextField(labelWithString: "Watcher: stopped")
    private var startWatcherButton: NSButton?
    private var stopWatcherButton: NSButton?

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
        !watcherRunning
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        appWatcher.stop { _ in }
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettingsWindow), keyEquivalent: ","))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit AI Reviewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Reviewer"
        window.minSize = NSSize(width: 680, height: 480)

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
        root.addArrangedSubview(row(label: "Codex Model", field: codexModelField))
        root.addArrangedSubview(row(label: "State Path", field: statePathField))
        root.addArrangedSubview(row(label: "Poll Seconds", field: pollIntervalField))
        root.addArrangedSubview(row(label: "Max Parallel", field: maxParallelField))
        root.addArrangedSubview(row(label: "Max Snapshot Bytes", field: maxSnapshotField))
        root.addArrangedSubview(checkboxRow(reviewStartupCheckbox))

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(button(title: "Save", action: #selector(saveSettings)))
        buttonRow.addArrangedSubview(button(title: "Validate", action: #selector(validateSettings)))
        buttonRow.addArrangedSubview(button(title: "Materialize HEAD", action: #selector(materializeHeadFromSettings)))
        buttonRow.addArrangedSubview(button(title: "Review HEAD", action: #selector(reviewHeadFromSettings)))
        buttonRow.addArrangedSubview(button(title: "Review Once", action: #selector(reviewOnceFromSettings)))
        buttonRow.addArrangedSubview(button(title: "Open Cache", action: #selector(openCache)))
        root.addArrangedSubview(buttonRow)

        let watcherRow = NSStackView()
        watcherRow.orientation = .horizontal
        watcherRow.spacing = 8
        let startButton = button(title: "Start Watching", action: #selector(startWatching))
        let stopButton = button(title: "Stop Watching", action: #selector(stopWatching))
        stopButton.isEnabled = false
        startWatcherButton = startButton
        stopWatcherButton = stopButton
        watcherRow.addArrangedSubview(startButton)
        watcherRow.addArrangedSubview(stopButton)
        root.addArrangedSubview(watcherRow)

        watcherField.lineBreakMode = .byWordWrapping
        watcherField.maximumNumberOfLines = 8
        watcherField.textColor = .secondaryLabelColor
        root.addArrangedSubview(watcherField)

        statusField.lineBreakMode = .byWordWrapping
        statusField.maximumNumberOfLines = 12
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

    @objc private func showSettingsWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    private func checkboxRow(_ checkbox: NSButton) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10

        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 140).isActive = true

        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(checkbox)
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
        codexModelField.stringValue = config.codexModel ?? ""
        statePathField.stringValue = config.statePath ?? ""
        pollIntervalField.stringValue = "\(config.pollIntervalSeconds)"
        maxParallelField.stringValue = "\(config.maxParallelReviews)"
        maxSnapshotField.stringValue = "\(config.snapshotByteLimit)"
        reviewStartupCheckbox.state = config.shouldReviewCurrentHeadOnStartup ? .on : .off
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
            maxSnapshotBytes: max(1, maxSnapshot),
            codexModel: codexModelField.stringValue.isEmpty ? nil : codexModelField.stringValue,
            statePath: statePathField.stringValue.isEmpty ? nil : statePathField.stringValue,
            reviewCurrentHeadOnStartup: reviewStartupCheckbox.state == .on
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
        runConfiguredOperation("Validating") { config in
            try validationSummary(config: config)
        }
    }

    @objc private func materializeHeadFromSettings() {
        runConfiguredOperation("Materializing HEAD") { config in
            let bundleURL = try materializeHead(config: config)
            return "Materialized HEAD into \(bundleURL.path)"
        }
    }

    @objc private func reviewHeadFromSettings() {
        runConfiguredOperation("Reviewing HEAD") { config in
            let bundleURL = try materializeHead(config: config)
            let reviewURL = try runCodex(config: config, bundleURL: bundleURL)
            return "Review written to \(reviewURL.path)"
        }
    }

    @objc private func reviewOnceFromSettings() {
        runConfiguredOperation("Running one-shot review") { config in
            if let reportURL = try reviewOnce(config: config) {
                return "Review copied to \(reportURL.path)"
            }

            return "HEAD already reviewed"
        }
    }

    @objc private func startWatching() {
        do {
            let config = try configFromFields()
            try saveConfig(config, to: configURL)
            watcherRunning = true
            startWatcherButton?.isEnabled = false
            stopWatcherButton?.isEnabled = true
            watcherField.stringValue = "Watcher: starting..."
            appWatcher.start(config: config) { [weak self] update in
                DispatchQueue.main.async {
                    self?.applyWatcherUpdate(update)
                }
            }
        } catch {
            watcherField.stringValue = "Watcher: \(error)"
        }
    }

    @objc private func stopWatching() {
        watcherRunning = false
        startWatcherButton?.isEnabled = true
        stopWatcherButton?.isEnabled = false
        watcherField.stringValue = "Watcher: stopping..."
        appWatcher.stop { [weak self] update in
            DispatchQueue.main.async {
                self?.applyWatcherUpdate(update)
            }
        }
    }

    private func applyWatcherUpdate(_ update: WatcherUpdate) {
        watcherRunning = update.isRunning
        startWatcherButton?.isEnabled = !update.isRunning
        stopWatcherButton?.isEnabled = update.isRunning

        var lines = ["Watcher: \(update.status)"]
        if let lastHead = update.lastHead {
            lines.append("Last HEAD: \(String(lastHead.prefix(12)))")
        }
        if let lastReview = update.lastReview {
            lines.append("Last report: \(lastReview)")
        }
        if let lastError = update.lastError {
            lines.append("Last error: \(lastError)")
        }
        watcherField.stringValue = lines.joined(separator: "\n")
    }

    private func runConfiguredOperation(_ label: String, operation: @escaping @Sendable (AppConfig) throws -> String) {
        do {
            let config = try configFromFields()
            try saveConfig(config, to: configURL)

            statusField.stringValue = "\(label)..."
            DispatchQueue.global(qos: .userInitiated).async {
                let result: String
                do {
                    result = try operation(config)
                } catch {
                    result = "\(error)"
                }

                DispatchQueue.main.async { [weak self] in
                    self?.statusField.stringValue = result
                }
            }
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
        let parsed = try parseCommand(CommandLine.arguments)
        let config = try loadConfig(path: parsed.configPath)

        switch parsed.command {
        case .validate:
            try validate(config: config)
        case .watch:
            try watch(config: config)
        case .materializeHead:
            _ = try materializeHead(config: config)
        case .runCodex:
            guard let bundle = parsed.bundle else {
                throw AIReviewerError.missingArgument(usage())
            }
            let bundleURL = try resolveBundleURL(config: config, bundle: bundle)
            _ = try runCodex(config: config, bundleURL: bundleURL)
        case .reviewHead:
            let bundleURL = try materializeHead(config: config)
            _ = try runCodex(config: config, bundleURL: bundleURL)
        case .reviewOnce:
            _ = try reviewOnce(config: config)
        }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}
