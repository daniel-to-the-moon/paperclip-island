import Foundation
import XCTest
@testable import IslandCore

final class EventDecoderTests: XCTestCase {
    private func decodeRaw(_ text: String) throws -> Event {
        try EventDecoder.decode(Data(text.utf8), generation: 7, receivedAt: Fixture.now)
    }

    private func decode(_ object: [String: Any], generation: UInt64 = 7, at: Instant = Fixture.now) throws -> Event {
        try EventDecoder.decode(Fixture.data(object), generation: generation, receivedAt: at)
    }

    // Missing stable identities must never be inferred from display text.
    func testMissingID() throws {
        for field in ["task_id", "attempt_id"] {
            var task = Fixture.taskJSON(); task.removeValue(forKey: field)
            XCTAssertThrowsError(try decode(Fixture.updateJSON(task: task)), field)
        }
        var event = Fixture.updateJSON(); event.removeValue(forKey: "source_id")
        XCTAssertThrowsError(try decode(event))
    }

    func testEmptyIDsAreRejected() throws {
        for field in ["task_id", "attempt_id"] {
            for invalid in ["", " \n\t"] {
                var task = Fixture.taskJSON(); task[field] = invalid
                XCTAssertThrowsError(try decode(Fixture.updateJSON(task: task)))
            }
        }
        for field in ["source_id", "stream_epoch"] {
            var event = Fixture.updateJSON(); event[field] = " "
            XCTAssertThrowsError(try decode(event))
        }
    }

    func testUnknownState() throws {
        XCTAssertThrowsError(try decode(Fixture.updateJSON(task: Fixture.taskJSON(state: "success"))))
    }

    func testNegativeSequence() throws {
        for kind in ["baseline", "task_update", "heartbeat"] {
            var event = kind == "baseline" ? Fixture.baselineJSON(tasks: []) : kind == "heartbeat" ? Fixture.heartbeatJSON() : Fixture.updateJSON()
            event["event_seq"] = -1
            XCTAssertThrowsError(try decode(event))
        }
    }

    func testIntegerOverflow() throws {
        for value in ["9223372036854775808", "-9223372036854775809"] {
            let raw = "{\"kind\":\"heartbeat\",\"source_id\":\"mock-source\",\"stream_epoch\":\"epoch-1\",\"event_seq\":\(value)}"
            XCTAssertThrowsError(try EventDecoder.decode(Data(raw.utf8), generation: 7, receivedAt: Fixture.now))
            for field in ["attempt_ordinal", "task_revision"] {
                let valid = String(decoding: try Fixture.data(Fixture.updateJSON()), as: UTF8.self)
                let literal = field == "attempt_ordinal" ? "0" : "1"
                let bad = valid.replacingOccurrences(of: "\"\(field)\":\(literal)", with: "\"\(field)\":\(value)")
                XCTAssertNotEqual(bad, valid)
                XCTAssertThrowsError(try EventDecoder.decode(Data(bad.utf8), generation: 7, receivedAt: Fixture.now))
            }
        }
    }

    func testInt64MaximumIsPreserved() throws {
        var task = Fixture.taskJSON(); task["attempt_ordinal"] = Int64.max; task["task_revision"] = Int64.max
        var event = Fixture.updateJSON(task: task); event["event_seq"] = Int64.max
        guard case let .taskUpdate(_, _, _, sequence, snapshot) = try decode(event) else { return XCTFail("expected update") }
        XCTAssertEqual(sequence, 9_223_372_036_854_775_807)
        XCTAssertEqual(snapshot.attemptOrdinal, 9_223_372_036_854_775_807)
        XCTAssertEqual(snapshot.revision, 9_223_372_036_854_775_807)
    }

    func testInvalidCounterTypesAndValues() throws {
        for value in [true, 1.5, "1", NSNull()] as [Any] {
            var event = Fixture.heartbeatJSON(); event["event_seq"] = value
            XCTAssertThrowsError(try decode(event))
            for field in ["attempt_ordinal", "task_revision"] {
                var task = Fixture.taskJSON(); task[field] = value
                XCTAssertThrowsError(try decode(Fixture.updateJSON(task: task)))
            }
        }
        for field in ["attempt_ordinal", "task_revision"] {
            var task = Fixture.taskJSON(); task[field] = -1
            XCTAssertThrowsError(try decode(Fixture.updateJSON(task: task)))
        }
    }

    func testConflictingBaseline() throws {
        let task = Fixture.taskJSON()
        for field in ["task_state", "attempt_id", "title", "summary", "task_revision"] {
            var conflict = task
            if field == "task_revision" {
                conflict[field] = 2
            } else {
                conflict[field] = field == "task_state" ? "failed" : "different"
            }
            XCTAssertThrowsError(try decode(Fixture.baselineJSON(tasks: [task, conflict])), field)
        }
    }

    func testIncompleteBaselineIsRejectedAtomically() throws {
        var bad = Fixture.taskJSON(); bad.removeValue(forKey: "attempt_id")
        XCTAssertThrowsError(try decode(Fixture.baselineJSON(tasks: [Fixture.taskJSON(), bad])))
        var event = Fixture.baselineJSON(tasks: []); event.removeValue(forKey: "tasks")
        XCTAssertThrowsError(try decode(event))
    }

    func testIdenticalBaselineDuplicatesCoalesce() throws {
        let task = Fixture.taskJSON()
        let event = try decode(Fixture.baselineJSON(tasks: [task, task]))
        XCTAssertEqual(event, Fixture.baseline(sequence: 0, generation: 7, tasks: [Fixture.task(state: .running, revision: 1, attempt: "attempt-1", ordinal: 0)]))
    }

    func testEmptyBaselineIsValid() throws {
        XCTAssertEqual(try decode(Fixture.baselineJSON(tasks: [])), Fixture.baseline(sequence: 0, generation: 7, tasks: []))
    }

    func testHeartbeatHasNoTaskFields() throws {
        let event = try decode(Fixture.heartbeatJSON())
        guard case let .heartbeat(source, epoch, generation, sequence) = event else { return XCTFail("expected heartbeat") }
        XCTAssertEqual(source, "mock-source"); XCTAssertEqual(epoch, "epoch-1")
        XCTAssertEqual(generation, 7); XCTAssertEqual(sequence, 2)
    }

    func testHeartbeatRejectsTaskFields() throws {
        for field in ["task", "tasks", "task_id", "attempt_id", "attempt_ordinal", "task_revision", "task_state"] {
            var event = Fixture.heartbeatJSON(); event[field] = Fixture.taskJSON()
            XCTAssertThrowsError(try decode(event), field)
        }
    }

    // Reception metadata cannot enter the normalized source payload or source timestamp.
    func testReceiptTimeIsLocal() throws {
        var event = Fixture.updateJSON()
        event["received_at"] = "2999-01-01T00:00:00Z"
        let local = Instant(monotonicMilliseconds: 25, wall: Date(timeIntervalSince1970: 123))
        XCTAssertEqual(try decode(event, at: local), try decode(Fixture.updateJSON(), at: local))
        guard case let .taskUpdate(_, _, _, _, task) = try decode(event, at: local) else { return XCTFail("expected update") }
        XCTAssertNil(task.sourceUpdatedAt)
        event["received_at"] = ["untrusted": true]
        XCTAssertEqual(try decode(event, at: local), try decode(Fixture.updateJSON(), at: local))
    }

    func testGenerationComesFromLocalCaller() throws {
        var event = Fixture.heartbeatJSON(); event["provider_generation"] = 999
        XCTAssertEqual(try decode(event, generation: 42), .heartbeat(sourceID: "mock-source", epoch: "epoch-1", generation: 42, sequence: 2))
    }

    func testLocalConnectionEventsDoNotConsumeSequence() throws {
        XCTAssertEqual(try decode(["kind": "connected", "source_id": "mock-source"]), .connected(sourceID: "mock-source", generation: 7))
        XCTAssertEqual(try decode(["kind": "disconnected", "source_id": "mock-source"]), .disconnected(sourceID: "mock-source", generation: 7))
        for kind in ["connected", "disconnected"] {
            for field in ["event_seq", "stream_epoch", "task", "tasks"] {
                XCTAssertThrowsError(try decode(["kind": kind, "source_id": "mock-source", field: 0]))
            }
        }
    }

    func testFourStatesAndPlainTextArePreserved() throws {
        for (raw, expected) in [("running", TaskState.running), ("succeeded", .succeeded), ("failed", .failed), ("unknown", .unknown)] {
            var task = Fixture.taskJSON(state: raw); task["title"] = "<b>虚构 🧪</b> https://invalid.example"
            guard case let .taskUpdate(_, _, _, _, decoded) = try decode(Fixture.updateJSON(task: task)) else { return XCTFail("expected update") }
            XCTAssertEqual(decoded.state, expected)
            XCTAssertEqual(decoded.title, "<b>虚构 🧪</b> https://invalid.example")
            XCTAssertEqual(decoded.summary, "")
            XCTAssertEqual(decoded.key, TaskKey(sourceID: "mock-source", taskID: "task-1"))
        }
    }

    func testTaskNamespaceMustMatchEnvelope() throws {
        var task = Fixture.taskJSON(); task["source_id"] = "other-source"
        XCTAssertThrowsError(try decode(Fixture.updateJSON(task: task)))
        task["source_id"] = "mock-source"
        XCTAssertNoThrow(try decode(Fixture.updateJSON(task: task)))
    }

    func testSourceTimestampIsOptionalAndDisplayOnly() throws {
        for raw in ["2026-11-02T10:00:00Z", "2026-11-02T10:00:00.000Z"] {
            var task = Fixture.taskJSON(); task["source_updated_at"] = raw
            guard case let .taskUpdate(_, _, _, sequence, decoded) = try decode(Fixture.updateJSON(task: task)) else { return XCTFail("expected update") }
            XCTAssertEqual(sequence, 1)
            XCTAssertEqual(decoded.sourceUpdatedAt, Date(timeIntervalSince1970: 1_793_613_600))
        }
        var task = Fixture.taskJSON(); task["source_updated_at"] = "not-a-date"
        XCTAssertThrowsError(try decode(Fixture.updateJSON(task: task)))
        task["source_updated_at"] = NSNull()
        XCTAssertNoThrow(try decode(Fixture.updateJSON(task: task)))
    }

    func testDetailTargetsRemainMockOnly() throws {
        for value in ["unavailable", "test:marker-1"] {
            var task = Fixture.taskJSON(); task["detail_target"] = value
            XCTAssertNoThrow(try decode(Fixture.updateJSON(task: task)))
        }
        for value in ["https://invalid.example", "file:///tmp/mock", "javascript:mock()", "test:https://invalid.example", "test:"] {
            var task = Fixture.taskJSON(); task["detail_target"] = value
            XCTAssertThrowsError(try decode(Fixture.updateJSON(task: task)))
        }
    }

    func testMissingRequiredFieldsAndUnknownKindAreRejected() throws {
        for field in ["kind", "stream_epoch", "event_seq", "task"] {
            var event = Fixture.updateJSON(); event.removeValue(forKey: field)
            XCTAssertThrowsError(try decode(event))
        }
        for field in ["attempt_ordinal", "task_revision", "task_state", "title", "summary"] {
            var task = Fixture.taskJSON(); task.removeValue(forKey: field)
            XCTAssertThrowsError(try decode(Fixture.updateJSON(task: task)))
        }
        var event = Fixture.heartbeatJSON(); event["kind"] = "future_kind"
        XCTAssertThrowsError(try decode(event))
    }

    func testUnknownAndConflictingFieldsAreRejected() throws {
        var event = Fixture.updateJSON(); event["tasks"] = []
        XCTAssertThrowsError(try decode(event))
        event = Fixture.heartbeatJSON(); event["unexpected"] = true
        XCTAssertThrowsError(try decode(event))
        var task = Fixture.taskJSON(); task["unexpected"] = true
        XCTAssertThrowsError(try decode(Fixture.updateJSON(task: task)))
    }

    func testMalformedInputHasRedactedDiagnostic() throws {
        for raw in ["not json", "[]", "null", "{\"kind\":\"private mock text\"}"] {
            XCTAssertThrowsError(try EventDecoder.decode(Data(raw.utf8), generation: 0, receivedAt: Fixture.now)) { error in
                XCTAssertEqual(error as? DiagnosticCode, .invalidInput)
                XCTAssertFalse(String(describing: error).contains("private mock text"))
            }
        }
    }

    func testRawFractionalPrecisionIsRejected() throws {
        for token in ["1.0000000000000001", "0.0000000000000000000001", "9223372036854775806.999999999999999999"] {
            for raw in [Fixture.rawUpdate(sequence: token), Fixture.rawUpdate(ordinal: token), Fixture.rawUpdate(revision: token)] {
                XCTAssertThrowsError(try decodeRaw(raw), token) { error in
                    XCTAssertEqual(error as? DiagnosticCode, .invalidInput)
                }
            }
        }
    }

    func testRawExactIntegerExponentFormsArePreserved() throws {
        let cases: [(String, Int64)] = [
            ("1.0", 1), ("1e0", 1), ("10e-1", 1), ("1e+2", 100), ("1.20e1", 12),
            ("-0.0e999999999999999999999", 0), ("0e-999999999999999999999", 0),
            ("9007199254740993.0", 9_007_199_254_740_993),
            ("9.223372036854775807e18", 9_223_372_036_854_775_807),
            ("92233720368547758070e-1", 9_223_372_036_854_775_807)
        ]
        for (token, expected) in cases {
            for (index, raw) in [Fixture.rawUpdate(sequence: token), Fixture.rawUpdate(ordinal: token), Fixture.rawUpdate(revision: token)].enumerated() {
                guard case let .taskUpdate(_, _, _, sequence, task) = try decodeRaw(raw) else { return XCTFail("expected update") }
                XCTAssertEqual([sequence, task.attemptOrdinal, task.revision][index], expected, token)
            }
        }
    }

    func testRawCounterOverflowAndNegativesAreRejected() throws {
        for token in ["9223372036854775808", "9.223372036854775808e18", "9223372036854775808.0", "1e100000000000000000000", "1e-100000000000000000000", "-1e0"] {
            for raw in [Fixture.rawUpdate(sequence: token), Fixture.rawUpdate(ordinal: token), Fixture.rawUpdate(revision: token)] {
                XCTAssertThrowsError(try decodeRaw(raw), token)
            }
        }
    }

    func testRawDuplicateEnvelopeKeysAreRejected() throws {
        let original = Fixture.rawUpdate()
        let replacements = [
            ("\"event_seq\":1", "\"event_seq\":1,\"event_seq\":2"),
            ("\"event_seq\":1", "\"event_seq\":1,\"event_seq\":1"),
            ("\"event_seq\":1", "\"event_seq\":1,\"event_\\u0073eq\":2"),
            ("\"source_id\":\"mock-source\"", "\"source_id\":\"mock-source\",\"source_id\":false"),
            ("\"kind\":\"task_update\"", "\"kind\":\"task_update\",\"kind\":\"unknown\"")
        ]
        for (before, after) in replacements {
            let raw = original.replacingOccurrences(of: before, with: after)
            XCTAssertNotEqual(raw, original)
            XCTAssertThrowsError(try decodeRaw(raw))
        }
    }

    func testRawDuplicateNestedAndMetadataKeysAreRejected() throws {
        let original = Fixture.rawUpdate()
        for replacement in [
            "\"task_state\":\"succeeded\",\"task_state\":\"failed\"",
            "\"task_state\":\"running\",\"task_\\u0073tate\":\"failed\"",
            "\"task_state\":\"running\",\"task_state\":\"unknown-state\""
        ] {
            XCTAssertThrowsError(try decodeRaw(original.replacingOccurrences(of: "\"task_state\":\"running\"", with: replacement)))
        }
        let metadata = original.replacingOccurrences(of: "\"event_seq\":1", with: "\"event_seq\":1,\"received_at\":{\"items\":[{\"x\":true,\"\\u0078\":false}]}")
        XCTAssertThrowsError(try decodeRaw(metadata))
    }

    func testRawKeysAcrossObjectsAndInsideTextAreAllowed() throws {
        let raw = #"{"kind":"task_update","source_\u0069d":"mock-source","stream_epoch":"epoch-1","event_seq":1,"received_at":{"items":[{"x":true},{"x":false}],"text":"\\\"x\\\":1,\\\"x\\\":2"},"task":{"task_id":"task-1","attempt_id":"attempt-1","attempt_ordinal":0,"task_revision":1,"task_\u0073tate":"running","title":"\"task_state\":\"failed\"","summary":""}}"#
        guard case let .taskUpdate(_, _, _, _, task) = try decodeRaw(raw) else { return XCTFail("expected update") }
        XCTAssertEqual(task.title, "\"task_state\":\"failed\"")
        XCTAssertEqual(task.state, .running)
    }

    func testRawDetailTargetBaselineConflictsAreRejected() throws {
        func baseline(_ first: String, _ second: String) -> String {
            let a = "{\"task_id\":\"task-1\",\"attempt_id\":\"attempt-1\",\"attempt_ordinal\":0,\"task_revision\":1,\"task_state\":\"running\",\"title\":\"mock\",\"summary\":\"\"\(first)}"
            let b = "{\"task_id\":\"task-1\",\"attempt_id\":\"attempt-1\",\"attempt_ordinal\":0,\"task_revision\":1,\"task_state\":\"running\",\"title\":\"mock\",\"summary\":\"\"\(second)}"
            return "{\"kind\":\"baseline\",\"source_id\":\"mock-source\",\"stream_epoch\":\"epoch-1\",\"event_seq\":0,\"tasks\":[\(a),\(b)]}"
        }
        for (first, second) in [("test:A", "test:B"), ("unavailable", "test:A")] {
            XCTAssertThrowsError(try decodeRaw(baseline(",\"detail_target\":\"\(first)\"", ",\"detail_target\":\"\(second)\"")))
        }
        XCTAssertThrowsError(try decodeRaw(baseline("", ",\"detail_target\":\"test:A\"")))
        guard case let .baseline(_, _, _, _, tasks) = try decodeRaw(baseline(",\"detail_target\":\"test:A\"", ",\"detail_target\":\"test:A\"")) else { return XCTFail("expected baseline") }
        XCTAssertEqual(tasks.count, 1)
    }

    func testRawDetailMarkersRemainDistinctAcrossEvents() throws {
        XCTAssertNotEqual(try decodeRaw(Fixture.rawUpdate(target: "test:A")), try decodeRaw(Fixture.rawUpdate(target: "test:B")))
        XCTAssertNotEqual(try decodeRaw(Fixture.rawUpdate()), try decodeRaw(Fixture.rawUpdate(target: "test:A")))
        XCTAssertEqual(try decodeRaw(Fixture.rawUpdate()), try decodeRaw(Fixture.rawUpdate(target: "unavailable")))
    }
}
