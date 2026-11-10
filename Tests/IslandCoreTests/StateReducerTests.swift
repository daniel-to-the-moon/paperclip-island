import Foundation
import XCTest
@testable import IslandCore

/// ST01–ST25 plus the T2 isolation, integer-boundary, and watermark assertions.
/// Clocks are injected `Instant` values; these tests never sleep or read `Date()`.
final class StateReducerTests: XCTestCase {
    private func at(_ milliseconds: Int64, wall: TimeInterval = 1_700_000_000) -> Instant {
        Instant(monotonicMilliseconds: milliseconds, wall: Date(timeIntervalSince1970: wall))
    }

    private func key(_ id: String = "task-1", source: String = "mock-source") -> TaskKey {
        TaskKey(sourceID: source, taskID: id)
    }

    private func task(
        source: String = "mock-source",
        id: String = "task-1",
        attempt: String = "attempt-1",
        ordinal: Int64 = 1,
        state: TaskState = .running,
        revision: Int64 = 1,
        title: String = "虚构任务",
        summary: String = "虚构摘要",
        sourceUpdatedAt: Date? = nil,
        detailTarget: DetailTarget = .unavailable
    ) -> TaskSnapshot {
        TaskSnapshot(
            key: TaskKey(sourceID: source, taskID: id),
            attemptID: attempt, attemptOrdinal: ordinal, revision: revision,
            state: state, title: title, summary: summary,
            sourceUpdatedAt: sourceUpdatedAt, detailTarget: detailTarget
        )
    }

    private func baseline(
        source: String = "mock-source",
        epoch: String = "epoch-1",
        generation: UInt64 = 1,
        watermark: Int64,
        tasks: [TaskSnapshot]
    ) -> Event {
        .baseline(sourceID: source, epoch: epoch, generation: generation, watermark: watermark, tasks: tasks)
    }

    private func update(
        source: String = "mock-source",
        epoch: String = "epoch-1",
        generation: UInt64 = 1,
        sequence: Int64,
        task: TaskSnapshot
    ) -> Event {
        .taskUpdate(sourceID: source, epoch: epoch, generation: generation, sequence: sequence, task: task)
    }

    private func heartbeat(
        source: String = "mock-source",
        epoch: String = "epoch-1",
        generation: UInt64 = 1,
        sequence: Int64
    ) -> Event {
        .heartbeat(sourceID: source, epoch: epoch, generation: generation, sequence: sequence)
    }

    private func connected(source: String = "mock-source", generation: UInt64 = 1) -> Event {
        .connected(sourceID: source, generation: generation)
    }

    private func disconnected(source: String = "mock-source", generation: UInt64 = 1) -> Event {
        .disconnected(sourceID: source, generation: generation)
    }

    private func makeReducer(
        source: String = "mock-source",
        generation: UInt64 = 1,
        staleAfterMilliseconds: Int64 = 30_000
    ) -> StateReducer {
        StateReducer(sourceID: source, generation: generation, staleAfterMilliseconds: staleAfterMilliseconds)
    }

    // MARK: - ST01–ST25

    func test_ST01_initial() {
        let reducer = StateReducer(sourceID: "mock-source")
        XCTAssertEqual(reducer.state.sourceID, "mock-source")
        XCTAssertEqual(reducer.state.generation, 0)
        XCTAssertEqual(reducer.state.connection, .offline)
        XCTAssertTrue(reducer.state.tasks.isEmpty)
        XCTAssertFalse(reducer.state.synchronized)
        XCTAssertNil(reducer.state.lastSuccess)

        var mutable = reducer
        let beat = mutable.apply(heartbeat(generation: 0, sequence: 1), now: at(1_000))
        XCTAssertEqual(beat.state.connection, .offline)
        XCTAssertNil(beat.state.lastSuccess)
        XCTAssertTrue(beat.state.tasks.isEmpty)
        XCTAssertTrue(beat.newFailureCandidates.isEmpty)
        XCTAssertTrue(beat.baselineObservedFailures.isEmpty)

        let ticked = mutable.tick(now: at(120_000))
        XCTAssertEqual(ticked.state.connection, .offline)
        XCTAssertTrue(ticked.state.tasks.isEmpty)
        XCTAssertTrue(ticked.newFailureCandidates.isEmpty)
    }

    func test_ST02_baseline() {
        var reducer = makeReducer()
        let running = task(id: "task-run", state: .running, title: "运行")
        let succeeded = task(id: "task-ok", attempt: "attempt-ok", state: .succeeded, title: "成功")
        let failed = task(id: "task-bad", attempt: "attempt-bad", state: .failed, title: "失败")
        let unknown = task(id: "task-unk", attempt: "attempt-unk", state: .unknown, title: "未知")
        let transition = reducer.apply(
            baseline(watermark: 10, tasks: [running, succeeded, failed, unknown]),
            now: at(0)
        )

        XCTAssertEqual(transition.state.connection, .online)
        XCTAssertTrue(transition.state.synchronized)
        XCTAssertEqual(transition.state.tasks[running.key]?.snapshot, running)
        XCTAssertEqual(transition.state.tasks[succeeded.key]?.snapshot, succeeded)
        XCTAssertEqual(transition.state.tasks[failed.key]?.snapshot, failed)
        XCTAssertEqual(transition.state.tasks[unknown.key]?.snapshot, unknown)
        XCTAssertEqual(transition.baselineObservedFailures, [AttemptKey(taskKey: failed.key, attemptID: failed.attemptID)])
        XCTAssertTrue(transition.newFailureCandidates.isEmpty)
        XCTAssertTrue(transition.diagnostics.isEmpty)
        XCTAssertEqual(transition.state.tasks[failed.key]?.sourceConflict, false)
    }

    func test_ST03_liveFailure() {
        var reducer = makeReducer()
        _ = reducer.apply(baseline(watermark: 10, tasks: [task(state: .running, title: "运行中")]), now: at(0))
        let failed = task(state: .failed, revision: 2, title: "失败了")
        let live = reducer.apply(update(sequence: 11, task: failed), now: at(1_000))

        XCTAssertEqual(live.newFailureCandidates.count, 1)
        XCTAssertEqual(live.newFailureCandidates.first?.snapshot, failed)
        XCTAssertEqual(live.newFailureCandidates.first?.sourceConflict, false)
        XCTAssertTrue(live.baselineObservedFailures.isEmpty)
        XCTAssertEqual(live.state.tasks[key()]?.snapshot.state, .failed)
        XCTAssertEqual(live.state.connection, .online)

        let detail = task(state: .failed, revision: 3, title: "补充说明", summary: "细节")
        let again = reducer.apply(update(sequence: 12, task: detail), now: at(2_000))
        XCTAssertTrue(again.newFailureCandidates.isEmpty)
        XCTAssertEqual(again.state.tasks[key()]?.snapshot, detail)
        XCTAssertEqual(again.state.tasks[key()]?.sourceConflict, false)
        XCTAssertEqual(again.state.connection, .online)
    }

    func test_ST04_success() {
        var reducer = makeReducer()
        let earlier = Date(timeIntervalSince1970: 1_600_000_000)
        let later = Date(timeIntervalSince1970: 1_800_000_000)
        _ = reducer.apply(
            baseline(watermark: 10, tasks: [task(state: .running, sourceUpdatedAt: later)]),
            now: at(0)
        )
        let succeeded = task(
            state: .succeeded, revision: 2, title: "完成",
            sourceUpdatedAt: earlier, detailTarget: .testMarker("marker-1")
        )
        let transition = reducer.apply(update(sequence: 11, task: succeeded), now: at(1_500))

        XCTAssertEqual(transition.state.tasks[key()]?.snapshot, succeeded)
        XCTAssertEqual(transition.state.tasks[key()]?.lastTaskUpdate, at(1_500))
        XCTAssertEqual(transition.state.lastSuccess, at(1_500))
        XCTAssertTrue(transition.newFailureCandidates.isEmpty)
        XCTAssertTrue(transition.baselineObservedFailures.isEmpty)
        XCTAssertEqual(transition.state.connection, .online)
    }

    func test_ST05_unknownTransitions() {
        var reducer = makeReducer()
        let running = task(id: "to-run", state: .unknown)
        let succeeded = task(id: "to-ok", attempt: "attempt-ok", state: .unknown)
        let failed = task(id: "to-bad", attempt: "attempt-bad", state: .unknown)
        _ = reducer.apply(baseline(watermark: 10, tasks: [running, succeeded, failed]), now: at(0))

        let toRunning = reducer.apply(
            update(sequence: 11, task: task(id: "to-run", state: .running, revision: 2, title: "开始")),
            now: at(1)
        )
        XCTAssertEqual(toRunning.state.tasks[running.key]?.snapshot.state, .running)
        XCTAssertTrue(toRunning.newFailureCandidates.isEmpty)

        let toSucceeded = reducer.apply(
            update(sequence: 12, task: task(id: "to-ok", attempt: "attempt-ok", state: .succeeded, revision: 2)),
            now: at(2)
        )
        XCTAssertEqual(toSucceeded.state.tasks[succeeded.key]?.snapshot.state, .succeeded)
        XCTAssertTrue(toSucceeded.newFailureCandidates.isEmpty)

        let failedNext = task(id: "to-bad", attempt: "attempt-bad", state: .failed, revision: 2, title: "新失败")
        let toFailed = reducer.apply(update(sequence: 13, task: failedNext), now: at(3))
        XCTAssertEqual(toFailed.state.tasks[failed.key]?.snapshot.state, .failed)
        XCTAssertEqual(toFailed.newFailureCandidates.map(\.snapshot), [failedNext])
        XCTAssertNotEqual(toFailed.state.tasks[running.key]?.snapshot.state, .succeeded)
    }

    func test_ST06_payloadConflict() {
        var reducer = makeReducer()
        let original = task(revision: 5, title: "v5")
        _ = reducer.apply(baseline(watermark: 10, tasks: [original]), now: at(0))
        let applied = task(revision: 6, title: "v6")
        _ = reducer.apply(update(sequence: 11, task: applied), now: at(1_000))

        let duplicate = reducer.apply(update(sequence: 11, task: applied), now: at(2_000))
        XCTAssertTrue(duplicate.diagnostics.isEmpty)
        XCTAssertEqual(duplicate.state.connection, .online)
        XCTAssertEqual(duplicate.state.tasks[key()]?.snapshot, applied)
        XCTAssertEqual(duplicate.state.tasks[key()]?.lastTaskUpdate, at(1_000))
        XCTAssertEqual(duplicate.state.lastSuccess, at(1_000))
        XCTAssertTrue(duplicate.newFailureCandidates.isEmpty)

        let staleRevision = task(revision: 4, title: "旧修订")
        let consumed = reducer.apply(update(sequence: 12, task: staleRevision), now: at(3_000))
        XCTAssertTrue(consumed.diagnostics.isEmpty)
        XCTAssertEqual(consumed.state.connection, .online)
        XCTAssertEqual(consumed.state.tasks[key()]?.snapshot, applied)
        XCTAssertEqual(consumed.state.tasks[key()]?.lastTaskUpdate, at(1_000))
        XCTAssertEqual(consumed.state.lastSuccess, at(3_000))
        XCTAssertTrue(consumed.newFailureCandidates.isEmpty)

        let alive = reducer.apply(heartbeat(sequence: 13), now: at(4_000))
        XCTAssertEqual(alive.state.connection, .online)
        XCTAssertEqual(alive.state.lastSuccess, at(4_000))
        XCTAssertEqual(alive.state.tasks[key()]?.lastTaskUpdate, at(1_000))

        let replayedBeat = reducer.apply(heartbeat(sequence: 13), now: at(4_500))
        XCTAssertEqual(replayedBeat.state.connection, .online)
        XCTAssertEqual(replayedBeat.state.lastSuccess, at(4_000))
        XCTAssertEqual(replayedBeat.state.tasks[key()]?.snapshot, applied)

        let conflict = reducer.apply(update(sequence: 13, task: task(revision: 7, title: "冲突载荷")), now: at(5_000))
        XCTAssertEqual(conflict.diagnostics, [.payloadConflict])
        XCTAssertEqual(conflict.state.connection, .stale)
        XCTAssertFalse(conflict.state.synchronized)
        XCTAssertEqual(conflict.state.tasks[key()]?.snapshot, applied)
        XCTAssertEqual(conflict.state.tasks[key()]?.lastTaskUpdate, at(1_000))
        XCTAssertEqual(conflict.state.lastSuccess, at(4_000))
        XCTAssertTrue(conflict.newFailureCandidates.isEmpty)
        XCTAssertNotEqual(conflict.state.connection, .online)

        let follow = reducer.apply(heartbeat(sequence: 14), now: at(6_000))
        XCTAssertNotEqual(follow.state.connection, .online)
        XCTAssertEqual(follow.state.lastSuccess, at(4_000))
        XCTAssertEqual(follow.state.tasks[key()]?.snapshot, applied)

        var other = makeReducer()
        _ = other.apply(baseline(watermark: 10, tasks: [task(title: "基线")]), now: at(0))
        let belowWatermark = other.apply(heartbeat(sequence: 9), now: at(1))
        XCTAssertTrue(belowWatermark.diagnostics.isEmpty)
        XCTAssertEqual(belowWatermark.state.connection, .online)
        XCTAssertTrue(belowWatermark.state.synchronized)
        XCTAssertEqual(belowWatermark.state.lastSuccess, at(0))
        let sameSequence = other.apply(update(sequence: 10, task: task(revision: 2, title: "别的")), now: at(2))
        XCTAssertTrue(sameSequence.diagnostics.isEmpty)
        XCTAssertEqual(sameSequence.state.connection, .online)
        XCTAssertTrue(sameSequence.state.synchronized)
        XCTAssertEqual(sameSequence.state.tasks[key()]?.snapshot.title, "基线")
        XCTAssertEqual(sameSequence.state.tasks[key()]?.lastTaskUpdate, at(0))
        XCTAssertEqual(sameSequence.state.lastSuccess, at(0))
        let continued = other.apply(heartbeat(sequence: 11), now: at(3))
        XCTAssertEqual(continued.state.connection, .online)
        XCTAssertEqual(continued.state.lastSuccess, at(3))
        XCTAssertEqual(continued.state.tasks[key()]?.lastTaskUpdate, at(0))

        var replayedBaseline = makeReducer()
        let snapshot = task(state: .running, title: "重复基线")
        _ = replayedBaseline.apply(baseline(watermark: 4, tasks: [snapshot]), now: at(0))
        let replay = replayedBaseline.apply(baseline(watermark: 4, tasks: [snapshot]), now: at(500))
        XCTAssertTrue(replay.diagnostics.isEmpty)
        XCTAssertEqual(replay.state.connection, .online)
        XCTAssertEqual(replay.state.lastSuccess, at(0))
        XCTAssertEqual(replay.state.tasks[key()]?.lastTaskUpdate, at(0))
        XCTAssertEqual(replay.state.tasks[key()]?.snapshot, snapshot)
    }

    func test_ST07_oldAttempt() {
        var reducer = makeReducer()
        let current = task(attempt: "attempt-new", ordinal: 5, state: .succeeded, revision: 3, title: "当前")
        _ = reducer.apply(baseline(watermark: 10, tasks: [current]), now: at(0))

        let oldAttempt = task(attempt: "attempt-old", ordinal: 2, state: .failed, revision: 9, title: "倒退")
        let ignored = reducer.apply(update(sequence: 11, task: oldAttempt), now: at(1_000))
        XCTAssertTrue(ignored.diagnostics.isEmpty)
        XCTAssertEqual(ignored.state.tasks[key()]?.snapshot, current)
        XCTAssertEqual(ignored.state.tasks[key()]?.lastTaskUpdate, at(0))
        XCTAssertEqual(ignored.state.lastSuccess, at(1_000))
        XCTAssertTrue(ignored.newFailureCandidates.isEmpty)
        XCTAssertEqual(ignored.state.connection, .online)

        let oldRevision = task(attempt: "attempt-new", ordinal: 5, state: .running, revision: 1, title: "旧修订")
        let stillCurrent = reducer.apply(update(sequence: 12, task: oldRevision), now: at(2_000))
        XCTAssertEqual(stillCurrent.state.tasks[key()]?.snapshot, current)
        XCTAssertEqual(stillCurrent.state.tasks[key()]?.lastTaskUpdate, at(0))
        XCTAssertEqual(stillCurrent.state.lastSuccess, at(2_000))

        let continued = reducer.apply(heartbeat(sequence: 13), now: at(3_000))
        XCTAssertEqual(continued.state.connection, .online)
        XCTAssertEqual(continued.state.tasks[key()]?.snapshot, current)

        let late = reducer.apply(update(sequence: 11, task: oldAttempt), now: at(4_000))
        XCTAssertEqual(late.state.lastSuccess, at(3_000))
        XCTAssertEqual(late.state.tasks[key()]?.snapshot, current)
        XCTAssertTrue(late.newFailureCandidates.isEmpty)
    }

    func test_ST08_terminalConflict() {
        var reducer = makeReducer()
        _ = reducer.apply(baseline(watermark: 10, tasks: [task(state: .succeeded, revision: 1)]), now: at(0))
        let conflict = reducer.apply(
            update(sequence: 11, task: task(state: .running, revision: 2, title: "反向")),
            now: at(1_000)
        )
        XCTAssertEqual(conflict.state.tasks[key()]?.snapshot.state, .unknown)
        XCTAssertEqual(conflict.state.tasks[key()]?.sourceConflict, true)
        XCTAssertEqual(conflict.state.tasks[key()]?.snapshot.attemptID, "attempt-1")
        XCTAssertTrue(conflict.newFailureCandidates.isEmpty)
        XCTAssertEqual(conflict.state.connection, .online)
        XCTAssertTrue(conflict.state.synchronized)

        let locked = reducer.apply(
            update(sequence: 12, task: task(state: .succeeded, revision: 3, title: "不能解开")),
            now: at(2_000)
        )
        XCTAssertEqual(locked.state.tasks[key()]?.snapshot.state, .unknown)
        XCTAssertEqual(locked.state.tasks[key()]?.sourceConflict, true)
        XCTAssertEqual(locked.state.tasks[key()]?.lastTaskUpdate, at(1_000))
        XCTAssertTrue(locked.newFailureCandidates.isEmpty)
        XCTAssertEqual(locked.state.connection, .online)

        let cleared = task(state: .running, revision: 1, title: "新基线")
        let baselineUnlock = reducer.apply(baseline(watermark: 20, tasks: [cleared]), now: at(3_000))
        XCTAssertEqual(baselineUnlock.state.connection, .online)
        XCTAssertEqual(baselineUnlock.state.tasks[key()]?.snapshot, cleared)
        XCTAssertEqual(baselineUnlock.state.tasks[key()]?.sourceConflict, false)
        XCTAssertTrue(baselineUnlock.newFailureCandidates.isEmpty)

        var other = makeReducer()
        _ = other.apply(baseline(watermark: 10, tasks: [task(state: .failed, revision: 1)]), now: at(0))
        let reversed = other.apply(update(sequence: 11, task: task(state: .succeeded, revision: 2)), now: at(1_000))
        XCTAssertEqual(reversed.state.tasks[key()]?.snapshot.state, .unknown)
        XCTAssertEqual(reversed.state.tasks[key()]?.sourceConflict, true)
        XCTAssertTrue(reversed.newFailureCandidates.isEmpty)

        let fresh = task(attempt: "attempt-2", ordinal: 2, state: .running, revision: 1, title: "新尝试")
        let unlocked = other.apply(update(sequence: 12, task: fresh), now: at(2_000))
        XCTAssertEqual(unlocked.state.tasks[key()]?.snapshot, fresh)
        XCTAssertEqual(unlocked.state.tasks[key()]?.sourceConflict, false)
        XCTAssertTrue(unlocked.newFailureCandidates.isEmpty)
        XCTAssertEqual(unlocked.state.connection, .online)
    }

    func test_ST09_newAttempt() {
        var reducer = makeReducer()
        let old = task(attempt: "attempt-old", ordinal: 1, state: .failed, title: "历史失败")
        let observed = reducer.apply(baseline(watermark: 10, tasks: [old]), now: at(0))
        XCTAssertTrue(observed.newFailureCandidates.isEmpty)
        XCTAssertEqual(observed.baselineObservedFailures.count, 1)

        let started = task(attempt: "attempt-new", ordinal: 2, state: .running, revision: 1, title: "新尝试")
        let visible = reducer.apply(update(sequence: 11, task: started), now: at(1_000))
        XCTAssertEqual(visible.state.tasks[key()]?.snapshot, started)
        XCTAssertEqual(visible.state.tasks[key()]?.sourceConflict, false)
        XCTAssertTrue(visible.newFailureCandidates.isEmpty)

        let failed = task(attempt: "attempt-new", ordinal: 2, state: .failed, revision: 2, title: "新失败")
        let candidate = reducer.apply(update(sequence: 12, task: failed), now: at(2_000))
        XCTAssertEqual(candidate.newFailureCandidates.map(\.snapshot), [failed])
        XCTAssertEqual(candidate.state.tasks[key()]?.snapshot.state, .failed)

        let detail = task(attempt: "attempt-new", ordinal: 2, state: .failed, revision: 3, title: "细节")
        let once = reducer.apply(update(sequence: 13, task: detail), now: at(3_000))
        XCTAssertTrue(once.newFailureCandidates.isEmpty)
        XCTAssertEqual(once.state.tasks[key()]?.snapshot, detail)
    }

    func test_ST10_attemptIdentity() {
        var sameOrdinal = makeReducer()
        let original = task(attempt: "attempt-a", ordinal: 1, state: .running, title: "原尝试")
        _ = sameOrdinal.apply(baseline(watermark: 5, tasks: [original]), now: at(0))
        let swappedID = task(attempt: "attempt-b", ordinal: 1, state: .failed, revision: 2, title: "换了ID")
        let rejected = sameOrdinal.apply(update(sequence: 6, task: swappedID), now: at(1_000))
        XCTAssertEqual(rejected.diagnostics, [.attemptConflict])
        XCTAssertEqual(rejected.state.tasks[key()]?.snapshot, original)
        XCTAssertNotEqual(rejected.state.tasks[key()]?.snapshot.attemptID, "attempt-b")
        XCTAssertTrue(rejected.newFailureCandidates.isEmpty)
        XCTAssertEqual(rejected.state.connection, .stale)
        XCTAssertFalse(rejected.state.synchronized)
        let spliced = sameOrdinal.apply(heartbeat(sequence: 7), now: at(2_000))
        XCTAssertNotEqual(spliced.state.connection, .online)
        XCTAssertEqual(spliced.state.tasks[key()]?.snapshot, original)

        var sameID = makeReducer()
        _ = sameID.apply(baseline(watermark: 5, tasks: [original]), now: at(0))
        let swappedOrdinal = task(attempt: "attempt-a", ordinal: 4, state: .succeeded, revision: 2, title: "同ID换序号")
        let conflict = sameID.apply(update(sequence: 6, task: swappedOrdinal), now: at(1_000))
        XCTAssertEqual(conflict.diagnostics, [.attemptConflict])
        XCTAssertEqual(conflict.state.tasks[key()]?.snapshot, original)
        XCTAssertEqual(conflict.state.tasks[key()]?.snapshot.attemptOrdinal, 1)
        XCTAssertTrue(conflict.newFailureCandidates.isEmpty)
        XCTAssertEqual(conflict.state.connection, .stale)
        XCTAssertNotEqual(conflict.state.connection, .online)

        var lowerOrdinal = makeReducer()
        _ = lowerOrdinal.apply(baseline(watermark: 5, tasks: [original]), now: at(0))
        let older = task(attempt: "attempt-a", ordinal: 0, state: .failed, revision: 2, title: "更低序号")
        let lowered = lowerOrdinal.apply(update(sequence: 6, task: older), now: at(1_000))
        XCTAssertEqual(lowered.diagnostics, [.attemptConflict])
        XCTAssertEqual(lowered.state.connection, .stale)
        XCTAssertFalse(lowered.state.synchronized)
        XCTAssertEqual(lowered.state.tasks[key()]?.snapshot, original)
        XCTAssertTrue(lowered.newFailureCandidates.isEmpty)
    }

    func test_ST11_malformed() {
        var reducer = makeReducer()
        let original = task(state: .running, revision: 4, title: "可信")
        _ = reducer.apply(baseline(watermark: 8, tasks: [original]), now: at(100))

        let wrongSource = reducer.apply(
            update(source: "other-source", sequence: 9, task: task(source: "other-source", state: .failed, revision: 5)),
            now: at(110)
        )
        XCTAssertEqual(wrongSource.diagnostics, [.invalidInput])
        XCTAssertEqual(wrongSource.state.connection, .online)
        XCTAssertEqual(wrongSource.state.lastSuccess, at(100))
        XCTAssertTrue(wrongSource.newFailureCandidates.isEmpty)

        let negative = reducer.apply(update(sequence: -5, task: task(state: .failed, revision: 5, title: "负数")), now: at(120))
        XCTAssertEqual(negative.diagnostics, [.invalidInput])
        XCTAssertEqual(negative.state.connection, .online)
        XCTAssertEqual(negative.state.tasks[key()]?.snapshot, original)
        XCTAssertEqual(negative.state.lastSuccess, at(100))

        let stillTrusted = task(state: .succeeded, revision: 5, title: "仍可信")
        let accepted = reducer.apply(update(sequence: 9, task: stillTrusted), now: at(130))
        XCTAssertEqual(accepted.state.connection, .online)
        XCTAssertEqual(accepted.state.tasks[key()]?.snapshot, stillTrusted)
        XCTAssertTrue(accepted.newFailureCandidates.isEmpty)

        let broken = reducer.apply(
            update(sequence: 10, task: task(id: " ", state: .succeeded, revision: 6, title: "坏标识")),
            now: at(140)
        )
        XCTAssertEqual(broken.diagnostics, [.invalidInput])
        XCTAssertEqual(broken.state.connection, .stale)
        XCTAssertFalse(broken.state.synchronized)
        XCTAssertEqual(broken.state.tasks[key()]?.snapshot, stillTrusted)
        XCTAssertEqual(broken.state.lastSuccess, at(130))
        XCTAssertTrue(broken.newFailureCandidates.isEmpty)
        XCTAssertNotEqual(broken.state.tasks[key()]?.snapshot.title, "坏标识")

        let follow = reducer.apply(heartbeat(sequence: 10), now: at(150))
        XCTAssertNotEqual(follow.state.connection, .online)
        XCTAssertEqual(follow.state.lastSuccess, at(130))
        XCTAssertEqual(follow.state.tasks[key()]?.snapshot, stillTrusted)
    }

    func test_ST12_atomicBaseline() {
        var reducer = makeReducer()
        let original = task(id: "keep", state: .running, revision: 1, title: "保留")
        _ = reducer.apply(baseline(watermark: 3, tasks: [original]), now: at(0))
        let conflicting = reducer.apply(
            baseline(watermark: 4, tasks: [
                task(id: "dup", state: .running, title: "A"),
                task(id: "dup", state: .failed, title: "B")
            ]),
            now: at(1_000)
        )
        XCTAssertEqual(conflicting.diagnostics, [.payloadConflict])
        XCTAssertEqual(conflicting.state.tasks, reducer.state.tasks)
        XCTAssertEqual(conflicting.state.tasks[original.key]?.snapshot, original)
        XCTAssertNil(conflicting.state.tasks[key("dup")])
        XCTAssertEqual(conflicting.state.connection, .online)
        XCTAssertEqual(conflicting.state.lastSuccess, at(0))
        XCTAssertTrue(conflicting.newFailureCandidates.isEmpty)

        let incomplete = reducer.apply(
            baseline(watermark: 5, tasks: [task(id: "  ", state: .succeeded, title: "缺身份")]),
            now: at(2_000)
        )
        XCTAssertEqual(incomplete.diagnostics, [.invalidInput])
        XCTAssertEqual(incomplete.state.tasks[original.key]?.snapshot, original)
        XCTAssertEqual(incomplete.state.tasks.count, 1)
        XCTAssertEqual(incomplete.state.connection, .online)
        XCTAssertEqual(incomplete.state.lastSuccess, at(0))

        var duplicates = makeReducer()
        let same = task(id: "dup", state: .running, title: "A")
        let accepted = duplicates.apply(baseline(watermark: 1, tasks: [same, same]), now: at(0))
        XCTAssertTrue(accepted.diagnostics.isEmpty)
        XCTAssertEqual(accepted.state.connection, .online)
        XCTAssertEqual(accepted.state.tasks.count, 1)
        XCTAssertEqual(accepted.state.tasks[same.key]?.snapshot, same)
    }

    func test_ST13_emptyBaseline() {
        var reducer = makeReducer()
        let succeeded = task(id: "gone-ok", state: .succeeded)
        let failed = task(id: "gone-bad", attempt: "attempt-bad", state: .failed)
        _ = reducer.apply(baseline(watermark: 10, tasks: [succeeded, failed]), now: at(0))
        let empty = reducer.apply(baseline(watermark: 11, tasks: []), now: at(1_000))

        XCTAssertTrue(empty.state.tasks.isEmpty)
        XCTAssertTrue(empty.newFailureCandidates.isEmpty)
        XCTAssertTrue(empty.baselineObservedFailures.isEmpty)
        XCTAssertEqual(empty.state.connection, .online)
        XCTAssertTrue(empty.state.synchronized)
        XCTAssertNotEqual(empty.state.tasks[succeeded.key]?.snapshot.state, .succeeded)
    }

    func test_ST14_disconnect() {
        var reducer = makeReducer()
        let running = task(state: .running, title: "仍在运行")
        _ = reducer.apply(baseline(watermark: 10, tasks: [running]), now: at(0))
        let transition = reducer.apply(disconnected(), now: at(5_000))

        XCTAssertEqual(transition.state.connection, .offline)
        XCTAssertFalse(transition.state.synchronized)
        XCTAssertEqual(transition.state.tasks[key()]?.snapshot, running)
        XCTAssertEqual(transition.state.tasks[key()]?.lastTaskUpdate, at(0))
        XCTAssertEqual(transition.state.lastSuccess, at(0))
        XCTAssertTrue(transition.newFailureCandidates.isEmpty)
        XCTAssertNotEqual(transition.state.tasks[key()]?.snapshot.state, .failed)
    }

    func test_ST15_staleBoundary() {
        var reducer = makeReducer()
        let running = task(state: .running)
        _ = reducer.apply(baseline(watermark: 10, tasks: [running]), now: at(1_000))

        XCTAssertEqual(reducer.tick(now: at(1_000)).state.connection, .online)
        let below = reducer.tick(now: at(1_000 + 29_999))
        XCTAssertEqual(below.state.connection, .online)
        XCTAssertEqual(below.state.tasks[key()]?.snapshot, running)
        XCTAssertTrue(below.newFailureCandidates.isEmpty)
        XCTAssertTrue(below.state.synchronized)

        let atThreshold = reducer.tick(now: at(1_000 + 30_000))
        XCTAssertEqual(atThreshold.state.connection, .stale)
        XCTAssertEqual(atThreshold.state.tasks[key()]?.snapshot, running)
        XCTAssertEqual(atThreshold.state.tasks[key()]?.lastTaskUpdate, at(1_000))
        XCTAssertTrue(atThreshold.newFailureCandidates.isEmpty)
        XCTAssertTrue(atThreshold.state.synchronized)
        XCTAssertEqual(reducer.tick(now: at(1_000 + 90_000)).state.connection, .stale)

        var custom = makeReducer(staleAfterMilliseconds: 5)
        _ = custom.apply(baseline(watermark: 1, tasks: [task()]), now: at(100))
        XCTAssertEqual(custom.tick(now: at(104)).state.connection, .online)
        XCTAssertEqual(custom.tick(now: at(105)).state.connection, .stale)
    }

    func test_ST16_heartbeat() {
        var reducer = makeReducer()
        let running = task(state: .running, title: "任务本身没变")
        _ = reducer.apply(baseline(watermark: 10, tasks: [running]), now: at(0))
        let beat = reducer.apply(heartbeat(sequence: 11), now: at(1_000))

        XCTAssertEqual(beat.state.connection, .online)
        XCTAssertTrue(beat.state.synchronized)
        XCTAssertEqual(beat.state.lastSuccess, at(1_000))
        XCTAssertEqual(beat.state.tasks[key()]?.snapshot, running)
        XCTAssertEqual(beat.state.tasks[key()]?.lastTaskUpdate, at(0))
        XCTAssertTrue(beat.newFailureCandidates.isEmpty)

        XCTAssertEqual(reducer.tick(now: at(1_000 + 30_000)).state.connection, .stale)
        let restored = reducer.apply(heartbeat(sequence: 12), now: at(1_000 + 30_000))
        XCTAssertEqual(restored.state.connection, .online)
        XCTAssertEqual(restored.state.lastSuccess, at(1_000 + 30_000))
        XCTAssertEqual(restored.state.tasks[key()]?.lastTaskUpdate, at(0))
        XCTAssertEqual(restored.state.tasks[key()]?.snapshot, running)
        XCTAssertTrue(restored.newFailureCandidates.isEmpty)
    }

    func test_ST17_oldGeneration() {
        var reducer = makeReducer()
        let running = task(state: .running, revision: 3, title: "旧世代")
        _ = reducer.apply(baseline(generation: 1, watermark: 10, tasks: [running]), now: at(0))
        let woken = reducer.wake(newGeneration: 2, now: at(1_000))
        XCTAssertEqual(woken.state.generation, 2)
        XCTAssertEqual(woken.state.connection, .stale)
        XCTAssertEqual(woken.state.tasks[key()]?.snapshot, running)
        XCTAssertTrue(woken.newFailureCandidates.isEmpty)
        XCTAssertNotEqual(woken.state.connection, .online)

        let old = reducer.apply(
            update(generation: 1, sequence: 11, task: task(state: .failed, revision: 4, title: "迟到回调")),
            now: at(1_100)
        )
        XCTAssertEqual(old.diagnostics, [.oldGeneration])
        XCTAssertEqual(old.state.generation, 2)
        XCTAssertEqual(old.state.tasks[key()]?.snapshot, running)
        XCTAssertNotEqual(old.state.connection, .online)
        XCTAssertTrue(old.newFailureCandidates.isEmpty)
        XCTAssertEqual(old.state.lastSuccess, at(0))

        let future = reducer.apply(
            update(generation: 9, sequence: 11, task: task(state: .succeeded, revision: 5)),
            now: at(1_200)
        )
        XCTAssertEqual(future.diagnostics, [.invalidInput])
        XCTAssertEqual(future.state.generation, 2)
        XCTAssertEqual(future.state.tasks[key()]?.snapshot, running)
        XCTAssertNotEqual(future.state.connection, .online)

        let fresh = task(state: .succeeded, revision: 1, title: "新基线")
        let restored = reducer.apply(baseline(generation: 2, watermark: 15, tasks: [fresh]), now: at(1_300))
        XCTAssertEqual(restored.state.connection, .online)
        XCTAssertEqual(restored.state.tasks[key()]?.snapshot, fresh)
        XCTAssertTrue(restored.newFailureCandidates.isEmpty)
        XCTAssertEqual(restored.state.lastSuccess, at(1_300))
    }

    func test_ST18_epoch() {
        var reducer = makeReducer()
        let failed = task(id: "task-old", state: .failed, title: "旧纪元失败")
        let first = reducer.apply(baseline(epoch: "epoch-1", watermark: 10, tasks: [failed]), now: at(0))
        XCTAssertTrue(first.newFailureCandidates.isEmpty)
        XCTAssertEqual(first.baselineObservedFailures, [AttemptKey(taskKey: failed.key, attemptID: failed.attemptID)])

        let continued = reducer.apply(heartbeat(epoch: "epoch-1", sequence: 11), now: at(1_000))
        XCTAssertEqual(continued.state.connection, .online)
        XCTAssertEqual(continued.state.tasks[failed.key]?.lastTaskUpdate, at(0))

        let foreign = reducer.apply(
            update(epoch: "epoch-2", sequence: 1, task: task(id: "task-old", state: .succeeded, revision: 2)),
            now: at(2_000)
        )
        XCTAssertEqual(foreign.diagnostics, [.invalidInput])
        XCTAssertEqual(foreign.state.connection, .stale)
        XCTAssertFalse(foreign.state.synchronized)
        XCTAssertEqual(foreign.state.tasks[failed.key]?.snapshot, failed)
        XCTAssertTrue(foreign.newFailureCandidates.isEmpty)

        let sharedCursor = reducer.apply(
            update(epoch: "epoch-1", sequence: 12, task: task(id: "task-old", state: .running, revision: 2)),
            now: at(2_100)
        )
        XCTAssertNotEqual(sharedCursor.state.connection, .online)
        XCTAssertEqual(sharedCursor.state.tasks[failed.key]?.snapshot.state, .failed)

        let fresh = task(id: "task-new", attempt: "attempt-new", state: .failed, title: "新纪元")
        let switched = reducer.apply(baseline(epoch: "epoch-2", watermark: 4, tasks: [fresh]), now: at(3_000))
        XCTAssertEqual(switched.state.connection, .online)
        XCTAssertNil(switched.state.tasks[failed.key])
        XCTAssertEqual(switched.state.tasks[fresh.key]?.snapshot, fresh)
        XCTAssertTrue(switched.newFailureCandidates.isEmpty)
        XCTAssertEqual(switched.baselineObservedFailures, [AttemptKey(taskKey: fresh.key, attemptID: fresh.attemptID)])

        let independent = reducer.apply(heartbeat(epoch: "epoch-2", sequence: 5), now: at(4_000))
        XCTAssertEqual(independent.state.connection, .online)
        XCTAssertEqual(independent.state.tasks[fresh.key]?.lastTaskUpdate, at(3_000))
    }

    func test_ST19_wallClockJump() {
        var reducer = makeReducer()
        let earlyWall = Date(timeIntervalSince1970: 1_800_000_000)
        let lateWall = Date(timeIntervalSince1970: 1_000_000)
        _ = reducer.apply(
            baseline(watermark: 5, tasks: [task(state: .running, revision: 1)]),
            now: Instant(monotonicMilliseconds: 10_000, wall: earlyWall)
        )
        let succeeded = task(state: .succeeded, revision: 2, title: "按序号生效")
        let applied = reducer.apply(
            update(sequence: 6, task: succeeded),
            now: Instant(monotonicMilliseconds: 11_000, wall: lateWall)
        )
        XCTAssertEqual(applied.state.connection, .online)
        XCTAssertEqual(applied.state.tasks[key()]?.snapshot, succeeded)
        XCTAssertEqual(applied.state.lastSuccess?.monotonicMilliseconds, 11_000)
        XCTAssertEqual(applied.state.lastSuccess?.wall, lateWall)
        XCTAssertTrue(applied.newFailureCandidates.isEmpty)

        let wallJumpsForward = reducer.tick(now: Instant(
            monotonicMilliseconds: 11_000 + 29_999,
            wall: Date(timeIntervalSince1970: 4_000_000_000)
        ))
        XCTAssertEqual(wallJumpsForward.state.connection, .online)
        XCTAssertTrue(wallJumpsForward.newFailureCandidates.isEmpty)

        let monotonicExpires = reducer.tick(now: Instant(
            monotonicMilliseconds: 11_000 + 30_000,
            wall: lateWall
        ))
        XCTAssertEqual(monotonicExpires.state.connection, .stale)
        XCTAssertEqual(monotonicExpires.state.tasks[key()]?.snapshot, succeeded)
        XCTAssertTrue(monotonicExpires.newFailureCandidates.isEmpty)
    }

    func test_ST20_invalidHeartbeat() {
        var fresh = makeReducer()
        let premature = fresh.apply(heartbeat(sequence: 1), now: at(50))
        XCTAssertEqual(premature.diagnostics, [.invalidInput])
        XCTAssertEqual(premature.state.connection, .offline)
        XCTAssertNil(premature.state.lastSuccess)
        XCTAssertTrue(premature.newFailureCandidates.isEmpty)

        var synced = makeReducer()
        _ = synced.apply(baseline(watermark: 3, tasks: [task(state: .running)]), now: at(10))
        let negative = synced.apply(heartbeat(sequence: -1), now: at(20))
        XCTAssertEqual(negative.diagnostics, [.invalidInput])
        XCTAssertEqual(negative.state.connection, .online)
        XCTAssertEqual(negative.state.lastSuccess, at(10))
        let stillContinuous = synced.apply(heartbeat(sequence: 4), now: at(30))
        XCTAssertEqual(stillContinuous.state.connection, .online)
        XCTAssertEqual(stillContinuous.state.lastSuccess, at(30))
        XCTAssertEqual(stillContinuous.state.tasks[key()]?.lastTaskUpdate, at(10))

        var gapped = makeReducer()
        _ = gapped.apply(baseline(watermark: 10, tasks: [task(state: .running)]), now: at(1_000))
        let gap = gapped.apply(heartbeat(sequence: 12), now: at(2_000))
        XCTAssertEqual(gap.diagnostics, [.sequenceGap])
        XCTAssertEqual(gap.state.connection, .stale)
        XCTAssertFalse(gap.state.synchronized)
        XCTAssertEqual(gap.state.lastSuccess, at(1_000))
        XCTAssertEqual(gap.state.tasks[key()]?.snapshot.state, .running)
        XCTAssertTrue(gap.newFailureCandidates.isEmpty)

        let ignored = gapped.apply(heartbeat(sequence: 11), now: at(3_000))
        XCTAssertEqual(ignored.diagnostics, [.sequenceGap])
        XCTAssertNotEqual(ignored.state.connection, .online)
        XCTAssertEqual(ignored.state.lastSuccess, at(1_000))
    }

    func test_ST21_gap() {
        var reducer = makeReducer()
        let taskA = task(id: "task-a", state: .running, title: "A")
        let taskB = task(id: "task-b", state: .failed, title: "B")
        _ = reducer.apply(baseline(watermark: 10, tasks: [taskA]), now: at(0))

        let gap = reducer.apply(update(sequence: 12, task: taskB), now: at(1_000))
        XCTAssertEqual(gap.diagnostics, [.sequenceGap])
        XCTAssertEqual(gap.state.connection, .stale)
        XCTAssertFalse(gap.state.synchronized)
        XCTAssertNil(gap.state.tasks[taskB.key])
        XCTAssertEqual(gap.state.tasks[taskA.key]?.snapshot, taskA)
        XCTAssertTrue(gap.newFailureCandidates.isEmpty)
        XCTAssertEqual(gap.state.lastSuccess, at(0))
        XCTAssertNotEqual(gap.state.connection, .online)

        let doesNotUnlock = reducer.apply(
            update(sequence: 11, task: task(id: "task-a", state: .succeeded, revision: 2)),
            now: at(2_000)
        )
        XCTAssertNotEqual(doesNotUnlock.state.connection, .online)
        XCTAssertEqual(doesNotUnlock.state.tasks[taskA.key]?.snapshot, taskA)
        XCTAssertNil(doesNotUnlock.state.tasks[taskB.key])
        XCTAssertTrue(doesNotUnlock.newFailureCandidates.isEmpty)

        let recovery = task(id: "task-a", state: .succeeded, revision: 3, title: "恢复")
        let restored = reducer.apply(baseline(watermark: 11, tasks: [recovery]), now: at(3_000))
        XCTAssertEqual(restored.state.connection, .online)
        XCTAssertTrue(restored.state.synchronized)
        XCTAssertEqual(restored.state.tasks[taskA.key]?.snapshot, recovery)
        XCTAssertNil(restored.state.tasks[taskB.key])
        XCTAssertTrue(restored.newFailureCandidates.isEmpty)
    }

    func test_ST22_offlinePriority() {
        var reducer = makeReducer()
        let premature = reducer.apply(heartbeat(sequence: 1), now: at(0))
        XCTAssertEqual(premature.state.connection, .offline)
        XCTAssertNil(premature.state.lastSuccess)

        let running = task(state: .running, revision: 1, title: "断线前")
        _ = reducer.apply(baseline(watermark: 10, tasks: [running]), now: at(1_000))
        _ = reducer.apply(disconnected(), now: at(2_000))

        let lateBeat = reducer.apply(heartbeat(sequence: 11), now: at(3_000))
        XCTAssertEqual(lateBeat.state.connection, .offline)
        XCTAssertEqual(lateBeat.state.lastSuccess, at(1_000))
        XCTAssertEqual(lateBeat.state.tasks[key()]?.snapshot, running)
        XCTAssertTrue(lateBeat.newFailureCandidates.isEmpty)

        let lateUpdate = reducer.apply(
            update(sequence: 11, task: task(state: .failed, revision: 2, title: "迟到")),
            now: at(4_000)
        )
        XCTAssertEqual(lateUpdate.state.connection, .offline)
        XCTAssertEqual(lateUpdate.state.tasks[key()]?.snapshot, running)
        XCTAssertTrue(lateUpdate.newFailureCandidates.isEmpty)

        let ticked = reducer.tick(now: at(2_000 + 60_000))
        XCTAssertEqual(ticked.state.connection, .offline)
        XCTAssertNotEqual(ticked.state.connection, .stale)

        let blocked = reducer.apply(
            baseline(watermark: 40, tasks: [task(state: .failed, revision: 1, title: "未重连")]),
            now: at(5_000)
        )
        XCTAssertEqual(blocked.diagnostics, [.invalidInput])
        XCTAssertEqual(blocked.state.connection, .offline)
        XCTAssertEqual(blocked.state.tasks[key()]?.snapshot, running)

        let linking = reducer.apply(connected(), now: at(6_000))
        XCTAssertEqual(linking.state.connection, .stale)
        XCTAssertNotEqual(linking.state.connection, .online)
        let stillBlocked = reducer.apply(
            baseline(watermark: 40, tasks: [task(state: .succeeded, revision: 1, title: "同世代")]),
            now: at(7_000)
        )
        XCTAssertEqual(stillBlocked.diagnostics, [.invalidInput])
        XCTAssertNotEqual(stillBlocked.state.connection, .online)
        XCTAssertEqual(stillBlocked.state.tasks[key()]?.snapshot.state, .running)

        let woken = reducer.wake(newGeneration: 2, now: at(8_000))
        XCTAssertNotEqual(woken.state.connection, .online)
        let restored = reducer.apply(
            baseline(generation: 2, watermark: 40, tasks: [task(state: .running, revision: 8, title: "恢复")]),
            now: at(9_000)
        )
        XCTAssertEqual(restored.state.connection, .online)
        XCTAssertEqual(restored.state.tasks[key()]?.snapshot.title, "恢复")
        XCTAssertTrue(restored.newFailureCandidates.isEmpty)
    }

    func test_ST23_matrix() {
        let matrix: [(current: TaskState, input: TaskState, state: TaskState, conflict: Bool, candidate: Bool)] = [
            (.running, .running, .running, false, false),
            (.running, .succeeded, .succeeded, false, false),
            (.running, .failed, .failed, false, true),
            (.running, .unknown, .unknown, false, false),
            (.unknown, .running, .running, false, false),
            (.unknown, .succeeded, .succeeded, false, false),
            (.unknown, .failed, .failed, false, true),
            (.unknown, .unknown, .unknown, false, false),
            (.succeeded, .running, .unknown, true, false),
            (.succeeded, .succeeded, .succeeded, false, false),
            (.succeeded, .failed, .unknown, true, false),
            (.succeeded, .unknown, .unknown, true, false),
            (.failed, .running, .unknown, true, false),
            (.failed, .succeeded, .unknown, true, false),
            (.failed, .failed, .failed, false, false),
            (.failed, .unknown, .unknown, true, false)
        ]
        XCTAssertEqual(matrix.count, 16)
        let states = TaskState.allCases
        XCTAssertEqual(Set(matrix.map(\.current)), Set(states))
        XCTAssertEqual(Set(matrix.map(\.input)), Set(states))

        for cell in matrix {
            let (current, input, wantState, wantConflict, wantCandidate) = (cell.current, cell.input, cell.state, cell.conflict, cell.candidate)
            var reducer = makeReducer()
            let initial = task(state: current, revision: 1, title: "当前-\(current.rawValue)")
            _ = reducer.apply(baseline(watermark: 1, tasks: [initial]), now: at(0))
            let incoming = task(state: input, revision: 2, title: "输入-\(input.rawValue)")
            let transition = reducer.apply(update(sequence: 2, task: incoming), now: at(1_000))
            let label = "\(current.rawValue)->\(input.rawValue)"
                XCTAssertEqual(transition.state.tasks[key()]?.snapshot.state, wantState, label)
                XCTAssertEqual(transition.state.tasks[key()]?.sourceConflict, wantConflict, label)
                XCTAssertEqual(transition.newFailureCandidates.isEmpty, !wantCandidate, label)
                XCTAssertEqual(transition.state.connection, .online, label)
                XCTAssertTrue(transition.state.synchronized, label)
                XCTAssertEqual(transition.state.tasks[key()]?.snapshot.title, incoming.title, label)
                XCTAssertEqual(transition.state.tasks[key()]?.lastTaskUpdate, at(1_000), label)
                if wantCandidate {
                    XCTAssertEqual(transition.newFailureCandidates.first?.snapshot.state, .failed, label)
                }
                if wantConflict {
                    let locked = reducer.apply(
                        update(sequence: 3, task: task(state: .succeeded, revision: 3, title: "仍锁定")),
                        now: at(2_000)
                    )
                    XCTAssertEqual(locked.state.tasks[key()]?.snapshot.state, .unknown, label)
                    XCTAssertEqual(locked.state.tasks[key()]?.sourceConflict, true, label)
                    XCTAssertEqual(locked.state.tasks[key()]?.lastTaskUpdate, at(1_000), label)
                    XCTAssertTrue(locked.newFailureCandidates.isEmpty, label)
                    XCTAssertEqual(locked.state.connection, .online, label)
                }
        }

        let origins: [(String, (inout StateReducer) -> Void)] = [
            ("running", { reducer in
                _ = reducer.apply(self.baseline(watermark: 1, tasks: [self.task(state: .running)]), now: self.at(0))
            }),
            ("unknown", { reducer in
                _ = reducer.apply(self.baseline(watermark: 1, tasks: [self.task(state: .unknown)]), now: self.at(0))
            }),
            ("succeeded", { reducer in
                _ = reducer.apply(self.baseline(watermark: 1, tasks: [self.task(state: .succeeded)]), now: self.at(0))
            }),
            ("failed", { reducer in
                _ = reducer.apply(self.baseline(watermark: 1, tasks: [self.task(state: .failed)]), now: self.at(0))
            }),
            ("conflict", { reducer in
                _ = reducer.apply(self.baseline(watermark: 1, tasks: [self.task(state: .succeeded)]), now: self.at(0))
                _ = reducer.apply(self.update(sequence: 2, task: self.task(state: .running, revision: 2)), now: self.at(10))
            })
        ]
        for (name, prepare) in origins {
            for input in states {
                var reducer = makeReducer()
                prepare(&reducer)
                let nextSequence: Int64 = name == "conflict" ? 3 : 2
                let incoming = task(attempt: "attempt-next", ordinal: 2, state: input, revision: 1, title: "新尝试-\(input.rawValue)")
                let transition = reducer.apply(update(sequence: nextSequence, task: incoming), now: at(1_000))
                let label = "\(name)->attempt(\(input.rawValue))"
                XCTAssertEqual(transition.state.tasks[key()]?.snapshot, incoming, label)
                XCTAssertEqual(transition.state.tasks[key()]?.sourceConflict, false, label)
                XCTAssertEqual(transition.newFailureCandidates.isEmpty, input != .failed, label)
                XCTAssertEqual(transition.state.connection, .online, label)
            }
        }
    }

    func test_ST24_wake() {
        var reducer = makeReducer()
        _ = reducer.apply(baseline(watermark: 21, tasks: [task(state: .running, revision: 1, title: "醒前")]), now: at(0))
        let failed = task(state: .failed, revision: 2, title: "失败")
        let live = reducer.apply(update(sequence: 22, task: failed), now: at(1_000))
        XCTAssertEqual(live.newFailureCandidates.count, 1)

        let woken = reducer.wake(newGeneration: 2, now: at(2_000))
        XCTAssertEqual(woken.state.generation, 2)
        XCTAssertEqual(woken.state.connection, .stale)
        XCTAssertFalse(woken.state.synchronized)
        XCTAssertEqual(woken.state.tasks[key()]?.snapshot, failed)
        XCTAssertEqual(woken.state.tasks[key()]?.lastTaskUpdate, at(1_000))
        XCTAssertTrue(woken.newFailureCandidates.isEmpty)
        XCTAssertTrue(woken.baselineObservedFailures.isEmpty)

        let oldBaseline = reducer.apply(
            baseline(generation: 2, watermark: 21, tasks: [task(state: .running, revision: 1, title: "醒前")]),
            now: at(2_100)
        )
        XCTAssertEqual(oldBaseline.diagnostics, [.oldBaseline])
        XCTAssertEqual(oldBaseline.state.connection, .stale)
        XCTAssertEqual(oldBaseline.state.tasks[key()]?.snapshot.state, .failed)

        let callback = reducer.apply(
            update(generation: 1, sequence: 23, task: task(state: .succeeded, revision: 3)),
            now: at(2_200)
        )
        XCTAssertEqual(callback.diagnostics, [.oldGeneration])
        XCTAssertNotEqual(callback.state.connection, .online)
        XCTAssertEqual(callback.state.tasks[key()]?.snapshot.state, .failed)
        XCTAssertTrue(callback.newFailureCandidates.isEmpty)

        let restored = reducer.apply(
            baseline(generation: 2, watermark: 30, tasks: [task(state: .running, revision: 1, title: "新基线")]),
            now: at(2_300)
        )
        XCTAssertEqual(restored.state.connection, .online)
        XCTAssertEqual(restored.state.tasks[key()]?.snapshot.title, "新基线")
        XCTAssertTrue(restored.newFailureCandidates.isEmpty)

        var offline = StateReducer(sourceID: "mock-source", generation: 1)
        _ = offline.apply(baseline(watermark: 4, tasks: [task(state: .running)]), now: at(0))
        _ = offline.apply(disconnected(), now: at(1))
        let stillOffline = offline.wake(newGeneration: 5, now: at(2))
        XCTAssertEqual(stillOffline.state.connection, .offline)
        XCTAssertEqual(stillOffline.state.generation, 5)
        XCTAssertEqual(stillOffline.state.tasks[key()]?.snapshot.state, .running)
        XCTAssertTrue(stillOffline.newFailureCandidates.isEmpty)
    }

    func test_ST25_oldBaseline() {
        var reducer = makeReducer()
        let terminal = task(state: .succeeded, revision: 7, title: "已接受21")
        _ = reducer.apply(baseline(generation: 1, watermark: 21, tasks: [terminal]), now: at(0))
        _ = reducer.apply(disconnected(generation: 1), now: at(1_000))
        let woken = reducer.wake(newGeneration: 2, now: at(1_100))
        XCTAssertEqual(woken.state.connection, .offline)
        _ = reducer.apply(connected(generation: 2), now: at(1_200))
        XCTAssertEqual(reducer.state.connection, .stale)
        XCTAssertEqual(reducer.state.tasks[key()]?.snapshot, terminal)

        let old = reducer.apply(
            baseline(generation: 2, watermark: 10, tasks: [task(state: .running, revision: 1, title: "旧快照")]),
            now: at(1_300)
        )
        XCTAssertEqual(old.diagnostics, [.oldBaseline])
        XCTAssertEqual(old.state.connection, .stale)
        XCTAssertEqual(old.state.tasks[key()]?.snapshot, terminal)
        XCTAssertNotEqual(old.state.connection, .online)
        XCTAssertTrue(old.newFailureCandidates.isEmpty)

        let contradictory = reducer.apply(
            baseline(generation: 2, watermark: 21, tasks: [task(state: .failed, revision: 7, title: "矛盾快照")]),
            now: at(1_400)
        )
        XCTAssertEqual(contradictory.diagnostics, [.payloadConflict])
        XCTAssertEqual(contradictory.state.connection, .stale)
        XCTAssertEqual(contradictory.state.tasks[key()]?.snapshot, terminal)
        XCTAssertNotEqual(contradictory.state.connection, .online)

        let consistent = reducer.apply(baseline(generation: 2, watermark: 21, tasks: [terminal]), now: at(1_500))
        XCTAssertTrue(consistent.diagnostics.isEmpty)
        XCTAssertEqual(consistent.state.connection, .online)
        XCTAssertTrue(consistent.state.synchronized)
        XCTAssertEqual(consistent.state.tasks[key()]?.snapshot, terminal)
        XCTAssertEqual(consistent.state.tasks[key()]?.lastTaskUpdate, at(0))
        XCTAssertEqual(consistent.state.lastSuccess, at(1_500))
        XCTAssertTrue(consistent.newFailureCandidates.isEmpty)

        _ = reducer.apply(disconnected(generation: 2), now: at(1_600))
        _ = reducer.wake(newGeneration: 3, now: at(1_700))
        _ = reducer.apply(connected(generation: 3), now: at(1_800))
        let higherTask = task(state: .failed, revision: 8, title: "更高水位")
        let higher = reducer.apply(baseline(generation: 3, watermark: 22, tasks: [higherTask]), now: at(1_900))
        XCTAssertEqual(higher.state.connection, .online)
        XCTAssertEqual(higher.state.tasks[key()]?.snapshot, higherTask)
        XCTAssertTrue(higher.newFailureCandidates.isEmpty)
        XCTAssertEqual(higher.baselineObservedFailures, [AttemptKey(taskKey: higherTask.key, attemptID: higherTask.attemptID)])
    }

    func test_consistentSameWatermarkBaselineRestoresTimedOutConnection() {
        var reducer = makeReducer()
        let snapshot = task(state: .running, title: "保持")
        _ = reducer.apply(baseline(watermark: 10, tasks: [snapshot]), now: at(0))
        let duplicate = reducer.apply(baseline(watermark: 10, tasks: [snapshot]), now: at(100))
        XCTAssertTrue(duplicate.diagnostics.isEmpty)
        XCTAssertEqual(duplicate.state.connection, .online)
        XCTAssertEqual(duplicate.state.lastSuccess, at(0))
        XCTAssertEqual(duplicate.state.tasks[key()]?.lastTaskUpdate, at(0))

        XCTAssertEqual(reducer.tick(now: at(30_000)).state.connection, .stale)
        XCTAssertTrue(reducer.state.synchronized)
        let confirmed = reducer.apply(baseline(watermark: 10, tasks: [snapshot]), now: at(30_000))
        XCTAssertTrue(confirmed.diagnostics.isEmpty)
        XCTAssertEqual(confirmed.state.connection, .online)
        XCTAssertTrue(confirmed.state.synchronized)
        XCTAssertEqual(confirmed.state.lastSuccess, at(30_000))
        XCTAssertEqual(confirmed.state.tasks[key()]?.snapshot, snapshot)
        XCTAssertEqual(confirmed.state.tasks[key()]?.lastTaskUpdate, at(0))
        XCTAssertTrue(confirmed.newFailureCandidates.isEmpty)
    }

    func test_higherWatermarkBaselinePreservesUnchangedTaskTime() {
        var reducer = makeReducer()
        let kept = task(id: "kept", state: .running, revision: 3, title: "不变")
        let changed = task(id: "changed", state: .running, revision: 1, title: "旧")
        _ = reducer.apply(baseline(watermark: 10, tasks: [kept, changed]), now: at(0))
        let changedNext = task(id: "changed", state: .succeeded, revision: 2, title: "新")
        let higher = reducer.apply(baseline(watermark: 20, tasks: [kept, changedNext]), now: at(5_000))
        XCTAssertEqual(higher.state.connection, .online)
        XCTAssertEqual(higher.state.lastSuccess, at(5_000))
        XCTAssertEqual(higher.state.tasks[kept.key]?.snapshot, kept)
        XCTAssertEqual(higher.state.tasks[kept.key]?.lastTaskUpdate, at(0))
        XCTAssertEqual(higher.state.tasks[changed.key]?.snapshot, changedNext)
        XCTAssertEqual(higher.state.tasks[changed.key]?.lastTaskUpdate, at(5_000))

        let switched = reducer.apply(baseline(epoch: "epoch-2", watermark: 1, tasks: [kept]), now: at(8_000))
        XCTAssertEqual(switched.state.connection, .online)
        XCTAssertEqual(switched.state.tasks[kept.key]?.snapshot, kept)
        XCTAssertEqual(switched.state.tasks[kept.key]?.lastTaskUpdate, at(8_000))
    }

    func test_unseenTaskIDFromIncrementalIsAccepted() {
        var reducer = makeReducer()
        let existing = task(id: "existing", state: .running, title: "已有")
        _ = reducer.apply(baseline(watermark: 4, tasks: [existing]), now: at(0))
        let appeared = task(id: "brand-new", attempt: "attempt-new", state: .failed, title: "新任务")
        let transition = reducer.apply(update(sequence: 5, task: appeared), now: at(1_000))
        XCTAssertEqual(transition.state.connection, .online)
        XCTAssertEqual(transition.state.tasks[appeared.key]?.snapshot, appeared)
        XCTAssertEqual(transition.newFailureCandidates.map(\.snapshot), [appeared])
        XCTAssertEqual(transition.state.tasks[existing.key]?.snapshot, existing)
        XCTAssertEqual(transition.state.tasks[existing.key]?.lastTaskUpdate, at(0))
    }

    func test_sameWatermarkBaselineClearsSourceConflict() {
        var reducer = makeReducer()
        _ = reducer.apply(baseline(watermark: 10, tasks: [task(state: .succeeded, revision: 1, title: "终态")]), now: at(0))
        let conflict = reducer.apply(update(sequence: 11, task: task(state: .running, revision: 2, title: "反向")), now: at(1_000))
        XCTAssertEqual(conflict.state.tasks[key()]?.sourceConflict, true)
        let converged = conflict.state.tasks[key()]!.snapshot
        XCTAssertEqual(converged.state, .unknown)
        let cleared = reducer.apply(baseline(watermark: 11, tasks: [converged]), now: at(2_000))
        XCTAssertTrue(cleared.diagnostics.isEmpty)
        XCTAssertEqual(cleared.state.connection, .online)
        XCTAssertEqual(cleared.state.tasks[key()]?.snapshot, converged)
        XCTAssertEqual(cleared.state.tasks[key()]?.sourceConflict, false)
    }

    func test_wakeWithCurrentGenerationIsInvalidInput() {
        var reducer = makeReducer()
        _ = reducer.apply(baseline(watermark: 3, tasks: [task(state: .running)]), now: at(0))
        let before = reducer.state
        let same = reducer.wake(newGeneration: 1, now: at(50_000))
        XCTAssertEqual(same.diagnostics, [.invalidInput])
        XCTAssertEqual(same.state, before)
        XCTAssertEqual(same.state.connection, .online)
        XCTAssertTrue(same.state.synchronized)
    }

    // MARK: - Additional T2 assertions

    func test_twoSourcesIsolateSameTaskID() {
        var alpha = makeReducer(source: "source-a")
        var beta = makeReducer(source: "source-b")
        let shared = "task-1"
        let alphaTask = task(source: "source-a", id: shared, state: .running, title: "A")
        let betaTask = task(source: "source-b", id: shared, state: .failed, title: "B")
        XCTAssertNotEqual(alphaTask.key, betaTask.key)

        let alphaBase = alpha.apply(baseline(source: "source-a", watermark: 5, tasks: [alphaTask]), now: at(0))
        let betaBase = beta.apply(baseline(source: "source-b", watermark: 5, tasks: [betaTask]), now: at(0))
        XCTAssertTrue(alphaBase.newFailureCandidates.isEmpty)
        XCTAssertTrue(betaBase.newFailureCandidates.isEmpty)
        XCTAssertEqual(betaBase.baselineObservedFailures.count, 1)

        let leaked = alpha.apply(
            update(source: "source-b", sequence: 6, task: task(source: "source-b", id: shared, state: .succeeded, revision: 2)),
            now: at(1)
        )
        XCTAssertEqual(leaked.diagnostics, [.invalidInput])
        XCTAssertEqual(alpha.state.connection, .online)
        XCTAssertEqual(alpha.state.tasks.count, 1)
        XCTAssertEqual(alpha.state.tasks[alphaTask.key]?.snapshot.state, .running)
        XCTAssertEqual(beta.state.tasks[betaTask.key]?.snapshot.state, .failed)

        let own = alpha.apply(
            update(source: "source-a", sequence: 6, task: task(source: "source-a", id: shared, state: .succeeded, revision: 2)),
            now: at(2)
        )
        XCTAssertEqual(own.state.connection, .online)
        XCTAssertEqual(own.state.tasks[alphaTask.key]?.snapshot.state, .succeeded)
        XCTAssertEqual(beta.state.tasks[betaTask.key]?.snapshot.state, .failed)
        XCTAssertEqual(beta.state.connection, .online)
    }

    func test_integerBoundariesDoNotTrap() {
        var edge = makeReducer()
        let maxed = task(attempt: "attempt-a", ordinal: Int64.max, state: .running, revision: Int64.max)
        _ = edge.apply(baseline(watermark: 10, tasks: [maxed]), now: at(0))
        let ignored = edge.apply(
            update(sequence: 11, task: task(
                attempt: "attempt-a", ordinal: Int64.max, state: .failed,
                revision: Int64.max, title: "不应覆盖"
            )),
            now: at(5)
        )
        XCTAssertEqual(ignored.state.connection, .online)
        XCTAssertEqual(ignored.state.tasks[key()]?.snapshot.state, .running)
        XCTAssertEqual(ignored.state.tasks[key()]?.snapshot.revision, Int64.max)
        XCTAssertEqual(ignored.state.tasks[key()]?.snapshot.attemptOrdinal, Int64.max)
        XCTAssertEqual(ignored.state.tasks[key()]?.lastTaskUpdate, at(0))
        XCTAssertTrue(ignored.newFailureCandidates.isEmpty)

        let clash = edge.apply(
            update(sequence: 12, task: task(attempt: "attempt-b", ordinal: Int64.max, state: .succeeded, revision: 1)),
            now: at(6)
        )
        XCTAssertEqual(clash.diagnostics, [.attemptConflict])
        XCTAssertEqual(clash.state.tasks[key()]?.snapshot.attemptID, "attempt-a")
        XCTAssertEqual(clash.state.connection, .stale)

        var topped = makeReducer()
        _ = topped.apply(baseline(watermark: Int64.max, tasks: [task(state: .running)]), now: at(0))
        let replay = topped.apply(heartbeat(sequence: Int64.max), now: at(1))
        XCTAssertTrue(replay.diagnostics.isEmpty)
        XCTAssertEqual(replay.state.connection, .online)
        XCTAssertTrue(replay.state.synchronized)
        XCTAssertEqual(replay.state.tasks[key()]?.snapshot.state, .running)
        XCTAssertEqual(replay.state.lastSuccess, at(0))

        var nearTop = makeReducer()
        _ = nearTop.apply(baseline(watermark: 1, tasks: [task()]), now: at(Int64.max - 10))
        XCTAssertEqual(nearTop.tick(now: at(Int64.max)).state.connection, .online)

        var backwards = makeReducer()
        _ = backwards.apply(baseline(watermark: 1, tasks: [task()]), now: at(100))
        XCTAssertEqual(backwards.tick(now: at(Int64.min)).state.connection, .online)

        var far = makeReducer()
        _ = far.apply(baseline(watermark: 1, tasks: [task()]), now: at(Int64.min))
        XCTAssertEqual(far.tick(now: at(Int64.max)).state.connection, .stale)
    }

    func test_rejectedInputDoesNotPolluteWatermark() {
        var reducer = makeReducer()
        let original = task(state: .running, revision: 1, title: "水位20")
        _ = reducer.apply(baseline(watermark: 20, tasks: [original]), now: at(0))

        let foreign = reducer.apply(
            update(source: "other-source", sequence: 99, task: task(source: "other-source", state: .failed)),
            now: at(1)
        )
        XCTAssertEqual(foreign.diagnostics, [.invalidInput])
        let negative = reducer.apply(update(sequence: -1, task: task(state: .failed, title: "负数")), now: at(2))
        XCTAssertEqual(negative.diagnostics, [.invalidInput])
        let blankEpoch = reducer.apply(heartbeat(epoch: " ", sequence: 21), now: at(3))
        XCTAssertEqual(blankEpoch.diagnostics, [.invalidInput])
        XCTAssertEqual(reducer.state.connection, .online)
        XCTAssertEqual(reducer.state.tasks[key()]?.snapshot, original)
        XCTAssertEqual(reducer.state.lastSuccess, at(0))

        let next = reducer.apply(heartbeat(sequence: 21), now: at(4))
        XCTAssertEqual(next.state.connection, .online)
        XCTAssertEqual(next.state.lastSuccess, at(4))
        XCTAssertEqual(next.state.tasks[key()]?.snapshot, original)

        let conflict = reducer.apply(
            update(sequence: 22, task: task(attempt: "attempt-other", ordinal: 1, state: .failed, revision: 2)),
            now: at(5)
        )
        XCTAssertEqual(conflict.diagnostics, [.attemptConflict])
        XCTAssertEqual(conflict.state.connection, .stale)
        XCTAssertEqual(conflict.state.tasks[key()]?.snapshot, original)

        let recovery = task(state: .succeeded, revision: 5, title: "水位仍是21")
        let restored = reducer.apply(baseline(watermark: 22, tasks: [recovery]), now: at(6))
        XCTAssertEqual(restored.state.connection, .online)
        XCTAssertEqual(restored.state.tasks[key()]?.snapshot, recovery)
        XCTAssertTrue(restored.newFailureCandidates.isEmpty)
    }
}
