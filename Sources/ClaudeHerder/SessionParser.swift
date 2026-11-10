import Foundation

/// Reads a Claude Code `.jsonl` transcript into a `Session`.
enum SessionParser {
    struct ParseError: LocalizedError {
        let line: Int
        let underlying: Error

        var errorDescription: String? {
            "line \(line): \(underlying)"
        }
    }

    /// Returns nil for transcripts with no prompts (e.g. only file snapshots).
    static func parse(transcript: URL, subagents: [URL]) throws -> Session? {
        var acc = Accumulator()
        try scan(transcript) { acc.addMain($0) }
        for subagent in subagents {
            try scan(subagent) { acc.addUsage($0) }
        }
        return acc.session(id: transcript.deletingPathExtension().lastPathComponent)
    }

    // Only lines containing one of these get JSON-decoded; the rest (tool output, snapshots,
    // attachments) are most of the bytes. Quotes inside JSON strings are escaped, so these
    // only match real top-level keys.
    private static let markers: [[UInt8]] = [
        "\"type\":\"user\"", "\"type\":\"assistant\"", "\"away_summary\"", "\"ai-title\"",
        "\"custom-title\"",
    ].map { Array($0.utf8) }
    private static let userMarker = Array("\"type\":\"user\"".utf8)
    private static let toolResultMarker = Array("\"tool_use_id\"".utf8)

    private static func scan(_ url: URL, _ visit: (Entry) -> Void) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let decoder = JSONDecoder()
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else {
                return
            }
            var start = 0
            var lineNumber = 0
            // A trailing line without "\n" is still being written by a live session: skip it.
            while start < buffer.count,
                let newline = memchr(base + start, 0x0A, buffer.count - start)
            {
                lineNumber += 1
                let end = base.distance(to: UnsafeRawPointer(newline))
                let line = UnsafeRawBufferPointer(rebasing: buffer[start..<end])
                start = end + 1
                guard isWorthDecoding(line) else {
                    continue
                }
                do {
                    visit(try decoder.decode(Entry.self, from: Data(line)))
                } catch {
                    throw ParseError(line: lineNumber, underlying: error)
                }
            }
        }
    }

    private static func isWorthDecoding(_ line: UnsafeRawBufferPointer) -> Bool {
        // Tool results are "user" lines too, and often huge; they carry nothing we show.
        if contains(line, userMarker) {
            return !contains(line, toolResultMarker)
        }
        return markers.contains { contains(line, $0) }
    }

    private static func contains(_ line: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        needle.withUnsafeBytes { needleBytes in
            memmem(line.baseAddress, line.count, needleBytes.baseAddress, needleBytes.count) != nil
        }
    }
}

private struct Accumulator {
    var firstAt: Date?
    var lastAt: Date?
    var cwd: String?
    var gitBranch: String?
    var aiTitle: String?
    var customTitle: String?
    var recap: String?
    var firstPrompt: String?
    var promptCount = 0
    var textReplyIDs = Set<String>()
    // Each content block of a streamed reply is its own line repeating the usage; keep the last.
    var usageByMessage: [String: (model: String, usage: Usage)] = [:]

    mutating func addMain(_ entry: Entry) {
        switch entry.type {
        case "user":
            addPrompt(entry)
        case "assistant":
            addUsage(entry)
            if let id = entry.message?.id, entry.message?.blocks.contains(where: { $0.type == "text" }) == true {
                textReplyIDs.insert(id)
            }
            touch(entry)
        case "system" where entry.subtype == "away_summary":
            recap = entry.content.map(stripRecapFooter)
        case "ai-title":
            aiTitle = entry.aiTitle
        case "custom-title":
            customTitle = entry.customTitle
        default:
            break
        }
    }

    mutating func addUsage(_ entry: Entry) {
        guard entry.type == "assistant", let message = entry.message, let usage = message.usage,
            let id = message.id ?? entry.uuid
        else {
            return
        }
        usageByMessage[id] = (message.model ?? "unknown", usage)
    }

    private mutating func addPrompt(_ entry: Entry) {
        guard entry.isMeta != true, entry.isSidechain != true, let message = entry.message else {
            return
        }
        guard !message.blocks.contains(where: { $0.type == "tool_result" }) else {
            return
        }
        let text = message.text ?? message.blocks.first(where: { $0.type == "text" })?.text
        guard let text, !text.isEmpty else {
            return
        }
        promptCount += 1
        if firstPrompt == nil {
            firstPrompt = text
        }
        touch(entry)
    }

    private mutating func touch(_ entry: Entry) {
        // Later entries follow Claude's `cd`s into subfolders, but `claude --resume` only finds
        // the session from the folder it started in.
        if cwd == nil {
            cwd = entry.cwd
            gitBranch = entry.gitBranch
        }
        guard let at = entry.timestamp else {
            return
        }
        firstAt = min(firstAt ?? at, at)
        lastAt = max(lastAt ?? at, at)
    }

    func session(id: String) -> Session? {
        guard promptCount > 0, let firstAt, let lastAt else {
            return nil
        }
        var cost = 0.0
        for (model, usage) in usageByMessage.values where usage.totalTokens > 0 {
            guard let rates = Pricing.rates(for: model) else {
                return makeSession(id: id, firstAt: firstAt, lastAt: lastAt, cost: nil)
            }
            cost += Pricing.cost(of: usage, rates: rates)
        }
        return makeSession(id: id, firstAt: firstAt, lastAt: lastAt, cost: cost)
    }

    private func makeSession(id: String, firstAt: Date, lastAt: Date, cost: Double?) -> Session {
        Session(
            id: id,
            cwd: cwd,
            gitBranch: gitBranch,
            title: customTitle ?? aiTitle ?? firstPrompt ?? id,
            recap: recap,
            firstPrompt: firstPrompt,
            firstAt: firstAt,
            lastAt: lastAt,
            messageCount: promptCount + textReplyIDs.count,
            costUSD: cost
        )
    }

    private func stripRecapFooter(_ recap: String) -> String {
        // Claude Code appends this hint to every recap it stores.
        let footer = " (disable recaps in /config)"
        return recap.hasSuffix(footer) ? String(recap.dropLast(footer.count)) : recap
    }
}

/// The subset of a transcript line we read. Unknown keys are ignored.
private struct Entry: Decodable {
    struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
        /// Set when `content` is a plain string (typed prompts).
        let text: String?
        /// Set when `content` is an array of blocks.
        let blocks: [Block]

        enum CodingKeys: String, CodingKey {
            case id, model, usage, content
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            model = try c.decodeIfPresent(String.self, forKey: .model)
            usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
            if let string = try? c.decode(String.self, forKey: .content) {
                text = string
                blocks = []
            } else {
                text = nil
                blocks = try c.decodeIfPresent([Block].self, forKey: .content) ?? []
            }
        }
    }

    struct Block: Decodable {
        let type: String
        let text: String?
    }

    let type: String
    let subtype: String?
    let uuid: String?
    let timestamp: Date?
    let cwd: String?
    let gitBranch: String?
    let isMeta: Bool?
    let isSidechain: Bool?
    /// String body of `system` entries such as recaps.
    let content: String?
    let message: Message?
    let aiTitle: String?
    let customTitle: String?

    enum CodingKeys: String, CodingKey {
        case type, subtype, uuid, timestamp, cwd, gitBranch, isMeta, isSidechain, content, message,
            aiTitle, customTitle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        subtype = try c.decodeIfPresent(String.self, forKey: .subtype)
        uuid = try c.decodeIfPresent(String.self, forKey: .uuid)
        timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp).map(Self.parseDate)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        gitBranch = try c.decodeIfPresent(String.self, forKey: .gitBranch)
        isMeta = try c.decodeIfPresent(Bool.self, forKey: .isMeta)
        isSidechain = try c.decodeIfPresent(Bool.self, forKey: .isSidechain)
        // Only `system` entries have a string `content`; elsewhere it's structured or absent.
        content = type == "system" ? try c.decodeIfPresent(String.self, forKey: .content) : nil
        message = try c.decodeIfPresent(Message.self, forKey: .message)
        aiTitle = try c.decodeIfPresent(String.self, forKey: .aiTitle)
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
    }

    private static func parseDate(_ string: String) throws -> Date {
        try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string)
    }
}
