import Foundation

public enum TaskState: String, CaseIterable, Equatable {
    case running, succeeded, failed, unknown
}

public enum ConnectionState: String, Equatable {
    case online, offline, stale
}

public struct TaskKey: Hashable {
    public let sourceID: String
    public let taskID: String

    public init(sourceID: String, taskID: String) {
        self.sourceID = sourceID
        self.taskID = taskID
    }
}

public struct AttemptKey: Hashable {
    public let taskKey: TaskKey
    public let attemptID: String

    public init(taskKey: TaskKey, attemptID: String) {
        self.taskKey = taskKey
        self.attemptID = attemptID
    }
}

/// A mock-only value, with no URL conversion or navigation operation.
public enum DetailTarget: Equatable {
    case unavailable
    case testMarker(String)
}

public struct TaskSnapshot: Equatable {
    public let key: TaskKey
    public let attemptID: String
    public let attemptOrdinal: Int64
    public let revision: Int64
    public let state: TaskState
    public let title: String
    public let summary: String
    public let sourceUpdatedAt: Date?
    public let detailTarget: DetailTarget

    public init(key: TaskKey, attemptID: String, attemptOrdinal: Int64, revision: Int64,
                state: TaskState, title: String, summary: String, sourceUpdatedAt: Date?,
                detailTarget: DetailTarget = .unavailable) {
        self.key = key
        self.attemptID = attemptID
        self.attemptOrdinal = attemptOrdinal
        self.revision = revision
        self.state = state
        self.title = title
        self.summary = summary
        self.sourceUpdatedAt = sourceUpdatedAt
        self.detailTarget = detailTarget
    }
}

public struct Instant: Equatable {
    public let monotonicMilliseconds: Int64
    public let wall: Date

    public init(monotonicMilliseconds: Int64, wall: Date) {
        self.monotonicMilliseconds = monotonicMilliseconds
        self.wall = wall
    }
}

/// Source payload excludes local receipt time; the reducer receives its local `now` separately.
public enum Event: Equatable {
    case baseline(sourceID: String, epoch: String, generation: UInt64, watermark: Int64, tasks: [TaskSnapshot])
    case taskUpdate(sourceID: String, epoch: String, generation: UInt64, sequence: Int64, task: TaskSnapshot)
    case heartbeat(sourceID: String, epoch: String, generation: UInt64, sequence: Int64)
    case connected(sourceID: String, generation: UInt64)
    case disconnected(sourceID: String, generation: UInt64)
}

public struct TaskRecord: Equatable {
    public let snapshot: TaskSnapshot
    public let lastTaskUpdate: Instant
    public let sourceConflict: Bool

    public init(snapshot: TaskSnapshot, lastTaskUpdate: Instant, sourceConflict: Bool) {
        self.snapshot = snapshot
        self.lastTaskUpdate = lastTaskUpdate
        self.sourceConflict = sourceConflict
    }
}

public struct ClientState: Equatable {
    public let sourceID: String
    public let generation: UInt64
    public let connection: ConnectionState
    public let tasks: [TaskKey: TaskRecord]
    public let lastSuccess: Instant?
    public let synchronized: Bool

    public init(sourceID: String, generation: UInt64, connection: ConnectionState,
                tasks: [TaskKey: TaskRecord], lastSuccess: Instant?, synchronized: Bool) {
        self.sourceID = sourceID
        self.generation = generation
        self.connection = connection
        self.tasks = tasks
        self.lastSuccess = lastSuccess
        self.synchronized = synchronized
    }
}

/// Finite diagnostics never carry fixture text or parser error descriptions.
public enum DiagnosticCode: String, Error, Equatable {
    case invalidInput, sequenceGap, payloadConflict, attemptConflict, oldBaseline, oldGeneration
}

public struct Transition: Equatable {
    public let state: ClientState
    public let baselineObservedFailures: Set<AttemptKey>
    public let newFailureCandidates: [TaskRecord]
    public let diagnostics: [DiagnosticCode]

    public init(state: ClientState, baselineObservedFailures: Set<AttemptKey>,
                newFailureCandidates: [TaskRecord], diagnostics: [DiagnosticCode]) {
        self.state = state
        self.baselineObservedFailures = baselineObservedFailures
        self.newFailureCandidates = newFailureCandidates
        self.diagnostics = diagnostics
    }
}
