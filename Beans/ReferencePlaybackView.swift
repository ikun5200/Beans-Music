import SwiftUI
import MediaPlayer

private struct ReferenceLyricCenterKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct ReferencePlaybackPresentationMetrics {
    static let headerTopSpacing: CGFloat = 8
    /// 底部控制区高度（进度条 52 + 间距 19 + 控制 64 + 间距 31 + 页面选择 50）。
    static let bottomControlsHeight: CGFloat = 216
}

/// Apple Music / MeloX 风格全屏播放器：
/// - 封面页：大封面（暂停时收缩）、歌名/歌手、右侧操作菜单
/// - 歌词页：顶部 72pt 小封面 + 大字歌词（点击歌词跳转、拖动浏览）
/// - 队列页：内嵌播放队列
/// - 底部：进度条（无滑块圆点）+ 时间/音质 + 上一首/播放/下一首 + 歌词/播放模式/队列
/// - 顶部胶囊点击关闭；页面切换使用 Apple Music 26 的 smooth 曲线
struct ReferencePlaybackView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var localLibrary = LocalLibraryStore.shared
    @ObservedObject private var appleLayout = AppleMusicLayoutStore.shared
    @ObservedObject private var networkQuality = NetworkQualityStore.shared

    let song: Song?
    let lyrics: [LyricLine]
    @Binding var showLyrics: Bool
    let onFavorite: () -> Void
    let onQueue: () -> Void
    let onComments: () -> Void
    let onSleepTimer: () -> Void
    let onAddToLocalPlaylist: () -> Void
    let onDownload: () -> Void
    let onPlayerSettings: () -> Void
    var onDismiss: (() -> Void)? = nil

    @AppStorage("beans.lyricOffset") private var lyricOffset = 0.0
    @AppStorage("beans.appleMusic.showVolume") private var showVolumeControl = false
    @AppStorage("beans.appleMusic.primaryHex") private var primaryHex = ""
    @AppStorage("beans.appleMusic.secondaryHex") private var secondaryHex = ""
    @AppStorage("beans.appleMusic.accentHex") private var accentHex = ""
    @AppStorage("beans.appleMusic.volumeHex") private var volumeHex = ""
    @AppStorage("beans.appleMusic.syncWallpaper") private var syncWallpaper = false
    @AppStorage("beans.appleMusic.wallpaperBlur") private var wallpaperBlur = 14.0
    @AppStorage("beans.showSongVIPBadge") private var showSongVIPBadge = true
    private let downloadFeatureUnlocked = true

    /// 0 = 封面页，1 = 歌词页，2 = 队列页（对齐 MeloX NowPlayingPage）
    @State private var page = 0
    @State private var lyricCenters: [UUID: CGFloat] = [:]
    @State private var focusedLyricID: UUID?
    @State private var lyricsViewportHeight: CGFloat = 0
    @State private var isDraggingLyrics = false
    @State private var resumeTask: Task<Void, Never>?
    @State private var artworkBounceScale: CGFloat = 1

    private func layoutEntry(_ part: AppleMusicLayoutPart) -> PlayerLayoutEntry {
        appleLayout.entry(for: part)
    }

    private var pageAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .beansSmooth
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                playerBackground

                VStack(spacing: 0) {
                    dismissalHandle

                    ZStack {
                        if page == 0 {
                            artworkPage(size: geometry.size)
                                .transition(.asymmetric(
                                    insertion: .offset(y: -14).combined(with: .opacity),
                                    removal: .offset(y: -14).combined(with: .opacity)
                                ))
                        } else if page == 1 {
                            lyricsPage
                                .transition(.asymmetric(
                                    insertion: .opacity,
                                    removal: .offset(y: 22).combined(with: .opacity)
                                ))
                        } else {
                            queuePage
                                .transition(.asymmetric(
                                    insertion: .offset(y: 24).combined(with: .opacity),
                                    removal: .offset(y: 24).combined(with: .opacity)
                                ))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(pageAnimation, value: page)

                    bottomControls(bottomInset: geometry.safeAreaInsets.bottom)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background {
            HighRefreshConfigurator()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .onAppear {
            page = showLyrics ? 1 : 0
        }
        .onChange(of: showLyrics) { value in
            let target = value ? 1 : 0
            guard page != 2, page != target else { return }
            withAnimation(pageAnimation) { page = target }
        }
        .onChange(of: page) { _ in
            showLyrics = (page == 1)
        }
        .task(id: song?.identityKey) {
            await animateArtworkBounce()
        }
        .onDisappear { resumeTask?.cancel() }
    }

    // MARK: - 背景

    @ViewBuilder
    private var playerBackground: some View {
        ZStack {
            // 不透明基底：封面加载中或关闭动画期间不露出主页
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            if syncWallpaper, let image = theme.customBackgroundImage(for: colorScheme) {
                WallpaperImage(image: image)
                    .blur(radius: CGFloat(wallpaperBlur))
                    .scaleEffect(wallpaperBlur > 0 ? 1.08 : 1)
                    .overlay(Color.black.opacity(colorScheme == .dark ? 0.44 : 0.16))
                    .ignoresSafeArea()
            } else if syncWallpaper, let color = theme.customBackground(for: colorScheme) {
                LinearGradient(
                    colors: [color.opacity(0.92), color.opacity(0.58), colorScheme == .dark ? .black.opacity(0.88) : .white.opacity(0.70)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .blur(radius: CGFloat(wallpaperBlur * 0.35))
                .ignoresSafeArea()
            } else {
                // MeloX / Apple Music：全屏模糊封面
                CoverBlurBackground(url: song?.coverURL, scheme: colorScheme)
                    .overlay(Color.black.opacity(colorScheme == .dark ? 0.48 : 0.22))
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - 顶部胶囊（点击关闭，对齐 MeloX dismissalHandle）

    private var dismissalHandle: some View {
        Capsule()
            .fill(.white.opacity(0.52))
            .frame(width: 60, height: 5)
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .contentShape(Rectangle())
            .onTapGesture {
                BeansHaptics.tap()
                if let onDismiss {
                    onDismiss()
                } else {
                    showLyrics = false
                }
            }
            .accessibilityLabel("收起播放器")
    }

    // MARK: - 封面页

    private func artworkPage(size: CGSize) -> some View {
        let maxArtwork = min(size.width - 56, max(170, size.height - ReferencePlaybackPresentationMetrics.bottomControlsHeight - 92))
        let artworkSize = min(maxArtwork, 430)

        return VStack(spacing: 0) {
            Spacer(minLength: 8)

            CoverImage(
                url: song?.coverURL,
                size: artworkSize,
                cornerRadius: 12,
                emptyHint: player.isBuffering ? "等待开始播放…" : nil
            )
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect((player.isPlaying ? 1 : 0.74) * artworkBounceScale)
            .shadow(
                color: .black.opacity(player.isPlaying ? 0.34 : 0.18),
                radius: player.isPlaying ? 26 : 14,
                y: player.isPlaying ? 15 : 8
            )
            .animation(reduceMotion ? nil : .beansSmooth, value: player.isPlaying)
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.cover)))
            .onTapGesture {
                BeansHaptics.tap()
                withAnimation(pageAnimation) { page = 1 }
            }

            Spacer(minLength: 22)

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(song?.name ?? "未在播放")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(primaryColor)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if showSongVIPBadge, song?.isVIP == true {
                            Text("VIP")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color(red: 0.93, green: 0.25, blue: 0.22), in: Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 20))
                        .foregroundStyle(primaryColor.opacity(0.64))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.title)))

                songActionsMenu
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 0)
        }
    }

    // MARK: - 歌词页（对齐 MeloX NowPlayingLyricsPage：72pt 歌曲头 + 大字歌词）

    private var lyricsPage: some View {
        VStack(spacing: 16) {
            lyricsHeader
                .padding(.horizontal, 24)

            if lyrics.isEmpty {
                emptyLyricsView
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 26) {
                            Color.clear.frame(height: max(88, lyricsViewportHeight * 0.30))
                            ForEach(lyrics) { line in
                                lyricLine(line, isFocused: line.id == currentVisualLyricID)
                                    .id(line.id)
                                    .background {
                                        GeometryReader { rowGeometry in
                                            Color.clear.preference(
                                                key: ReferenceLyricCenterKey.self,
                                                value: [line.id: rowGeometry.frame(in: .named("referenceLyricsViewport")).midY]
                                            )
                                        }
                                    }
                            }
                            Color.clear.frame(height: max(110, lyricsViewportHeight * 0.34))
                        }
                        .padding(.horizontal, 28)
                    }
                    .coordinateSpace(name: "referenceLyricsViewport")
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .black, location: 0.12),
                                .init(color: .black, location: 0.84),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .background {
                        GeometryReader { viewport in
                            Color.clear
                                .onAppear { lyricsViewportHeight = viewport.size.height }
                                .onChange(of: viewport.size.height) { lyricsViewportHeight = $0 }
                        }
                    }
                    .onPreferenceChange(ReferenceLyricCenterKey.self) { centers in
                        lyricCenters = centers
                        updateFocusedLyric(from: centers)
                    }
                    .simultaneousGesture(lyricsDragGesture(proxy: proxy))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                            scrollToPlaybackLyric(proxy: proxy, animated: false)
                        }
                    }
                    .onChange(of: currentPlaybackLyricID) { _ in
                        guard !isDraggingLyrics else { return }
                        scrollToPlaybackLyric(proxy: proxy, animated: true)
                    }
                }
            }
        }
    }

    /// 顶部 72pt 小封面 + 歌名/歌手（点击封面返回封面页）
    private var lyricsHeader: some View {
        HStack(spacing: 12) {
            Button {
                BeansHaptics.tap()
                withAnimation(pageAnimation) { page = 0 }
            } label: {
                CoverImage(url: song?.coverURL, size: 72, cornerRadius: 12)
                    .shadow(color: .black.opacity(0.26), radius: 10, y: 5)
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.94))

            VStack(alignment: .leading, spacing: 2) {
                Text(song?.name ?? "未在播放")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(primaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(song?.artists ?? "")
                    .font(.system(size: 20))
                    .foregroundStyle(primaryColor.opacity(0.64))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)

            songActionsMenu
        }
    }

    private var songActionsMenu: some View {
        Menu {
            qualityMenu
            Divider()
            Button("收藏", action: onFavorite)
            Button("定时关闭", action: onSleepTimer)
            Button("添加到本地歌单", action: onAddToLocalPlaylist)
            if downloadFeatureUnlocked {
                Button("下载歌曲", action: onDownload)
            }
            Button("评论", action: onComments)
            Button("播放器设置", action: onPlayerSettings)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(primaryColor.opacity(0.78))
                .frame(width: 38, height: 38)
                .background(primaryColor.opacity(0.10), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var qualityMenu: some View {
        Menu {
            ForEach(networkQuality.availablePlaybackQualities, id: \.rawValue) { (quality: ThirdPartyAudioQuality) in
                Button {
                    networkQuality.setManualQuality(quality)
                    player.reloadForQualityChange()
                    BeansHaptics.select()
                } label: {
                    if quality.rawValue == networkQuality.resolvedQuality.rawValue {
                        Label(quality.displayName, systemImage: "checkmark")
                    } else {
                        Text(quality.displayName)
                    }
                }
            }
            if networkQuality.isManual {
                Divider()
                Button {
                    networkQuality.setManualQuality(nil)
                    player.reloadForQualityChange()
                    BeansHaptics.select()
                } label: {
                    Label("恢复默认音质", systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            Label("音质（本次播放）", systemImage: "waveform.badge.magnifyingglass")
        }
    }

    private func lyricLine(_ line: LyricLine, isFocused: Bool) -> some View {
        Button {
            BeansHaptics.tap()
            player.seek(to: LyricTiming.seekTime(for: line, userOffset: lyricOffset))
            // 点击后立即聚焦该行（MeloX 的 seek 反馈）
            withAnimation(.beansSnappy) { focusedLyricID = line.id }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(BeansFont.appFont(isFocused ? 27 : 23, isFocused ? .bold : .semibold))
                        .foregroundStyle(primaryColor.opacity(isFocused ? 1 : 0.36))
                        .fixedSize(horizontal: false, vertical: true)
                    if isFocused && isDraggingLyrics {
                        Spacer(minLength: 8)
                        Text(beansTimeString(line.time))
                            .font(BeansFont.appFont(11, .semibold, .monospaced))
                            .foregroundStyle(secondaryColor.opacity(0.82))
                    }
                }
                if isFocused, let translation = line.translation, !translation.isEmpty {
                    Text(translation)
                        .font(BeansFont.appFont(15, .medium))
                        .foregroundStyle(secondaryColor.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .scaleEffect(isFocused ? 1.05 : 0.86, anchor: .leading)
            .opacity(isFocused ? 1 : 0.92)
            .blur(radius: isFocused ? 0 : 0.5)
        }
        .buttonStyle(.plain)
        .animation(.beansSmooth, value: isFocused)
    }

    private var emptyLyricsView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "quote.bubble")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.42))
            Text("暂无歌词")
                .font(BeansFont.appFont(15, .semibold))
                .foregroundStyle(.white.opacity(0.86))
            Text("点击左上角封面返回")
                .font(BeansFont.appFont(12))
                .foregroundStyle(.white.opacity(0.46))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - 队列页（MeloX 内嵌队列）

    private var queuePage: some View {
        VStack(spacing: 0) {
            HStack {
                Text("播放队列")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(primaryColor)
                Spacer()
                Text("\(player.queue.count) 首")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(primaryColor.opacity(0.5))
                Button {
                    BeansHaptics.tap()
                    player.togglePlayMode()
                } label: {
                    Image(systemName: player.playMode.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(primaryColor.opacity(0.7))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 6)

            if player.queue.isEmpty {
                EmptyStateView(icon: "music.note.list", text: "播放队列为空")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(player.queue.enumerated()), id: \.element.identityKey) { index, item in
                            queueRow(item, index: index)
                            Divider().overlay(primaryColor.opacity(0.08))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private func queueRow(_ item: Song, index: Int) -> some View {
        let isCurrent = index == player.currentIndex
        return Button {
            BeansHaptics.tap()
            player.playQueueIndex(index)
        } label: {
            HStack(spacing: 12) {
                CoverImage(url: item.coverURL, size: 44, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? accentColor : primaryColor)
                        .lineLimit(1)
                    Text(item.artists)
                        .font(.system(size: 12))
                        .foregroundStyle(primaryColor.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accentColor)
                } else {
                    Text(item.formattedDuration)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(primaryColor.opacity(0.45))
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部控制（对齐 MeloX：进度 52 + 19 + 控制 64 + 31 + 页面选择 50）

    private func bottomControls(bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            ReferenceScrubber()
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.progress)))

            Color.clear.frame(height: 19)

            transportControls

            Color.clear.frame(height: 31)

            if showVolumeControl {
                ReferenceVolumeControl(accent: volumeColor, secondary: secondaryColor)
                    .frame(maxWidth: 420)
                    .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.volume)))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                Color.clear.frame(height: 3)
            }

            pageSelector
        }
        .padding(.horizontal, 24)
        .padding(.bottom, max(12, bottomInset + 4))
        .gesture(commentsGesture)
    }

    private var transportControls: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button {
                BeansHaptics.tap()
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(primaryColor)
                    .frame(width: 64, height: 64)
                    .contentShape(Circle())
            }
            .buttonStyle(TransportPressStyle())
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.previous)))

            Spacer(minLength: 0)

            Button {
                BeansHaptics.tap()
                player.togglePlayPause()
            } label: {
                PlayPauseMorphIcon(isPlaying: player.isPlaying, size: 48)
                    .foregroundStyle(primaryColor)
                    .frame(width: 64, height: 64)
                    .contentShape(Circle())
            }
            .buttonStyle(TransportPressStyle())
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.play)))

            Spacer(minLength: 0)

            Button {
                BeansHaptics.tap()
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(primaryColor)
                    .frame(width: 64, height: 64)
                    .contentShape(Circle())
            }
            .buttonStyle(TransportPressStyle())
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.next)))

            Spacer(minLength: 0)
        }
        .frame(height: 64)
    }

    /// 底部页面选择：歌词 / 播放模式 / 队列（MeloX NowPlayingPageSelector）
    private var pageSelector: some View {
        HStack {
            pageButton(target: 1, systemImage: "quote.bubble")
            Spacer()
            Button {
                BeansHaptics.tap()
                player.togglePlayMode()
            } label: {
                Image(systemName: player.playMode.icon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(player.playMode == .shuffle ? accentColor : primaryColor.opacity(0.72))
                    .frame(width: 52, height: 50)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            pageButton(target: 2, systemImage: "list.bullet")
        }
        .padding(.horizontal, 36)
        .foregroundStyle(primaryColor.opacity(0.72))
        .frame(height: 50)
    }

    private func pageButton(target: Int, systemImage: String) -> some View {
        Button {
            BeansHaptics.tap()
            withAnimation(pageAnimation) {
                page = (page == target) ? 0 : target
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(page == target ? accentColor : primaryColor.opacity(0.72))
                .frame(width: 52, height: 50)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 歌词辅助

    private var currentPlaybackLyricIndex: Int? {
        guard !lyrics.isEmpty else { return nil }
        let progress = LyricTiming.effectiveProgress(clock.progress, userOffset: lyricOffset)
        var low = 0
        var high = lyrics.count - 1
        var answer: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lyrics[mid].time <= progress {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }

    private var currentPlaybackLyricID: UUID? {
        guard let index = currentPlaybackLyricIndex, lyrics.indices.contains(index) else { return nil }
        return lyrics[index].id
    }

    private var currentVisualLyricID: UUID? {
        isDraggingLyrics ? focusedLyricID : (focusedLyricID ?? currentPlaybackLyricID)
    }

    private var subtitle: String {
        guard let song else { return "" }
        let parts = [song.artists, song.album].filter { !$0.isEmpty }
        return parts.isEmpty ? "未知歌曲" : parts.joined(separator: " · ")
    }

    private func updateFocusedLyric(from centers: [UUID: CGFloat]) {
        guard lyricsViewportHeight > 0, !centers.isEmpty else { return }
        let center = lyricsViewportHeight / 2
        focusedLyricID = centers.min { abs($0.value - center) < abs($1.value - center) }?.key
    }

    private func scrollToPlaybackLyric(proxy: ScrollViewProxy, animated: Bool) {
        guard let id = currentPlaybackLyricID else { return }
        let action = { proxy.scrollTo(id, anchor: .center) }
        if animated {
            withAnimation(.beansSnappy) { action() }
        } else {
            action()
        }
    }

    private func lyricsDragGesture(proxy: ScrollViewProxy) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { _ in
                isDraggingLyrics = true
                resumeTask?.cancel()
                updateFocusedLyric(from: lyricCenters)
            }
            .onEnded { _ in
                resumeTask?.cancel()
                if let id = focusedLyricID {
                    withAnimation(.beansSnappy) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                resumeTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    guard !Task.isCancelled else { return }
                    isDraggingLyrics = false
                }
            }
    }

    private var commentsGesture: some Gesture {
        DragGesture(minimumDistance: 25)
            .onEnded { value in
                guard value.translation.height < -54, abs(value.translation.height) > abs(value.translation.width) else { return }
                BeansHaptics.medium()
                onComments()
            }
    }

    // MARK: - 切歌封面弹跳（MeloX animateArtworkBounce）

    private func animateArtworkBounce() async {
        artworkBounceScale = 1
        guard !reduceMotion, player.isPlaying else { return }
        await Task.yield()
        withAnimation(.easeOut(duration: 0.17)) { artworkBounceScale = 1.055 }
        try? await Task.sleep(nanoseconds: 170_000_000)
        withAnimation(.beansSmooth) { artworkBounceScale = 1 }
    }

    // MARK: - 颜色

    private var primaryColor: Color {
        if primaryHex.hasPrefix("#"), let color = Color(hex: primaryHex) { return color }
        return .white
    }

    private var secondaryColor: Color {
        if secondaryHex.hasPrefix("#"), let color = Color(hex: secondaryHex) { return color }
        return .white.opacity(0.58)
    }

    private var accentColor: Color {
        if accentHex.hasPrefix("#"), let color = Color(hex: accentHex) { return color }
        return MeloDesign.accent
    }

    private var volumeColor: Color {
        if volumeHex.hasPrefix("#"), let color = Color(hex: volumeHex) { return color }
        return primaryColor
    }
}

// MARK: - 播放控制按压效果（MeloX TransportButtonStyle）

private struct TransportPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.beansSnappy, value: configuration.isPressed)
    }
}

// MARK: - 进度条（MeloX：细线、无滑块圆点、时间+音质徽章）

private struct ReferenceScrubber: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let total = max(max(clock.duration, player.currentSong?.duration ?? 0), 1)
                let progress = min(max((scrubbing ? scrubValue : clock.progress) / total, 0), 1)
                let width = geometry.size.width

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .frame(height: 4)
                    Capsule()
                        .fill(.white.opacity(0.88))
                        .frame(width: width * progress, height: 4)
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !scrubbing {
                                scrubValue = clock.progress
                                BeansHaptics.medium()
                            }
                            scrubbing = true
                            scrubValue = min(max(value.location.x / max(width, 1), 0), 1) * total
                        }
                        .onEnded { _ in
                            player.seek(to: scrubValue)
                            scrubbing = false
                            BeansHaptics.tap()
                        }
                )
            }
            .frame(height: 24)

            let total = max(clock.duration, player.currentSong?.duration ?? 0)
            let elapsed = scrubbing ? scrubValue : clock.progress
            HStack(spacing: 8) {
                Text(beansTimeString(elapsed))
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.system(size: 9, weight: .semibold))
                    Text(NetworkQualityStore.shared.resolvedQuality.displayName)
                }
                .font(BeansFont.appFont(10, .semibold))
                .foregroundStyle(.white.opacity(0.74))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.white.opacity(0.14), in: Capsule())
                Spacer(minLength: 4)
                Text("-" + beansTimeString(max(total - elapsed, 0)))
            }
            .font(BeansFont.appFont(11, .regular, .monospaced))
            .foregroundStyle(.white.opacity(0.52))
        }
        .frame(maxWidth: 420)
        .padding(.top, 4)
    }
}

// MARK: - 音量

private struct ReferenceVolumeControl: View {
    let accent: Color
    let secondary: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(secondary.opacity(0.84))
            ReferenceSystemVolumeView(accent: accent, secondary: secondary)
                .frame(height: 32)
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(secondary.opacity(0.84))
        }
        .frame(height: 34)
    }
}

private struct ReferenceSystemVolumeView: UIViewRepresentable {
    let accent: Color
    let secondary: Color

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        styleVolumeSlider(in: view)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        styleVolumeSlider(in: uiView)
    }

    private func styleVolumeSlider(in view: MPVolumeView) {
        let applyStyle = {
            let sliders = allSubviews(in: view).compactMap { $0 as? UISlider }
            sliders.forEach { slider in
                slider.minimumTrackTintColor = UIColor(accent.opacity(0.88))
                slider.maximumTrackTintColor = UIColor(secondary.opacity(0.32))
                slider.thumbTintColor = UIColor(accent)
            }
        }

        applyStyle()
        DispatchQueue.main.async {
            applyStyle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                applyStyle()
            }
        }
    }

    private func allSubviews(in view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { allSubviews(in: $0) }
    }
}
