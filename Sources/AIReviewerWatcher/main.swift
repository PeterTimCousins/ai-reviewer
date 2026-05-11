import Foundation

struct AppConfig: Codable {
    let repoPath: String
    let reportsPath: String
    let maxParallelReviews: Int
    let pollIntervalSeconds: Int
    let codexHome: String
    let reviewCachePath: String
    let maxSnapshotBytes: Int?

    var snapshotByteLimit: Int {
        max(1, maxSnapshotBytes ?? 200_000)
    }
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

func validate(config: AppConfig) throws {
    try validatePaths(config: config)

    let repoPath = repoURL(config: config).path
    let head = try runGit(repoPath: repoPath, arguments: ["rev-parse", "--short", "HEAD"])
    let branch = try runGit(repoPath: repoPath, arguments: ["branch", "--show-current"])

    print("AI Reviewer")
    print("repo: \(repoPath)")
    print("reports: \(reportsURL(config: config).path)")
    print("cache: \(cacheURL(config: config).path)")
    print("codexHome: \(expandedPath(config.codexHome))")
    print("head: \(head)")
    print("branch: \(branch.isEmpty ? "(detached)" : branch)")
    print("maxParallelReviews: \(config.maxParallelReviews)")
    print("pollIntervalSeconds: \(config.pollIntervalSeconds)")
    print("maxSnapshotBytes: \(config.snapshotByteLimit)")
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
