import Foundation
@testable import IslandCore

enum Fixture {
    static let now = Instant(monotonicMilliseconds: 12_000, wall: Date(timeIntervalSince1970: 1_700_000_000))

    static func task(state: TaskState, revision: Int64, attempt: String, ordinal: Int64) -> TaskSnapshot {
        TaskSnapshot(
            key: TaskKey(sourceID: "mock-source", taskID: "task-1"),
            attemptID: attempt, attemptOrdinal: ordinal, revision: revision,
            state: state, title: "虚构任务 🧪", summary: "", sourceUpdatedAt: nil
        )
    }

    static func baseline(sequence: Int64, generation: UInt64, tasks: [TaskSnapshot]) -> Event {
        .baseline(sourceID: "mock-source", epoch: "epoch-1", generation: generation, watermark: sequence, tasks: tasks)
    }

    static func taskJSON(state: String = "running") -> [String: Any] {
        ["task_id": "task-1", "attempt_id": "attempt-1", "attempt_ordinal": 0,
         "task_revision": 1, "task_state": state, "title": "虚构任务 🧪", "summary": ""]
    }

    static func updateJSON(task: [String: Any]? = nil) -> [String: Any] {
        ["kind": "task_update", "source_id": "mock-source", "stream_epoch": "epoch-1",
         "event_seq": 1, "task": task ?? taskJSON()]
    }

    static func baselineJSON(tasks: [[String: Any]]) -> [String: Any] {
        ["kind": "baseline", "source_id": "mock-source", "stream_epoch": "epoch-1",
         "event_seq": 0, "tasks": tasks]
    }

    static func heartbeatJSON() -> [String: Any] {
        ["kind": "heartbeat", "source_id": "mock-source", "stream_epoch": "epoch-1", "event_seq": 2]
    }

    static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // Raw numeric spellings and duplicate members must reach the decoder unchanged.
    static func rawUpdate(sequence: String = "1", ordinal: String = "0", revision: String = "1", target: String? = nil) -> String {
        let detail = target.map { ",\"detail_target\":\"\($0)\"" } ?? ""
        return """
        {"kind":"task_update","source_id":"mock-source","stream_epoch":"epoch-1","event_seq":\(sequence),"task":{"task_id":"task-1","attempt_id":"attempt-1","attempt_ordinal":\(ordinal),"task_revision":\(revision),"task_state":"running","title":"mock","summary":""\(detail)}}
        """
    }
}
