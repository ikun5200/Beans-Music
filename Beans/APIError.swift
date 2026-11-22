import Foundation

/// 音乐平台接口通用错误。
enum MusicAPIError: LocalizedError {
    case network
    case httpStatus(Int, String)
    case decoding(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .network: return "网络连接失败，请检查网络"
        case .httpStatus(let code, let snippet):
            return snippet.isEmpty ? "服务器响应异常（\(code)）" : "服务器响应异常（\(code)）\(snippet)"
        case .decoding(let snippet):
            return snippet.isEmpty ? "数据解析失败" : "数据解析失败：\(snippet)"
        case .unknown(let message): return message
        }
    }
}

// MARK: - 通用工具

import CommonCrypto

extension Data {
    /// MD5 十六进制摘要。
    func md5Hex() -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        _ = withUnsafeBytes { CC_MD5($0.baseAddress, CC_LONG(count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// 扫码登录状态（QQ / 酷狗二维码登录共用）。
enum QRStatus: Equatable {
    case loading
    case waiting
    case scanned
    case success
    case expired
    case error(String)
}
