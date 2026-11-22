import SwiftUI
import UIKit

private enum LibraryRoute: Hashable {
    case playlist(Playlist)
}

struct LibraryView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var favorites: FavoritesStore
    @ObservedObject private var qqAuth = QQMusicAuth.shared

    @State private var showHistory = false
    @State private var showSectionSort = false
    @State private var showSyncedPlaylistSort = false
    /// MeloX 风格分段：本地音乐库 / 我的歌单 / 最近播放
    @State private var librarySegmentIndex = 0
    /// 音乐库板块顺序（本地音乐库 / 我的歌单 / 最近播放，可自定义）
    @State private var libraryOrder = SectionOrderStore.load(SectionOrderStore.libraryKey, defaults: SectionOrderStore.libraryDefaults)
    @State private var navigationPath: [LibraryRoute] = []
    @State private var legacyRoute: LibraryRoute?
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""
    @State private var pendingDelete: Playlist?
    @State private var showDeleteConfirm = false
    @AppStorage("beans.homeHeaderHideSort") private var hideSortButton = false
    @State private var qqPlaylists: [Playlist] = []
    @State private var qqLoading = false
    @State private var qqSavedAt = Date.distantPast
    @AppStorage("beans.uiStyle") private var uiStyleRaw = BeansUIStyle.liquid.rawValue

    private var orderedQQPlaylists: [Playlist] {
        SyncedPlaylistOrderStore.shared.ordered(qqPlaylists, source: .qq)
    }

    private var qqCacheAccountID: String {
        let raw = qqAuth.rawUin
        return raw.isEmpty ? qqAuth.playlistUin : raw
    }

    private var syncedPlaylistBinding: Binding<[Playlist]> {
        Binding(
            get: { orderedQQPlaylists },
            set: { value in
                qqPlaylists = value
                SyncedPlaylistOrderStore.shared.save(value, source: .qq)
            }
        )
    }

    private var isNativeClean: Bool {
        BeansUIStyle(rawValue: uiStyleRaw) == .nativeClean
    }

    var body: some View {
        let _ = theme.accent
        BeansNavigationStackWithPath(path: $navigationPath) {
        ZStack {
            // 页面背景：同步开启时显示壁纸/背景色，否则默认氛围渐变
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            // 实例级 UITabBar 清透风格（固定全透明，无需调节）
            TabBarAppearanceConfigurator()
            if #unavailable(iOS 16.0) {
                NavigationLink(
                    destination: libraryDestination(legacyRoute ?? .playlist(Playlist(id: 0, name: "", coverURL: nil))),
                    isActive: Binding(
                        get: { legacyRoute != nil },
                        set: { if !$0 { legacyRoute = nil } }
                    )
                ) {
                    EmptyView()
                }
                .hidden()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: isNativeClean ? 30 : 24) {
                    if isNativeClean {
                        appleHeader
                    } else {
                        header
                    }
                    if isNativeClean {
                        // MeloX 风格：分段控件切换内容
                        VStack(alignment: .leading, spacing: 18) {
                            librarySegmentedControl
                            switch librarySegmentIndex {
                            case 0: LocalMusicSection()
                            case 1: qqSection
                            default: historySection
                            }
                        }
                    } else {
                        // 自定义板块顺序（可拖拽排序）
                        ForEach(libraryOrder, id: \.self) { key in
                            switch key {
                            case "本地音乐库":
                                LocalMusicSection()
                            case "我的歌单":
                                qqSection
                            case "最近播放":
                                historySection
                            default:
                                EmptyView()
                            }
                        }
                    }
                }
                .padding(.horizontal, isNativeClean ? 24 : 16)
                .padding(.top, isNativeClean ? 20 : 8)
                .padding(.bottom, 190)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .beansScrollIndicatorsHidden()
            .refreshable {
                await refreshQQPlaylists(force: true)
            }
        }
        .task {
            await refreshQQPlaylists(force: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .beansQQLoginDidUpdate)) { _ in
            Task { await loadQQPlaylists(force: true) }
        }
        .sheet(isPresented: $showHistory) {
            HistoryView()
                .environmentObject(player)
                .environmentObject(theme)
        }
        .sheet(isPresented: $showSectionSort) {
            SectionOrderSheet(
                title: "音乐库板块排序",
                sections: SectionOrderStore.libraryDefaults,
                order: $libraryOrder
            )
                .onDisappear { SectionOrderStore.save(SectionOrderStore.libraryKey, libraryOrder) }
        }
        .sheet(isPresented: $showSyncedPlaylistSort) {
            SyncedPlaylistOrderSheet(
                title: "我的歌单排序",
                source: .qq,
                playlists: syncedPlaylistBinding
            )
            .environmentObject(theme)
        }
        .alert("新建歌单", isPresented: $showCreatePlaylist) {
            TextField("歌单名称", text: $newPlaylistName)
            Button("创建") { createPlaylist() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("输入歌单名称，创建后同步到QQ音乐")
        }
        .confirmationDialog("确定删除歌单「\(pendingDelete?.name ?? "")」吗？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) { confirmDeletePlaylist() }
            Button("取消", role: .cancel) {}
        }
        .beansNavigationDestination(for: LibraryRoute.self) { route in
            libraryDestination(route)
        }
    }
    }

    @ViewBuilder
    private func libraryDestination(_ route: LibraryRoute) -> some View {
        switch route {
        case .playlist(let playlist):
            PlaylistView(playlist: playlist)
                .environmentObject(player)
                .environmentObject(theme)
        }
    }

    private func openRoute(_ route: LibraryRoute) {
        if #available(iOS 16.0, *) {
            navigationPath.append(route)
        } else {
            legacyRoute = route
        }
    }

    /// MeloX 风格分段控件（灰底胶囊 + 白色选中胶囊）
    private var librarySegmentedControl: some View {
        let segments = ["歌曲", "歌单", "最近播放"]
        return HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, title in
                Button {
                    BeansHaptics.select()
                    withAnimation(.beansSnappy) { librarySegmentIndex = index }
                } label: {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(librarySegmentIndex == index ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if librarySegmentIndex == index {
                                Capsule(style: .continuous)
                                    .fill(Color(UIColor.systemBackground))
                                    .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                    libraryTitleButton
                    Text(librarySubtitle)
                        .font(BeansFont.appFont(13))
                        .foregroundStyle(Color.beansComment)
                }
                Spacer()
                HStack(spacing: 10) {
                if !hideSortButton {
                    GlassIconButton(systemName: "arrow.up.arrow.down", forceLiquid: isNativeClean) {
                        BeansHaptics.tap()
                        showSectionSort = true
                    }
                    GlassIconButton(systemName: "list.number", forceLiquid: isNativeClean) {
                        BeansHaptics.tap()
                        showSyncedPlaylistSort = true
                    }
                }
                }
            }
        }
        .padding(.top, 8)
    }

    private var appleHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center) {
                libraryTitleButton
                Spacer(minLength: 12)
                if !hideSortButton {
                    GlassIconButton(systemName: "arrow.up.arrow.down", forceLiquid: isNativeClean) {
                        BeansHaptics.tap()
                        showSectionSort = true
                    }
                    GlassIconButton(systemName: "list.number", forceLiquid: isNativeClean) {
                        BeansHaptics.tap()
                        showSyncedPlaylistSort = true
                    }
                }
            }
            Text(librarySubtitle)
                .font(BeansFont.appFont(12, .medium))
                .foregroundStyle(Color.beansComment)
                .lineLimit(1)
            Rectangle()
                .fill(Color.beansLabel.opacity(0.10))
                .frame(height: 1)
        }
        .padding(.top, 4)
    }

    private var librarySubtitle: String { "QQ 音乐收藏与歌单" }

    private var libraryTitleButton: some View {
        Text("音乐库")
            .font(BeansFont.appFont(isNativeClean ? 34 : 30, .bold))
            .foregroundStyle(Color.beansLabel)
    }


    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "最近播放", trailing: "查看全部") {
                showHistory = true
            }
            if player.history.isEmpty {
                EmptyStateView(icon: "clock.arrow.circlepath", text: "暂无播放记录")
            } else {
                VStack(spacing: 0) {
                    ForEach(player.history.prefix(5), id: \.identityKey) { song in
                        SongCell(song: song, suppressNativeCleanRowGlass: isNativeClean) {
                            playFromHistory(song)
                        }
                        Divider().overlay(Color.beansComment.opacity(0.15))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background {
                                        BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .beansCardShadow(radius: 8, y: 3)
            }
        }
    }

    private func refreshQQPlaylists(force: Bool) async {
        await loadQQPlaylists(force: force)
    }

    /// QQ 模式整体内容：用户歌单（创建 + 收藏同步）
    private var qqSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            qqPlaylistsSection
        }
    }

    /// 我的 QQ 歌单（登录后从 QQ 音乐拉取）
    private var qqPlaylistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "我的 QQ 歌单", trailing: qqAuth.isLoggedIn ? (qqPlaylists.isEmpty ? "新建" : "新建 · \(qqPlaylists.count) 个") : nil) {
                if qqAuth.isLoggedIn {
                    BeansHaptics.tap()
                    newPlaylistName = ""
                    showCreatePlaylist = true
                }
            }
            if !qqAuth.isLoggedIn {
                EmptyStateView(icon: "music.note.list", text: "登录 QQ 音乐后即可查看你的歌单")
            } else if qqLoading {
                LoadingStateView()
            } else if qqPlaylists.isEmpty {
                EmptyStateView(icon: "music.note.list", text: "暂无 QQ 歌单")
            } else {
                VStack(spacing: 0) {
                    ForEach(orderedQQPlaylists) { playlist in
                        Button {
                            openRoute(LibraryRoute.playlist(playlist))
                        } label: {
                            HStack(spacing: 12) {
                                CoverImage(url: playlist.coverURL, size: 56, cornerRadius: 12)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(playlist.name)
                                        .font(BeansFont.appFont(15, .medium))
                                        .foregroundStyle(Color.beansLabel)
                                        .lineLimit(1)
                                    Text(beansSongCountText(playlist.trackCount))
                                        .font(BeansFont.appFont(12))
                                        .foregroundStyle(Color.beansComment)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.beansComment.opacity(0.6))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                BeansHaptics.tap()
                                requestDelete(playlist)
                            } label: {
                                Label("删除歌单", systemImage: "trash")
                            }
                        }
                        Divider().overlay(Color.beansComment.opacity(0.12))
                    }
                }
                .padding(.vertical, 6)
                .background {
                                        BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .beansCardShadow(radius: 8, y: 3)
            }
        }
    }

    // MARK: - 歌单新建 / 删除

    private func loadQQPlaylists(force: Bool = false) async {
        guard qqAuth.isLoggedIn else {
            qqPlaylists = []
            qqLoading = false
            return
        }
        let cache = SyncedPlaylistCache.shared
        if qqPlaylists.isEmpty,
           let cached = cache.cachedPlaylists(source: .qq, accountID: qqCacheAccountID) {
            qqPlaylists = cached.playlists
            qqSavedAt = cached.savedAt
        }
        // 持久化缓存仍新鲜时直接展示；下拉刷新会跳过缓存。
        if !force, !qqPlaylists.isEmpty, Date().timeIntervalSince(qqSavedAt) < cache.playlistTTL { return }
        qqLoading = qqPlaylists.isEmpty
        let list = (try? await QQMusicAPI.shared.userPlaylists(uin: qqAuth.uin)) ?? []
        if !list.isEmpty {
            qqPlaylists = list
            cache.savePlaylists(list, source: .qq, accountID: qqCacheAccountID)
        }
        await favorites.syncQQFromCloud()
        if !list.isEmpty { qqSavedAt = Date() }
        qqLoading = false
        // 封面兜底：歌单封面缺失时默认取第一首歌曲封面（列表先展示，封面后台补齐）
        if !list.isEmpty { await fillQQPlaylistCovers(list) }
        if !qqPlaylists.isEmpty {
            cache.savePlaylists(qqPlaylists, source: .qq, accountID: qqCacheAccountID)
        }
    }

    private func fillQQPlaylistCovers(_ list: [Playlist]) async {
        let missing = list.filter { $0.coverURL == nil }
        guard !missing.isEmpty else { return }
        var covers: [Int: URL] = [:]
        await withTaskGroup(of: (Int, URL?).self) { group in
            for playlist in missing {
                group.addTask {
                    let cover = try? await QQMusicAPI.shared.firstSongCover(listID: playlist.id)
                    return (playlist.id, cover)
                }
            }
            for await (id, url) in group {
                if let url { covers[id] = url }
            }
        }
        for i in qqPlaylists.indices where qqPlaylists[i].coverURL == nil {
            if let url = covers[qqPlaylists[i].id] { qqPlaylists[i].coverURL = url }
        }
    }

    private func createPlaylist() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            ToastCenter.shared.show("请输入歌单名称")
            return
        }
        guard qqAuth.isLoggedIn else {
            ToastCenter.shared.show("请先登录 QQ 音乐后再创建歌单")
            return
        }
        Task {
            do {
                let ok = try await QQMusicAPI.shared.createPlaylist(name: name)
                if ok {
                    ToastCenter.shared.show("歌单「\(name)」已创建")
                    newPlaylistName = ""
                    await loadQQPlaylists(force: true)
                } else {
                    ToastCenter.shared.show("创建失败，请确认已登录 QQ 音乐")
                }
            } catch {
                ToastCenter.shared.show("创建失败：\(error.localizedDescription)")
            }
        }
    }

    private func requestDelete(_ playlist: Playlist) {
        pendingDelete = playlist
        showDeleteConfirm = true
    }

    private func confirmDeletePlaylist() {
        guard let playlist = pendingDelete else { return }
        Task {
            do {
                let ok = try await QQMusicAPI.shared.deletePlaylist(dirid: playlist.id)
                if ok {
                    ToastCenter.shared.show("已删除歌单「\(playlist.name)」")
                    await loadQQPlaylists(force: true)
                } else {
                    ToastCenter.shared.show("删除失败，请确认已登录 QQ 音乐")
                }
            } catch {
                ToastCenter.shared.show("删除失败：\(error.localizedDescription)")
            }
        }
    }

    private func playFromHistory(_ song: Song) {
        if let index = player.history.firstIndex(of: song) {
            player.play(songs: player.history, startAt: index)
        }
    }
}

