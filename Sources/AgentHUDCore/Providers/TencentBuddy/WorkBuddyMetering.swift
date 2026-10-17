import AgentHUDSupport
import Foundation

/// What WorkBuddy's own database (`~/.workbuddy/workbuddy.db`) holds of a pass: the names the app keeps for its sessions
/// and the metering it records for them, both beside the `projects` folder the transcripts lie under. One connection
/// serves both reads.
extension WorkBuddySessions {
    /// The app's own database, which sits beside the `projects` folder a transcript lies under: the one connection a
    /// pass needs for both the session names it keeps there and the metering it records there.
    static func database(for sessions: [ProviderSession]) -> ReadOnlySQLite? {
        guard let path = sessions.lazy.compactMap(\.path).first,
              let projects = sequence(first: URL(fileURLWithPath: path).deletingLastPathComponent(), next: {
                  $0.pathComponents.count > 1 ? $0.deletingLastPathComponent() : nil
              }).first(where: { $0.lastPathComponent == "projects" }) else { return nil }
        return try? ReadOnlySQLite(projects.deletingLastPathComponent().appendingPathComponent("workbuddy.db"))
    }

    /// The app's own name for each session, from the record it keeps beside `projects`, where a rename from its sidebar
    /// goes: the name the user gave, else the generated one. Read on every pass, so a rename shows without reparsing
    /// transcripts. Sessions the record does not hold keep the name their transcript gave them.
    static func named(_ sessions: [ProviderSession], database: ReadOnlySQLite) -> [ProviderSession] {
        let prefix = "\(AdditionalSource.workbuddy.rawValue):"
        let ids = sessions.map { String($0.id.dropFirst(prefix.count)) }
        guard let list = try? JSONSerialization.data(withJSONObject: ids), let json = String(data: list, encoding: .utf8) else { return sessions }
        var titles: [String: String] = [:]
        try? database.rows("SELECT id, custom_title, title FROM sessions WHERE id IN (SELECT value FROM json_each(?))", strings: [json]) { row in
            if let id = ReadOnlySQLite.text(row, 0),
               let title = SessionTitle.named(ReadOnlySQLite.text(row, 1)) ?? SessionTitle.named(ReadOnlySQLite.text(row, 2)) { titles[prefix + id] = title }
        }
        return sessions.map { var item = $0; if let title = titles[item.id] { item.title = title }; return item }
    }

    /// What the app's own metering (`session_usage`) charged each session this pass lists: the credits its per-model
    /// entries add up to, attributed to the one model every listed session carrying an entry called, with the rest
    /// reported as unattributed rather than guessed. Its `used`/`size` are the context size and limit it metered, in
    /// tokens. `models` is each session's models as its transcript logged them, and `database` the connection the same
    /// pass read the session names with.
    static func credits(sessions: [ProviderSession], models: [String: Set<String>], database: ReadOnlySQLite) -> [String: SessionCredits] {
        let prefix = "\(AdditionalSource.workbuddy.rawValue):"
        // Only the sessions this pass lists are read: the metering table holds every session the app ever recorded,
        // and a pass pays for the rows it reports rather than for the whole table.
        let ids = sessions.map { String($0.id.dropFirst(prefix.count)) }
        guard !ids.isEmpty, let list = try? JSONSerialization.data(withJSONObject: ids),
              let idList = String(data: list, encoding: .utf8) else { return [:] }
        // The metering's entries, keyed as the transcripts key their sessions.
        var entries: [String: (used: Int, size: Int, credits: [String: Double])] = [:]
        do {
            try database.rows("SELECT session_id, used, size, credit_json FROM session_usage WHERE credit_json IS NOT NULL AND credit_json != '' AND session_id IN (SELECT value FROM json_each(?))",
                              strings: [idList]) { row in
                guard let raw = ReadOnlySQLite.text(row, 0), let used = ReadOnlySQLite.text(row, 1).flatMap(Int.init),
                      let size = ReadOnlySQLite.text(row, 2).flatMap(Int.init), let json = ReadOnlySQLite.text(row, 3),
                      let credits = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double] else { return }
                entries[prefix + raw] = (used, size, credits)
            }
        } catch { return [:] }
        guard !entries.isEmpty else { return [:] }
        let keyed = entryModels(entries: entries.mapValues(\.credits), models: models)
        var result: [String: SessionCredits] = [:]
        for (id, record) in entries {
            var byModel: [String: Double] = [:], unattributed = 0.0
            for (key, value) in record.credits {
                if let model = keyed[key] { byModel[model, default: 0] += value } else { unattributed += value }
            }
            result[id] = SessionCredits(total: record.credits.values.reduce(0, +), unattributed: unattributed,
                                        byModel: byModel.mapKeys { "\(AdditionalSource.workbuddy.rawValue)-model:\($0)" },
                                        used: record.used, size: record.size)
        }
        return result
    }

    /// Names the model each metering entry charges, when one model can be the only one behind it: the model every
    /// session the entry appears in called, once those sessions are intersected. Entries whose sessions disagree,
    /// and entries no session's models explain, are left unnamed rather than guessed. Both dictionaries are keyed
    /// as the transcripts key their sessions.
    static func entryModels(entries: [String: [String: Double]], models: [String: Set<String>]) -> [String: String] {
        var keyed: [String: String] = [:]
        // The entry keys are the metering's own ids; each is looked for in every session's entries.
        for key in Set(entries.values.flatMap(\.keys)) {
            var shared: Set<String>? = nil
            for (id, record) in entries where record[key] != nil {
                guard let called = models[id] else { continue }
                shared = shared == nil ? called : shared!.intersection(called)
                if shared?.isEmpty == true { break }
            }
            if let only = shared, only.count == 1 { keyed[key] = only.first! }
        }
        return keyed
    }
}

private extension Dictionary where Key == String {
    /// A map with its keys rewritten; identical keys keep their first value in iteration order, like `mapValues` order.
    func mapKeys(_ transform: (Key) -> String) -> [Key: Value] {
        var mapped: [Key: Value] = [:]
        for (key, value) in self { mapped[transform(key)] = value }
        return mapped
    }
}
