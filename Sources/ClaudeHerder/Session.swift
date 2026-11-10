import Foundation

/// One Claude Code session, summarized from its `.jsonl` transcript.
struct Session: Codable, Identifiable, Hashable {
    /// The session UUID, as accepted by `claude --resume`.
    let id: String
    /// Folder the session started in; `claude --resume` only finds the session from there.
    let cwd: String?
    /// Branch checked out when it started; tells which `cow` made its folder.
    let gitBranch: String?
    let title: String
    /// Latest recap Claude wrote when the user stepped away; nil if it never did.
    let recap: String?
    let firstPrompt: String?
    let firstAt: Date
    let lastAt: Date
    /// User prompts plus assistant replies that contain text (tool-only turns don't count).
    let messageCount: Int
    /// API list price in USD, subagents included; nil when a model has no known price.
    let costUSD: Double?

    var projectName: String {
        guard let cwd else {
            return "Unknown folder"
        }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}
