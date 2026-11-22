import Foundation
import Network
import Combine

/// 播放音质管理：
/// - Wi-Fi / 蜂窝网络分别配置默认音质（持久化）。
/// - 播放页手动切换音质只对本次运行有效，下次启动恢复默认。
/// - 聆澜音源启用且已识别 Key 支持的档位时，自动降级到可用档位。
final class NetworkQualityStore: ObservableObject {
    static let shared = NetworkQualityStore()

    enum NetworkType: Equatable {
        case wifi
        case cellular
        case other

        var title: String {
            switch self {
            case .wifi: return beansLocalized("Wi-Fi", "Wi-Fi")
            case .cellular: return beansLocalized("蜂窝网络", "Cellular")
            case .other: return beansLocalized("网络", "Network")
            }
        }

        var icon: String {
            switch self {
            case .wifi: return "wifi"
            case .cellular: return "antenna.radiowaves.left.and.right"
            case .other: return "network"
            }
        }
    }

    static let wifiKey = "beans.quality.wifi"
    static let cellularKey = "beans.quality.cellular"

    /// 当前网络类型（由 NWPathMonitor 实时更新）。
    @Published private(set) var networkType: NetworkType = .wifi
    /// 本次运行的手动音质覆盖；不持久化，App 重启即恢复网络默认。
    @Published private(set) var manualQuality: ThirdPartyAudioQuality?

    @Published var wifiQuality: ThirdPartyAudioQuality {
        didSet { defaults.set(wifiQuality.rawValue, forKey: Self.wifiKey) }
    }

    @Published var cellularQuality: ThirdPartyAudioQuality {
        didSet { defaults.set(cellularQuality.rawValue, forKey: Self.cellularKey) }
    }

    private let defaults = UserDefaults.standard
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "Beans.NetworkQuality")

    private init() {
        wifiQuality = ThirdPartyAudioQuality(
            sourceValue: defaults.string(forKey: Self.wifiKey) ?? ""
        ) ?? .flac
        cellularQuality = ThirdPartyAudioQuality(
            sourceValue: defaults.string(forKey: Self.cellularKey) ?? ""
        ) ?? .kb320

        monitor.pathUpdateHandler = { [weak self] path in
            let type: NetworkType
            if path.usesInterfaceType(.wifi) {
                type = .wifi
            } else if path.usesInterfaceType(.cellular) {
                type = .cellular
            } else {
                type = .other
            }
            DispatchQueue.main.async {
                guard let self, self.networkType != type else { return }
                self.networkType = type
            }
        }
        monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
    }

    // MARK: - 生效音质

    /// 当前网络对应的默认音质。
    var networkDefault: ThirdPartyAudioQuality {
        switch networkType {
        case .wifi: return wifiQuality
        case .cellular: return cellularQuality
        case .other: return wifiQuality
        }
    }

    /// 当前实际使用的音质：手动覆盖 > 网络默认，再按聆澜 Key 支持档位降级。
    var resolvedQuality: ThirdPartyAudioQuality {
        LinglanSource.shared.downgrade(manualQuality ?? networkDefault)
    }

    var isManual: Bool { manualQuality != nil }

    /// 可选的播放音质：聆澜已识别时按 Key 支持档位展示，否则按 QQ 官方支持档位。
    var availablePlaybackQualities: [ThirdPartyAudioQuality] {
        let linglan = LinglanSource.shared.supportedQualities
        if LinglanSource.shared.isConfigured, !linglan.isEmpty {
            return linglan
        }
        return ThirdPartyAudioQuality.supported(providerCode: "tx")
    }

    func setManualQuality(_ quality: ThirdPartyAudioQuality?) {
        manualQuality = quality
    }
}
