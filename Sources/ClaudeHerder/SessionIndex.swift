import Foundation
import Observation

struct IndexFailure: Identifiable, Hashable {
    let path: String
    let message: String

    var id: String { path }
}

/// Scans `~/.claude/projects` for transcripts, reparsing only files that changed since last run.
enum SessionIndexer {
    struct Result {
        let sessions: [Session]
        let failures: [IndexFailure]
    }

    /// A top-level transcript plus the subagent transcripts it spawned.
    private struct Transcript {
        let url: URL
        let subagents: [URL]
        let fingerprint: String
    }

    private struct CacheEntry: Codable {
        let fingerprint: String
        let session: Session?
    }

    static let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    private static let cacheURL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClaudeHerder/index-v4.json")

    static func index(root: URL = projectsRoot) -> Result {
        let transcripts: [Transcript]
        do {
            transcripts = try listTranscripts(root: root)
        } catch {
            return Result(sessions: [], failures: [IndexFailure(path: root.path, message: "\(error)")])
        }

        let cache = loadCache()
        var entries = [CacheEntry?](repeating: nil, count: transcripts.count)
        var failures = [IndexFailure?](repeating: nil, count: transcripts.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: transcripts.count) { i in
            let transcript = transcripts[i]
            if let cached = cache[transcript.url.path], cached.fingerprint == transcript.fingerprint {
                lock.withLock { entries[i] = cached }
                return
            }
            do {
                let session = try SessionParser.parse(
                    transcript: transcript.url, subagents: transcript.subagents)
                let entry = CacheEntry(fingerprint: transcript.fingerprint, session: session)
                lock.withLock { entries[i] = entry }
            } catch {
                let failure = IndexFailure(
                    path: transcript.url.path, message: error.localizedDescription)
                lock.withLock { failures[i] = failure }
            }
        }

        var newCache: [String: CacheEntry] = [:]
        for (transcript, entry) in zip(transcripts, entries) {
            newCache[transcript.url.path] = entry
        }
        var allFailures = failures.compactMap { $0 }
        do {
            try saveCache(newCache)
        } catch {
            allFailures.append(IndexFailure(path: cacheURL.path, message: "\(error)"))
        }
        let sessions = deduplicated(entries.compactMap { $0?.session })
        return Result(sessions: sessions, failures: allFailures)
    }

    /// Resuming a session in another folder copies its transcript there under the same ID.
    /// Keep one card per ID: the copy with the latest activity.
    static func deduplicated(_ sessions: [Session]) -> [Session] {
        var byID: [String: Session] = [:]
        for session in sessions {
            if let existing = byID[session.id], existing.lastAt >= session.lastAt {
                continue
            }
            byID[session.id] = session
        }
        return Array(byID.values)
    }

    /// Layout: `<root>/<project>/<uuid>.jsonl`, subagents in `<root>/<project>/<uuid>/subagents/`.
    private static func listTranscripts(root: URL) throws -> [Transcript] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        var transcripts: [Transcript] = []
        let projects = try fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
        for project in projects {
            let files = try fm.contentsOfDirectory(at: project, includingPropertiesForKeys: keys)
            for file in files where file.pathExtension == "jsonl" {
                let subagentDir = file.deletingPathExtension().appendingPathComponent("subagents")
                let subagentFiles = fm.fileExists(atPath: subagentDir.path)
                    ? try fm.contentsOfDirectory(at: subagentDir, includingPropertiesForKeys: keys)
                    : []
                let subagents = subagentFiles
                    .filter { $0.pathExtension == "jsonl" }
                    .sorted { $0.path < $1.path }
                let fingerprint = try ([file] + subagents).map(fingerprintPart).joined(separator: ";")
                transcripts.append(Transcript(url: file, subagents: subagents, fingerprint: fingerprint))
            }
        }
        return transcripts
    }

    private static func fingerprintPart(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.lastPathComponent):\(values.fileSize ?? 0):\(mtime)"
    }

    private static func loadCache() -> [String: CacheEntry] {
        // A missing or outdated cache just means a full reparse.
        guard let data = try? Data(contentsOf: cacheURL) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: CacheEntry].self, from: data)) ?? [:]
    }

    private static func saveCache(_ cache: [String: CacheEntry]) throws {
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
    }
}

@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [Session] = []
    private(set) var failures: [IndexFailure] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// Not cached: folders get deleted without touching the transcript.
    private(set) var folderStates: [String: FolderState] = [:]
    private(set) var done = DoneMarks.load()
    /// Sessions running in a terminal right now.
    /// Session ID to the PID of its Claude process.
    private(set) var openPIDs: [String: Int32] = [:]
    private var openFailures: [IndexFailure] = []
    private var indexFailures: [IndexFailure] = []

    func reload() async {
        guard !isLoading else {
            return
        }
        isLoading = true
        let (result, states) = await Task.detached(priority: .userInitiated) {
            let result = SessionIndexer.index()
            let states = result.sessions.map { ($0.id, FolderState.of(cwd: $0.cwd)) }
            return (result, Dictionary(uniqueKeysWithValues: states))
        }.value
        sessions = result.sessions
        indexFailures = result.failures
        failures = indexFailures + openFailures
        folderStates = states
        isLoading = false
        hasLoaded = true
    }

    /// Cheap (a handful of tiny files), so it runs on a short timer.
    func refreshOpenSessions() async {
        let result = await Task.detached { OpenSessions.scan() }.value
        openPIDs = result.pids
        openFailures = result.failures
        failures = indexFailures + openFailures
    }

    func toggleDone(_ session: Session) {
        done.toggle(session)
        done.save()
    }
}
