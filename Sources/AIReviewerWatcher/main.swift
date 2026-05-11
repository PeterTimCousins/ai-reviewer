import AppKit
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

final class FileLock {
    private let url: URL
    private var descriptor: Int32 = -1

    init(url: URL) {
        self.url = url
    }

    deinit {
        unlock()
    }

    func tryLock() throws -> Bool {
        if descriptor >= 0 {
            return true
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw AIReviewerError.unableToWrite(url.path)
        }

        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            descriptor = fd
            let payload = "\(ProcessInfo.processInfo.processIdentifier)\n"
            _ = ftruncate(fd, 0)
            _ = write(fd, payload, payload.utf8.count)
            return true
        }

        close(fd)
        return false
    }

    func unlock() {
        guard descriptor >= 0 else {
            return
        }

        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    func lock() throws {
        if descriptor >= 0 {
            return
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw AIReviewerError.unableToWrite(url.path)
        }

        if flock(fd, LOCK_EX) == 0 {
            descriptor = fd
            let payload = "\(ProcessInfo.processInfo.processIdentifier)\n"
            _ = ftruncate(fd, 0)
            _ = write(fd, payload, payload.utf8.count)
            return
        }

        close(fd)
        throw AIReviewerError.unableToWrite(url.path)
    }
}

final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var exceededLimit = false

    func append(_ nextData: Data) {
        guard !nextData.isEmpty else {
            return
        }

        lock.lock()
        data.append(nextData)
        lock.unlock()
    }

    func append(_ nextData: Data, maxBytes: Int) -> Bool {
        guard !nextData.isEmpty else {
            return true
        }

        lock.lock()
        defer {
            lock.unlock()
        }

        guard !exceededLimit else {
            return false
        }

        let remaining = maxBytes - data.count
        if remaining <= 0 {
            exceededLimit = true
            return false
        }

        if nextData.count > remaining {
            data.append(nextData.prefix(remaining))
            exceededLimit = true
            return false
        }

        data.append(nextData)
        return true
    }

    var didExceedLimit: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }

        return exceededLimit
    }

    func snapshot() -> Data {
        lock.lock()
        defer {
            lock.unlock()
        }

        return data
    }
}

struct AppConfig: Codable, Sendable {
    var repoPath: String
    var reportsPath: String
    var maxParallelReviews: Int
    var maxParallelCommitReviews: Int?
    var pollIntervalSeconds: Int
    var codexHome: String
    var reviewCachePath: String
    var maxSnapshotBytes: Int?
    var codexModel: String?
    var reviewProfilePath: String?
    var statePath: String?
    var reviewCurrentHeadOnStartup: Bool?
    var startWatcherOnLaunch: Bool?
    var hideDockIcon: Bool?
    var sweepDepth: Int?
    var retryFailedAfterSeconds: Int?
    var codexTimeoutSeconds: Int?
    var maxPromptSnapshotBytes: Int?

    var snapshotByteLimit: Int {
        max(1, maxSnapshotBytes ?? 200_000)
    }

    var promptSnapshotByteLimit: Int {
        max(1, maxPromptSnapshotBytes ?? 500_000)
    }

    var shouldReviewCurrentHeadOnStartup: Bool {
        reviewCurrentHeadOnStartup ?? false
    }

    var shouldStartWatcherOnLaunch: Bool {
        startWatcherOnLaunch ?? true
    }

    var shouldHideDockIcon: Bool {
        hideDockIcon ?? true
    }

    var reviewSweepDepth: Int {
        max(1, sweepDepth ?? 50)
    }

    var failedReviewRetrySeconds: Int {
        max(0, retryFailedAfterSeconds ?? 3_600)
    }

    var codexRunTimeoutSeconds: Int {
        max(30, codexTimeoutSeconds ?? 1_800)
    }

    var commitReviewConcurrency: Int {
        max(1, maxParallelCommitReviews ?? 1)
    }
}

func defaultConfig() -> AppConfig {
    AppConfig(
        repoPath: "",
        reportsPath: "tmp_docs/reviews",
        maxParallelReviews: 1,
        maxParallelCommitReviews: 1,
        pollIntervalSeconds: 10,
        codexHome: "~/.codex",
        reviewCachePath: "~/Library/Caches/com.ai-reviewer",
        maxSnapshotBytes: 200_000,
        codexModel: nil,
        reviewProfilePath: nil,
        statePath: nil,
        reviewCurrentHeadOnStartup: false,
        startWatcherOnLaunch: true,
        hideDockIcon: true,
        sweepDepth: 50,
        retryFailedAfterSeconds: 3_600,
        codexTimeoutSeconds: 1_800,
        maxPromptSnapshotBytes: 500_000
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
    let reviewProfile: String
    let changedFiles: [ChangedFile]
}

struct ReviewProfile: Codable, Sendable {
    var schemaVersion: Int
    var name: String
    var description: String?
    var maxDiffBytes: Int?
    var ignorePaths: [String]
    var globalInstructions: String
    var defaultModel: String?
    var agents: [ReviewAgentProfile]
}

struct ReviewAgentProfile: Codable, Sendable {
    var id: String
    var title: String
    var category: String
    var model: String?
    var instructions: String
    var alwaysRun: Bool?
    var runIfPathContains: [String]?
    var runIfDiffContains: [String]?

    var shouldAlwaysRun: Bool {
        alwaysRun ?? true
    }
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
    var skipped: [String: ReviewSkipRecord]?
    var reviewed: [String: ReviewRecord]
    var failed: [String: ReviewFailureRecord]

    init(
        schemaVersion: Int,
        updatedAt: String?,
        lastSeenHead: String?,
        lastBundlePath: String?,
        lastReviewPath: String?,
        skipped: [String: ReviewSkipRecord]?,
        reviewed: [String: ReviewRecord],
        failed: [String: ReviewFailureRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.lastSeenHead = lastSeenHead
        self.lastBundlePath = lastBundlePath
        self.lastReviewPath = lastReviewPath
        self.skipped = skipped
        self.reviewed = reviewed
        self.failed = failed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        lastSeenHead = try container.decodeIfPresent(String.self, forKey: .lastSeenHead)
        lastBundlePath = try container.decodeIfPresent(String.self, forKey: .lastBundlePath)
        lastReviewPath = try container.decodeIfPresent(String.self, forKey: .lastReviewPath)
        skipped = try container.decodeIfPresent([String: ReviewSkipRecord].self, forKey: .skipped) ?? [:]
        reviewed = try container.decodeIfPresent([String: ReviewRecord].self, forKey: .reviewed) ?? [:]
        failed = try container.decodeIfPresent([String: ReviewFailureRecord].self, forKey: .failed) ?? [:]
    }

    static func empty() -> ReviewState {
        ReviewState(
            schemaVersion: 1,
            updatedAt: nil,
            lastSeenHead: nil,
            lastBundlePath: nil,
            lastReviewPath: nil,
            skipped: [:],
            reviewed: [:],
            failed: [:]
        )
    }
}

struct ReviewSkipRecord: Codable {
    var sha: String
    var shortSha: String
    var skippedAt: String
    var reason: String
}

enum ReviewHistoryStatus: String {
    case completed = "Completed"
    case failed = "Failed"
    case skipped = "Skipped"
    case queued = "Queued"
    case running = "Running"
    case pending = "Pending"
}

struct ReviewHistoryItem {
    let sha: String
    let shortSha: String
    let date: String
    let subject: String
    let status: ReviewHistoryStatus
    let detail: String
    let reviewPath: String?
    let localReviewPath: String?
    let bundlePath: String?
    let logPath: String?
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
    case permanentReviewSkip(String)
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
        case .permanentReviewSkip(let message):
            return message
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
    if nextState.skipped == nil {
        nextState.skipped = [:]
    }
    nextState.updatedAt = isoNow()

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(nextState)
    let url = stateURL(config: config)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

@discardableResult
func mutateState(config: AppConfig, _ update: (inout ReviewState) throws -> Void) throws -> ReviewState {
    let lock = FileLock(url: stateMutationLockURL())
    try lock.lock()
    var state = try loadState(config: config)
    try update(&state)
    try saveState(state, config: config)
    return state
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

func appInstanceLockURL() -> URL {
    appSupportURL().appendingPathComponent("app.lock")
}

func watcherLockURL() -> URL {
    appSupportURL().appendingPathComponent("watcher.lock")
}

func stateMutationLockURL() -> URL {
    appSupportURL().appendingPathComponent("state.lock")
}

func reviewCommitLockURL(commit: String) -> URL {
    appSupportURL()
        .appendingPathComponent("review-locks", isDirectory: true)
        .appendingPathComponent("\(commit).lock")
}

func appLogsURL() -> URL {
    FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/com.ai-reviewer")
}

func watcherLogURL() -> URL {
    appLogsURL().appendingPathComponent("watcher.log")
}

func stateURL(config: AppConfig) -> URL {
    if let statePath = config.statePath, !statePath.isEmpty {
        return URL(fileURLWithPath: expandedPath(statePath))
    }

    return appSupportURL().appendingPathComponent("state.json")
}

func bundledProfileURL(name: String) -> URL? {
    let candidates = [
        Bundle.main.resourceURL?
            .appendingPathComponent("profiles")
            .appendingPathComponent(name),
        Bundle.main.executableURL?
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .appendingPathComponent("profiles")
            .appendingPathComponent(name),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("profiles")
            .appendingPathComponent(name)
    ]

    return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
}

func defaultReviewProfile() -> ReviewProfile {
    ReviewProfile(
        schemaVersion: 1,
        name: "Enterprise Default Review",
        description: "Generic enterprise-grade post-commit review profile.",
        maxDiffBytes: 200_000,
        ignorePaths: [],
        globalInstructions: """
        You are Codex running a precise, read-only post-commit review for an enterprise software project.
        Review only changes introduced by the commit represented in the bundle.
        Do not report pre-existing issues unless this diff clearly makes them worse.
        Report only concrete correctness, security, data integrity, authorization, API compatibility, migration, concurrency, resilience, observability, user-facing behavior, or test issues visible from the diff and included snapshots.
        """,
        defaultModel: nil,
        agents: [
            ReviewAgentProfile(
                id: "correctness",
                title: "Correctness",
                category: "correctness",
                model: nil,
                instructions: "Check for concrete bugs: missing awaits, null/undefined access, wrong variable usage, inverted conditions, error handling gaps, data loss, and API contract breakage.",
                alwaysRun: true,
                runIfPathContains: nil,
                runIfDiffContains: nil
            ),
            ReviewAgentProfile(
                id: "security",
                title: "Security",
                category: "security",
                model: nil,
                instructions: "Check for security issues: injection, auth or authorization gaps, unsafe filesystem/shell/network use, secret exposure, tenant or user isolation failures, and unsafe logging.",
                alwaysRun: true,
                runIfPathContains: nil,
                runIfDiffContains: nil
            ),
            ReviewAgentProfile(
                id: "quality",
                title: "Quality",
                category: "quality",
                model: nil,
                instructions: "Check for maintainability risks that can cause real future defects: duplicated logic, unclear state transitions, overly broad abstractions, dead compatibility shims, and fragile UI state.",
                alwaysRun: true,
                runIfPathContains: nil,
                runIfDiffContains: nil
            )
        ]
    )
}

func loadReviewProfile(config: AppConfig) throws -> ReviewProfile {
    let decoder = JSONDecoder()

    if let profilePath = config.reviewProfilePath, !profilePath.isEmpty {
        let url = URL(fileURLWithPath: expandedPath(profilePath))
        let data = try Data(contentsOf: url)
        return try decoder.decode(ReviewProfile.self, from: data)
    }

    if let url = bundledProfileURL(name: "default-review.json"),
       FileManager.default.fileExists(atPath: url.path) {
        let data = try Data(contentsOf: url)
        return try decoder.decode(ReviewProfile.self, from: data)
    }

    return defaultReviewProfile()
}

func isoNow() -> String {
    ISO8601DateFormatter().string(from: Date())
}

func isoDate(_ value: String) -> Date? {
    ISO8601DateFormatter().date(from: value)
}

func timestampForFilename() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
}

func runGitData(repoPath: String, arguments: [String], maxOutputBytes: Int? = nil, allowTruncatedOutput: Bool = false) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", repoPath] + arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let outputBuffer = PipeBuffer()
    let errorBuffer = PipeBuffer()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    outputPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if let maxOutputBytes, !outputBuffer.append(data, maxBytes: maxOutputBytes) {
            process.terminate()
        } else if maxOutputBytes == nil {
            outputBuffer.append(data)
        }
    }
    errorPipe.fileHandleForReading.readabilityHandler = { handle in
        errorBuffer.append(handle.availableData)
    }

    try process.run()
    process.waitUntilExit()

    outputPipe.fileHandleForReading.readabilityHandler = nil
    errorPipe.fileHandleForReading.readabilityHandler = nil
    let remainingOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
    if let maxOutputBytes {
        _ = outputBuffer.append(remainingOutput, maxBytes: maxOutputBytes)
    } else {
        outputBuffer.append(remainingOutput)
    }
    errorBuffer.append(errorPipe.fileHandleForReading.readDataToEndOfFile())

    let output = outputBuffer.snapshot()
    let errorOutput = String(data: errorBuffer.snapshot(), encoding: .utf8) ?? ""

    if let maxOutputBytes, outputBuffer.didExceedLimit {
        if allowTruncatedOutput {
            return output
        }

        throw AIReviewerError.invalidConfig("git output exceeded \(maxOutputBytes) bytes for git \(arguments.joined(separator: " "))")
    }

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
    guard FileManager.default.fileExists(atPath: repoPath) else {
        throw AIReviewerError.missingPath(repoPath)
    }

    let insideWorkTree = try runGit(repoPath: repoPath, arguments: ["rev-parse", "--is-inside-work-tree"])
    guard insideWorkTree == "true" else {
        throw AIReviewerError.invalidPath("\(repoPath) is not a Git worktree")
    }

    _ = try runGit(repoPath: repoPath, arguments: ["rev-parse", "HEAD"])
    try FileManager.default.createDirectory(at: reportsURL(config: config), withIntermediateDirectories: true)
}

func validationSummary(config: AppConfig) throws -> String {
    try validatePaths(config: config)

    let repoPath = repoURL(config: config).path
    let head = try runGit(repoPath: repoPath, arguments: ["rev-parse", "--short", "HEAD"])
    let branch = try runGit(repoPath: repoPath, arguments: ["branch", "--show-current"])
    let profile = try loadReviewProfile(config: config)

    return """
    AI Reviewer
    repo: \(repoPath)
    reports: \(reportsURL(config: config).path)
    cache: \(cacheURL(config: config).path)
    state: \(stateURL(config: config).path)
    codexHome: \(expandedPath(config.codexHome))
    reviewProfile: \(profile.name)
    head: \(head)
    branch: \(branch.isEmpty ? "(detached)" : branch)
    maxParallelAgentsPerReview: \(config.maxParallelReviews)
    maxParallelCommitReviews: \(config.commitReviewConcurrency)
    pollIntervalSeconds: \(config.pollIntervalSeconds)
    startWatcherOnLaunch: \(config.shouldStartWatcherOnLaunch)
    hideDockIcon: \(config.shouldHideDockIcon)
    reviewCurrentHeadOnStartup: \(config.shouldReviewCurrentHeadOnStartup)
    sweepDepth: \(config.reviewSweepDepth)
    retryFailedAfterSeconds: \(config.failedReviewRetrySeconds)
    codexTimeoutSeconds: \(config.codexRunTimeoutSeconds)
    maxSnapshotBytes: \(config.snapshotByteLimit)
    maxPromptSnapshotBytes: \(config.promptSnapshotByteLimit)
    """
}

func validate(config: AppConfig) throws {
    print(try validationSummary(config: config))
}

func watch(config: AppConfig) throws -> Never {
    try validate(config: config)
    let lock = FileLock(url: watcherLockURL())
    guard try lock.tryLock() else {
        throw AIReviewerError.commandFailed("AI Reviewer watcher is already running.")
    }

    let repoPath = repoURL(config: config).path
    let interval = max(1, config.pollIntervalSeconds)
    var lastHead = try runGit(repoPath: repoPath, arguments: ["rev-parse", "HEAD"])

    print("watching: \(repoPath)")
    print("initialHead: \(lastHead)")
    if config.shouldReviewCurrentHeadOnStartup {
        do {
            _ = try reviewPendingCommits(config: config)
        } catch {
            fputs("watch startup warning: \(error)\n", stderr)
        }
    } else {
        try recordSeenHead(config: config, head: lastHead)
    }

    while true {
        Thread.sleep(forTimeInterval: TimeInterval(interval))

        do {
            let head = try runGit(repoPath: repoPath, arguments: ["rev-parse", "HEAD"])
            if head != lastHead {
                print("headChanged: \(lastHead) -> \(head)")
                _ = try reviewPendingCommits(config: config)
                lastHead = head
            } else if try hasRetryableFailedReviews(config: config) {
                print("retryingFailedReviews")
                _ = try reviewPendingCommits(config: config)
            }
        } catch {
            fputs("watch warning: \(error)\n", stderr)
        }
    }
}

func parseChangedFiles(repoPath: String, commit: String) throws -> [(status: String, path: String, oldPath: String?)] {
    try parseChangedFiles(repoPath: repoPath, commit: commit, ignorePaths: [])
}

func parseChangedFiles(repoPath: String, commit: String, ignorePaths: [String]) throws -> [(status: String, path: String, oldPath: String?)] {
    let output = try runGit(repoPath: repoPath, arguments: ["diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-M", commit] + gitPathspecArguments(ignorePaths: ignorePaths))

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

func gitPathspecArguments(ignorePaths: [String]) -> [String] {
    guard !ignorePaths.isEmpty else {
        return []
    }

    return ["--", "."] + ignorePaths.map { ":(exclude)\($0)" }
}

func reviewableDiffData(repoPath: String, commit: String, ignorePaths: [String], maxDiffBytes: Int?) throws -> Data {
    let limit: Int?
    if let maxDiffBytes, maxDiffBytes > 0 {
        guard maxDiffBytes < Int.max else {
            throw AIReviewerError.invalidConfig("maxDiffBytes is too large")
        }
        limit = maxDiffBytes + 1
    } else {
        limit = nil
    }

    do {
        return try runGitData(
            repoPath: repoPath,
            arguments: ["show", "--format=", "--find-renames", "--patch", commit] + gitPathspecArguments(ignorePaths: ignorePaths),
            maxOutputBytes: limit
        )
    } catch AIReviewerError.invalidConfig(_) where limit != nil {
        throw AIReviewerError.permanentReviewSkip("reviewable diff is above profile limit \(maxDiffBytes ?? 0) bytes")
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
        data = try runGitData(
            repoPath: repoPath,
            arguments: ["show", "\(commit):\(statusPath)"],
            maxOutputBytes: byteLimit + 1,
            allowTruncatedOutput: true
        )
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
    let profile = try loadReviewProfile(config: config)
    let repoPath = repoURL(config: config).path
    let commit = try runGit(repoPath: repoPath, arguments: ["rev-parse", "HEAD"])
    return try materializeCommit(config: config, profile: profile, commit: commit)
}

func materializeHead(config: AppConfig, profile: ReviewProfile) throws -> URL {
    let repoPath = repoURL(config: config).path
    let commit = try runGit(repoPath: repoPath, arguments: ["rev-parse", "HEAD"])
    return try materializeCommit(config: config, profile: profile, commit: commit)
}

func materializeCommit(config: AppConfig, profile: ReviewProfile, commit: String) throws -> URL {
    try validatePaths(config: config)

    let repoPath = repoURL(config: config).path
    let branch = try runGit(repoPath: repoPath, arguments: ["branch", "--show-current"])
    let resolvedCommit = try runGit(repoPath: repoPath, arguments: ["rev-parse", commit])
    let shortCommit = try runGit(repoPath: repoPath, arguments: ["rev-parse", "--short", resolvedCommit])

    let bundleURL = bundlesURL(config: config)
        .appendingPathComponent(resolvedCommit)
    let snapshotsURL = bundleURL.appendingPathComponent("snapshots")

    try trashExistingItem(at: bundleURL)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

    let commitText = try runGitData(repoPath: repoPath, arguments: ["show", "--no-patch", "--format=fuller", resolvedCommit])
    try writeData(commitText, to: bundleURL.appendingPathComponent("commit.txt"))

    let diff = try reviewableDiffData(
        repoPath: repoPath,
        commit: resolvedCommit,
        ignorePaths: profile.ignorePaths,
        maxDiffBytes: profile.maxDiffBytes
    )
    if let maxDiffBytes = profile.maxDiffBytes, maxDiffBytes > 0, diff.count > maxDiffBytes {
        throw AIReviewerError.permanentReviewSkip("reviewable diff is \(diff.count) bytes, above profile limit \(maxDiffBytes)")
    }
    try writeData(diff, to: bundleURL.appendingPathComponent("diff.patch"))

    let profileEncoder = JSONEncoder()
    profileEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try writeData(try profileEncoder.encode(profile), to: bundleURL.appendingPathComponent("review-profile.json"))

    let changedFiles = try parseChangedFiles(repoPath: repoPath, commit: resolvedCommit, ignorePaths: profile.ignorePaths).map { changed -> ChangedFile in
        let snapshot: (relativePath: String, bytes: Int, capped: Bool)?
        if changed.status.hasPrefix("D") {
            snapshot = nil
        } else {
            snapshot = try materializeSnapshot(
                repoPath: repoPath,
                commit: resolvedCommit,
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
        commit: resolvedCommit,
        shortCommit: shortCommit,
        branch: branch.isEmpty ? "(detached)" : branch,
        createdAt: ISO8601DateFormatter().string(from: Date()),
        reviewProfile: profile.name,
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

    let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
    let resolvedRoot = bundlesURL(config: config).resolvingSymlinksInPath().standardizedFileURL
    guard resolvedCandidate.path == resolvedRoot.path || resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/") else {
        throw AIReviewerError.invalidPath("bundle must live under \(resolvedRoot.path)")
    }

    for name in ["bundle.json", "commit.txt", "diff.patch", "changed-files.json"] {
        let path = resolvedCandidate.appendingPathComponent(name).path
        guard FileManager.default.fileExists(atPath: path) else {
            throw AIReviewerError.missingPath(path)
        }
    }

    return resolvedCandidate
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
    let runID = "\(bundleURL.lastPathComponent)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)"
    let runURL = runRoot.appendingPathComponent(runID)
    let homeURL = runURL.appendingPathComponent("home")
    let tmpURL = runURL.appendingPathComponent("tmp")
    let outputURL = bundleURL.appendingPathComponent("codex-review.md")
    let logURL = bundleURL.appendingPathComponent("codex.log")
    let prompt = runCodexPrompt(bundleURL: bundleURL)

    try runCodexExecution(
        config: config,
        bundleURL: bundleURL,
        prompt: prompt,
        model: config.codexModel,
        outputURL: outputURL,
        logURL: logURL,
        homeURL: homeURL,
        tmpURL: tmpURL
    )

    print("codexReview: \(outputURL.path)")
    print("codexLog: \(logURL.path)")
    return outputURL
}

func sandboxString(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

func copyCodexAuthMaterial(from sourcePath: String, to destinationURL: URL) throws {
    let sourceURL = URL(fileURLWithPath: expandedPath(sourcePath))
    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

    for filename in ["auth.json", "config.toml", "version.json", "installation_id", "models_cache.json"] {
        let sourceFile = sourceURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: sourceFile.path) else {
            continue
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: sourceFile.path)
        let fileSize = attributes[.size] as? NSNumber
        guard fileSize?.intValue ?? 0 <= 5_000_000 else {
            continue
        }

        let destinationFile = destinationURL.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destinationFile.path) {
            try FileManager.default.removeItem(at: destinationFile)
        }
        try FileManager.default.copyItem(at: sourceFile, to: destinationFile)
    }
}

func sandboxProfile(bundleURL: URL, runURL: URL, codexHomeURL: URL, outputURL: URL, logURL: URL) -> String {
    let bundlePath = sandboxString(bundleURL.resolvingSymlinksInPath().standardizedFileURL.path)
    let runPath = sandboxString(runURL.resolvingSymlinksInPath().standardizedFileURL.path)
    let codexHomePath = sandboxString(codexHomeURL.resolvingSymlinksInPath().standardizedFileURL.path)
    let outputPath = sandboxString(outputURL.resolvingSymlinksInPath().standardizedFileURL.path)
    let logPath = sandboxString(logURL.resolvingSymlinksInPath().standardizedFileURL.path)

    return """
    (version 1)
    (deny default)
    (allow process*)
    (allow signal (target self))
    (allow network*)
    (allow sysctl-read)
    (allow mach-lookup)
    (allow file-read-metadata)
    (allow file-read*
      (literal "/")
      (literal "/dev/null")
      (subpath "/dev")
      (subpath "/System")
      (subpath "/Library")
      (subpath "/usr")
      (subpath "/bin")
      (subpath "/sbin")
      (subpath "/opt/homebrew")
      (subpath "/usr/local")
      (subpath "/tmp")
      (subpath "/private/tmp")
      (subpath "/private/etc")
      (subpath "/private/var/folders")
      (subpath "/private/var/db/timezone")
      (subpath "\(bundlePath)")
      (subpath "\(runPath)")
      (subpath "\(codexHomePath)"))
    (allow file-write*
      (subpath "/dev")
      (subpath "/tmp")
      (subpath "/private/tmp")
      (subpath "/private/var/folders")
      (subpath "\(bundlePath)")
      (subpath "\(runPath)")
      (subpath "\(codexHomePath)")
      (literal "\(outputPath)")
      (literal "\(logPath)"))
    """
}

func runCodexExecution(
    config: AppConfig,
    bundleURL: URL,
    prompt: String,
    model: String?,
    outputURL: URL,
    logURL: URL,
    homeURL: URL,
    tmpURL: URL
) throws {
    let reviewPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let runURL = homeURL.deletingLastPathComponent()
    let runCodexHomeURL = runURL.appendingPathComponent("codex-home", isDirectory: true)
    try copyCodexAuthMaterial(from: config.codexHome, to: runCodexHomeURL)
    let sandboxURL = runURL.appendingPathComponent("codex.sb")
    try writeData(
        Data(sandboxProfile(bundleURL: bundleURL, runURL: runURL, codexHomeURL: runCodexHomeURL, outputURL: outputURL, logURL: logURL).utf8),
        to: sandboxURL
    )

    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let logHandle = try FileHandle(forWritingTo: logURL)
    try logHandle.truncate(atOffset: 0)
    defer {
        try? logHandle.close()
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    process.currentDirectoryURL = bundleURL

    var arguments = [
        "-f",
        sandboxURL.path,
        "/usr/bin/env",
        "-i",
        "HOME=\(homeURL.path)",
        "CODEX_HOME=\(runCodexHomeURL.path)",
        "TMPDIR=\(tmpURL.path)",
        "PATH=\(reviewPath)",
        "USER=\(NSUserName())",
        "LOGNAME=\(NSUserName())",
        "SHELL=/bin/bash",
        "codex",
        "--ask-for-approval", "never",
        "exec",
        "--disable", "shell_zsh_fork",
        "--disable", "shell_snapshot",
        "--ignore-user-config",
        "--ignore-rules",
        "--skip-git-repo-check",
        "--cd", bundleURL.path,
        "--sandbox", "read-only",
        "--ephemeral",
        "--color", "never",
        "-c", "shell_environment_policy.inherit=none"
    ]

    if let model, !model.isEmpty {
        arguments += ["--model", model]
    }

    arguments += ["--output-last-message", outputURL.path, "-"]
    process.arguments = arguments

    let inputPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = logHandle
    process.standardError = logHandle
    let termination = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in
        termination.signal()
    }

    try process.run()
    inputPipe.fileHandleForWriting.write(Data(prompt.utf8))
    try inputPipe.fileHandleForWriting.close()

    if termination.wait(timeout: .now() + .seconds(config.codexRunTimeoutSeconds)) == .timedOut {
        process.terminate()
        if termination.wait(timeout: .now() + .seconds(5)) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = termination.wait(timeout: .now() + .seconds(5))
        }

        throw AIReviewerError.commandFailed("codex timed out after \(config.codexRunTimeoutSeconds) seconds")
    }

    guard process.terminationStatus == 0 else {
        let logData = (try? Data(contentsOf: logURL)) ?? Data()
        let logText = String(data: logData, encoding: .utf8) ?? ""
        let tail = logText.split(separator: "\n").suffix(40).joined(separator: "\n")
        throw AIReviewerError.commandFailed("codex exited with status \(process.terminationStatus)\n\(tail)")
    }

    guard FileManager.default.fileExists(atPath: outputURL.path) else {
        throw AIReviewerError.missingPath(outputURL.path)
    }
}

func profileAgentPrompt(bundleURL: URL, profile: ReviewProfile, agent: ReviewAgentProfile, snapshotByteLimit: Int) throws -> String {
    let manifestData = try Data(contentsOf: bundleURL.appendingPathComponent("bundle.json"))
    let changedFilesData = try Data(contentsOf: bundleURL.appendingPathComponent("changed-files.json"))
    let commitText = try String(contentsOf: bundleURL.appendingPathComponent("commit.txt"), encoding: .utf8)
    let diffText = try String(contentsOf: bundleURL.appendingPathComponent("diff.patch"), encoding: .utf8)
    let changedFilesText = String(data: changedFilesData, encoding: .utf8) ?? "[]"
    let manifestText = String(data: manifestData, encoding: .utf8) ?? "{}"
    let snapshotsText = snapshotPromptText(bundleURL: bundleURL, byteLimit: snapshotByteLimit)

    return """
    You are Codex running an isolated read-only specialist review against a local AI Reviewer bundle.

    Security boundary:
    - Your working directory is the local bundle directory.
    - Review only files and prompt content in this bundle.
    - Do not access paths outside the current working directory.
    - Do not edit files, create files, run tests, install packages, or call network services.
    - The live source repository is intentionally not available.

    Output rules for this specialist:
    - Output only finding lines or exactly NO_ISSUES.
    - Finding format: [score|\(agent.category)] file:line - explanation
    - Do not include headers, summaries, code examples, markdown fences, or prose.
    - Report only concrete issues that are visible from the diff and included snapshots.
    - Scores: 80 minor but real risk, 90 clear defect, 95 serious/security/data risk, 100 production incident.

    Review profile:
    \(profile.name)

    Global instructions:
    \(profile.globalInstructions)

    Specialist:
    \(agent.title)

    Specialist instructions:
    \(agent.instructions)

    Bundle manifest:
    \(manifestText)

    Changed files:
    \(changedFilesText)

    Commit:
    \(commitText)

    Diff:
    \(diffText)

    Post-commit snapshots:
    \(snapshotsText)
    """
}

func snapshotPromptText(bundleURL: URL, byteLimit: Int) -> String {
    let snapshotsURL = bundleURL.appendingPathComponent("snapshots")
    guard let enumerator = FileManager.default.enumerator(at: snapshotsURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
        return "(none)"
    }

    var sections: [String] = []
    var remainingBytes = max(1, byteLimit)
    var capped = false
    for case let url as URL in enumerator {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let rawData = try? Data(contentsOf: url),
              !rawData.contains(0)
        else {
            continue
        }

        let data: Data
        if rawData.count > remainingBytes {
            data = rawData.prefix(remainingBytes)
            capped = true
        } else {
            data = rawData
        }

        guard !data.isEmpty else {
            continue
        }

        let text = String(decoding: data, as: UTF8.self)
        let relative = url.path.replacingOccurrences(of: snapshotsURL.path + "/", with: "")
        sections.append("--- \(relative) ---\n\(text)")

        remainingBytes -= data.count
        if remainingBytes <= 0 {
            capped = true
            break
        }
    }

    if capped {
        sections.append("--- snapshots omitted ---\nSnapshot prompt content capped at \(byteLimit) bytes.")
    }

    return sections.isEmpty ? "(none)" : sections.joined(separator: "\n\n")
}

func runReviewProfile(config: AppConfig, bundleURL: URL, profile: ReviewProfile) throws -> URL {
    let outputURL = bundleURL.appendingPathComponent("codex-review.md")
    let runRoot = cacheURL(config: config).appendingPathComponent("codex-runs")
    let runID = "\(bundleURL.lastPathComponent)-profile-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)"
    let runURL = runRoot.appendingPathComponent(runID)
    let diffText = (try? String(contentsOf: bundleURL.appendingPathComponent("diff.patch"), encoding: .utf8)) ?? ""
    let changedFiles = try loadBundleChangedFiles(bundleURL: bundleURL)
    let agents = runnableAgents(profile: profile, changedFiles: changedFiles, diffText: diffText)

    if changedFiles.isEmpty {
        let manifest = try loadBundleManifest(bundleURL: bundleURL)
        try writeData(Data(profileReviewText(manifest: manifest, profile: profile, agents: [], findings: []).utf8), to: outputURL)
        return outputURL
    }

    let outputs = try runProfileAgents(
        config: config,
        bundleURL: bundleURL,
        profile: profile,
        agents: agents,
        runURL: runURL
    )

    let findings = requiredFindings(from: outputs)
    let manifest = try loadBundleManifest(bundleURL: bundleURL)
    try writeData(Data(profileReviewText(manifest: manifest, profile: profile, agents: agents, findings: findings).utf8), to: outputURL)
    print("codexReview: \(outputURL.path)")
    return outputURL
}

func safeFilenameComponent(_ value: String, fallback: String) -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    let scalars = value.unicodeScalars.map { scalar -> Character in
        allowed.contains(scalar) ? Character(scalar) : "-"
    }
    let sanitized = String(scalars)
        .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        .prefix(80)

    return sanitized.isEmpty ? fallback : String(sanitized)
}

func runProfileAgents(
    config: AppConfig,
    bundleURL: URL,
    profile: ReviewProfile,
    agents: [ReviewAgentProfile],
    runURL: URL
) throws -> [(agent: ReviewAgentProfile, output: String)] {
    let parallelism = max(1, min(config.maxParallelReviews, agents.count))
    let queue = DispatchQueue(label: "com.ai-reviewer.profile-agents", attributes: .concurrent)
    let group = DispatchGroup()
    let semaphore = DispatchSemaphore(value: parallelism)
    let results = ProfileAgentResults(count: agents.count)

    print("profileAgents: \(agents.map(\.id).joined(separator: ","))")
    print("profileAgentParallelism: \(parallelism)")

    for (index, agent) in agents.enumerated() {
        semaphore.wait()
        group.enter()
        queue.async {
            defer {
                semaphore.signal()
                group.leave()
            }

            do {
                let safeAgentID = "\(index + 1)-\(safeFilenameComponent(agent.id, fallback: "agent"))"
                let agentURL = runURL.appendingPathComponent(safeAgentID, isDirectory: true)
                let output = bundleURL.appendingPathComponent("agent-\(safeAgentID).md")
                let log = bundleURL.appendingPathComponent("agent-\(safeAgentID).log")
                let prompt = try profileAgentPrompt(
                    bundleURL: bundleURL,
                    profile: profile,
                    agent: agent,
                    snapshotByteLimit: config.promptSnapshotByteLimit
                )
                try runCodexExecution(
                    config: config,
                    bundleURL: bundleURL,
                    prompt: prompt,
                    model: agent.model ?? config.codexModel ?? profile.defaultModel,
                    outputURL: output,
                    logURL: log,
                    homeURL: agentURL.appendingPathComponent("home"),
                    tmpURL: agentURL.appendingPathComponent("tmp")
                )
                let outputText = (try? String(contentsOf: output, encoding: .utf8)) ?? ""

                results.set(index: index, agent: agent, output: outputText)
            } catch {
                results.fail(error)
            }
        }
    }

    group.wait()

    return try results.ordered()
}

final class ProfileAgentResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(agent: ReviewAgentProfile, output: String)?]
    private var firstError: Error?

    init(count: Int) {
        values = Array(repeating: nil, count: count)
    }

    func set(index: Int, agent: ReviewAgentProfile, output: String) {
        lock.lock()
        values[index] = (agent: agent, output: output)
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        if firstError == nil {
            firstError = error
        }
        lock.unlock()
    }

    func ordered() throws -> [(agent: ReviewAgentProfile, output: String)] {
        lock.lock()
        defer {
            lock.unlock()
        }

        if let firstError {
            throw firstError
        }

        return values.compactMap { $0 }
    }
}

func loadBundleManifest(bundleURL: URL) throws -> BundleManifest {
    let data = try Data(contentsOf: bundleURL.appendingPathComponent("bundle.json"))
    return try JSONDecoder().decode(BundleManifest.self, from: data)
}

func loadBundleChangedFiles(bundleURL: URL) throws -> [ChangedFile] {
    let data = try Data(contentsOf: bundleURL.appendingPathComponent("changed-files.json"))
    return try JSONDecoder().decode([ChangedFile].self, from: data)
}

func runnableAgents(profile: ReviewProfile, changedFiles: [ChangedFile], diffText: String) -> [ReviewAgentProfile] {
    profile.agents.filter { agent in
        if agent.shouldAlwaysRun {
            return true
        }

        let pathMatch = agent.runIfPathContains?.contains { token in
            changedFiles.contains { $0.path.localizedCaseInsensitiveContains(token) }
        } ?? false
        let diffMatch = agent.runIfDiffContains?.contains { token in
            diffText.localizedCaseInsensitiveContains(token)
        } ?? false
        return pathMatch || diffMatch
    }
}

func requiredFindings(from outputs: [(agent: ReviewAgentProfile, output: String)]) -> [String] {
    var order: [String] = []
    var best: [String: (score: Int, line: String)] = [:]

    for item in outputs {
        for rawLine in item.output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("["),
                  let close = line.firstIndex(of: "]"),
                  let pipe = line.firstIndex(of: "|"),
                  pipe < close,
                  let score = Int(line[line.index(after: line.startIndex)..<pipe])
            else {
                continue
            }

            let remainder = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            let location = remainder.split(separator: " ", maxSplits: 1).first.map(String.init) ?? line
            if best[location] == nil {
                order.append(location)
                best[location] = (score, line)
            } else if let existing = best[location], score > existing.score {
                best[location] = (score, line)
            }
        }
    }

    return order.compactMap { best[$0]?.line }
}

func profileReviewText(manifest: BundleManifest, profile: ReviewProfile, agents: [ReviewAgentProfile], findings: [String]) -> String {
    let maxScore = findings.compactMap { line -> Int? in
        guard let pipe = line.firstIndex(of: "|") else {
            return nil
        }
        return Int(line[line.index(after: line.startIndex)..<pipe])
    }.max() ?? 0
    let verdict = maxScore >= 95 ? "FAIL" : (maxScore >= 80 ? "WARN" : "PASS")
    let files = manifest.changedFiles.map(\.path).joined(separator: ", ")
    let body = findings.isEmpty ? "" : "\n\n" + findings.joined(separator: "\n")
    let agentList = agents.map(\.id).joined(separator: ", ")

    return """
    REVIEW sha:\(manifest.shortCommit) date:\(String(manifest.createdAt.prefix(10)))
    PROFILE: \(profile.name)
    AGENTS: \(agentList.isEmpty ? "(none)" : agentList)
    FILES: \(files.isEmpty ? "(none)" : files)
    VERDICT: \(verdict)\(body)
    """
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
    return try reviewCommit(config: config, commit: commit)
}

func reviewCommit(config: AppConfig, commit: String) throws -> URL? {
    try validatePaths(config: config)

    let repoPath = repoURL(config: config).path
    let resolvedCommit = try runGit(repoPath: repoPath, arguments: ["rev-parse", commit])
    let shortCommit = try runGit(repoPath: repoPath, arguments: ["rev-parse", "--short", resolvedCommit])
    let commitLock = FileLock(url: reviewCommitLockURL(commit: resolvedCommit))
    guard try commitLock.tryLock() else {
        throw AIReviewerError.commandFailed("Review for \(shortCommit) is already running.")
    }

    if try shouldSkipCommit(repoPath: repoPath, commit: resolvedCommit) {
        try mutateState(config: config) { state in
            state.lastSeenHead = resolvedCommit
            state.skipped = state.skipped ?? [:]
            state.skipped?[resolvedCommit] = ReviewSkipRecord(
                sha: resolvedCommit,
                shortSha: shortCommit,
                skippedAt: isoNow(),
                reason: "commit message bypass marker"
            )
        }
        print("skippedReview: \(shortCommit)")
        return nil
    }

    var alreadyReviewed: ReviewRecord?
    try mutateState(config: config) { state in
        state.lastSeenHead = resolvedCommit
        if let reviewed = state.reviewed[resolvedCommit] {
            alreadyReviewed = reviewed
            state.lastBundlePath = reviewed.bundlePath
            state.lastReviewPath = reviewed.localReviewPath
        }
    }

    if let reviewed = alreadyReviewed {
        print("alreadyReviewed: \(shortCommit)")
        print("copiedReport: \(reviewed.copiedReportPath)")
        return nil
    }

    var bundleURL: URL?
    var reviewURL: URL?

    do {
        let profile = try loadReviewProfile(config: config)
        let materializedBundleURL = try materializeCommit(config: config, profile: profile, commit: resolvedCommit)
        bundleURL = materializedBundleURL
        try mutateState(config: config) { state in
            state.lastBundlePath = materializedBundleURL.path
        }

        let localReviewURL = try runReviewProfile(config: config, bundleURL: materializedBundleURL, profile: profile)
        reviewURL = localReviewURL

        let copiedReportURL = try copyReportBack(config: config, reviewURL: localReviewURL, shortCommit: shortCommit)
        try mutateState(config: config) { state in
            state.lastReviewPath = localReviewURL.path
            state.reviewed[resolvedCommit] = ReviewRecord(
                sha: resolvedCommit,
                shortSha: shortCommit,
                reviewedAt: isoNow(),
                bundlePath: materializedBundleURL.path,
                localReviewPath: localReviewURL.path,
                copiedReportPath: copiedReportURL.path
            )
            state.failed.removeValue(forKey: resolvedCommit)
            state.skipped?.removeValue(forKey: resolvedCommit)
        }

        print("reviewed: \(shortCommit)")
        return copiedReportURL
    } catch AIReviewerError.permanentReviewSkip(let reason) {
        _ = try? mutateState(config: config) { state in
            state.skipped = state.skipped ?? [:]
            state.skipped?[resolvedCommit] = ReviewSkipRecord(
                sha: resolvedCommit,
                shortSha: shortCommit,
                skippedAt: isoNow(),
                reason: reason
            )
            state.failed.removeValue(forKey: resolvedCommit)
        }
        print("skippedReview: \(shortCommit) \(reason)")
        return nil
    } catch {
        _ = try? mutateState(config: config) { state in
            state.failed[resolvedCommit] = ReviewFailureRecord(
                sha: resolvedCommit,
                shortSha: shortCommit,
                failedAt: isoNow(),
                error: "\(error)",
                bundlePath: bundleURL?.path,
                localReviewPath: reviewURL?.path
            )
        }
        throw error
    }
}

func shouldSkipCommit(repoPath: String, commit: String) throws -> Bool {
    let message = try runGit(repoPath: repoPath, arguments: ["log", "-1", "--format=%B", commit])
    return message.range(of: #"\[(skip-review|no-review)\]"#, options: .regularExpression) != nil
}

func shouldRetryFailure(_ failure: ReviewFailureRecord, retryAfterSeconds: Int, now: Date = Date()) -> Bool {
    guard retryAfterSeconds > 0 else {
        return true
    }

    guard let failedAt = isoDate(failure.failedAt) else {
        return true
    }

    return now.timeIntervalSince(failedAt) >= TimeInterval(retryAfterSeconds)
}

func hasRetryableFailedReviews(config: AppConfig) throws -> Bool {
    try validatePaths(config: config)

    let state = try loadState(config: config)
    guard !state.failed.isEmpty else {
        return false
    }

    let repoPath = repoURL(config: config).path
    let recentHistory = try runGit(repoPath: repoPath, arguments: ["rev-list", "--max-count=\(config.reviewSweepDepth)", "HEAD"])
        .split(separator: "\n")
        .map(String.init)

    for commit in recentHistory {
        if let failure = state.failed[commit],
           shouldRetryFailure(failure, retryAfterSeconds: config.failedReviewRetrySeconds) {
            return true
        }
    }

    return false
}

func recordSeenHead(config: AppConfig, head: String) throws {
    try mutateState(config: config) { state in
        state.lastSeenHead = head
    }
}

func pendingReviewCommits(config: AppConfig) throws -> [String] {
    try validatePaths(config: config)

    let repoPath = repoURL(config: config).path
    let state = try loadState(config: config)
    let head = try runGit(repoPath: repoPath, arguments: ["rev-parse", "HEAD"])
    let output: String
    if let lastSeenHead = state.lastSeenHead,
       !lastSeenHead.isEmpty {
        if (try? runGit(repoPath: repoPath, arguments: ["merge-base", "--is-ancestor", lastSeenHead, head])) != nil {
            output = try runGit(repoPath: repoPath, arguments: ["rev-list", "--reverse", "--max-count=\(config.reviewSweepDepth)", "\(lastSeenHead)..\(head)"])
        } else {
            output = head
        }
    } else {
        output = try runGit(repoPath: repoPath, arguments: ["rev-list", "--reverse", "--max-count=\(config.reviewSweepDepth)", "HEAD"])
    }

    let reviewed = Set(state.reviewed.keys)
    let skipped = Set((state.skipped ?? [:]).keys)
    let recentHistory = try runGit(repoPath: repoPath, arguments: ["rev-list", "--reverse", "--max-count=\(config.reviewSweepDepth)", "HEAD"])
        .split(separator: "\n")
        .map(String.init)
    let rangeCandidates = Set(output.split(separator: "\n").map(String.init))
    let candidates = recentHistory.filter { rangeCandidates.contains($0) || state.failed[$0] != nil }

    var pending: [String] = []
    var newSkips: [String: ReviewSkipRecord] = [:]

    for commit in candidates {
        if reviewed.contains(commit) || skipped.contains(commit) {
            continue
        }

        if let failure = state.failed[commit],
           !shouldRetryFailure(failure, retryAfterSeconds: config.failedReviewRetrySeconds) {
            continue
        }

        let parentCount = try runGit(repoPath: repoPath, arguments: ["log", "-1", "--format=%P", commit])
            .split(separator: " ")
            .count
        if parentCount > 1 {
            newSkips[commit] = ReviewSkipRecord(
                sha: commit,
                shortSha: try runGit(repoPath: repoPath, arguments: ["rev-parse", "--short", commit]),
                skippedAt: isoNow(),
                reason: "merge commit"
            )
            continue
        }

        if try shouldSkipCommit(repoPath: repoPath, commit: commit) {
            newSkips[commit] = ReviewSkipRecord(
                sha: commit,
                shortSha: try runGit(repoPath: repoPath, arguments: ["rev-parse", "--short", commit]),
                skippedAt: isoNow(),
                reason: "commit message bypass marker"
            )
            continue
        }

        pending.append(commit)
    }

    if !newSkips.isEmpty {
        try mutateState(config: config) { state in
            state.skipped = state.skipped ?? [:]
            for (commit, record) in newSkips {
                state.skipped?[commit] = record
            }
        }
    }

    return pending
}

func reviewPendingCommits(config: AppConfig) throws -> [URL] {
    let pending = try pendingReviewCommits(config: config)
    var reports: [URL] = []

    if pending.isEmpty {
        let repoPath = repoURL(config: config).path
        let head = try runGit(repoPath: repoPath, arguments: ["rev-parse", "HEAD"])
        try recordSeenHead(config: config, head: head)
        return []
    }

    for commit in pending {
        if let report = try reviewCommit(config: config, commit: commit) {
            reports.append(report)
        }
    }

    return reports
}

func logPathForReviewPath(_ path: String?) -> String? {
    guard let path, !path.isEmpty else {
        return nil
    }

    let url = URL(fileURLWithPath: path)
    let name = url.deletingPathExtension().lastPathComponent + ".log"
    return url.deletingLastPathComponent().appendingPathComponent(name).path
}

func preferredReviewPath(_ record: ReviewRecord) -> String? {
    if FileManager.default.fileExists(atPath: record.copiedReportPath) {
        return record.copiedReportPath
    }
    if FileManager.default.fileExists(atPath: record.localReviewPath) {
        return record.localReviewPath
    }
    return record.copiedReportPath
}

func loadReviewHistory(config: AppConfig, runningCommits: Set<String> = [], queuedCommits: Set<String> = []) throws -> [ReviewHistoryItem] {
    try validatePaths(config: config)

    let repoPath = repoURL(config: config).path
    let state = try loadState(config: config)
    let output = try runGit(
        repoPath: repoPath,
        arguments: [
            "log",
            "--max-count=\(config.reviewSweepDepth)",
            "--date=iso-strict",
            "--format=%H%x1f%h%x1f%ad%x1f%s"
        ]
    )

    return output
        .split(separator: "\n", omittingEmptySubsequences: true)
        .compactMap { line -> ReviewHistoryItem? in
            let parts = line.split(separator: "\u{1f}", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4 else {
                return nil
            }

            let sha = parts[0]
            let shortSha = parts[1]
            let date = parts[2]
            let subject = parts[3]

            if runningCommits.contains(sha) {
                return ReviewHistoryItem(
                    sha: sha,
                    shortSha: shortSha,
                    date: date,
                    subject: subject,
                    status: .running,
                    detail: "Review is currently running.",
                    reviewPath: nil,
                    localReviewPath: nil,
                    bundlePath: nil,
                    logPath: nil
                )
            }

            if queuedCommits.contains(sha) {
                return ReviewHistoryItem(
                    sha: sha,
                    shortSha: shortSha,
                    date: date,
                    subject: subject,
                    status: .queued,
                    detail: "Review is queued.",
                    reviewPath: nil,
                    localReviewPath: nil,
                    bundlePath: nil,
                    logPath: nil
                )
            }

            if let reviewed = state.reviewed[sha] {
                let reviewPath = preferredReviewPath(reviewed)
                return ReviewHistoryItem(
                    sha: sha,
                    shortSha: reviewed.shortSha,
                    date: date,
                    subject: subject,
                    status: .completed,
                    detail: FileManager.default.fileExists(atPath: reviewed.copiedReportPath) ? "Review completed." : "Review completed, but the copied report file is missing.",
                    reviewPath: reviewPath,
                    localReviewPath: reviewed.localReviewPath,
                    bundlePath: reviewed.bundlePath,
                    logPath: logPathForReviewPath(reviewed.localReviewPath)
                )
            }

            if let failure = state.failed[sha] {
                return ReviewHistoryItem(
                    sha: sha,
                    shortSha: failure.shortSha,
                    date: date,
                    subject: subject,
                    status: .failed,
                    detail: failure.error,
                    reviewPath: failure.localReviewPath,
                    localReviewPath: failure.localReviewPath,
                    bundlePath: failure.bundlePath,
                    logPath: logPathForReviewPath(failure.localReviewPath)
                )
            }

            if let skipped = state.skipped?[sha] {
                return ReviewHistoryItem(
                    sha: sha,
                    shortSha: skipped.shortSha,
                    date: date,
                    subject: subject,
                    status: .skipped,
                    detail: skipped.reason,
                    reviewPath: nil,
                    localReviewPath: nil,
                    bundlePath: nil,
                    logPath: nil
                )
            }

            return ReviewHistoryItem(
                sha: sha,
                shortSha: shortSha,
                date: date,
                subject: subject,
                status: .pending,
                detail: "No review ledger entry yet.",
                reviewPath: nil,
                localReviewPath: nil,
                bundlePath: nil,
                logPath: nil
            )
        }
}

func rerunReviewCommit(config: AppConfig, commit: String) throws -> URL? {
    let repoPath = repoURL(config: config).path
    let resolvedCommit = try runGit(repoPath: repoPath, arguments: ["rev-parse", commit])
    try mutateState(config: config) { state in
        state.reviewed.removeValue(forKey: resolvedCommit)
        state.failed.removeValue(forKey: resolvedCommit)
        state.skipped?.removeValue(forKey: resolvedCommit)
    }
    return try reviewCommit(config: config, commit: resolvedCommit)
}

func readTextFileIfPresent(path: String?) -> String? {
    guard let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
        return nil
    }

    return try? String(contentsOfFile: path, encoding: .utf8)
}

func readLogText(lineLimit: Int = 250) -> String {
    let logURL = watcherLogURL()
    guard let data = try? Data(contentsOf: logURL),
          let text = String(data: data, encoding: .utf8)
    else {
        return "No watcher log has been written yet."
    }

    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lineLimit)
    return lines.joined(separator: "\n")
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
                    self.reviewPending(config: config, reason: "Reviewing pending commits on startup", onUpdate: onUpdate)
                } else {
                    try recordSeenHead(config: config, head: self.lastHead ?? "")
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
                if try hasRetryableFailedReviews(config: config) {
                    reviewPending(
                        config: config,
                        reason: "Retrying failed reviews",
                        onUpdate: onUpdate
                    )
                    return
                }

                send("Watching for commits", onUpdate: onUpdate)
                return
            }

            let previousHead = lastHead
            lastHead = head
            reviewPending(
                config: config,
                reason: "HEAD changed \(short(previousHead)) -> \(short(head))",
                onUpdate: onUpdate
            )
        } catch {
            lastError = "\(error)"
            send("Watcher poll failed", onUpdate: onUpdate)
        }
    }

    private func reviewPending(config: AppConfig, reason: String, onUpdate: @escaping @Sendable (WatcherUpdate) -> Void) {
        guard isRunning else {
            return
        }

        isReviewing = true
        lastError = nil
        send(reason, onUpdate: onUpdate)

        do {
            let reports = try reviewPendingCommits(config: config)
            if let reportURL = reports.last {
                lastReview = reportURL.path
                send("Review completed (\(reports.count) commit\(reports.count == 1 ? "" : "s"))", onUpdate: onUpdate)
            } else {
                send("No pending commits", onUpdate: onUpdate)
            }
        } catch {
            lastError = "\(error)"
            send("Review failed", onUpdate: onUpdate)
        }

        isReviewing = false
    }

    private func send(_ status: String, onUpdate: @Sendable (WatcherUpdate) -> Void) {
        let update = WatcherUpdate(
            status: status,
            isRunning: isRunning,
            lastHead: lastHead,
            lastReview: lastReview,
            lastError: lastError
        )
        appendLog(update)
        onUpdate(update)
    }

    private func appendLog(_ update: WatcherUpdate) {
        let logURL = watcherLogURL()
        let fields = [
            "status=\(update.status)",
            "running=\(update.isRunning)",
            "head=\(update.lastHead ?? "")",
            "review=\(update.lastReview ?? "")",
            "error=\(update.lastError ?? "")"
        ]
        let line = "\(isoNow()) \(fields.joined(separator: " "))\n"

        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            defer {
                try? handle.close()
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            fputs("watcher log warning: \(error)\n", stderr)
        }
    }

    private func short(_ sha: String?) -> String {
        guard let sha, !sha.isEmpty else {
            return "(none)"
        }

        return String(sha.prefix(7))
    }
}

final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class SettingsAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum MainSection: Int {
        case reviews = 0
        case logs = 1
        case settings = 2
    }

    private enum MenuBadgeState {
        case completed
        case running
        case queued
        case issue
    }

    private let configURL = defaultAppConfigURL()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let appWatcher = AppWatcher()
    private let watcherLock = FileLock(url: watcherLockURL())
    private var watcherRunning = false
    private var activeSection: MainSection = .reviews
    private var reviewItems: [ReviewHistoryItem] = []
    private var selectedReviewIndex: Int?
    private var runningCommits = Set<String>()
    private var queuedManualCommits: [String] = []
    private var activeManualCommits = Set<String>()
    private var hasStatusIssue = false
    private var advancedSettingsVisible = false

    private let repoField = NSTextField()
    private let reportsField = NSTextField()
    private let cacheField = NSTextField()
    private let codexHomeField = NSTextField()
    private let codexModelField = NSTextField()
    private let reviewProfileField = NSTextField()
    private let statePathField = NSTextField()
    private let pollIntervalField = NSTextField()
    private let sweepDepthField = NSTextField()
    private let retryFailedAfterField = NSTextField()
    private let codexTimeoutField = NSTextField()
    private let maxParallelCommitReviewsField = NSTextField()
    private let maxParallelField = NSTextField()
    private let maxSnapshotField = NSTextField()
    private let maxPromptSnapshotField = NSTextField()
    private let startWatcherOnLaunchCheckbox = NSButton(checkboxWithTitle: "Start watching when app opens", target: nil, action: nil)
    private let hideDockIconCheckbox = NSButton(checkboxWithTitle: "Hide Dock icon", target: nil, action: nil)
    private let reviewStartupCheckbox = NSButton(checkboxWithTitle: "Review pending commits when watcher starts", target: nil, action: nil)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch AI Reviewer at login", target: nil, action: nil)
    private let statusField = NSTextField(labelWithString: "Idle")
    private let watcherField = NSTextField(labelWithString: "Watcher: stopped")
    private let summaryField = NSTextField(labelWithString: "No repository loaded")
    private let contentContainer = NSView()
    private let segmentedControl = NSSegmentedControl(labels: ["Reviews", "Logs", "Settings"], trackingMode: .selectOne, target: nil, action: nil)
    private let reviewTableView = NSTableView()
    private let reviewDetailTextView = NSTextView()
    private let logsTextView = NSTextView()
    private var rerunReviewButton: NSButton?
    private var openReviewButton: NSButton?
    private var openBundleButton: NSButton?
    private var primaryActionButton: NSButton?
    private var startWatcherButton: NSButton?
    private var stopWatcherButton: NSButton?
    private var watcherStatusMenuItem: NSMenuItem?
    private var startWatcherMenuItem: NSMenuItem?
    private var stopWatcherMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildStatusItem()
        buildWindow()
        let config = loadConfigIntoFields()
        refreshLoginItemCheckbox()
        applyActivationPolicy(config: config, windowVisible: false)
        showSection(.reviews)
        window?.center()

        if config.shouldStartWatcherOnLaunch && !config.repoPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.beginWatching(showSettingsWindowOnFailure: true)
            }
        } else {
            showSettingsWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if activeSection == .settings {
            persistSettingsFromFields(showStatus: false)
        }
        if let config = try? configFromFields() {
            applyActivationPolicy(config: config, windowVisible: false)
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if let config = try? configFromFields() {
            applyActivationPolicy(config: config, windowVisible: false)
        }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        if let config = try? configFromFields() {
            applyActivationPolicy(config: config, windowVisible: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistSettingsFromFields(showStatus: false)
        appWatcher.stop { _ in }
        watcherLock.unlock()
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Open AI Reviewer", action: #selector(showSettingsWindow), keyEquivalent: ","))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit AI Reviewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func buildStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "AI Reviewer"
        statusItem.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        let status = NSMenuItem(title: "Watcher: stopped", action: nil, keyEquivalent: "")
        watcherStatusMenuItem = status
        menu.addItem(status)
        menu.addItem(NSMenuItem.separator())

        let settings = NSMenuItem(title: "Open AI Reviewer", action: #selector(showSettingsWindow), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        let start = NSMenuItem(title: "Start Watching", action: #selector(startWatching), keyEquivalent: "")
        start.target = self
        startWatcherMenuItem = start
        menu.addItem(start)

        let stop = NSMenuItem(title: "Stop Watching", action: #selector(stopWatching), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = false
        stopWatcherMenuItem = stop
        menu.addItem(stop)

        menu.addItem(NSMenuItem.separator())

        let openLogs = NSMenuItem(title: "Open Logs", action: #selector(openLogs), keyEquivalent: "")
        openLogs.target = self
        menu.addItem(openLogs)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit AI Reviewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        statusItem.menu = menu
        self.statusItem = statusItem
        updateStatusItemIcon()
        updateWatcherControls(status: "Watcher: stopped")
    }

    private func currentMenuBadgeState() -> MenuBadgeState {
        if hasStatusIssue {
            return .issue
        }
        if !queuedManualCommits.isEmpty {
            return .queued
        }
        if !runningCommits.isEmpty || !activeManualCommits.isEmpty {
            return .running
        }
        return .completed
    }

    private func updateStatusItemIcon() {
        statusItem?.button?.image = statusItemImage(state: currentMenuBadgeState())
    }

    private func statusItemImage(state: MenuBadgeState) -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 22))
        image.lockFocus()

        let baseRect = NSRect(x: 0, y: 1, width: 20, height: 20)
        if let appIcon = menuBarBaseIcon() {
            appIcon.draw(in: baseRect)
        } else {
            NSColor.labelColor.setFill()
            NSBezierPath(roundedRect: baseRect, xRadius: 4, yRadius: 4).fill()
        }

        let badgeRect = NSRect(x: 13, y: 1, width: 10, height: 10)
        badgeColor(for: state).setFill()
        NSBezierPath(ovalIn: badgeRect).fill()

        let glyph = badgeGlyph(for: state)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let glyphSize = glyph.size(withAttributes: attributes)
        glyph.draw(
            at: NSPoint(
                x: badgeRect.midX - glyphSize.width / 2,
                y: badgeRect.midY - glyphSize.height / 2
            ),
            withAttributes: attributes
        )

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func menuBarBaseIcon() -> NSImage? {
        if let image = NSImage(named: "AppIcon") {
            return image
        }
        if let url = Bundle.main.resourceURL?.appendingPathComponent("AppIcon.icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        let localURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Assets/AppIcon.png")
        return NSImage(contentsOf: localURL)
    }

    private func badgeColor(for state: MenuBadgeState) -> NSColor {
        switch state {
        case .completed:
            return .systemGreen
        case .running:
            return .systemBlue
        case .queued:
            return .systemPurple
        case .issue:
            return .systemRed
        }
    }

    private func badgeGlyph(for state: MenuBadgeState) -> NSString {
        switch state {
        case .completed:
            return "✓"
        case .running:
            return "•"
        case .queued:
            return "≡"
        case .issue:
            return "!"
        }
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Reviewer"
        window.minSize = NSSize(width: 860, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3

        let title = NSTextField(labelWithString: "AI Reviewer")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        titleStack.addArrangedSubview(title)

        summaryField.lineBreakMode = .byTruncatingMiddle
        summaryField.maximumNumberOfLines = 2
        summaryField.textColor = .secondaryLabelColor
        titleStack.addArrangedSubview(summaryField)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let startButton = button(title: "Start", action: #selector(startWatching))
        let stopButton = button(title: "Stop", action: #selector(stopWatching))
        let primaryButton = button(title: "Refresh", action: #selector(refreshCurrentView))
        stopButton.isEnabled = false
        startWatcherButton = startButton
        stopWatcherButton = stopButton
        primaryActionButton = primaryButton

        header.addArrangedSubview(titleStack)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(primaryButton)
        header.addArrangedSubview(startButton)
        header.addArrangedSubview(stopButton)
        root.addArrangedSubview(header)

        segmentedControl.target = self
        segmentedControl.action = #selector(sectionChanged)
        segmentedControl.selectedSegment = MainSection.reviews.rawValue
        root.addArrangedSubview(segmentedControl)

        watcherField.lineBreakMode = .byWordWrapping
        watcherField.maximumNumberOfLines = 3
        watcherField.textColor = .secondaryLabelColor
        root.addArrangedSubview(watcherField)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(contentContainer)

        statusField.lineBreakMode = .byWordWrapping
        statusField.maximumNumberOfLines = 4
        statusField.textColor = .secondaryLabelColor
        root.addArrangedSubview(statusField)

        window.contentView = NSView()
        window.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
            segmentedControl.widthAnchor.constraint(equalToConstant: 300),
            watcherField.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
            contentContainer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
            contentContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 460),
            statusField.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48)
        ])

        self.window = window
    }

    private func replaceContent(with view: NSView) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
    }

    private func showSection(_ section: MainSection) {
        if activeSection == .settings, section != .settings {
            persistSettingsFromFields(showStatus: true)
        }

        activeSection = section
        segmentedControl.selectedSegment = section.rawValue
        primaryActionButton?.title = section == .settings ? "Save" : "Refresh"

        switch section {
        case .reviews:
            replaceContent(with: buildReviewsView())
            refreshReviewHistory()
        case .logs:
            replaceContent(with: buildLogsView())
            refreshLogs(scrollToBottom: true)
        case .settings:
            replaceContent(with: buildSettingsView())
        }
    }

    @objc private func sectionChanged() {
        showSection(MainSection(rawValue: segmentedControl.selectedSegment) ?? .reviews)
    }

    @objc private func refreshCurrentView() {
        switch activeSection {
        case .reviews:
            refreshReviewHistory()
        case .logs:
            refreshLogs(scrollToBottom: true)
        case .settings:
            persistSettingsFromFields(showStatus: true)
        }
    }

    private func buildReviewsView() -> NSView {
        configureReviewTableIfNeeded()

        let layout = NSStackView()
        layout.orientation = .horizontal
        layout.alignment = .top
        layout.spacing = 14

        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .noBorder
        tableScroll.documentView = reviewTableView
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tableScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tableScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 500).isActive = true
        tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 430).isActive = true

        let detailStack = NSStackView()
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 8
        detailStack.setContentHuggingPriority(.required, for: .horizontal)
        detailStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.spacing = 8
        let rerun = button(title: "Rerun Review", action: #selector(rerunSelectedReview))
        let openReview = button(title: "Show Review", action: #selector(openSelectedReview))
        let openBundle = button(title: "Open Bundle", action: #selector(openSelectedBundle))
        rerunReviewButton = rerun
        openReviewButton = openReview
        openBundleButton = openBundle
        actionRow.addArrangedSubview(rerun)
        actionRow.addArrangedSubview(openReview)
        actionRow.addArrangedSubview(openBundle)

        reviewDetailTextView.isEditable = false
        reviewDetailTextView.isRichText = false
        reviewDetailTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        reviewDetailTextView.textContainerInset = NSSize(width: 10, height: 10)
        let detailScroll = NSScrollView()
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .noBorder
        detailScroll.documentView = reviewDetailTextView
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true

        detailStack.addArrangedSubview(actionRow)
        detailStack.addArrangedSubview(detailScroll)
        detailScroll.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true

        layout.addArrangedSubview(tableScroll)
        layout.addArrangedSubview(detailStack)
        detailStack.widthAnchor.constraint(equalToConstant: 360).isActive = true
        return layout
    }

    private func configureReviewTableIfNeeded() {
        guard reviewTableView.tableColumns.isEmpty else {
            return
        }

        reviewTableView.delegate = self
        reviewTableView.dataSource = self
        reviewTableView.headerView = nil
        reviewTableView.rowHeight = 44
        reviewTableView.usesAlternatingRowBackgroundColors = true
        reviewTableView.allowsEmptySelection = true

        for column in [
            ("status", "Status", 112.0),
            ("commit", "Commit", 86.0),
            ("subject", "Commit", 250.0),
            ("date", "Date", 130.0)
        ] {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.0))
            tableColumn.title = column.1
            tableColumn.width = column.2
            reviewTableView.addTableColumn(tableColumn)
        }
    }

    private func buildLogsView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.addArrangedSubview(button(title: "Refresh Logs", action: #selector(refreshLogsAction)))
        actions.addArrangedSubview(button(title: "Open Logs Folder", action: #selector(openLogs)))
        let note = NSTextField(labelWithString: "Showing latest 250 lines")
        note.textColor = .secondaryLabelColor
        actions.addArrangedSubview(note)
        stack.addArrangedSubview(actions)

        logsTextView.isEditable = false
        logsTextView.isRichText = false
        logsTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logsTextView.textContainerInset = NSSize(width: 10, height: 10)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.documentView = logsTextView
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 430).isActive = true
        return stack
    }

    private func buildSettingsView() -> NSView {
        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 12
        form.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)

        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        form.addArrangedSubview(title)

        form.addArrangedSubview(sectionHeader("Project"))
        form.addArrangedSubview(row(label: "Repository", field: repoField, buttonTitle: "Choose", action: #selector(chooseRepository)))
        form.addArrangedSubview(row(label: "Reports Folder", field: reportsField, buttonTitle: "Choose", action: #selector(chooseReportsFolder)))
        form.addArrangedSubview(row(label: "Review Instructions", field: reviewProfileField, buttonTitle: "Choose", action: #selector(chooseReviewProfile)))

        form.addArrangedSubview(sectionHeader("Automation"))
        form.addArrangedSubview(row(label: "Reviews at Once", field: maxParallelCommitReviewsField))
        form.addArrangedSubview(row(label: "Agents per Review", field: maxParallelField))
        form.addArrangedSubview(checkboxRow(startWatcherOnLaunchCheckbox))
        form.addArrangedSubview(checkboxRow(hideDockIconCheckbox))
        form.addArrangedSubview(checkboxRow(launchAtLoginCheckbox))

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(button(title: "Save", action: #selector(saveSettings)))
        buttonRow.addArrangedSubview(button(title: advancedSettingsVisible ? "Hide Advanced" : "Show Advanced", action: #selector(toggleAdvancedSettings)))
        form.addArrangedSubview(buttonRow)

        if advancedSettingsVisible {
            form.addArrangedSubview(sectionHeader("Advanced"))
            form.addArrangedSubview(row(label: "Cache Folder", field: cacheField))
            form.addArrangedSubview(row(label: "Codex Home", field: codexHomeField))
            form.addArrangedSubview(row(label: "Codex Model", field: codexModelField))
            form.addArrangedSubview(row(label: "State File", field: statePathField))
            form.addArrangedSubview(row(label: "Poll Seconds", field: pollIntervalField))
            form.addArrangedSubview(row(label: "History Depth", field: sweepDepthField))
            form.addArrangedSubview(row(label: "Retry Failed Secs", field: retryFailedAfterField))
            form.addArrangedSubview(row(label: "Codex Timeout Secs", field: codexTimeoutField))
            form.addArrangedSubview(row(label: "Snapshot Bytes", field: maxSnapshotField))
            form.addArrangedSubview(row(label: "Prompt Snapshot Bytes", field: maxPromptSnapshotField))
            form.addArrangedSubview(checkboxRow(reviewStartupCheckbox))

            let advancedButtons = NSStackView()
            advancedButtons.orientation = .horizontal
            advancedButtons.spacing = 8
            advancedButtons.addArrangedSubview(button(title: "Materialize Bundle", action: #selector(materializeHeadFromSettings)))
            advancedButtons.addArrangedSubview(button(title: "Run Bundle Review", action: #selector(reviewHeadFromSettings)))
            advancedButtons.addArrangedSubview(button(title: "Open Cache", action: #selector(openCache)))
            form.addArrangedSubview(advancedButtons)
        }

        let container = FlippedDocumentView()
        container.translatesAutoresizingMaskIntoConstraints = false
        form.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(form)
        let bottom = form.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        bottom.priority = .defaultLow
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            form.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            form.topAnchor.constraint(equalTo: container.topAnchor),
            bottom
        ])
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.documentView = container
        container.frame = NSRect(x: 0, y: 0, width: 940, height: advancedSettingsVisible ? 780 : 360)
        return scroll
    }

    private func sectionHeader(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        field.textColor = .secondaryLabelColor
        return field
    }

    @objc private func toggleAdvancedSettings() {
        commitFieldEditing()
        advancedSettingsVisible.toggle()
        replaceContent(with: buildSettingsView())
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        reviewItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < reviewItems.count else {
            return nil
        }

        let item = reviewItems[row]
        let identifier = tableColumn?.identifier.rawValue ?? "subject"
        if identifier == "status" {
            return statusCell(for: item.status)
        }

        let value: String
        switch identifier {
        case "commit":
            value = item.shortSha
        case "date":
            value = String(item.date.prefix(16)).replacingOccurrences(of: "T", with: " ")
        default:
            value = item.subject
        }

        let text = NSTextField(labelWithString: value)
        text.lineBreakMode = identifier == "subject" ? .byTruncatingTail : .byTruncatingMiddle
        text.maximumNumberOfLines = identifier == "subject" ? 2 : 1
        text.textColor = color(for: item.status)
        return centeredCell(text)
    }

    private func centeredCell(_ text: NSTextField) -> NSView {
        let container = NSView()
        text.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            text.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    private func statusCell(for status: ReviewHistoryStatus) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6

        if let image = statusImage(for: status) {
            let imageView = NSImageView(image: image)
            imageView.contentTintColor = color(for: status)
            imageView.widthAnchor.constraint(equalToConstant: 14).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: 14).isActive = true
            stack.addArrangedSubview(imageView)
        }

        let text = NSTextField(labelWithString: status.rawValue)
        text.textColor = color(for: status)
        text.maximumNumberOfLines = 1
        stack.addArrangedSubview(text)
        return stack
    }

    private func statusImage(for status: ReviewHistoryStatus) -> NSImage? {
        if #available(macOS 11.0, *) {
            let name: String
            switch status {
            case .completed:
                name = "checkmark.circle.fill"
            case .failed:
                name = "xmark.octagon.fill"
            case .skipped:
                name = "forward.circle.fill"
            case .queued:
                name = "list.bullet.circle.fill"
            case .running:
                name = "arrow.triangle.2.circlepath.circle.fill"
            case .pending:
                name = "clock.fill"
            }
            return NSImage(systemSymbolName: name, accessibilityDescription: status.rawValue)
        }

        return nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = reviewTableView.selectedRow
        selectedReviewIndex = row >= 0 && row < reviewItems.count ? row : nil
        updateSelectedReviewDetail()
    }

    private func color(for status: ReviewHistoryStatus) -> NSColor {
        switch status {
        case .completed:
            return .systemGreen
        case .failed:
            return .systemRed
        case .skipped:
            return .systemOrange
        case .queued:
            return .systemPurple
        case .running:
            return .systemBlue
        case .pending:
            return .systemGray
        }
    }

    private func selectedReviewItem() -> ReviewHistoryItem? {
        guard let selectedReviewIndex,
              selectedReviewIndex >= 0,
              selectedReviewIndex < reviewItems.count
        else {
            return nil
        }
        return reviewItems[selectedReviewIndex]
    }

    private func refreshReviewHistory() {
        do {
            let config = try configFromFields()
            reviewItems = try loadReviewHistory(
                config: config,
                runningCommits: runningCommits,
                queuedCommits: Set(queuedManualCommits)
            )
            reviewTableView.reloadData()
            if reviewItems.indices.contains(selectedReviewIndex ?? -1) {
                reviewTableView.selectRowIndexes(IndexSet(integer: selectedReviewIndex ?? 0), byExtendingSelection: false)
            } else if !reviewItems.isEmpty {
                selectedReviewIndex = 0
                reviewTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            } else {
                selectedReviewIndex = nil
            }
            updateSummary(config: config)
            updateSelectedReviewDetail()
        } catch {
            reviewItems = []
            reviewTableView.reloadData()
            reviewDetailTextView.string = "\(error)"
            summaryField.stringValue = "Unable to load review history"
            statusField.stringValue = "\(error)"
        }
    }

    private func updateSummary(config: AppConfig) {
        let completed = reviewItems.filter { $0.status == .completed }.count
        let failed = reviewItems.filter { $0.status == .failed }.count
        let skipped = reviewItems.filter { $0.status == .skipped }.count
        let queued = reviewItems.filter { $0.status == .queued || $0.status == .running }.count
        let pending = reviewItems.filter { $0.status == .pending }.count
        let repoName = URL(fileURLWithPath: expandedPath(config.repoPath)).lastPathComponent
        summaryField.stringValue = "\(repoName) - \(completed) completed, \(failed) failed, \(skipped) skipped, \(queued) active, \(pending) pending in last \(config.reviewSweepDepth) commits"
    }

    private func updateSelectedReviewDetail() {
        guard let item = selectedReviewItem() else {
            reviewDetailTextView.string = "Select a commit to see review status and output."
            rerunReviewButton?.isEnabled = false
            openReviewButton?.isEnabled = false
            openBundleButton?.isEnabled = false
            return
        }

        rerunReviewButton?.isEnabled = item.status != .running && item.status != .queued
        openReviewButton?.isEnabled = item.reviewPath != nil
        openBundleButton?.isEnabled = item.bundlePath != nil

        var header = """
        Commit: \(item.shortSha)
        Status: \(item.status.rawValue)
        Date: \(item.date)
        Subject: \(item.subject)
        Detail: \(item.detail)
        """

        if let reviewText = readTextFileIfPresent(path: item.reviewPath) {
            header += "\n\n" + reviewText
        } else if let logText = readTextFileIfPresent(path: item.logPath) {
            header += "\n\nLog:\n" + logText
        } else if item.reviewPath != nil {
            header += "\n\nReview ledger exists, but no readable review file was found."
        }

        reviewDetailTextView.string = header
    }

    @objc private func rerunSelectedReview() {
        guard let item = selectedReviewItem() else {
            return
        }

        do {
            let config = try configFromFields()
            if runningCommits.contains(item.sha) || queuedManualCommits.contains(item.sha) {
                statusField.stringValue = "\(item.shortSha) is already queued or running."
                return
            }

            queuedManualCommits.append(item.sha)
            updateStatusItemIcon()
            refreshReviewHistory()
            statusField.stringValue = "Queued \(item.shortSha)"
            drainManualReviewQueue(config: config)
        } catch {
            statusField.stringValue = "\(error)"
        }
    }

    private func drainManualReviewQueue(config: AppConfig) {
        let limit = config.commitReviewConcurrency
        while activeManualCommits.count < limit, !queuedManualCommits.isEmpty {
            let commit = queuedManualCommits.removeFirst()
            activeManualCommits.insert(commit)
            runningCommits.insert(commit)
            updateStatusItemIcon()
            refreshReviewHistory()
            runManualReview(config: config, commit: commit)
        }
    }

    private func runManualReview(config: AppConfig, commit: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: String
            let succeeded: Bool
            let short = String(commit.prefix(8))
            do {
                if let reportURL = try rerunReviewCommit(config: config, commit: commit) {
                    result = "Review copied to \(reportURL.path)"
                } else {
                    result = "Review did not produce a report for \(short)"
                }
                succeeded = true
            } catch {
                result = "\(error)"
                succeeded = false
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.activeManualCommits.remove(commit)
                self.runningCommits.remove(commit)
                self.hasStatusIssue = !succeeded
                self.statusField.stringValue = result
                self.refreshReviewHistory()
                if let nextConfig = try? self.configFromFields() {
                    self.drainManualReviewQueue(config: nextConfig)
                }
                self.updateStatusItemIcon()
            }
        }
    }

    @objc private func openSelectedReview() {
        guard let item = selectedReviewItem(),
              let path = item.reviewPath
        else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func openSelectedBundle() {
        guard let item = selectedReviewItem(),
              let path = item.bundlePath
        else {
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func refreshLogsAction() {
        refreshLogs(scrollToBottom: true)
    }

    private func refreshLogs(scrollToBottom: Bool, preservePosition: Bool = false) {
        let scrollView = logsTextView.enclosingScrollView
        let clipView = scrollView?.contentView
        let previousOrigin = clipView?.bounds.origin ?? .zero
        let visibleMaxY = (clipView?.bounds.maxY ?? 0)
        let documentHeight = logsTextView.bounds.height
        let wasNearBottom = documentHeight - visibleMaxY < 24

        logsTextView.string = readLogText()
        if let textContainer = logsTextView.textContainer {
            logsTextView.layoutManager?.ensureLayout(for: textContainer)
        }

        if preservePosition && !wasNearBottom {
            if let clipView {
                clipView.scroll(to: previousOrigin)
                scrollView?.reflectScrolledClipView(clipView)
            }
        } else if scrollToBottom || wasNearBottom {
            logsTextView.scrollToEndOfDocument(nil)
        }
    }

    @objc private func showSettingsWindow() {
        if let config = try? configFromFields() {
            applyActivationPolicy(config: config, windowVisible: true)
        }
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

    private func loginItemStatusText(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:
            return "not registered"
        case .enabled:
            return "enabled"
        case .requiresApproval:
            return "requires approval in System Settings"
        case .notFound:
            return "not found"
        @unknown default:
            return "unknown"
        }
    }

    private func refreshLoginItemCheckbox() {
        let status = SMAppService.mainApp.status
        launchAtLoginCheckbox.state = (status == .enabled || status == .requiresApproval) ? .on : .off
    }

    private func syncLoginItemSetting() throws -> String {
        let service = SMAppService.mainApp
        let wantsLoginItem = launchAtLoginCheckbox.state == .on

        if wantsLoginItem {
            if service.status != .enabled && service.status != .requiresApproval {
                try service.register()
            }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }

        refreshLoginItemCheckbox()
        return loginItemStatusText(service.status)
    }

    private func applyActivationPolicy(config: AppConfig, windowVisible: Bool) {
        NSApp.setActivationPolicy(config.shouldHideDockIcon && !windowVisible ? .accessory : .regular)
    }

    @discardableResult
    private func loadConfigIntoFields() -> AppConfig {
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
        reviewProfileField.stringValue = config.reviewProfilePath ?? ""
        statePathField.stringValue = config.statePath ?? ""
        pollIntervalField.stringValue = "\(config.pollIntervalSeconds)"
        sweepDepthField.stringValue = "\(config.reviewSweepDepth)"
        retryFailedAfterField.stringValue = "\(config.failedReviewRetrySeconds)"
        codexTimeoutField.stringValue = "\(config.codexRunTimeoutSeconds)"
        maxParallelCommitReviewsField.stringValue = "\(config.commitReviewConcurrency)"
        maxParallelField.stringValue = "\(config.maxParallelReviews)"
        maxSnapshotField.stringValue = "\(config.snapshotByteLimit)"
        maxPromptSnapshotField.stringValue = "\(config.promptSnapshotByteLimit)"
        startWatcherOnLaunchCheckbox.state = config.shouldStartWatcherOnLaunch ? .on : .off
        hideDockIconCheckbox.state = config.shouldHideDockIcon ? .on : .off
        reviewStartupCheckbox.state = config.shouldReviewCurrentHeadOnStartup ? .on : .off
        return config
    }

    private func commitFieldEditing() {
        window?.makeFirstResponder(nil)
    }

    private func configFromFields() throws -> AppConfig {
        commitFieldEditing()

        guard let pollInterval = Int(pollIntervalField.stringValue),
              let sweepDepth = Int(sweepDepthField.stringValue),
              let retryFailedAfter = Int(retryFailedAfterField.stringValue),
              let codexTimeout = Int(codexTimeoutField.stringValue),
              let maxConcurrentReviews = Int(maxParallelCommitReviewsField.stringValue),
              let maxParallel = Int(maxParallelField.stringValue),
              let maxSnapshot = Int(maxSnapshotField.stringValue),
              let maxPromptSnapshot = Int(maxPromptSnapshotField.stringValue)
        else {
            throw AIReviewerError.invalidConfig("numeric settings must be valid integers")
        }

        return AppConfig(
            repoPath: repoField.stringValue,
            reportsPath: reportsField.stringValue,
            maxParallelReviews: max(1, maxParallel),
            maxParallelCommitReviews: max(1, maxConcurrentReviews),
            pollIntervalSeconds: max(1, pollInterval),
            codexHome: codexHomeField.stringValue,
            reviewCachePath: cacheField.stringValue,
            maxSnapshotBytes: max(1, maxSnapshot),
            codexModel: codexModelField.stringValue.isEmpty ? nil : codexModelField.stringValue,
            reviewProfilePath: reviewProfileField.stringValue.isEmpty ? nil : reviewProfileField.stringValue,
            statePath: statePathField.stringValue.isEmpty ? nil : statePathField.stringValue,
            reviewCurrentHeadOnStartup: reviewStartupCheckbox.state == .on,
            startWatcherOnLaunch: startWatcherOnLaunchCheckbox.state == .on,
            hideDockIcon: hideDockIconCheckbox.state == .on,
            sweepDepth: max(1, sweepDepth),
            retryFailedAfterSeconds: max(0, retryFailedAfter),
            codexTimeoutSeconds: max(30, codexTimeout),
            maxPromptSnapshotBytes: max(1, maxPromptSnapshot)
        )
    }

    @discardableResult
    private func persistSettingsFromFields(showStatus: Bool) -> AppConfig? {
        do {
            let config = try configFromFields()
            try saveConfig(config, to: configURL)
            applyActivationPolicy(config: config, windowVisible: window?.isVisible == true && window?.isMiniaturized == false)
            let loginItemStatus = try syncLoginItemSetting()
            drainManualReviewQueue(config: config)
            if showStatus {
                statusField.stringValue = "Saved \(configURL.path)\nLogin item: \(loginItemStatus)"
            }
            return config
        } catch {
            if showStatus {
                statusField.stringValue = "\(error)"
            }
            return nil
        }
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

    @objc private func chooseReportsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        let repoURL = URL(fileURLWithPath: expandedPath(repoField.stringValue)).standardizedFileURL
        panel.directoryURL = repoURL

        if panel.runModal() == .OK, let url = panel.url {
            let selected = url.standardizedFileURL.path
            let repoPath = repoURL.path
            guard selected == repoPath || selected.hasPrefix(repoPath + "/") else {
                statusField.stringValue = "Reports folder must be inside the repository."
                return
            }

            if selected == repoPath {
                reportsField.stringValue = "."
            } else {
                reportsField.stringValue = String(selected.dropFirst(repoPath.count + 1))
            }
        }
    }

    @objc private func chooseReviewProfile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            reviewProfileField.stringValue = url.path
        }
    }

    @objc private func saveSettings() {
        persistSettingsFromFields(showStatus: true)
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
            let profile = try loadReviewProfile(config: config)
            let bundleURL = try materializeHead(config: config, profile: profile)
            let reviewURL = try runReviewProfile(config: config, bundleURL: bundleURL, profile: profile)
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
        beginWatching(showSettingsWindowOnFailure: false)
    }

    private func beginWatching(showSettingsWindowOnFailure: Bool) {
        do {
            let config = try configFromFields()
            try saveConfig(config, to: configURL)
            applyActivationPolicy(config: config, windowVisible: window?.isVisible == true && window?.isMiniaturized == false)
            guard try watcherLock.tryLock() else {
                watcherRunning = false
                updateWatcherControls(status: "Watcher: already running in another AI Reviewer instance")
                watcherField.stringValue = "Watcher: already running in another AI Reviewer instance"
                if showSettingsWindowOnFailure {
                    showSettingsWindow()
                }
                return
            }

            watcherRunning = true
            updateWatcherControls(status: "Watcher: starting...")
            watcherField.stringValue = "Watcher: starting..."
            appWatcher.start(config: config) { [weak self] update in
                DispatchQueue.main.async {
                    self?.applyWatcherUpdate(update)
                }
            }
        } catch {
            watcherLock.unlock()
            watcherRunning = false
            updateWatcherControls(status: "Watcher: \(error)")
            watcherField.stringValue = "Watcher: \(error)"
            if showSettingsWindowOnFailure {
                showSettingsWindow()
            }
        }
    }

    @objc private func stopWatching() {
        updateWatcherControls(status: "Watcher: stopping...")
        watcherField.stringValue = "Watcher: stopping..."
        appWatcher.stop { [weak self] update in
            DispatchQueue.main.async {
                self?.applyWatcherUpdate(update)
                self?.watcherLock.unlock()
            }
        }
    }

    private func applyWatcherUpdate(_ update: WatcherUpdate) {
        watcherRunning = update.isRunning
        if update.lastError != nil || update.status.localizedCaseInsensitiveContains("failed") {
            hasStatusIssue = true
        } else if update.status.localizedCaseInsensitiveContains("completed") ||
                    update.status.localizedCaseInsensitiveContains("Watching") ||
                    update.status.localizedCaseInsensitiveContains("No pending") ||
                    update.status.localizedCaseInsensitiveContains("Starting") {
            hasStatusIssue = false
        }

        if let lastHead = update.lastHead,
           update.status.localizedCaseInsensitiveContains("review") || update.status.localizedCaseInsensitiveContains("retry") {
            runningCommits.insert(lastHead)
        } else if update.status.localizedCaseInsensitiveContains("completed") ||
                    update.status.localizedCaseInsensitiveContains("failed") ||
                    update.status.localizedCaseInsensitiveContains("No pending") {
            if let lastHead = update.lastHead, !activeManualCommits.contains(lastHead) {
                runningCommits.remove(lastHead)
            }
        }

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
        updateWatcherControls(status: lines[0])
        if activeSection == .reviews {
            refreshReviewHistory()
        } else if activeSection == .logs {
            refreshLogs(scrollToBottom: false, preservePosition: true)
        }
        updateStatusItemIcon()
        if !update.isRunning {
            watcherLock.unlock()
        }
    }

    private func updateWatcherControls(status: String) {
        startWatcherButton?.isEnabled = !watcherRunning
        stopWatcherButton?.isEnabled = watcherRunning
        startWatcherMenuItem?.isEnabled = !watcherRunning
        stopWatcherMenuItem?.isEnabled = watcherRunning
        watcherStatusMenuItem?.title = status
        statusItem?.button?.toolTip = status
        updateStatusItemIcon()
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

    @objc private func openLogs() {
        do {
            let url = appLogsURL()
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch {
            statusField.stringValue = "\(error)"
        }
    }
}

@MainActor
func runSettingsApp() {
    let appLock = FileLock(url: appInstanceLockURL())
    do {
        guard try appLock.tryLock() else {
            fputs("AI Reviewer is already running.\n", stderr)
            return
        }
    } catch {
        fputs("Unable to acquire AI Reviewer app lock: \(error)\n", stderr)
        return
    }

    let app = NSApplication.shared
    let delegate = SettingsAppDelegate()
    app.delegate = delegate
    objc_setAssociatedObject(app, "com.ai-reviewer.app-lock", appLock, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
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
            let profile = try loadReviewProfile(config: config)
            let bundleURL = try materializeHead(config: config, profile: profile)
            _ = try runReviewProfile(config: config, bundleURL: bundleURL, profile: profile)
        case .reviewOnce:
            _ = try reviewOnce(config: config)
        }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}
