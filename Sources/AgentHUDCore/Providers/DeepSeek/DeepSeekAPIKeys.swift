import Foundation

/// The DeepSeek API keys WorkBuddy keeps in its own model list, for the official balance read when the Harness
/// is not the credential's home — its app deleted, or never installed. A key counts when its model entry calls
/// DeepSeek's own endpoint; a proxy or another vendor's entry does not, mirroring how the same file is read for
/// every other client's stored credentials.
enum DeepSeekAPIKeys {
    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let file = home.appendingPathComponent(".workbuddy/models.json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1024 * 1024,
              let data = try? Data(contentsOf: file), let json = try? ProviderJSON.read(data),
              let entries = json.arrayValue else { return [] }
        var keys: [String] = [], seen: Set<String> = []
        for entry in entries {
            guard let address = entry["url"].stringValue, let url = URL(string: address), url.scheme == "https",
                  url.host?.lowercased() == "api.deepseek.com", url.user == nil, url.password == nil,
                  let key = entry["apiKey"].stringValue, !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            keys.append(key)
        }
        return keys
    }
}
