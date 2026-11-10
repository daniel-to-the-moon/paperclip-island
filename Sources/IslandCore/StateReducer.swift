import Foundation

/// Synchronous dual-axis reducer for one mock source.
///
/// Task identity is `TaskKey` (Swift `String` equality, including canonical equivalence).
/// Identifiers are not renormalized; control characters stay distinct, matching T1.
/// The caller supplies every `Instant`. This type never reads the clock, network, or notifications.
public struct StateReducer {
    public private(set) var state: ClientState

    private let staleAfterMilliseconds: Int64
    private var currentEpoch: String?
    private var cursor: Int64?
    private var highWater: [String: Int64]
    private var trusted: [String: [TaskKey: TaskSnapshot]]
    private var seen: [StreamKey: StreamPayload]
    private var explicitlyDisconnected: Bool
    private var generationAtDisconnect: UInt64?
    private var connectedAfterDisconnect: Bool

    public init(sourceID: String, generation: UInt64 = 0, staleAfterMilliseconds: Int64 = 30_000) {
        self.state = ClientState(
            sourceID: sourceID, generation: generation, connection: .offline,
            tasks: [:], lastSuccess: nil, synchronized: false
        )
        self.staleAfterMilliseconds = staleAfterMilliseconds
        self.currentEpoch = nil
        self.cursor = nil
        self.highWater = [:]
        self.trusted = [:]
        self.seen = [:]
        self.explicitlyDisconnected = false
        self.generationAtDisconnect = nil
        self.connectedAfterDisconnect = false
    }

    public mutating func apply(_ event: Event, now: Instant) -> Transition {
        guard sourceID(of: event) == state.sourceID else { return reject(.invalidInput) }
        let eventGeneration = generation(of: event)
        if eventGeneration < state.generation { return reject(.oldGeneration) }
        if eventGeneration > state.generation { return reject(.invalidInput) }

        switch event {
        case let .baseline(_, epoch, _, watermark, tasks):
            return applyBaseline(epoch: epoch, watermark: watermark, tasks: tasks, now: now)
        case let .taskUpdate(_, epoch, _, sequence, task):
            return applyTaskUpdate(epoch: epoch, sequence: sequence, task: task, now: now)
        case let .heartbeat(_, epoch, _, sequence):
            return applyHeartbeat(epoch: epoch, sequence: sequence, now: now)
        case .connected:
            return applyConnected()
        case .disconnected:
            return applyDisconnected()
        }
    }

    public mutating func tick(now: Instant) -> Transition {
        guard state.connection == .online, state.synchronized, let last = state.lastSuccess else {
            return transition()
        }
        guard freshnessExpired(now: now.monotonicMilliseconds, since: last.monotonicMilliseconds) else {
            return transition()
        }
        state = ClientState(
            sourceID: state.sourceID, generation: state.generation, connection: .stale,
            tasks: state.tasks, lastSuccess: state.lastSuccess, synchronized: true
        )
        return transition()
    }

    public mutating func wake(newGeneration: UInt64, now: Instant) -> Transition {
        _ = now
        if newGeneration < state.generation { return reject(.oldGeneration) }
        if newGeneration == state.generation { return reject(.invalidInput) }
        seen.removeAll()
        state = ClientState(
            sourceID: state.sourceID,
            generation: newGeneration,
            connection: state.connection == .offline ? .offline : .stale,
            tasks: state.tasks,
            lastSuccess: state.lastSuccess,
            synchronized: false
        )
        return transition()
    }

    // MARK: - Events

    private mutating func applyBaseline(epoch: String, watermark: Int64, tasks: [TaskSnapshot], now: Instant) -> Transition {
        guard validID(epoch), watermark >= 0 else { return reject(.invalidInput) }
        var snapshots: [TaskKey: TaskSnapshot] = [:]
        for snapshot in tasks {
            guard validate(snapshot) else { return reject(.invalidInput) }
            if let previous = snapshots[snapshot.key], previous != snapshot {
                return reject(.payloadConflict)
            }
            snapshots[snapshot.key] = snapshot
        }
        // After an explicit disconnect, a new baseline needs both a connected event and a newer generation.
        guard baselineAllowed else { return reject(.invalidInput) }

        if let known = highWater[epoch] {
            if watermark < known { return reject(.oldBaseline) }
            if watermark == known {
                if snapshots != (trusted[epoch] ?? [:]) { return reject(.payloadConflict) }
                // A matching older epoch must not replace the epoch currently in view.
                if epoch != currentEpoch { return reject(.oldBaseline) }
                // Already synchronized: this is a duplicate baseline and must not refresh times.
                if state.synchronized { return transition() }
                return acceptBaseline(epoch: epoch, watermark: watermark, snapshots: snapshots, now: now)
            }
        }
        return acceptBaseline(epoch: epoch, watermark: watermark, snapshots: snapshots, now: now)
    }

    private mutating func applyTaskUpdate(epoch: String, sequence: Int64, task: TaskSnapshot, now: Instant) -> Transition {
        guard validate(task) else {
            if breaksContinuity(epoch: epoch, sequence: sequence) { return breakSync(.invalidInput) }
            return reject(.invalidInput)
        }
        let payload = StreamPayload.task(task)
        if let handled = prepareIncremental(epoch: epoch, sequence: sequence, payload: payload) {
            return handled
        }
        return reduceTask(task, epoch: epoch, sequence: sequence, payload: payload, now: now)
    }

    private mutating func applyHeartbeat(epoch: String, sequence: Int64, now: Instant) -> Transition {
        let payload = StreamPayload.heartbeat
        if let handled = prepareIncremental(epoch: epoch, sequence: sequence, payload: payload) {
            return handled
        }
        return noteAlive(epoch: epoch, sequence: sequence, payload: payload, now: now)
    }

    private mutating func applyConnected() -> Transition {
        if explicitlyDisconnected { connectedAfterDisconnect = true }
        guard !state.synchronized else { return transition() }
        state = ClientState(
            sourceID: state.sourceID, generation: state.generation, connection: .stale,
            tasks: state.tasks, lastSuccess: state.lastSuccess, synchronized: false
        )
        return transition()
    }

    private mutating func applyDisconnected() -> Transition {
        explicitlyDisconnected = true
        generationAtDisconnect = state.generation
        connectedAfterDisconnect = false
        state = ClientState(
            sourceID: state.sourceID, generation: state.generation, connection: .offline,
            tasks: state.tasks, lastSuccess: state.lastSuccess, synchronized: false
        )
        return transition()
    }

    // MARK: - Stream continuity

    /// Nil means the event is the next continuous input and the caller should apply it.
    private mutating func prepareIncremental(epoch: String, sequence: Int64, payload: StreamPayload) -> Transition? {
        guard validID(epoch), sequence >= 0 else {
            if breaksContinuity(epoch: epoch, sequence: sequence) { return breakSync(.invalidInput) }
            return reject(.invalidInput)
        }
        guard state.synchronized, let cursor, let currentEpoch else {
            if state.connection == .offline || self.cursor == nil { return reject(.invalidInput) }
            return reject(.sequenceGap)
        }
        guard epoch == currentEpoch else { return breakSync(.invalidInput) }
        let key = StreamKey(epoch: epoch, sequence: sequence)
        if let previous = seen[key] {
            if previous == payload { return transition() }
            return breakSync(.payloadConflict)
        }
        if sequence <= cursor { return transition() }
        guard let next = nextSequence(after: cursor), sequence == next else {
            return breakSync(.sequenceGap)
        }
        return nil
    }

    private func breaksContinuity(epoch: String, sequence: Int64) -> Bool {
        guard state.synchronized, sequence >= 0, validID(epoch),
              let currentEpoch, epoch == currentEpoch, let cursor else { return false }
        return sequence > cursor
    }

    private func nextSequence(after cursor: Int64) -> Int64? {
        cursor == Int64.max ? nil : cursor + 1
    }

    // MARK: - Task rules

    private mutating func reduceTask(
        _ snapshot: TaskSnapshot, epoch: String, sequence: Int64, payload: StreamPayload, now: Instant
    ) -> Transition {
        guard let existing = state.tasks[snapshot.key] else {
            return commit(
                snapshot, conflict: false, candidate: snapshot.state == .failed,
                epoch: epoch, sequence: sequence, payload: payload, now: now
            )
        }
        let current = existing.snapshot
        if snapshot.attemptOrdinal > current.attemptOrdinal && snapshot.attemptID != current.attemptID {
            return commit(
                snapshot, conflict: false, candidate: snapshot.state == .failed,
                epoch: epoch, sequence: sequence, payload: payload, now: now
            )
        }
        if snapshot.attemptID == current.attemptID && snapshot.attemptOrdinal == current.attemptOrdinal {
            // Conflict stays locked, and an older or equal revision does not refresh the task.
            if existing.sourceConflict || snapshot.revision <= current.revision {
                return noteAlive(epoch: epoch, sequence: sequence, payload: payload, now: now)
            }
            return applyMatrix(current: current.state, incoming: snapshot, epoch: epoch, sequence: sequence, payload: payload, now: now)
        }
        if snapshot.attemptOrdinal < current.attemptOrdinal && snapshot.attemptID != current.attemptID {
            return noteAlive(epoch: epoch, sequence: sequence, payload: payload, now: now)
        }
        return breakSync(.attemptConflict)
    }

    private mutating func applyMatrix(
        current: TaskState, incoming: TaskSnapshot, epoch: String, sequence: Int64, payload: StreamPayload, now: Instant
    ) -> Transition {
        switch (current, incoming.state) {
        case (.running, .failed), (.unknown, .failed):
            return commit(incoming, conflict: false, candidate: true, epoch: epoch, sequence: sequence, payload: payload, now: now)
        case (.succeeded, .succeeded), (.failed, .failed),
             (.running, .running), (.running, .succeeded), (.running, .unknown),
             (.unknown, .running), (.unknown, .succeeded), (.unknown, .unknown):
            return commit(incoming, conflict: false, candidate: false, epoch: epoch, sequence: sequence, payload: payload, now: now)
        case (.succeeded, _), (.failed, _):
            let coerced = TaskSnapshot(
                key: incoming.key, attemptID: incoming.attemptID, attemptOrdinal: incoming.attemptOrdinal,
                revision: incoming.revision, state: .unknown, title: incoming.title, summary: incoming.summary,
                sourceUpdatedAt: incoming.sourceUpdatedAt, detailTarget: incoming.detailTarget
            )
            return commit(coerced, conflict: true, candidate: false, epoch: epoch, sequence: sequence, payload: payload, now: now)
        }
    }

    // MARK: - Acceptance

    private mutating func acceptBaseline(
        epoch: String, watermark: Int64, snapshots: [TaskKey: TaskSnapshot], now: Instant
    ) -> Transition {
        let preserveTimes = highWater[epoch] == watermark
        var records: [TaskKey: TaskRecord] = [:]
        var observed: Set<AttemptKey> = []
        for (key, snapshot) in snapshots {
            let previous = state.tasks[key]
            let keepTime = preserveTimes && previous?.snapshot == snapshot && previous?.sourceConflict == false
            records[key] = TaskRecord(
                snapshot: snapshot,
                lastTaskUpdate: keepTime ? previous!.lastTaskUpdate : now,
                sourceConflict: false
            )
            if snapshot.state == .failed {
                observed.insert(AttemptKey(taskKey: key, attemptID: snapshot.attemptID))
            }
        }
        explicitlyDisconnected = false
        generationAtDisconnect = nil
        connectedAfterDisconnect = false
        advance(
            tasks: records, epoch: epoch, sequence: watermark,
            payload: .baseline(snapshots), now: now
        )
        return transition(baselineObservedFailures: observed)
    }

    private mutating func commit(
        _ snapshot: TaskSnapshot, conflict: Bool, candidate: Bool,
        epoch: String, sequence: Int64, payload: StreamPayload, now: Instant
    ) -> Transition {
        var tasks = state.tasks
        let record = TaskRecord(snapshot: snapshot, lastTaskUpdate: now, sourceConflict: conflict)
        tasks[snapshot.key] = record
        advance(tasks: tasks, epoch: epoch, sequence: sequence, payload: payload, now: now)
        return transition(newFailureCandidates: candidate ? [record] : [])
    }

    private mutating func noteAlive(epoch: String, sequence: Int64, payload: StreamPayload, now: Instant) -> Transition {
        advance(tasks: state.tasks, epoch: epoch, sequence: sequence, payload: payload, now: now)
        return transition()
    }

    private mutating func advance(
        tasks: [TaskKey: TaskRecord], epoch: String, sequence: Int64, payload: StreamPayload, now: Instant
    ) {
        seen[StreamKey(epoch: epoch, sequence: sequence)] = payload
        cursor = sequence
        if let existing = highWater[epoch] {
            if sequence > existing { highWater[epoch] = sequence }
        } else {
            highWater[epoch] = sequence
        }
        trusted[epoch] = tasks.mapValues(\.snapshot)
        currentEpoch = epoch
        state = ClientState(
            sourceID: state.sourceID, generation: state.generation, connection: .online,
            tasks: tasks, lastSuccess: now, synchronized: true
        )
    }

    private mutating func breakSync(_ diagnostic: DiagnosticCode) -> Transition {
        state = ClientState(
            sourceID: state.sourceID,
            generation: state.generation,
            connection: state.connection == .offline ? .offline : .stale,
            tasks: state.tasks,
            lastSuccess: state.lastSuccess,
            synchronized: false
        )
        return transition(diagnostics: [diagnostic])
    }

    // MARK: - Guards

    private var baselineAllowed: Bool {
        guard explicitlyDisconnected else { return true }
        guard let frozen = generationAtDisconnect else { return false }
        return connectedAfterDisconnect && state.generation > frozen
    }

    private func validate(_ snapshot: TaskSnapshot) -> Bool {
        snapshot.key.sourceID == state.sourceID
            && validID(snapshot.key.taskID)
            && validID(snapshot.attemptID)
            && snapshot.revision >= 0
            && snapshot.attemptOrdinal >= 0
    }

    private func validID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func freshnessExpired(now: Int64, since: Int64) -> Bool {
        if now < since { return false }
        if staleAfterMilliseconds <= 0 { return true }
        let (limit, overflow) = since.addingReportingOverflow(staleAfterMilliseconds)
        if overflow { return false }
        return now >= limit
    }

    private func reject(_ diagnostic: DiagnosticCode) -> Transition {
        transition(diagnostics: [diagnostic])
    }

    private func transition(
        baselineObservedFailures: Set<AttemptKey> = [],
        newFailureCandidates: [TaskRecord] = [],
        diagnostics: [DiagnosticCode] = []
    ) -> Transition {
        Transition(
            state: state,
            baselineObservedFailures: baselineObservedFailures,
            newFailureCandidates: newFailureCandidates,
            diagnostics: diagnostics
        )
    }

    private func sourceID(of event: Event) -> String {
        switch event {
        case let .baseline(source, _, _, _, _): return source
        case let .taskUpdate(source, _, _, _, _): return source
        case let .heartbeat(source, _, _, _): return source
        case let .connected(source, _): return source
        case let .disconnected(source, _): return source
        }
    }

    private func generation(of event: Event) -> UInt64 {
        switch event {
        case let .baseline(_, _, generation, _, _): return generation
        case let .taskUpdate(_, _, generation, _, _): return generation
        case let .heartbeat(_, _, generation, _): return generation
        case let .connected(_, generation): return generation
        case let .disconnected(_, generation): return generation
        }
    }

    private struct StreamKey: Hashable {
        let epoch: String
        let sequence: Int64
    }

    private enum StreamPayload: Equatable {
        case baseline([TaskKey: TaskSnapshot])
        case task(TaskSnapshot)
        case heartbeat
    }
}
