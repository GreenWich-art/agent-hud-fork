import AgentHUDSupport
import Foundation

/// A WorkBuddy ceiling: a 429 a transcript logged, read as a quota window of its own. WorkBuddy publishes no quota
/// endpoint for the plans behind the models its transcripts reach, so a logged reset is the only reading such a row
/// has.
enum WorkBuddyCeilings {
    /// How the rows name each window, in the vendor's own words where the transcripts quote them
    /// (`5 小时的使用上限`), else in the words the other plans' clients read; and each window's length, which the message
    /// itself does not carry. The month's length is a guess at a calendar month, not a vendor's number: a monthly
    /// ceiling's row simply retires at its reset time, and only the pace of a forecast reads the length.
    static let durations: [String: TimeInterval] = ["5h": 5 * 3600, "day": 86400, "week": 7 * 86400, "month": 30 * 86400]

    static func label(_ window: String) -> String {
        switch window {
        case "5h": L10n.text("5 小时使用上限", "5-hour usage limit")
        case "day": L10n.text("每日使用上限", "Daily usage limit")
        case "week": L10n.text("每周使用上限", "Weekly usage limit")
        default: L10n.text("每月使用上限", "Monthly usage limit")
        }
    }

    /// The short name of a window, from the length above: `WindowNames` words the periods the vendor's message names.
    static func short(_ window: String) -> String {
        WindowNames.Period(seconds: durations[window]).map(\.shortName) ?? label(window)
    }

    /// This pass's ceilings and the ones an earlier pass saw, one entry per model and window, the newest reading of
    /// each. A ceiling whose reset has passed is dropped, so what an earlier pass saw stops being remembered at its
    /// reset rather than at the end of the retention period.
    static func hits(_ logged: [ProviderLimitHit], remembered: [ProviderLimitHit], now: Date) -> [ProviderLimitHit] {
        var merged: [String: ProviderLimitHit] = [:]
        for hit in remembered.filter({ $0.reset > now }) + logged {
            let key = "\(hit.model):\(hit.window)"
            if let kept = merged[key], kept.observedAt >= hit.observedAt { continue }
            merged[key] = hit
        }
        return merged.values.sorted { ($0.model, $0.window) < ($1.model, $1.window) }
    }

    /// The plan every entry of the app's own model list goes through, by the model its transcripts log: an entry whose
    /// URL is a plan's own coding endpoint carries that plan's key, and the pool its readings are kept under is derived
    /// the same way the credential discovery derives it. An entry that calls anybody else is no plan of the app's, and
    /// a value that names WorkBuddy's own folder is not read here at all.
    static func plans(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: BillingPool] {
        let file = home.appendingPathComponent(".workbuddy/models.json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1024 * 1024,
              let data = try? Data(contentsOf: file), let json = try? ProviderJSON.read(data),
              let entries = json.arrayValue else { return [:] }
        var plans: [String: BillingPool] = [:]
        for entry in entries {
            let key = (entry["apiKey"].stringValue ?? "").trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty,
                  let service = OpenAgentCredentials.service(provider: entry["vendor"].stringValue ?? "", baseURL: entry["url"].stringValue)
            else { continue }
            let pool = OpenAgentCredentials.credential(service, token: key, client: "WorkBuddy").pool
            for model in [entry["id"].stringValue, entry["name"].stringValue].compactMap({ $0 }) where !model.isEmpty { plans[model] = pool }
        }
        return plans
    }

    /// The rows the ceilings still ahead make, under the account they belong to, and the raw window ids they carry,
    /// which is what that account's inventory lists. `named` writes a model as the surface it is shown on does, and
    /// `plan` gives the plan a model goes through, whose own quota reading takes the place of the ceiling's row.
    static func windows(_ hits: [ProviderLimitHit], account: ProviderAccount, named: (String) -> String,
                        plan: (String) -> BillingPool?) -> (windows: [ProviderQuota.Window], ids: Set<String>, pools: [String: BillingPool]) {
        let latest = Dictionary(hits.map { ($0.model, $0) }, uniquingKeysWith: { max($0.observedAt, $1.observedAt) == $0.observedAt ? $0 : $1 })
        var windows: [ProviderQuota.Window] = [], ids: Set<String> = [], pools: [String: BillingPool] = [:]
        for hit in latest.values.sorted(by: { $0.model < $1.model }) {
            let raw = "limit:\(hit.model):\(hit.window)", id = account.windowID(raw)
            // The model's own name leads, because two models can sit at their ceilings at once and the window's period
            // alone would not tell their rows apart.
            let model = named(hit.model)
            windows.append(.init(id: id, label: "\(model) · \(label(hit.window))",
                                 remaining: 0, reset: hit.reset, duration: durations[hit.window],
                                 shortLabel: "\(model) · \(short(hit.window))", observedAt: hit.observedAt))
            ids.insert(raw)
            if let pool = plan(hit.model) { pools[id] = pool }
        }
        return (windows, ids, pools)
    }
}

/// Reading the ceilings a WorkBuddy transcript's 429 answers logged.
extension TencentBuddySessions {
    /// One 429 ceiling a line logged, nil for anything else: only an incomplete answer that carries a 429 error reports
    /// one. The message names the window in the vendor's words and the reset in the vendor's own zone, which its servers
    /// report in (`DateParsing.serverWallClock`). The model is the session's latest successful one, because the failed
    /// call itself records none; a 429 before any success names nothing.
    static func limitHit(_ json: ProviderJSON, session: String, date: Date?, lastModels: [String: String]) -> ProviderLimitHit? {
        guard let date, json["status"].stringValue == "incomplete",
              providerErrorStatus(json["providerData"]["error"]) == 429,
              let message = nonEmpty(json["providerData"]["error"]["message"]),
              let window = ProviderLimitHit.windows.first(where: { message.contains(phrases[$0]!) }),
              let model = lastModels[session],
              let reset = resetDate(message) else { return nil }
        return ProviderLimitHit(model: model, window: window, reset: reset, observedAt: date)
    }

    /// How the vendor's words name each window its 429s report. A window whose words are missing is never matched.
    static let phrases: [String: String] = ["5h": "5 小时", "day": "每日", "week": "每周", "month": "每月"]

    /// The reset time in the vendor's message, a wall-clock time in the vendor's own zone (`2026-10-14 01:06:03 重置`).
    private static func resetDate(_ message: String) -> Date? {
        guard let range = message.range(of: #"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) 重置"#, options: .regularExpression) else { return nil }
        return DateParsing.serverWallClock(String(message[range].dropLast(3)))
    }
}
