import Foundation
import Observation
import BloomCore

@MainActor
@Observable
final class TranscriptHistory {
    var checkpoints: [TurnCheckpoint] = []
    private(set) var isCapturing = false
    var isFinalisingTurn = false
    var hasActiveTurn: Bool { active != nil || starting != nil }
    @ObservationIgnored private var active: TurnCheckpoint?
    /// The starting snapshot while it is still being taken. See `begin`.
    @ObservationIgnored private var starting: Task<Void, Never>?
    /// Where a failure is said. A toast rather than a strip above the composer: the strip sat
    /// under "Running Bash" while the turn carried on, and read as part of the work in progress
    /// rather than as a note that this turn's file list would be missing.
    @ObservationIgnored var report: (String) -> Void = { _ in }
    /// Where a summary read from git is kept. See `files(_:cwd:)`.
    @ObservationIgnored private var store: Store?

    func load(store: Store, sessionID: SessionID) async {
        self.store = store
        do {
            checkpoints = try await store.turnCheckpoints(sessionID: sessionID)
        } catch { report("Could not load this conversation's turn history. \(error.readableMessage)") }
    }

    /// Starts taking the turn's starting snapshot and returns at once, so the message goes to the
    /// agent while git works.
    ///
    /// This used to be awaited in front of the send, and the snapshot is about a dozen git
    /// processes including a full `git add -A` into a scratch index. Measured on a 31,000 file
    /// worktree: 430 ms per message warm and 800 ms cold, every one of them spent before the
    /// prompt reached the CLI, which is the delay a terminal does not have. Nothing reads `before`
    /// except the turn's changed file list, and an agent needs a model round trip, seconds rather
    /// than milliseconds, before its first tool can write anything. So the race this opens costs at
    /// worst a file missing from that list, never a file. `finish` waits for the snapshot, so a
    /// turn that ends before it is taken still closes the checkpoint it started.
    func begin(delivery: Delivery, store: Store, cwd: String) {
        isCapturing = true
        starting = Task { [weak self] in
            var checkpoint: TurnCheckpoint?
            do {
                guard let saved = try await store.delivery(id: delivery.id), let seq = saved.deliveredSeq else {
                    throw SnapshotFailure("The sent message has no stored sequence.")
                }
                checkpoint = try await TurnCheckpointStore(store: store).begin(
                    sessionID: delivery.targetSessionID, cwd: cwd, startSeq: seq
                )
            } catch { self?.report("This turn's file changes will not be listed. \(error.readableMessage)") }
            guard let self else { return }
            active = checkpoint
            starting = nil
            isCapturing = false
        }
    }

    func finish(store: Store, cwd: String, endSeq: Int, captureFiles: Bool = true) async {
        if let starting { await starting.value }
        guard let checkpoint = active else { return }
        active = nil
        isCapturing = true
        defer { isCapturing = false }
        do {
            if !captureFiles {
                var closed = checkpoint
                closed.endSeq = max(endSeq, checkpoint.startSeq)
                try await store.saveTurnCheckpoint(closed)
                merge(try await store.turnCheckpoints(sessionID: checkpoint.sessionID))
                report("This turn's file changes will not be listed. Another turn had already started before it finished.")
                return
            }
            _ = try await TurnCheckpointStore(store: store).finish(
                id: checkpoint.id, sessionID: checkpoint.sessionID, cwd: cwd, endSeq: max(endSeq, checkpoint.startSeq)
            )
            merge(try await store.turnCheckpoints(sessionID: checkpoint.sessionID))
        } catch { report("This turn's file changes will not be listed. \(error.readableMessage)") }
    }

    private func merge(_ records: [TurnCheckpoint]) {
        let previous = Dictionary(checkpoints.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        checkpoints = records.map { record in
            var merged = record
            if merged.after == nil, let completed = previous[record.id], completed.after != nil {
                merged.after = completed.after
                merged.endSeq = completed.endSeq
            }
            return merged
        }
    }

    /// Read from git once, then kept on the checkpoint. See `TurnCheckpoint.files`.
    func files(_ checkpoint: TurnCheckpoint, cwd: String) async throws -> [TurnFile] {
        guard let after = checkpoint.after else { throw SnapshotFailure("This turn has no completed snapshot.") }
        let files = try await Git.snapshotFiles(from: checkpoint.before, to: after, in: cwd).map(TurnFile.init)
        guard let index = checkpoints.firstIndex(where: { $0.id == checkpoint.id }) else { return files }
        checkpoints[index].files = files
        let summarised = checkpoints[index]
        // A lost write costs one more git read on the next open, nothing the reader can see.
        try? await store?.saveTurnCheckpoint(summarised)
        return files
    }
}
