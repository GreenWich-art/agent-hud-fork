import XCTest
@testable import AgentHUDCore

@MainActor
final class WorkBuddyApprovalObserverTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-approvals-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A line of the engine's audit log, shaped as its writer shapes it.
    private func line(_ event: String, toolCall: String = "call-1", session: String = "session-1",
                      at milliseconds: Double) -> String {
        """
        {"sessionId":"\(session)","requestId":"request","toolCallId":"\(toolCall)","category":"file-safety",\
        "eventType":"\(event)","decision":"info","messageKey":"key","timestamp":\(milliseconds)}
        """
    }

    private func write(_ lines: String..., spool: String = "audit-spool-48693-2026-10-15.jsonl") {
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("spool"), withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("spool/\(spool)")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try? handle.close()
    }

    private func makeObserver(now: Date = Date(timeIntervalSince1970: 10_000))
        -> (observer: WorkBuddyApprovalObserver, queue: PermissionRequests) {
        let queue = PermissionRequests()
        let observer = WorkBuddyApprovalObserver(requests: queue)
        let folder = self.folder!
        observer.directory = { folder }
        observer.clock = { now }
        observer.read = { url, offset in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
            defer { try? handle.close() }
            _ = try? handle.seek(toOffset: UInt64(offset))
            return (try? handle.readToEnd()) ?? Data()
        }
        return (observer, queue)
    }

    private func seconds(_ value: Double) -> Double { value * 1000 }

    func testAnAskWaitsUntilItsSettlementArrives() {
        let (observer, queue) = makeObserver()
        let since = Date(timeIntervalSince1970: 0)
        write(line("file-safety.needs-approval", at: seconds(9_990)))
        observer.poll(since: since)
        XCTAssertFalse(queue.waitingSessions.isEmpty, "an unanswered ask reports its session as waiting")
        write(line("file-safety.approved", at: seconds(9_995)))
        observer.poll(since: since)
        XCTAssertTrue(queue.waitingSessions.isEmpty, "the settlement takes the session out of the wait")
    }

    func testTheSessionCarriesTheClientsOwnPrefix() {
        let (observer, queue) = makeObserver()
        write(line("file-safety.needs-approval", session: "6e474468", at: seconds(9_990)))
        observer.poll(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(Array(queue.waitingSessions.keys), ["workbuddy:6e474468"])
    }

    func testAnExpiryOldAskNoLongerCounts() {
        // The clock sits past `expiry` after the ask: the wait has aged out, dialog or not.
        let (observer, queue) = makeObserver(now: Date(timeIntervalSince1970: 10_000 + WorkBuddyApprovalObserver.expiry + 1))
        write(line("file-safety.needs-approval", at: seconds(10_000 - WorkBuddyApprovalObserver.expiry - 2)))
        observer.poll(since: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(queue.waitingSessions.isEmpty)
    }

    func testAReaskedCallWaitsAgain() {
        let (observer, queue) = makeObserver()
        let since = Date(timeIntervalSince1970: 0)
        write(line("file-safety.needs-approval", at: seconds(9_900)),
              line("file-safety.approved", at: seconds(9_910)))
        observer.poll(since: since)
        XCTAssertTrue(queue.waitingSessions.isEmpty)
        write(line("file-safety.needs-approval", at: seconds(9_990)))
        observer.poll(since: since)
        XCTAssertFalse(queue.waitingSessions.isEmpty, "the same tool call asked again waits again")
    }

    func testTheFirstPassSeedsFromHistoryWithoutReportingAncientAsks() {
        // An ask older than `history` is the log's own beginning, not a wait the user still owes an answer.
        let (observer, queue) = makeObserver()
        write(line("file-safety.needs-approval", at: seconds(1_000)),
              line("file-safety.needs-approval", toolCall: "call-2", at: seconds(9_990)))
        observer.poll(since: Date(timeIntervalSince1970: 10_000 - WorkBuddyApprovalObserver.history))
        XCTAssertEqual(Array(queue.waitingSessions.keys), ["workbuddy:session-1"], "only the fresh ask waits")
    }

    func testEventsTheEngineRecordsWithoutAskingAreIgnored() {
        let (observer, queue) = makeObserver()
        write(line("command-safety.sandbox-executed", at: seconds(9_990)),
              line("file-safety.allow-listed", at: seconds(9_991)),
              line("file-safety.auto-approved", at: seconds(9_992)))
        observer.poll(since: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(queue.waitingSessions.isEmpty)
    }

    func testASandboxEscalationWaitsUntilTheUserAnswers() {
        let (observer, queue) = makeObserver()
        let since = Date(timeIntervalSince1970: 0)
        write(line("command-safety.pre-exec-bypass-requested", at: seconds(9_990)))
        observer.poll(since: since)
        XCTAssertFalse(queue.waitingSessions.isEmpty, "an escalation awaiting its user reports its session as waiting")
        write(line("command-safety.pre-exec-bypass-approved", at: seconds(9_995)))
        observer.poll(since: since)
        XCTAssertTrue(queue.waitingSessions.isEmpty, "the approval takes the session out of the wait")
    }

    func testTheDatedLogIsReadBesideTheSpools() {
        let (observer, queue) = makeObserver()
        // A spool already folded: its ask lives only in the dated log.
        try? line("file-safety.needs-approval", session: "from-dated-log", at: seconds(9_990)).write(
            to: folder.appendingPathComponent(WorkBuddyApprovalObserver.datedName(for: Date())), atomically: true, encoding: .utf8)
        write(line("file-safety.needs-approval", toolCall: "call-2", session: "from-spool", at: seconds(9_995)))
        observer.poll(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(queue.waitingSessions.count, 2, "both files' sessions wait")
    }

    func testEachPassReadsOnlyWhatWasAppended() {
        let (observer, queue) = makeObserver()
        write(line("file-safety.needs-approval", session: "first", at: seconds(9_990)))
        let since = Date(timeIntervalSince1970: 0)
        observer.poll(since: since)
        XCTAssertEqual(queue.waitingSessions.count, 1)
        // An unchanged file is not so much as opened again.
        let seen = Seen()
        let plain = observer.read
        observer.read = { url, offset in seen.note(offset); return plain(url, offset) }
        observer.poll(since: since)
        XCTAssertTrue(seen.offsets.isEmpty, "an unchanged file is not opened")
        // A file that grew is read from where the last pass stopped, and the appended ask waits with the first.
        let grown = (try? FileManager.default.attributesOfItem(
            atPath: folder.appendingPathComponent("spool/audit-spool-48693-2026-10-15.jsonl").path))?[.size] as? Int
        write(line("file-safety.needs-approval", toolCall: "call-2", session: "second", at: seconds(9_995)))
        observer.poll(since: since)
        XCTAssertEqual(seen.offsets.count, 1, "only the grown spool is opened")
        XCTAssertEqual(seen.offsets.first, grown, "the read starts where the last pass stopped")
        XCTAssertEqual(queue.waitingSessions.count, 2, "the appended ask waits with the first")
    }
}

/// Offsets a @Sendable closure was handed.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    var offsets: [Int] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
    func note(_ value: Int) {
        lock.lock(); values.append(value); lock.unlock()
    }
}
