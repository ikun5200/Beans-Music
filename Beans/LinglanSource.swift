import Foundation
import Combine

/// 内置聆澜音源：对接 source.shiqianjiang.cn（ceru 音乐插件后端）。
///
/// - API Key 由用户在设置页填写，不随 App 内置。
/// - 播放地址解析优先走聆澜（支持 128k ~ master 共 8 档音质），
///   失败或未配置时自动回退 QQ 音乐官方 vkey。
/// - 登录、收藏、歌单等网易云时代已移除的内容能力仍由 QQ 音乐官方接口提供。
final class LinglanSource: ObservableObject {
    static let shared = LinglanSource()

    enum Status: Equatable {
        case disabled
        case notConfigured
        case idle
        case testing
        case online(platforms: Int, qualities: [String])
        case failed(String)
    }

    static let apiKeyKey = "beans.linglan.apiKey"
    static let enabledKey = "beans.linglan.enabled"
    private static let endpoint = "https://source.shiqianjiang.cn/api"
    private static let userAgent = "CeruMusic-Plugin/9.0.1"

    @Published var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: Self.apiKeyKey)
            scheduleKeyProbe()
        }
    }

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            scheduleKeyProbe()
        }
    }

    @Published private(set) var status: Status = .idle
    /// 后端返回的 QQ 平台可用音质（高到低）。
    @Published private(set) var platformQualities: [String] = []

    /// 429/401 冷却，避免反复请求加重限流。
    private var cooldownUntil: Date?
    /// 输入 Key 后的自动识别任务（防抖，避免逐字请求）。
    private var probeTask: Task<Void, Never>?

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private init() {
        apiKey = UserDefaults.standard.string(forKey: Self.apiKeyKey) ?? ""
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        if !isConfigured {
            status = enabled ? .notConfigured : .disabled
        }
    }

    // MARK: - 状态

    var isConfigured: Bool {
        enabled && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canResolve: Bool {
        guard isConfigured else { return false }
        if let cooldownUntil, cooldownUntil > Date() { return false }
        return true
    }

    var maskedKey: String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 10 else { return trimmed }
        return String(trimmed.prefix(8)) + "…" + String(trimmed.suffix(4))
    }

    /// 当前 Key 识别到的 QQ 可用音质（低 → 高）。
    var supportedQualities: [ThirdPartyAudioQuality] {
        platformQualities.compactMap { ThirdPartyAudioQuality(sourceValue: $0) }
    }

    /// 按 Key 支持的档位降级；未配置或尚未识别时原样返回。
    func downgrade(_ quality: ThirdPartyAudioQuality) -> ThirdPartyAudioQuality {
        guard isConfigured, !platformQualities.isEmpty else { return quality }
        let supported = Set(platformQualities)
        for candidate in quality.fallbackChain where supported.contains(candidate.rawValue) {
            return candidate
        }
        return ThirdPartyAudioQuality(sourceValue: platformQualities.first ?? "320k") ?? .kb320
    }

    /// Key/开关变化后自动识别支持的音质（1.2 秒防抖）。
    private func scheduleKeyProbe() {
        probeTask?.cancel()
        guard enabled, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            platformQualities = []
            status = enabled ? .notConfigured : .disabled
            return
        }
        status = .testing
        probeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await self?.testConnection()
        }
    }

    // MARK: - 播放解析

    /// 优先使用聆澜解析 QQ 歌曲播放地址；失败返回 nil（由调用方回退 QQ 官方）。
    func resolve(songID: Int, quality: ThirdPartyAudioQuality) async -> UnblockService.Resolved? {
        guard canResolve else { return nil }
        // 最多尝试两档音质：首档失败后请求次档，仍失败则交给 QQ 官方兜底，
        // 避免每首歌在播放前等待过多轮网络请求。
        for candidate in qualityChain(for: quality).prefix(2) {
            if let url = await requestPlayURL(songID: songID, quality: candidate) {
                return UnblockService.Resolved(
                    url: url,
                    source: "聆澜音源",
                    quality: ThirdPartyAudioQuality(sourceValue: candidate) ?? quality
                )
            }
            if !canResolve { break }
        }
        return nil
    }

    /// 按设置音质生成降级链，并与后端声明的可用音质取交集。
    private func qualityChain(for quality: ThirdPartyAudioQuality) -> [String] {
        let chain = quality.fallbackChain.map(\.rawValue)
        guard !platformQualities.isEmpty else { return chain }
        let supported = chain.filter { platformQualities.contains($0) }
        return supported.isEmpty ? [] : supported
    }

    private func requestPlayURL(songID: Int, quality: String) async -> URL? {
        guard var comps = URLComponents(string: Self.endpoint + "/music/url") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "source", value: "tx"),
            URLQueryItem(name: "songId", value: String(songID)),
            URLQueryItem(name: "quality", value: quality)
        ]
        guard let url = comps.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-API-Key")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            switch http.statusCode {
            case 200:
                break
            case 401, 403:
                cooldownUntil = Date().addingTimeInterval(30)
                await MainActor.run { self.status = .failed("API Key 无效或已过期") }
                BeansLogger.shared.log("聆澜音源鉴权失败（\(http.statusCode)）：请检查 API Key", level: .error)
                return nil
            case 429:
                cooldownUntil = Date().addingTimeInterval(60)
                BeansLogger.shared.log("聆澜音源触发限流，暂停解析 60 秒", level: .warn)
                return nil
            default:
                BeansLogger.shared.log("聆澜音源 HTTP 异常：\(http.statusCode)", level: .debug)
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let code = (json["code"] as? NSNumber)?.intValue ?? 200
            guard code == 0 || code == 200 else {
                BeansLogger.shared.log("聆澜音源返回错误 code=\(code) message=\(json["message"] ?? "")", level: .debug)
                return nil
            }
            let urlString = (json["url"] as? String)
                ?? ((json["data"] as? [String: Any])?["url"] as? String)
            guard let urlString, !urlString.isEmpty,
                  let playURL = URL(string: urlString),
                  playURL.path.count > 1,
                  !playURL.lastPathComponent.isEmpty else {
                // 无效歌曲时后端可能只返回 CDN 域名（无实际文件路径），视为未命中。
                BeansLogger.shared.log("聆澜音源返回无效地址：songID=\(songID) url=\(urlString)", level: .debug)
                return nil
            }
            BeansLogger.shared.log("聆澜音源命中：songID=\(songID) 音质=\(quality)", level: .info)
            return playURL
        } catch {
            BeansLogger.shared.log("聆澜音源请求失败：\(error.localizedDescription)", level: .debug)
            return nil
        }
    }

    // MARK: - 连接测试 / 状态

    /// 读取插件信息与音源健康状态，用于设置页展示。
    @MainActor
    func testConnection() async {
        guard isConfigured else {
            status = enabled ? .notConfigured : .disabled
            return
        }
        status = .testing
        async let sourcesJSON = requestJSON(path: "music/sources")
        async let infoJSON = requestJSON(path: "plugin/info")
        let (sources, info) = await (sourcesJSON, infoJSON)

        var freeLimited = false
        if let sources {
            let data = sources["data"] as? [String: Any]
            let sourceMap = data?["sources"] as? [String: Any]
            let freeLimit = data?["freeQualityLimit"] as? [String] ?? []
            if let tx = sourceMap?["tx"] as? [String], !tx.isEmpty {
                platformQualities = tx
                // 当 tx 列表与免费档位完全一致时，视为免费额度 Key。
                freeLimited = !freeLimit.isEmpty && Set(tx) == Set(freeLimit)
            } else if !freeLimit.isEmpty {
                // 免费 Key 未列出 tx 时，按免费档位上限处理。
                platformQualities = freeLimit
                freeLimited = true
            }
        }

        guard sources != nil || info != nil else {
            status = .failed("无法连接聆澜服务，请检查网络或 API Key")
            return
        }
        if platformQualities.isEmpty {
            status = .failed("当前 Key 不支持 QQ 音乐音源")
            return
        }

        var platformCount = 0
        if let info, let data = info["data"] as? [String: Any],
           let capabilities = data["capabilities"] as? [String: Any],
           let paid = capabilities["paid"] as? [String: Any] {
            platformCount = paid.filter { ($0.value as? [String: Any])?["enabled"] as? Bool == true }.count
        }
        if let sources, let data = sources["data"] as? [String: Any],
           let sourceMap = data["sources"] as? [String: Any] {
            if platformCount == 0 { platformCount = sourceMap.count }
            if platformQualities.isEmpty, let tx = sourceMap["tx"] as? [String] {
                platformQualities = tx
            }
        }
        status = .online(platforms: platformCount, qualities: platformQualities)
        _ = freeLimited
        BeansLogger.shared.log(
            "聆澜音源连接成功：平台=\(platformCount) QQ音质=\(platformQualities.joined(separator: "/"))",
            level: .info
        )
    }

    private func requestJSON(path: String) async -> [String: Any]? {
        guard let url = URL(string: Self.endpoint + "/" + path) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-API-Key")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
