import Foundation

public enum EventDecoder {
    public static func decode(_ data: Data, generation: UInt64, receivedAt: Instant) throws -> Event {
        // Preserve the mapped Event shape. The caller supplies this same local context to
        // reducer.apply(now:); neither generation nor receipt time is taken from JSON.
        _ = receivedAt
        do {
            var validator = RawJSONValidator(data)
            let validated = try validator.normalizedData()
            return try JSONDecoder().decode(WireEvent.self, from: validated).event(generation: generation)
        } catch {
            throw DiagnosticCode.invalidInput
        }
    }
}

private struct WireKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ value: String) { stringValue = value }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireKeys(_ container: KeyedDecodingContainer<WireKey>, allowed: Set<String>) throws {
    guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
        throw DiagnosticCode.invalidInput
    }
}

private func identifier(_ value: String) throws -> String {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw DiagnosticCode.invalidInput
    }
    return value
}

private func nonnegative(_ value: Int64) throws -> Int64 {
    guard value >= 0 else { throw DiagnosticCode.invalidInput }
    return value
}

private struct WireEvent: Decodable {
    private enum Kind: String, Decodable {
        case baseline, taskUpdate = "task_update", heartbeat, connected, disconnected
    }

    private enum Body {
        case baseline(String, Int64, [TaskSnapshot])
        case taskUpdate(String, Int64, TaskSnapshot)
        case heartbeat(String, Int64)
        case connected, disconnected
    }

    private let sourceID: String
    private let body: Body

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        let kind = try container.decode(Kind.self, forKey: WireKey("kind"))
        let source = try identifier(container.decode(String.self, forKey: WireKey("source_id")))
        sourceID = source
        let common: Set<String> = ["kind", "source_id", "provider_generation", "received_at"]

        switch kind {
        case .connected, .disconnected:
            try requireKeys(container, allowed: common)
            body = kind == .connected ? .connected : .disconnected
        case .baseline, .taskUpdate, .heartbeat:
            let payloadKey: Set<String> = kind == .baseline ? ["tasks"] : kind == .taskUpdate ? ["task"] : []
            try requireKeys(container, allowed: common.union(["stream_epoch", "event_seq"]).union(payloadKey))
            let epoch = try identifier(container.decode(String.self, forKey: WireKey("stream_epoch")))
            let sequence = try nonnegative(container.decode(Int64.self, forKey: WireKey("event_seq")))
            switch kind {
            case .baseline:
                let rawTasks = try container.decode([WireTask].self, forKey: WireKey("tasks"))
                var tasks: [TaskSnapshot] = []
                var unique: [TaskKey: TaskSnapshot] = [:]
                for rawTask in rawTasks {
                    let task = try rawTask.snapshot(sourceID: source)
                    if let previous = unique[task.key] {
                        guard previous == task else { throw DiagnosticCode.invalidInput }
                    } else {
                        unique[task.key] = task
                        tasks.append(task)
                    }
                }
                body = .baseline(epoch, sequence, tasks)
            case .taskUpdate:
                let task = try container.decode(WireTask.self, forKey: WireKey("task")).snapshot(sourceID: source)
                body = .taskUpdate(epoch, sequence, task)
            case .heartbeat:
                body = .heartbeat(epoch, sequence)
            case .connected, .disconnected:
                throw DiagnosticCode.invalidInput
            }
        }
    }

    func event(generation: UInt64) -> Event {
        switch body {
        case let .baseline(epoch, sequence, tasks):
            return .baseline(sourceID: sourceID, epoch: epoch, generation: generation, watermark: sequence, tasks: tasks)
        case let .taskUpdate(epoch, sequence, task):
            return .taskUpdate(sourceID: sourceID, epoch: epoch, generation: generation, sequence: sequence, task: task)
        case let .heartbeat(epoch, sequence):
            return .heartbeat(sourceID: sourceID, epoch: epoch, generation: generation, sequence: sequence)
        case .connected:
            return .connected(sourceID: sourceID, generation: generation)
        case .disconnected:
            return .disconnected(sourceID: sourceID, generation: generation)
        }
    }
}

private struct WireTask: Decodable {
    let sourceID: String?
    let taskID: String
    let attemptID: String
    let ordinal: Int64
    let revision: Int64
    let state: TaskState
    let title: String
    let summary: String
    let sourceUpdatedAt: Date?
    let detailTarget: DetailTarget

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        try requireKeys(container, allowed: ["source_id", "task_id", "attempt_id", "attempt_ordinal",
                                             "task_revision", "task_state", "title", "summary",
                                             "source_updated_at", "detail_target"])
        if container.contains(WireKey("source_id")) {
            sourceID = try identifier(container.decode(String.self, forKey: WireKey("source_id")))
        } else {
            sourceID = nil
        }
        taskID = try identifier(container.decode(String.self, forKey: WireKey("task_id")))
        attemptID = try identifier(container.decode(String.self, forKey: WireKey("attempt_id")))
        ordinal = try nonnegative(container.decode(Int64.self, forKey: WireKey("attempt_ordinal")))
        revision = try nonnegative(container.decode(Int64.self, forKey: WireKey("task_revision")))
        let rawState = try container.decode(String.self, forKey: WireKey("task_state"))
        guard let decodedState = TaskState(rawValue: rawState) else { throw DiagnosticCode.invalidInput }
        state = decodedState
        title = try container.decode(String.self, forKey: WireKey("title"))
        summary = try container.decode(String.self, forKey: WireKey("summary"))

        if let rawDate = try container.decodeIfPresent(String.self, forKey: WireKey("source_updated_at")) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = formatter.date(from: rawDate)
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = fractional ?? formatter.date(from: rawDate) else { throw DiagnosticCode.invalidInput }
            sourceUpdatedAt = date
        } else {
            sourceUpdatedAt = nil
        }

        if container.contains(WireKey("detail_target")) {
            let target = try container.decode(String.self, forKey: WireKey("detail_target"))
            if target == "unavailable" {
                detailTarget = .unavailable
            } else {
                let marker = target.dropFirst(5)
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
                guard target.hasPrefix("test:"), !marker.isEmpty,
                      marker.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                    throw DiagnosticCode.invalidInput
                }
                detailTarget = .testMarker(String(marker))
            }
        } else {
            detailTarget = .unavailable
        }
    }

    func snapshot(sourceID envelopeSourceID: String) throws -> TaskSnapshot {
        guard sourceID == nil || sourceID == envelopeSourceID else { throw DiagnosticCode.invalidInput }
        return TaskSnapshot(key: TaskKey(sourceID: envelopeSourceID, taskID: taskID),
                            attemptID: attemptID, attemptOrdinal: ordinal, revision: revision,
                            state: state, title: title, summary: summary, sourceUpdatedAt: sourceUpdatedAt,
                            detailTarget: detailTarget)
    }
}

/// Validate JSON structure before Foundation can fold keys or round numeric tokens.
/// Only contract counters are rewritten, to an exactly equivalent Int64 literal.
private struct RawJSONValidator {
    private enum Context { case event, task, taskArray, other }
    private let bytes: [UInt8]
    private var index = 0
    private var replacements: [(Range<Int>, String)] = []

    init(_ data: Data) { bytes = Array(data) }

    mutating func normalizedData() throws -> Data {
        try value(context: .event, depth: 0)
        whitespace()
        guard index == bytes.count else { throw DiagnosticCode.invalidInput }
        var output = Data()
        var start = 0
        for (range, literal) in replacements {
            output.append(contentsOf: bytes[start..<range.lowerBound])
            output.append(contentsOf: literal.utf8)
            start = range.upperBound
        }
        output.append(contentsOf: bytes[start..<bytes.count])
        return output
    }

    private mutating func whitespace() {
        while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private mutating func require(_ byte: UInt8) throws {
        guard index < bytes.count, bytes[index] == byte else { throw DiagnosticCode.invalidInput }
        index += 1
    }

    private func digit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }

    private mutating func value(context: Context, depth: Int, counter: Bool = false) throws {
        whitespace()
        guard index < bytes.count, depth <= 512 else { throw DiagnosticCode.invalidInput }
        let byte = bytes[index]
        if counter && byte != 45 && !digit(byte) { throw DiagnosticCode.invalidInput }
        switch byte {
        case 123: try object(context: context, depth: depth + 1)
        case 91: try array(context: context, depth: depth + 1)
        case 34: _ = try string()
        case 116: try literal(Array("true".utf8))
        case 102: try literal(Array("false".utf8))
        case 110: try literal(Array("null".utf8))
        case 45, 48...57:
            let range = try number()
            if counter { replacements.append((range, try exactCounter(range))) }
        default: throw DiagnosticCode.invalidInput
        }
    }

    private mutating func object(context: Context, depth: Int) throws {
        try require(123)
        whitespace()
        if index < bytes.count && bytes[index] == 125 { index += 1; return }
        var keys: Set<Data> = []
        while true {
            let key = try string()
            // Compare decoded Unicode scalars, including equivalent JSON escapes.
            guard keys.insert(Data(key.utf8)).inserted else { throw DiagnosticCode.invalidInput }
            whitespace()
            try require(58)
            let isCounter = (context == .event && key == "event_seq") ||
                (context == .task && (key == "attempt_ordinal" || key == "task_revision"))
            let child: Context = context == .event && key == "task" ? .task :
                context == .event && key == "tasks" ? .taskArray : .other
            try value(context: child, depth: depth, counter: isCounter)
            whitespace()
            guard index < bytes.count else { throw DiagnosticCode.invalidInput }
            if bytes[index] == 125 { index += 1; return }
            try require(44)
            whitespace()
        }
    }

    private mutating func array(context: Context, depth: Int) throws {
        try require(91)
        whitespace()
        if index < bytes.count && bytes[index] == 93 { index += 1; return }
        while true {
            try value(context: context == .taskArray ? .task : .other, depth: depth)
            whitespace()
            guard index < bytes.count else { throw DiagnosticCode.invalidInput }
            if bytes[index] == 93 { index += 1; return }
            try require(44)
        }
    }

    private mutating func string() throws -> String {
        let start = index
        try require(34)
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 34 {
                index += 1
                // Foundation only decodes this one string, never an object or number.
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            }
            guard byte >= 32 else { throw DiagnosticCode.invalidInput }
            if byte == 92 {
                index += 1
                guard index < bytes.count else { throw DiagnosticCode.invalidInput }
                if bytes[index] == 117 {
                    guard bytes.count - index >= 5 else { throw DiagnosticCode.invalidInput }
                    for offset in 1...4 {
                        let hex = bytes[index + offset]
                        guard digit(hex) || (65...70).contains(hex) || (97...102).contains(hex) else {
                            throw DiagnosticCode.invalidInput
                        }
                    }
                    index += 5
                } else {
                    guard [34, 47, 92, 98, 102, 110, 114, 116].contains(bytes[index]) else {
                        throw DiagnosticCode.invalidInput
                    }
                    index += 1
                }
            } else {
                index += 1
            }
        }
        throw DiagnosticCode.invalidInput
    }

    private mutating func literal(_ spelling: [UInt8]) throws {
        guard bytes.count - index >= spelling.count,
              bytes[index..<(index + spelling.count)].elementsEqual(spelling) else {
            throw DiagnosticCode.invalidInput
        }
        index += spelling.count
    }

    private mutating func number() throws -> Range<Int> {
        let start = index
        if bytes[index] == 45 { index += 1 }
        guard index < bytes.count else { throw DiagnosticCode.invalidInput }
        if bytes[index] == 48 {
            index += 1
        } else {
            guard (49...57).contains(bytes[index]) else { throw DiagnosticCode.invalidInput }
            while index < bytes.count && digit(bytes[index]) { index += 1 }
        }
        if index < bytes.count && bytes[index] == 46 {
            index += 1
            let fractionStart = index
            while index < bytes.count && digit(bytes[index]) { index += 1 }
            guard index > fractionStart else { throw DiagnosticCode.invalidInput }
        }
        if index < bytes.count && (bytes[index] == 101 || bytes[index] == 69) {
            index += 1
            if index < bytes.count && (bytes[index] == 43 || bytes[index] == 45) { index += 1 }
            let exponentStart = index
            while index < bytes.count && digit(bytes[index]) { index += 1 }
            guard index > exponentStart else { throw DiagnosticCode.invalidInput }
        }
        return start..<index
    }

    private func exactCounter(_ range: Range<Int>) throws -> String {
        let token = Array(bytes[range])
        let negative = token[0] == 45
        var cursor = negative ? 1 : 0
        var coefficient: [UInt8] = []
        var fraction = false
        var fractionDigits = 0
        while cursor < token.count && token[cursor] != 101 && token[cursor] != 69 {
            let byte = token[cursor]
            if byte == 46 {
                fraction = true
            } else {
                coefficient.append(byte)
                if fraction { fractionDigits += 1 }
            }
            cursor += 1
        }
        // Zero is exact for every syntactically valid exponent, including negative zero.
        guard let first = coefficient.firstIndex(where: { $0 != 48 }),
              let last = coefficient.lastIndex(where: { $0 != 48 }) else { return "0" }
        guard !negative else { throw DiagnosticCode.invalidInput }
        let significant = Array(coefficient[first...last])
        guard significant.count <= 19 else { throw DiagnosticCode.invalidInput }
        let trailingZeros = coefficient.count - last - 1
        var exponent = 0
        if cursor < token.count {
            cursor += 1
            let negativeExponent = token[cursor] == 45
            if token[cursor] == 45 || token[cursor] == 43 { cursor += 1 }
            var magnitude = 0
            while cursor < token.count {
                let (timesTen, multipliedOverflow) = magnitude.multipliedReportingOverflow(by: 10)
                let (next, addedOverflow) = timesTen.addingReportingOverflow(Int(token[cursor] - 48))
                guard !multipliedOverflow && !addedOverflow else { throw DiagnosticCode.invalidInput }
                magnitude = next
                cursor += 1
            }
            exponent = negativeExponent ? -magnitude : magnitude
        }
        // value = significant * 10^(exponent - fractionDigits + trailingZeros).
        // Its scale must be nonnegative and its total decimal width at most 19.
        let minimumExponent = fractionDigits - trailingZeros
        let (maximumExponent, overflow) = minimumExponent.addingReportingOverflow(19 - significant.count)
        guard !overflow, exponent >= minimumExponent, exponent <= maximumExponent else {
            throw DiagnosticCode.invalidInput
        }
        let scale = exponent - minimumExponent
        let canonical = significant + Array(repeating: UInt8(48), count: scale)
        let maximum = Array("9223372036854775807".utf8)
        guard canonical.count < 19 || canonical == maximum || canonical.lexicographicallyPrecedes(maximum) else {
            throw DiagnosticCode.invalidInput
        }
        return String(decoding: canonical, as: UTF8.self)
    }
}
