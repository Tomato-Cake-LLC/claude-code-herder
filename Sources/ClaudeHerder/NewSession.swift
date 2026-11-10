import Foundation

/// Where a new session starts; mirrors the `cowclaude` shell function.
enum Workspace: Hashable {
    case repo
    case cow(URL)
    case newCow
}

/// A tab to open in `directory` that types `input`: re-clone a deleted cow and resume in it.
struct Recreation: Equatable {
    let branch: String
    let directory: URL
    let input: String
}

/// Starts sessions by typing `cow` / `claude` into a new tab, so `cow.sh` stays the only
/// implementation of making a cow.
enum NewSession {
    /// Hardcoded for now: the monorepo is where all the Claude sessions live.
    static let repo = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Developer/tomatocake-dev")
    /// `cow` names the folder after the branch with `/` turned into `-` (`tommo-store`).
    static let branchPrefix = "tommo/"

    /// Cows cloned from `repo`, which `cow` keeps in a `cows` folder beside it.
    static func cows(of repo: URL) throws -> [URL] {
        let parent = cowsFolder(of: repo)
        guard FileManager.default.fileExists(atPath: parent.path) else {
            return []
        }
        let source = repo.standardizedFileURL.path
        return try FileManager.default
            .contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter { dir in
                let marker = dir.appendingPathComponent(".git/cow-source")
                let recorded = try? String(contentsOf: marker, encoding: .utf8)
                return recorded?.trimmingCharacters(in: .whitespacesAndNewlines) == source
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Why a typed `name` can't be a new cow; nil if it can (or nothing is typed yet).
    static func problem(withName name: String, existing cows: [URL]) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.")
        guard name.unicodeScalars.allSatisfy(allowed.contains), !name.hasPrefix("-"),
            !name.contains("..")
        else {
            return "Use lowercase letters, digits, - _ and ."
        }
        let folder = folderName(for: name)
        if cows.contains(where: { $0.lastPathComponent == folder }) {
            return "The \(folder) cow already exists; pick it on the first page."
        }
        return nil
    }

    static func folderName(for name: String) -> String {
        folderName(forBranch: branchPrefix + name)
    }

    static func folderName(forBranch branch: String) -> String {
        branch.replacingOccurrences(of: "/", with: "-")
    }

    private static func cowsFolder(of repo: URL) -> URL {
        repo.deletingLastPathComponent().appendingPathComponent("cows")
    }

    /// How to bring back the deleted cow `session` ran in; nil unless its folder was a cow
    /// of `repo` whose name matches the branch, i.e. what `cow <branch>` would make again.
    static func recreation(of session: Session, repo: URL = repo) -> Recreation? {
        guard let cwd = session.cwd, let branch = session.gitBranch, branch != "HEAD" else {
            return nil
        }
        let cows = cowsFolder(of: repo).standardizedFileURL.pathComponents
        let parts = URL(fileURLWithPath: cwd).standardizedFileURL.pathComponents
        guard parts.count > cows.count, Array(parts.prefix(cows.count)) == cows,
            parts[cows.count] == folderName(forBranch: branch)
        else {
            return nil
        }
        let line = "cow \(shellQuoted(branch)) && cd \(shellQuoted(cwd))"
            + " && claude --resume \(shellQuoted(session.id))"
        return Recreation(branch: branch, directory: repo, input: line)
    }

    static func recreate(_ recreation: Recreation) async throws {
        try await Ghostty.newTab(in: recreation.directory.path, typing: recreation.input)
    }

    /// The folder the tab opens in and the line typed into it. The prompt is read from a file
    /// so quotes and newlines in it can't break the shell line.
    static func command(for workspace: Workspace, name: String, promptFile: URL)
        -> (directory: URL, input: String)
    {
        let file = shellQuoted(promptFile.path)
        let claude = "p=\"$(cat \(file))\" && rm \(file) && claude \"$p\""
        switch workspace {
        case .repo:
            return (repo, claude)
        case .cow(let dir):
            return (dir, claude)
        case .newCow:
            return (repo, "cow \(shellQuoted(branchPrefix + name)) && \(claude)")
        }
    }

    static func start(_ workspace: Workspace, name: String, prompt: String) async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-herder-prompt-\(UUID().uuidString).txt")
        try prompt.write(to: file, atomically: true, encoding: .utf8)
        let (directory, input) = command(for: workspace, name: name, promptFile: file)
        try await Ghostty.newTab(in: directory.path, typing: input)
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
