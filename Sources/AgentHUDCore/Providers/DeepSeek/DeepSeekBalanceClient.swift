import Foundation

public struct DeepSeekBalanceClient: Sendable {
    public let directory: URL
    /// The transport the key's read goes through; the tests point it at an answer of their own.
    var http = ProviderHTTP()

    public init(directory: URL) { self.directory = directory }

    public func fetch() async throws -> DeepSeekBalance {
        let directory = directory
        return try await Task.detached(priority: .utility) {
            // Reuse Harness's actual YAML parser. Secrets stay inside the short-lived helper process.
            let data = try await DeepSeekNode.run(script: Self.script,
                                                 arguments: [directory.path, DeepSeekCredentialLocator.module()?.path ?? ""],
                                                 environment: ProcessInfo.processInfo.environment.filter { !["NODE_OPTIONS", "NODE_PATH"].contains($0.key) })
            if let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any], let error = reply["error"] as? String {
                let message: String
                switch error {
                case "missing-key": message = L10n.text("请在 Harness 中配置 DeepSeek API Key", "Configure a DeepSeek API key in Harness")
                case "credentials": message = L10n.text("无法读取 Harness 的 DeepSeek 凭据", "Cannot read the DeepSeek credential from Harness")
                case "custom-endpoint": message = L10n.text("自定义 API 地址不支持官方余额查询", "Official balance is unavailable for a custom API endpoint")
                case "http-401", "http-403": message = L10n.text("DeepSeek API Key 无效或无权读取余额", "DeepSeek API key cannot read the balance")
                default: message = L10n.text("DeepSeek 余额读取失败，请检查网络后重试", "Cannot read DeepSeek balance; check the connection and retry")
                }
                throw UsageProviderError(message)
            }
            return try JSONDecoder().decode(DeepSeekBalance.self, from: data)
        }.value
    }

    private static let script = #"""
    const fs = require('node:fs'), path = require('node:path');
    const {pathToFileURL} = require('node:url');
    const {createRequire} = require('node:module');
    async function main() {
      const [home, modulePath] = process.argv.slice(1);
      let key, base;
      try {
        let settings = {}, credentials;
        if (modulePath) {
          const requireHarness = createRequire(modulePath);
          const settingsPath = path.join(home, 'settings.yaml');
          if (fs.existsSync(settingsPath)) settings = requireHarness('yaml').parse(fs.readFileSync(settingsPath, 'utf8')) || {};
          const file = path.join(home, '.credentials.yaml');
          if (fs.existsSync(file)) {
            const {parseCredentialsDocument} = await import(pathToFileURL(modulePath).href);
            credentials = parseCredentialsDocument(fs.readFileSync(file, 'utf8'), file);
          }
        } else if (fs.existsSync(path.join(home, '.credentials.yaml'))) return {error: 'credentials'};
        const config = settings['llm-deepseek'] || {};
        const ref = config.apiKeyEnv || 'DEEPSEEK_API_KEY';
        key = process.env[ref] || credentials?.refs.get(ref);
        base = new URL(config.baseURL || process.env.DEEPSEEK_BASE_URL || 'https://api.deepseek.com');
      } catch { return {error: 'credentials'}; }
      if (base.origin !== 'https://api.deepseek.com' || base.username || base.password) return {error: 'custom-endpoint'};
      if (!key) return {error: 'missing-key'};
      try {
        const response = await fetch('https://api.deepseek.com/user/balance', {
          headers: {Authorization: 'Bearer ' + key}, redirect: 'error', signal: AbortSignal.timeout(15000)
        });
        return response.ok ? await response.json() : {error: 'http-' + response.status};
      } catch { return {error: 'network'}; }
    }
    main().then(value => console.log(JSON.stringify(value))).catch(() => {
      console.log(JSON.stringify({error: 'credentials'}));
    });
    """#

    /// The official balance read with an API key the user keeps in WorkBuddy's model list, for when the Harness
    /// is not the credential's home — its app deleted, or never installed. The same endpoint answers either
    /// credential, so this read needs no helper process and no Harness install.
    public func fetch(apiKey key: String) async throws -> DeepSeekBalance {
        do {
            let data = try await http.data(Self.balanceURL, headers: ["Authorization": "Bearer \(key)"])
            return try JSONDecoder().decode(DeepSeekBalance.self, from: data)
        } catch let error as ProviderHTTPError {
            throw UsageProviderError(error.isAuthentication
                ? L10n.text("DeepSeek API Key 无效或无权读取余额", "DeepSeek API key cannot read the balance")
                : L10n.text("DeepSeek 余额服务返回 HTTP \(error.status)", "DeepSeek balance service returned HTTP \(error.status)"))
        } catch {
            throw UsageProviderError(L10n.text("DeepSeek 余额读取失败，请检查网络后重试", "Cannot read DeepSeek balance; check the connection and retry"))
        }
    }

    /// The balance as the app can read it for this account: the API key WorkBuddy keeps when there is one, the
    /// Harness's own credentials otherwise. Both credentials answer the same official endpoint; the key's read
    /// needs no helper process, so it comes first.
    func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> DeepSeekBalance {
        if let key = DeepSeekAPIKeys.read(home: home).first { return try await fetch(apiKey: key) }
        return try await fetch()
    }

    private static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
}
