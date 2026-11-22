import Foundation

/// 收藏管理（红心）：QQ 本地持久化，登录 QQ 时尽力同步到 QQ 云端（music.srfDissong），失败不影响本地收藏。
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    /// QQ 红心收藏（本地持久化，供音乐库展示）
    @Published private(set) var qqFavoriteSongs: [Song] = []

    private let defaults = UserDefaults.standard
    private let qqKey = "beans.fav.qq.v1"

    private init() {
        qqFavoriteSongs = Self.loadSongs(qqKey)
    }

    /// 该歌曲是否已收藏
    func isLiked(_ song: Song?) -> Bool {
        guard let song else { return false }
        switch song.source {
        case .qq:
            if let mid = song.qqMid, !mid.isEmpty {
                return qqFavoriteSongs.contains { $0.qqMid == mid || $0.identityKey == song.identityKey }
            }
            return qqFavoriteSongs.contains { $0.identityKey == song.identityKey }
        }
    }

    /// 切换收藏状态；返回是否成功
    @discardableResult
    func toggle(_ song: Song) async -> Bool {
        switch song.source {
        case .qq:
            let liked = !isLiked(song)
            updateQQ(song, liked: liked)
            guard let mid = song.qqMid, !mid.isEmpty else {
                BeansLogger.shared.log("QQ 红心缺少 songmid，已保留本地收藏：\(song.name) liked=\(liked)", level: .warn)
                return true
            }
            if QQMusicAuth.shared.isLoggedIn {
                let ok = (try? await QQMusicAPI.shared.like(songmid: mid, liked: liked)) ?? false
                if !ok {
                    BeansLogger.shared.log("QQ 红心云端同步失败，已保留本地收藏：\(song.name) liked=\(liked)", level: .warn)
                }
            }
            return true
        }
    }

    /// 移除 QQ 收藏（音乐库侧滑删除）
    func removeQQFavorite(_ song: Song) {
        updateQQ(song, liked: false)
    }

    /// 登录 QQ / 微信后从 QQ 音乐云端同步“我的喜欢”。
    /// 只有云端明确返回歌曲时才覆盖本地，避免接口空响应误清空收藏。
    @MainActor
    func syncQQFromCloud() async {
        guard QQMusicAuth.shared.isLoggedIn else { return }
        guard let songs = try? await QQMusicAPI.shared.favoriteSongs(), !songs.isEmpty else { return }
        qqFavoriteSongs = songs
        saveSongs(qqFavoriteSongs, key: qqKey)
    }

    private func updateQQ(_ song: Song, liked: Bool) {
        if liked {
            qqFavoriteSongs.removeAll { existing in
                existing.identityKey == song.identityKey
                    || (existing.qqMid != nil && song.qqMid != nil && existing.qqMid == song.qqMid)
            }
            qqFavoriteSongs.insert(song, at: 0)
        } else {
            qqFavoriteSongs.removeAll { existing in
                existing.identityKey == song.identityKey
                    || (existing.qqMid != nil && song.qqMid != nil && existing.qqMid == song.qqMid)
            }
        }
        saveSongs(qqFavoriteSongs, key: qqKey)
    }

    private static func loadSongs(_ key: String) -> [Song] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([Song].self, from: data) else { return [] }
        return saved
    }

    private func saveSongs(_ songs: [Song], key: String) {
        if let data = try? JSONEncoder().encode(songs) {
            defaults.set(data, forKey: key)
        }
    }

}
