import Foundation

struct AppConfig: Codable {
    let repoPath: String
    let reportsPath: String
    let maxParallelReviews: Int
    let pollIntervalSeconds: Int
    let codexHome: String
    let reviewCachePath: String
}

enum AIReviewerError: Error, CustomStringConvertible {
    case missingArgument(String)
    case unreadableConfig(String)
    case invalidConfig(String)
    case missingPath(String)
    case commandFailed(String)

    var description: String {
        switch self {
        case .missingArgument(let message):
            return message
        case .unreadableConfig(let path):
            return "Unable to read config at \(path)"
        case .invalidConfig(let message):
            return "Invalid config: \(message)"
        case .missingPath(let path):
            return "Missing path: \(path)"
        case .commandFailed(let message):
            return message
        }
    }
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

func runGit(repoPath: String, arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", repoPath] + arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
        throw AIReviewerError.commandFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

func validate(config: AppConfig) throws {
    let repoPath = expandedPath(config.repoPath)
    let reportsPath = URL(fileURLWithPath: repoPath).appendingPathComponent(config.reportsPath).path
    let headLogPath = URL(fileURLWithPath: repoPath).appendingPathComponent(".git/logs/HEAD").path

    for path in [repoPath, reportsPath, headLogPath] {
        guard FileManager.default.fileExists(atPath: path) else {
            throw AIReviewerError.missingPath(path)
        }
    }

    let head = try runGit(repoPath: repoPath, arguments: ["rev-parse", "--short", "HEAD"])
    let branch = try runGit(repoPath: repoPath, arguments: ["branch", "--show-current"])

    print("AI Reviewer")
    print("repo: \(repoPath)")
    print("reports: \(reportsPath)")
    print("head: \(head)")
    print("branch: \(branch.isEmpty ? "(detached)" : branch)")
    print("maxParallelReviews: \(config.maxParallelReviews)")
    print("pollIntervalSeconds: \(config.pollIntervalSeconds)")
}

let args = CommandLine.arguments

do {
    guard args.count == 3, args[1] == "--config" else {
        throw AIReviewerError.missingArgument("Usage: ai-reviewer-watcher --config <path>")
    }

    let config = try loadConfig(path: args[2])
    try validate(config: config)
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
