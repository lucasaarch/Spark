import Foundation

/// Only numerical usage and display metadata cross into Spark. Conversation
/// content, credentials, and transcript paths are deliberately not retained.
struct AgentMetrics: Codable, Equatable, Sendable {
    struct Limit: Codable, Equatable, Sendable {
        let name: String
        let usedPercent: Double?
        let detail: String?
        let resetsAt: Date?
    }

    var model: String?
    var sessionTitle: String?
    var contextPercent: Double?
    var contextWindow: Int?
    var inputTokens: String?
    var outputTokens: String?
    var costUSD: Double?
    var limits: [Limit] = []
    var updatedAt = Date()

    /// Spark configures fixed slots separated by the client's supported
    /// `app-name` title item. Empty values keep their slot. Only terminated
    /// slots are accepted: Codex may truncate its OSC title to 240 characters.
    static func codex(title: String) -> AgentMetrics? {
        guard title.hasPrefix("codex | "), title.count <= 2048 else { return nil }
        let slots = String(title.dropFirst(5)).components(separatedBy: " | codex").dropLast().map {
            $0.hasPrefix(" | ") ? String($0.dropFirst(3)) : $0
        }
        guard slots.count >= 3 else { return nil }
        func slot(_ index: Int) -> String? {
            guard slots.indices.contains(index) else { return nil }
            return clean(slots[index])
        }
        var result = AgentMetrics()
        result.sessionTitle = slot(0)
        result.model = slot(1)
        if let context = slot(2), context.hasPrefix("Context "), context.hasSuffix("% used") {
            result.contextPercent = percentage(Double(context.dropFirst(8).dropLast(6)))
        }
        if let input = slot(3), input.hasSuffix(" in") { result.inputTokens = clean(String(input.dropLast(3))) }
        if let output = slot(4), output.hasSuffix(" out") { result.outputTokens = clean(String(output.dropLast(4))) }
        for (index, name) in [(5, "5-hour limit"), (6, "Weekly limit")] {
            if let detail = slot(index) {
                // Keep the CLI's exact label and remaining/used semantics.
                result.limits.append(Limit(name: name, usedPercent: nil, detail: detail, resetsAt: nil))
            }
        }
        return result
    }

    static func claude(data: Data) throws -> AgentMetrics {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(ClaudeStatus.self, from: data)
        var result = AgentMetrics()
        result.model = clean(payload.model?.displayName ?? payload.model?.id)
        result.sessionTitle = clean(payload.sessionName)
        result.contextPercent = percentage(payload.contextWindow?.usedPercentage)
        result.contextWindow = payload.contextWindow?.contextWindowSize.flatMap { $0 > 0 ? $0 : nil }
        result.inputTokens = payload.contextWindow?.totalInputTokens.flatMap { $0 >= 0 ? String($0) : nil }
        result.outputTokens = payload.contextWindow?.totalOutputTokens.flatMap { $0 >= 0 ? String($0) : nil }
        result.costUSD = payload.cost?.totalCostUsd.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        for (name, window) in [("5-hour limit", payload.rateLimits?.fiveHour), ("Weekly limit", payload.rateLimits?.sevenDay)] {
            guard let window, let percent = percentage(window.usedPercentage) else { continue }
            let reset = window.resetsAt.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            result.limits.append(Limit(name: name, usedPercent: percent, detail: nil, resetsAt: reset))
        }
        return result
    }

    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let visible = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            $0.properties.generalCategory != .format && !CharacterSet.controlCharacters.contains($0)
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        return visible.isEmpty ? nil : String(visible.prefix(160))
    }

    private static func percentage(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
    }

    private struct ClaudeStatus: Decodable {
        struct Model: Decodable { let id: String?; let displayName: String? }
        struct Context: Decodable {
            let usedPercentage: Double?
            let contextWindowSize: Int?
            let totalInputTokens: Int?
            let totalOutputTokens: Int?
        }
        struct Cost: Decodable { let totalCostUsd: Double? }
        struct Window: Decodable { let usedPercentage: Double?; let resetsAt: Double? }
        struct Limits: Decodable { let fiveHour: Window?; let sevenDay: Window? }
        let model: Model?
        let sessionName: String?
        let contextWindow: Context?
        let cost: Cost?
        let rateLimits: Limits?
    }
}

enum ClaudeStatusBridge {
    /// Invoked by Claude's statusLine command, before AppKit starts. The file
    /// name is an invocation UUID, never a path supplied by the JSON payload.
    static func run(environment: [String: String] = ProcessInfo.processInfo.environment) {
        do {
            var input = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 16_384), !chunk.isEmpty {
                input.append(chunk)
                guard input.count <= 262_144 else { return }
            }
            let metrics = try AgentMetrics.claude(data: input)
            if let folder = environment["SPARK_METRICS_DIRECTORY"],
               let rawInvocation = environment["SPARK_CLAUDE_INVOCATION"], let invocation = UUID(uuidString: rawInvocation) {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
                guard directory.lastPathComponent.hasPrefix("Spark-"),
                      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                      (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
                      attributes[.type] as? FileAttributeType == .typeDirectory else { return }
                try JSONEncoder().encode(metrics).write(to: directory.appendingPathComponent(invocation.uuidString + ".json"), options: .atomic)
            }
            // A useful CLI footer is retained while the same figures reach Spark.
            var line = metrics.model ?? "Claude Code"
            if let percent = metrics.contextPercent { line += " · \(Int(percent))% context" }
            if let cost = metrics.costUSD { line += String(format: " · $%.3f", cost) }
            print(line)
        } catch {
            // Status lines are best-effort and must never interfere with a turn.
            print("Claude Code")
        }
    }

    static func read(_ file: URL) -> AgentMetrics? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_537), data.count <= 65_536 else { return nil }
        return try? JSONDecoder().decode(AgentMetrics.self, from: data)
    }
}
