import Foundation

/// Follows the approvals WorkBuddy asks about in its own dialog, which no permission hook carries: the engine's
/// sandbox, file and network prompts run through its in-app channel. The engine appends each of those — asked and
/// answered — synchronously to its security audit spool, so this observer reads what it wrote and reports the
/// sessions with an unanswered ask.
///
/// The engine stays the authority: answering happens in WorkBuddy's own dialog, and an ask old beyond `expiry` no
/// longer counts as waiting, whatever closed it.
@MainActor
public final class WorkBuddyApprovalObserver {
    private let requests: PermissionRequests
    private var task: Task<Void, Never>?
    /// The audit entries read so far: every ask and every answer, keyed by tool call — the id an ask and its
    /// settlement share. Newest wins, the later pass having read the later event.
    private var asks: [String: (session: String, at: Date)] = [:]
    private var answers: [String: Date] = [:]
    /// How far into each file the last pass read, by path: only the lines appended since are read again.
    private var offsets: [String: Int] = [:]
    /// How far back the first pass reads, so a restart does not wait for the engine's next ask.
    static let history: TimeInterval = 1800
    /// An ask older than this stops counting as waiting. The engine's own dialog stays up, but a HUD that reads
    /// only the audit log cannot tell a dialog the user walked away from for good, and a glow that stays yellow
    /// for hours says nothing.
    static let expiry: TimeInterval = 600

    /// Where the audit log lives; the tests point this at a folder of their own.
    var directory: @Sendable () -> URL = { WorkBuddyApprovalObserver.defaultDirectory() }
    var clock: @Sendable () -> Date = { Date() }
    var read: @Sendable (URL, Int) -> Data = { url, offset in
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        _ = try? handle.seek(toOffset: UInt64(offset))
        return (try? handle.readToEnd()) ?? Data()
    }
    /// The file's whole size, or nothing when it does not exist. A read that returns nothing only means the last
    /// pass reached the end; a smaller size than that is what says the file was folded away and begun again.
    var length: @Sendable (URL) -> Int? = { url in
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    public init() {
        requests = .shared
    }

    init(requests: PermissionRequests) {
        self.requests = requests
    }

    /// The engine keeps its audit under `~/.workbuddy/audit-log`: a dated file the housekeeper folds the spools
    /// into, and the spools themselves, which hold everything written since the last fold.
    nonisolated public static func defaultDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".workbuddy/audit-log")
    }

    /// How often the audit spool is read while the app runs. An ask reaches the glow within this much of the
    /// engine writing it.
    nonisolated static let pollInterval: TimeInterval = 1

    public func setEnabled(_ enabled: Bool) {
        guard enabled else { return stop() }
        guard task == nil else { return }
        task = Task { [weak self] in
            var startedAt: Date?
            while !Task.isCancelled {
                guard let self else { return }
                self.poll(since: startedAt ?? self.clock().addingTimeInterval(-Self.history))
                startedAt = startedAt ?? self.clock()
                do { try await Task.sleep(for: .seconds(Self.pollInterval)) }
                catch { return }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        asks.removeAll()
        answers.removeAll()
        offsets.removeAll()
        requests.updateWaitingSessions([], source: .workbuddy)
    }

    /// Reads the audit entries appended since `since` and reports the sessions with an unanswered ask. The first
    /// pass seeds the tables from `history` back: an ask that old with no answer on record is the log's own
    /// beginning, not a wait.
    func poll(since: Date, report: Bool = true) {
        let now = clock()
        var newEntries: [Entry] = []
        for file in Self.files(in: directory()) {
            let path = file.path
            // A missing file, or one smaller than the last pass read of it, was folded away and begun again:
            // the next pass reads it whole.
            guard let size = length(file) else {
                offsets[path] = nil
                continue
            }
            if let reached = offsets[path], size < reached { offsets[path] = nil }
            // Nothing was appended since the last pass: nothing to read, not even an open.
            guard (offsets[path] ?? 0) < size else { continue }
            let data = read(file, offsets[path] ?? 0)
            offsets[path] = (offsets[path] ?? 0) + data.count
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                if let entry = Self.entry(String(line)), entry.at > since { newEntries.append(entry) }
            }
        }
        for entry in newEntries {
            switch entry.kind {
            case .ask: asks[entry.toolCall] = (entry.session, entry.at)
            case .answer: answers[entry.toolCall] = entry.at
            }
        }
        // A fresh ask whose settlement is older than itself — the same call asked again — waits again.
        var waiting: [String: Date] = [:]
        for (toolCall, ask) in asks {
            guard ask.at > (answers[toolCall] ?? .distantPast), now.timeIntervalSince(ask.at) < Self.expiry else { continue }
            waiting[ask.session] = min(waiting[ask.session] ?? ask.at, ask.at)
        }
        guard report else { return }
        requests.updateWaitingSessions(Set(waiting.keys), source: .workbuddy, now: now)
    }

    // MARK: Reading

    struct Entry {
        enum Kind { case ask, answer }
        let kind: Kind
        /// The session the HUD knows: WorkBuddy's sessions carry the client's own prefix.
        let session: String
        let toolCall: String
        let at: Date
    }

    /// The event types the engine writes for an approval asked about in its own dialog, and the ones that settle
    /// it. An event's own fields name its session and tool call; the pairing key is the tool call. The file and
    /// network asks come from their own gates; the command-safety ones from the sandbox escalation dialog, whose
    /// ask is written before the engine awaits the user's answer.
    static let askEvents: Set<String> = ["file-safety.needs-approval", "file-safety.bulk-delete.needs-approval",
                                         "sensitive-protection.detected", "file-safety.ask-matched", "network.ask-matched",
                                         "command-safety.pre-exec-bypass-requested", "command-safety.ask-matched"]
    static let settlementEvents: Set<String> = ["file-safety.approved", "file-safety.bulk-delete.approved",
                                                "file-safety.auto-approved", "file-safety.rejected",
                                                "file-safety.auto-rejected", "file-safety.deny-matched",
                                                "sensitive-protection.approval-resolved",
                                                "sensitive-protection.protection-applied",
                                                "network.approved", "network.rejected",
                                                "command-safety.pre-exec-bypass-approved",
                                                "command-safety.pre-exec-bypass-rejected",
                                                "command-safety.auto-approved"]

    /// The dated log of today and the spools, oldest order irrelevant: each is read by its own offset.
    static func files(in directory: URL) -> [URL] {
        var result = [directory.appendingPathComponent(Self.datedName(for: Date()))]
        if let spools = try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("spool"),
                                                                     includingPropertiesForKeys: nil) {
            result += spools.filter { $0.lastPathComponent.hasPrefix("audit-spool-") && $0.pathExtension == "jsonl" }
        }
        return result
    }

    /// Today's dated log file: `YYYY-MM-DD.jsonl` beside the spools.
    static func datedName(for date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.jsonl", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func entry(_ line: String) -> Entry? {
        guard let data = line.data(using: .utf8), let json = try? ProviderJSON.read(data),
              let event = json["eventType"].stringValue,
              let toolCall = json["toolCallId"].stringValue, !toolCall.isEmpty,
              let session = json["sessionId"].stringValue, !session.isEmpty,
              let milliseconds = json["timestamp"].numberValue else { return nil }
        let kind: Entry.Kind
        if Self.askEvents.contains(event) { kind = .ask }
        else if Self.settlementEvents.contains(event) { kind = .answer }
        else { return nil }
        return Entry(kind: kind, session: PermissionHooks.Source.workbuddy.sessionID(session),
                     toolCall: toolCall, at: Date(timeIntervalSince1970: milliseconds / 1000))
    }
}
