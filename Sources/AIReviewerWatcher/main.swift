import AppKit
import Foundation
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
}

struct AppConfig: Codable, Sendable {
    var repoPath: String
    var reportsPath: String
    var maxParallelReviews: Int
    var pollIntervalSeconds: Int
    var codexHome: String
    var reviewCachePath: String
    var maxSnapshotBytes: Int?
    var codexModel: String?
    var reviewProfilePath: String?
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
        reviewProfilePath: nil,
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

func appInstanceLockURL() -> URL {
    appSupportURL().appendingPathComponent("app.lock")
}

func watcherLockURL() -> URL {
    appSupportURL().appendingPathComponent("watcher.lock")
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
    try parseChangedFiles(repoPath: repoPath, commit: commit, ignorePaths: [])
}

func parseChangedFiles(repoPath: String, commit: String, ignorePaths: [String]) throws -> [(status: String, path: String, oldPath: String?)] {
    let output = try runGit(repoPath: repoPath, arguments: ["diff-tree", "--no-commit-id", "--name-status", "-r", "-M", commit] + gitPathspecArguments(ignorePaths: ignorePaths))

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

func reviewableDiffData(repoPath: String, commit: String, ignorePaths: [String]) throws -> Data {
    try runGitData(
        repoPath: repoPath,
        arguments: ["show", "--format=", "--find-renames", "--patch", commit] + gitPathspecArguments(ignorePaths: ignorePaths)
    )
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
    let profile = try loadReviewProfile(config: config)
    return try materializeHead(config: config, profile: profile)
}

func materializeHead(config: AppConfig, profile: ReviewProfile) throws -> URL {
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

    let diff = try reviewableDiffData(repoPath: repoPath, commit: commit, ignorePaths: profile.ignorePaths)
    if let maxDiffBytes = profile.maxDiffBytes, maxDiffBytes > 0, diff.count > maxDiffBytes {
        throw AIReviewerError.invalidConfig("reviewable diff is \(diff.count) bytes, above profile limit \(maxDiffBytes)")
    }
    try writeData(diff, to: bundleURL.appendingPathComponent("diff.patch"))

    let profileEncoder = JSONEncoder()
    profileEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try writeData(try profileEncoder.encode(profile), to: bundleURL.appendingPathComponent("review-profile.json"))

    let changedFiles = try parseChangedFiles(repoPath: repoPath, commit: commit, ignorePaths: profile.ignorePaths).map { changed -> ChangedFile in
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

    if let model, !model.isEmpty {
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
}

func profileAgentPrompt(bundleURL: URL, profile: ReviewProfile, agent: ReviewAgentProfile) throws -> String {
    let manifestData = try Data(contentsOf: bundleURL.appendingPathComponent("bundle.json"))
    let changedFilesData = try Data(contentsOf: bundleURL.appendingPathComponent("changed-files.json"))
    let commitText = try String(contentsOf: bundleURL.appendingPathComponent("commit.txt"), encoding: .utf8)
    let diffText = try String(contentsOf: bundleURL.appendingPathComponent("diff.patch"), encoding: .utf8)
    let changedFilesText = String(data: changedFilesData, encoding: .utf8) ?? "[]"
    let manifestText = String(data: manifestData, encoding: .utf8) ?? "{}"
    let snapshotsText = snapshotPromptText(bundleURL: bundleURL)

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

func snapshotPromptText(bundleURL: URL) -> String {
    let snapshotsURL = bundleURL.appendingPathComponent("snapshots")
    guard let enumerator = FileManager.default.enumerator(at: snapshotsURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
        return "(none)"
    }

    var sections: [String] = []
    for case let url as URL in enumerator {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let data = try? Data(contentsOf: url),
              !data.contains(0),
              let text = String(data: data, encoding: .utf8)
        else {
            continue
        }

        let relative = url.path.replacingOccurrences(of: snapshotsURL.path + "/", with: "")
        sections.append("--- \(relative) ---\n\(text)")
    }

    return sections.isEmpty ? "(none)" : sections.joined(separator: "\n\n")
}

func runReviewProfile(config: AppConfig, bundleURL: URL, profile: ReviewProfile) throws -> URL {
    let outputURL = bundleURL.appendingPathComponent("codex-review.md")
    let runRoot = cacheURL(config: config).appendingPathComponent("codex-runs")
    let runID = "\(bundleURL.lastPathComponent)-profile-\(Int(Date().timeIntervalSince1970))"
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
                let agentURL = runURL.appendingPathComponent(agent.id)
                let output = bundleURL.appendingPathComponent("agent-\(agent.id).md")
                let log = bundleURL.appendingPathComponent("agent-\(agent.id).log")
                let prompt = try profileAgentPrompt(bundleURL: bundleURL, profile: profile, agent: agent)
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
        let profile = try loadReviewProfile(config: config)
        let materializedBundleURL = try materializeHead(config: config, profile: profile)
        bundleURL = materializedBundleURL
        state.lastBundlePath = materializedBundleURL.path
        try saveState(state, config: config)

        let localReviewURL = try runReviewProfile(config: config, bundleURL: materializedBundleURL, profile: profile)
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

@MainActor
final class SettingsAppDelegate: NSObject, NSApplicationDelegate {
    private let configURL = defaultAppConfigURL()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let appWatcher = AppWatcher()
    private let watcherLock = FileLock(url: watcherLockURL())
    private var watcherRunning = false

    private let repoField = NSTextField()
    private let reportsField = NSTextField()
    private let cacheField = NSTextField()
    private let codexHomeField = NSTextField()
    private let codexModelField = NSTextField()
    private let reviewProfileField = NSTextField()
    private let statePathField = NSTextField()
    private let pollIntervalField = NSTextField()
    private let maxParallelField = NSTextField()
    private let maxSnapshotField = NSTextField()
    private let reviewStartupCheckbox = NSButton(checkboxWithTitle: "Review current HEAD when watcher starts", target: nil, action: nil)
    private let statusField = NSTextField(labelWithString: "Idle")
    private let watcherField = NSTextField(labelWithString: "Watcher: stopped")
    private var startWatcherButton: NSButton?
    private var stopWatcherButton: NSButton?
    private var watcherStatusMenuItem: NSMenuItem?
    private var startWatcherMenuItem: NSMenuItem?
    private var stopWatcherMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        buildStatusItem()
        buildWindow()
        loadConfigIntoFields()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        appWatcher.stop { _ in }
        watcherLock.unlock()
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

    private func buildStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "AI"
        statusItem.button?.toolTip = "AI Reviewer"

        let menu = NSMenu()
        let status = NSMenuItem(title: "Watcher: stopped", action: nil, keyEquivalent: "")
        watcherStatusMenuItem = status
        menu.addItem(status)
        menu.addItem(NSMenuItem.separator())

        let settings = NSMenuItem(title: "Settings...", action: #selector(showSettingsWindow), keyEquivalent: "")
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
        updateWatcherControls(status: "Watcher: stopped")
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
        window.isReleasedWhenClosed = false

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
        root.addArrangedSubview(row(label: "Review Profile", field: reviewProfileField, buttonTitle: "Choose", action: #selector(chooseReviewProfile)))
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
        buttonRow.addArrangedSubview(button(title: "Open Logs", action: #selector(openLogs)))
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
        reviewProfileField.stringValue = config.reviewProfilePath ?? ""
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
            reviewProfilePath: reviewProfileField.stringValue.isEmpty ? nil : reviewProfileField.stringValue,
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
        do {
            let config = try configFromFields()
            try saveConfig(config, to: configURL)
            guard try watcherLock.tryLock() else {
                watcherRunning = false
                updateWatcherControls(status: "Watcher: already running in another AI Reviewer instance")
                watcherField.stringValue = "Watcher: already running in another AI Reviewer instance"
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
        }
    }

    @objc private func stopWatching() {
        watcherRunning = false
        updateWatcherControls(status: "Watcher: stopping...")
        watcherField.stringValue = "Watcher: stopping..."
        watcherLock.unlock()
        appWatcher.stop { [weak self] update in
            DispatchQueue.main.async {
                self?.applyWatcherUpdate(update)
            }
        }
    }

    private func applyWatcherUpdate(_ update: WatcherUpdate) {
        watcherRunning = update.isRunning

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
    }

    private func updateWatcherControls(status: String) {
        startWatcherButton?.isEnabled = !watcherRunning
        stopWatcherButton?.isEnabled = watcherRunning
        startWatcherMenuItem?.isEnabled = !watcherRunning
        stopWatcherMenuItem?.isEnabled = watcherRunning
        watcherStatusMenuItem?.title = status
        statusItem?.button?.toolTip = status
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
