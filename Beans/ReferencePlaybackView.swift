import SwiftUI
import MediaPlayer
import UIKit

private struct ReferenceLyricCenterKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct ReferenceArtworkFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0, next.height > 0 { value = next }
    }
}

/// MeloX `NowPlayingMotionSpec.appleMusic26` 的等价参数。
private enum ReferencePlaybackMetrics {
    /// 播放页左右安全边距（MeloX portraitHorizontalPadding = 32）
    static let horizontal: CGFloat = 32
    /// 顶部收起胶囊高度
    static let handleHeight: CGFloat = 34
    /// 歌词页语言按钮行（MeloX utilityHeight = 62）
    static let utilityHeight: CGFloat = 62
    /// 核心控制区：52 + 19 + 82 + 31 + 42 + 3 + 50 = 279
    static let coreHeight: CGFloat = 279
    /// 底部覆盖层总高度（62 + 279）
    static let overlayHeight: CGFloat = utilityHeight + coreHeight
    /// 歌词页顶部 72pt 歌曲头
    static let songHeaderHeight: CGFloat = 72
    /// 歌词焦点行位于视口 25% 处
    static let lyricFocusPosition: CGFloat = 0.25
}

private extension Animation {
    /// MeloX `.smooth(duration:)`；iOS 17 以下回退到系统缓动。
    static func meloSmooth(_ duration: Double) -> Animation {
        if #available(iOS 17.0, *) {
            return .smooth(duration: duration)
        }
        return .easeInOut(duration: duration)
    }
}

/// Apple Music / MeloX 风格全屏播放器（1:1 复刻 MeloX NowPlayingView 26）：
/// - 顶部 60×5 收起胶囊（高 34，点击收起）
/// - 封面页：封面尺寸 min(宽-48, max(170, 页高-279-92))、暂停缩至 0.74、切歌回弹 1.055
/// - 歌词页：72pt 歌曲头 + 34pt heavy 大字歌词（焦点位于 25%、行距 28、远处模糊）
/// - 队列页：共享歌曲头 + 内嵌队列
/// - 底部：62pt 语言按钮 + 52/19/82/31/42/3/50 的核心控制（279）
/// - 页面切换：封面页 -300 位移、歌词 0.07s 延迟淡入、队列 0.34/0.11 延迟；界面 5 秒自动隐藏，
///   各层按 180/165/148/128 位移、语言按钮 64 + 0.82 缩放
struct ReferencePlaybackView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// 封面页大封面在页面坐标系中的位置（用于跨页封面变形动画）
    @State private var artworkPageFrame: CGRect = .zero
    @State private var isPageTransitioning = false
    /// 歌词页界面显隐（MeloX showsLyricsControls）
    @State private var chromeVisible = true
    /// 翻译显示（MeloX lyricsTranslationEnabled，默认开启）
    @State private var showTranslations = true
    @State private var autoHideTask: Task<Void, Never>?
    @State private var lastAutoHideSchedule = Date.distantPast

    private func layoutEntry(_ part: AppleMusicLayoutPart) -> PlayerLayoutEntry {
        appleLayout.entry(for: part)
    }

    private var hasTranslations: Bool {
        lyrics.contains { ($0.translation?.isEmpty == false) }
    }

    /// 仅歌词页会隐藏界面；其他页始终可见。
    private var interfaceVisible: Bool {
        page != 1 || chromeVisible
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                playerBackground

                VStack(spacing: 0) {
                    dismissalHandle

                    ZStack(alignment: .bottom) {
                        pages(size: geometry.size)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        bottomOverlay
                            .frame(height: ReferencePlaybackMetrics.overlayHeight)
                    }
                }
                .padding(.bottom, 3)
                .frame(width: geometry.size.width, height: geometry.size.height)
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
            if page == 1 { scheduleAutoHide() }
        }
        .onChange(of: showLyrics) { value in
            let target = value ? 1 : 0
            guard page != 2, page != target else { return }
            selectPage(target, syncBinding: false)
        }
        .onChange(of: page) { newPage in
            showLyrics = (newPage == 1)
            if newPage != 1 {
                autoHideTask?.cancel()
                if !chromeVisible {
                    withAnimation(interfaceShowAnimation) { chromeVisible = true }
                }
            } else {
                revealChrome()
            }
        }
        .task(id: song?.identityKey) {
            await animateArtworkBounce()
        }
        .onDisappear {
            resumeTask?.cancel()
            autoHideTask?.cancel()
        }
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
                // MeloX 默认 appleMusicBackdrop：封面模糊 + 旋流 + 微光 + 底部黑色渐变
                NowPlayingBackdrop(url: song?.coverURL, isBehindLyrics: page == 1)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - 顶部胶囊（MeloX dismissalHandle：60×5，顶部 8，高 34）

    private var dismissalHandle: some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(.white.opacity(0.52))
                .frame(width: 60, height: 5)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: ReferencePlaybackMetrics.handleHeight)
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

    // MARK: - 三页内容

    @ViewBuilder
    private func pages(size: CGSize) -> some View {
        // 页面可用高度 = 全高 - 收起胶囊 - 底部 3pt 安全留白
        let pageHeight = max(1, size.height - ReferencePlaybackMetrics.handleHeight - 3)

        ZStack(alignment: .top) {
            if page == 0 {
                artworkPage(size: size, pageHeight: pageHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .transition(artworkPageTransition)
            } else {
                // 常驻隐藏测量：保证从歌词/队列返回封面页时封面能从 72pt 平滑放大（MeloX 同款）
                artworkPage(size: size, pageHeight: pageHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            // 歌词页与队列页常驻，保证交叉淡入淡出与状态延续（MeloX resident 页面）
            lyricsPage(size: size)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(page == 1 ? 1 : 0)
                .allowsHitTesting(page == 1)
                .animation(lyricsPageAnimation, value: page)

            queuePage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(page == 2 ? 1 : 0)
                .scaleEffect(page == 1 ? 0.90 : 1)
                .allowsHitTesting(page == 2)
                .animation(queuePageAnimation, value: page)

            if page != 0 {
                songHeader
                    .padding(.horizontal, ReferencePlaybackMetrics.horizontal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: ReferencePlaybackMetrics.songHeaderHeight, alignment: .center)
                    .transition(songHeaderTransition)
            }

            // 跨页共用的封面图层：封面页 ↔ 72pt 歌曲头（MeloX portrait artwork overlay）
            artworkOverlay
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: "referencePlayerPages")
        .onPreferenceChange(ReferenceArtworkFrameKey.self) { frame in
            guard !isPageTransitioning, frame.width > 1, frame.height > 1 else { return }
            if abs(frame.midX - artworkPageFrame.midX) > 0.5
                || abs(frame.midY - artworkPageFrame.midY) > 0.5
                || abs(frame.width - artworkPageFrame.width) > 0.5 {
                artworkPageFrame = frame
            }
        }
    }

    // MARK: - 跨页封面（MeloX artworkResize：0.48s smooth）

    private var headerArtworkFrame: CGRect {
        CGRect(
            x: ReferencePlaybackMetrics.horizontal,
            y: 0,
            width: ReferencePlaybackMetrics.songHeaderHeight,
            height: ReferencePlaybackMetrics.songHeaderHeight
        )
    }

    private var artworkTargetFrame: CGRect {
        if page == 0, artworkPageFrame.width > 1 {
            return artworkPageFrame
        }
        return headerArtworkFrame
    }

    @ViewBuilder
    private var artworkOverlay: some View {
        let frame = artworkTargetFrame
        let isOnArtworkPage = page == 0

        if frame.width > 1, artworkPageFrame.width > 1 || !isOnArtworkPage {
            RefPlaybackArtwork(url: song?.coverURL, cornerRadius: 12)
                .frame(width: max(1, frame.width), height: max(1, frame.height))
                .shadow(
                    color: .black.opacity(isOnArtworkPage ? (player.isPlaying ? 0.34 : 0.18) : 0.20),
                    radius: isOnArtworkPage ? (player.isPlaying ? 26 : 14) : 10,
                    y: isOnArtworkPage ? (player.isPlaying ? 15 : 8) : 5
                )
                .scaleEffect(
                    isOnArtworkPage
                        ? (player.isPlaying ? 1 : 0.74) * artworkBounceScale
                        : 1
                )
                .position(x: frame.midX, y: frame.midY)
                .modifier(
                    AppleMusicLayoutTransform(
                        entry: isOnArtworkPage
                            ? layoutEntry(.cover)
                            : PlayerLayoutEntry()
                    )
                )
                .animation(
                    reduceMotion ? nil : Animation.meloSmooth(0.48),
                    value: frame
                )
                .animation(artworkExpansionAnimation, value: player.isPlaying)
        }
    }

    // MARK: - 页面切换动画（MeloX NowPlayingPageTransition）

    private var artworkPageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let incoming = Animation.meloSmooth(0.22).delay(0.07)
        let outgoing = Animation.meloSmooth(0.24)
        return .asymmetric(
            insertion: .offset(y: -300).combined(with: .opacity).animation(incoming),
            removal: .offset(y: -300).combined(with: .opacity).animation(outgoing)
        )
    }

    private var songHeaderTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(y: 40)
                .combined(with: .opacity)
                .animation(.meloSmooth(0.40).delay(0.08)),
            removal: .offset(y: 40)
                .combined(with: .opacity)
                .animation(.meloSmooth(0.24))
        )
    }

    private var lyricsPageAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return page == 1
            ? Animation.meloSmooth(0.22).delay(0.07)
            : Animation.meloSmooth(0.24)
    }

    private var queuePageAnimation: Animation? {
        guard !reduceMotion else { return nil }
        if page == 2 { return Animation.meloSmooth(0.34).delay(0.11) }
        if page == 1 { return Animation.meloSmooth(0.44) }
        return Animation.meloSmooth(0.24)
    }

    private var interfaceShowAnimation: Animation? {
        reduceMotion ? nil : Animation.meloSmooth(0.34)
    }

    private var interfaceHideAnimation: Animation? {
        reduceMotion ? nil : Animation.meloSmooth(0.34)
    }

    private func selectPage(_ target: Int, syncBinding: Bool = true) {
        guard target != page else { return }
        // 歌词与队列之间的直接切换使用 MeloX directAlternate 0.44
        let animation: Animation? = reduceMotion
            ? nil
            : ((page == 1 && target == 2) || (page == 2 && target == 1)
                ? Animation.meloSmooth(0.44)
                : Animation.meloSmooth(0.30))
        withAnimation(animation) {
            page = target
        }
        // 过渡期间不接收封面测量值（避免把 -300 的临时位移记录为最终位置）
        isPageTransitioning = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled else { return }
            isPageTransitioning = false
        }
        if syncBinding {
            showLyrics = (target == 1)
        }
        if target == 1 {
            revealChrome()
        } else {
            autoHideTask?.cancel()
        }
    }

    // MARK: - 封面页（MeloX NowPlayingArtworkPage）

    private func artworkPage(size: CGSize, pageHeight: CGFloat) -> some View {
        // MeloX: min(宽度 + 16, max(170, 页高 - coreHeight - 92))
        // 我们的页面没有额外左右内边距，等价为 min(屏宽 - 48, ...)
        let artworkSize = max(
            1,
            min(
                size.width - ReferencePlaybackMetrics.horizontal * 2 + 16,
                max(170, pageHeight - ReferencePlaybackMetrics.coreHeight - 92)
            )
        )

        return VStack(spacing: 0) {
            Spacer(minLength: 8)

            // 封面由跨页 overlay 绘制（MeloX portrait artwork），这里只负责占位与测量
            Color.clear
                .frame(width: artworkSize, height: artworkSize)
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ReferenceArtworkFrameKey.self,
                            value: geo.frame(in: .named("referencePlayerPages"))
                        )
                    }
                }
                .overlay {
                    // 首次测量完成前用同尺寸封面占位，避免一帧空白
                    if artworkPageFrame.width <= 1 {
                        CoverImage(
                            url: song?.coverURL,
                            size: artworkSize,
                            cornerRadius: 12,
                            emptyHint: player.isBuffering ? "等待开始播放…" : nil
                        )
                    }
                }
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.cover)))

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
            .padding(.horizontal, ReferencePlaybackMetrics.horizontal)
        }
        .padding(.bottom, ReferencePlaybackMetrics.coreHeight)
        .frame(width: size.width, height: pageHeight)
    }

    private var artworkExpansionAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return Animation.meloSmooth(0.48)
    }

    // MARK: - 共享歌曲头（MeloX NowPlayingSongHeader referenceHeight 72）

    private var songHeader: some View {
        HStack(spacing: 12) {
            // 封面由跨页 overlay 绘制
            Color.clear
                .frame(
                    width: ReferencePlaybackMetrics.songHeaderHeight,
                    height: ReferencePlaybackMetrics.songHeaderHeight
                )

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
            .frame(maxWidth: .infinity, alignment: .leading)

            songActionsMenu
        }
        .frame(height: ReferencePlaybackMetrics.songHeaderHeight)
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
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(primaryColor)
                .frame(width: 40, height: 40)
                .background(primaryColor.opacity(0.15), in: Circle())
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

    // MARK: - 歌词页（MeloX NowPlayingLyricsPage + AppleMusicLyricsView）

    private func lyricsPage(size: CGSize) -> some View {
        VStack(spacing: 0) {
            if lyrics.isEmpty {
                emptyLyricsView
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            Color.clear
                                .frame(height: max(40, lyricsViewportHeight * ReferencePlaybackMetrics.lyricFocusPosition))
                            ForEach(lyrics) { line in
                                lyricRow(line, isFocused: line.id == currentVisualLyricID)
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
                            Color.clear
                                .frame(height: max(120, lyricsViewportHeight * 0.72))
                        }
                        .padding(.horizontal, ReferencePlaybackMetrics.horizontal)
                    }
                    .coordinateSpace(name: "referenceLyricsViewport")
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .black, location: 0.07),
                                .init(color: .black, location: 0.86),
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
                        if isDraggingLyrics {
                            updateFocusedLyric(from: centers)
                        }
                    }                    .simultaneousGesture(lyricsDragGesture(proxy: proxy))
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            revealChrome()
                        }
                    )
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                            scrollToPlaybackLyric(proxy: proxy, animated: false)
                        }
                    }
                    .onChange(of: currentPlaybackLyricID) { _ in
                        guard !isDraggingLyrics, page == 1 else { return }
                        focusedLyricID = nil
                        scrollToPlaybackLyric(proxy: proxy, animated: true)
                    }
                }
            }
        }
        .padding(.top, ReferencePlaybackMetrics.songHeaderHeight)
        .padding(.bottom, 12)
        .frame(width: size.width)
    }

    private func lyricRow(_ line: LyricLine, isFocused: Bool) -> some View {
        let distance = lyricDistance(for: line)
        // MeloX AppleMusicLyricsMotionProfile：非焦点行 0.175 透明度、3pt 模糊、0.98 缩放
        let textOpacity = isFocused ? 1.0 : (distance <= 1 ? 0.28 : 0.175)
        let blurRadius: CGFloat = isFocused ? 0 : (distance <= 1 ? 2.4 : 3.2)

        return Button {
            BeansHaptics.tap()
            revealChrome()
            player.seek(to: LyricTiming.seekTime(for: line, userOffset: lyricOffset))
            withAnimation(lyricFocusAnimation) { focusedLyricID = line.id }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(line.text.isEmpty ? " " : line.text)
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(primaryColor.opacity(textOpacity))
                    .blur(radius: blurRadius)
                    .lineSpacing(0)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                if showTranslations, let translation = line.translation, !translation.isEmpty {
                    Text(translation)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(primaryColor.opacity(isFocused ? 0.86 : textOpacity * 0.9))
                        .blur(radius: blurRadius * 0.8)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .scaleEffect(isFocused ? 1.02 : 0.98, anchor: .leading)
        }
        .buttonStyle(.plain)
        .animation(lyricFocusAnimation, value: isFocused)
    }

    private var lyricFocusAnimation: Animation {
        guard !reduceMotion else { return .linear(duration: 0.01) }
        // MeloX AppleMusicLyricsMotionProfile.lineChangeSpring
        return .interpolatingSpring(mass: 1, stiffness: 100, damping: 18)
    }

    private var emptyLyricsView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "quote.bubble")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.42))
            Text("暂无歌词")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { revealChrome() }
    }

    // MARK: - 队列页

    private var queuePage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("播放队列")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primaryColor.opacity(0.56))
                Text("\(player.queue.count) 首")
                    .font(.system(size: 12))
                    .foregroundStyle(primaryColor.opacity(0.40))
                Spacer()
            }
            .padding(.horizontal, ReferencePlaybackMetrics.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 4)

            if player.queue.isEmpty {
                EmptyStateView(icon: "music.note.list", text: "播放队列为空")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(player.queue.enumerated()), id: \.element.identityKey) { index, item in
                            queueRow(item, index: index)
                            Divider().overlay(primaryColor.opacity(0.08))
                        }
                    }
                    .padding(.horizontal, ReferencePlaybackMetrics.horizontal)
                    .padding(.bottom, 24)
                }
            }
        }
        .padding(.top, ReferencePlaybackMetrics.songHeaderHeight + 12)
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

    // MARK: - 底部覆盖层：62pt 语言按钮 + 279pt 核心控制

    private var bottomOverlay: some View {
        VStack(spacing: 0) {
            languageRow
                .frame(height: ReferencePlaybackMetrics.utilityHeight, alignment: .top)

            coreControls
        }
        .frame(height: ReferencePlaybackMetrics.overlayHeight)
        .allowsHitTesting(interfaceVisible || page != 1)
    }

    private var languageRow: some View {
        HStack {
            if hasTranslations {
                Menu {
                    Toggle("显示翻译", isOn: $showTranslations)
                } label: {
                    Image(systemName: "translate")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(showTranslations ? 0.18 : 0.10), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .scaleEffect(languageButtonVisible ? 1 : 0.82)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ReferencePlaybackMetrics.horizontal)
        .opacity(languageButtonVisible ? 1 : 0)
        .offset(y: languageButtonVisible ? 0 : 64)
        .allowsHitTesting(languageButtonVisible)
        .animation(
            reduceMotion ? nil : Animation.meloSmooth(0.24).delay(languageButtonVisible ? 0 : 0.10),
            value: languageButtonVisible
        )
    }

    private var languageButtonVisible: Bool {
        page == 1 && chromeVisible && hasTranslations
    }

    private var coreControls: some View {
        VStack(spacing: 0) {
            interfaceLayer(offset: 180, showDelay: 0.025, hideDelay: 0.075) {
                ReferenceScrubber()
                    .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.progress)))
            }

            Color.clear.frame(height: 19)

            interfaceLayer(offset: 165, showDelay: 0.05, hideDelay: 0.05) {
                transportControls
            }

            Color.clear.frame(height: 31)

            interfaceLayer(offset: 148, showDelay: 0.075, hideDelay: 0.025) {
                ReferenceVolumeControl()
                    .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.volume)))
            }

            Color.clear.frame(height: 3)

            interfaceLayer(offset: 128, showDelay: 0.10, hideDelay: 0) {
                pageSelector
            }
        }
        .padding(.horizontal, ReferencePlaybackMetrics.horizontal)
        .frame(height: ReferencePlaybackMetrics.coreHeight)
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {}
        }
    }

    private func interfaceLayer<Content: View>(
        offset: CGFloat,
        showDelay: Double,
        hideDelay: Double,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let visible = interfaceVisible
        return content()
            .offset(y: visible ? 0 : offset)
            .opacity(visible ? 1 : 0)
            .animation(
                reduceMotion
                    ? nil
                    : Animation.meloSmooth(0.24).delay(visible ? showDelay : hideDelay),
                value: visible
            )
    }

    // MARK: - 传输控制（MeloX 82 高、按钮 64、图标 34/48）

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
            .buttonStyle(ReferenceTransportButtonStyle(diameter: 64, reduceMotion: reduceMotion))
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
            .buttonStyle(ReferenceTransportButtonStyle(diameter: 64, reduceMotion: reduceMotion))
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
            .buttonStyle(ReferenceTransportButtonStyle(diameter: 64, reduceMotion: reduceMotion))
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.next)))

            Spacer(minLength: 0)
        }
        .frame(height: 82)
    }

    // MARK: - 页面选择（MeloX NowPlayingPageSelector：高 50，额外左右 32）

    private var pageSelector: some View {
        HStack {
            pageButton(target: 1, systemImage: "quote.bubble")
            Spacer()
            playModeButton
            Spacer()
            pageButton(target: 2, systemImage: "list.bullet")
        }
        .padding(.horizontal, ReferencePlaybackMetrics.horizontal)
        .foregroundStyle(primaryColor.opacity(0.72))
        .frame(height: 50)
    }

    private func pageButton(target: Int, systemImage: String) -> some View {
        let isSelected = page == target
        return Button {
            BeansHaptics.tap()
            selectPage(isSelected ? 0 : target)
        } label: {
            Image(systemName: systemImage)
                .symbolVariant(isSelected ? .fill : .none)
                .font(.title3)
                .foregroundStyle(isSelected ? Color.black.opacity(0.68) : primaryColor.opacity(0.72))
                .frame(width: 44, height: 44)
                .background(
                    isSelected ? Color.white.opacity(0.68) : Color.clear,
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var playModeButton: some View {
        Button {
            BeansHaptics.tap()
            player.togglePlayMode()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: player.playMode.icon)
                    .font(.title3)
                    .foregroundStyle(primaryColor.opacity(0.72))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())

                if player.playMode != .sequential {
                    Circle()
                        .fill(Color.white.opacity(0.82))
                        .frame(width: 7, height: 7)
                        .offset(x: -4, y: 4)
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.playMode.title)
    }

    // MARK: - 界面自动隐藏（MeloX：歌词页 5 秒无操作隐藏，滚动/点击唤起）

    private func revealChrome() {
        guard page == 1 else { return }
        if !chromeVisible {
            withAnimation(interfaceShowAnimation) { chromeVisible = true }
            scheduleAutoHide()
            lastAutoHideSchedule = Date()
            return
        }
        // 拖动/点击会高频触发，节流避免反复重建隐藏任务
        let now = Date()
        guard now.timeIntervalSince(lastAutoHideSchedule) > 0.8 else { return }
        lastAutoHideSchedule = now
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        guard page == 1 else { return }
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, page == 1, chromeVisible else { return }
            withAnimation(interfaceHideAnimation) { chromeVisible = false }
        }
    }

    private func hideChrome() {
        guard page == 1, chromeVisible else { return }
        autoHideTask?.cancel()
        withAnimation(interfaceHideAnimation) { chromeVisible = false }
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
        isDraggingLyrics
            ? (focusedLyricID ?? currentPlaybackLyricID)
            : currentPlaybackLyricID
    }

    private func lyricDistance(for line: LyricLine) -> Int {
        guard let centerID = currentVisualLyricID,
              let centerIndex = lyrics.firstIndex(where: { $0.id == centerID }),
              let index = lyrics.firstIndex(where: { $0.id == line.id }) else { return 3 }
        return abs(index - centerIndex)
    }

    private var subtitle: String {
        guard let song else { return "" }
        let parts = [song.artists, song.album].filter { !$0.isEmpty }
        return parts.isEmpty ? "未知歌曲" : parts.joined(separator: " · ")
    }

    private func updateFocusedLyric(from centers: [UUID: CGFloat]) {
        guard lyricsViewportHeight > 0, !centers.isEmpty else { return }
        let focusY = lyricsViewportHeight * ReferencePlaybackMetrics.lyricFocusPosition
        focusedLyricID = centers.min { abs($0.value - focusY) < abs($1.value - focusY) }?.key
    }

    private var lyricScrollAnchor: UnitPoint {
        UnitPoint(x: 0.5, y: ReferencePlaybackMetrics.lyricFocusPosition)
    }

    private func scrollToPlaybackLyric(proxy: ScrollViewProxy, animated: Bool) {
        guard let id = currentPlaybackLyricID else { return }
        let action = { proxy.scrollTo(id, anchor: lyricScrollAnchor) }
        if animated {
            withAnimation(lyricFocusAnimation) { action() }
        } else {
            action()
        }
    }

    private func lyricsDragGesture(proxy: ScrollViewProxy) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard page == 1 else { return }
                isDraggingLyrics = true
                resumeTask?.cancel()
                updateFocusedLyric(from: lyricCenters)
                // MeloX：向上滚动隐藏界面，向下滚动唤出
                if value.translation.height < -28 {
                    hideChrome()
                } else if value.translation.height > 28 {
                    revealChrome()
                }
            }
            .onEnded { _ in
                resumeTask?.cancel()
                if let id = focusedLyricID {
                    withAnimation(lyricFocusAnimation) {
                        proxy.scrollTo(id, anchor: lyricScrollAnchor)
                    }
                }
                resumeTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    guard !Task.isCancelled else { return }
                    // 恢复跟随播放：焦点回到当前播放行（MeloX auto-follow）
                    isDraggingLyrics = false
                    focusedLyricID = nil
                    scrollToPlaybackLyric(proxy: proxy, animated: true)
                }
            }
    }

    // MARK: - 切歌封面弹跳（MeloX animateArtworkBounce：1.055 / 170ms → spring 0.42, bounce 0.24）

    private func animateArtworkBounce() async {
        artworkBounceScale = 1
        guard !reduceMotion, player.isPlaying else { return }
        await Task.yield()
        withAnimation(.easeOut(duration: 0.17)) { artworkBounceScale = 1.055 }
        try? await Task.sleep(nanoseconds: 170_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(artworkSettleAnimation) { artworkBounceScale = 1 }
    }

    private var artworkSettleAnimation: Animation {
        if #available(iOS 17.0, *) {
            return .spring(duration: 0.42, bounce: 0.24)
        }
        return .spring(response: 0.42, dampingFraction: 0.82)
    }

    // MARK: - 颜色

    private var primaryColor: Color {
        if primaryHex.hasPrefix("#"), let color = Color(hex: primaryHex) { return color }
        return .white
    }

    private var secondaryColor: Color {
        if secondaryHex.hasPrefix("#"), let color = Color(hex: secondaryHex) { return color }
        return .white.opacity(0.64)
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

// MARK: - 传输按钮按压效果（MeloX NowPlayingTransportButtonStyle）

private struct ReferenceTransportButtonStyle: ButtonStyle {
    var diameter: CGFloat = 64
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        ReferenceTransportButtonBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            diameter: diameter,
            reduceMotion: reduceMotion
        )
    }
}

private struct ReferenceTransportButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let diameter: CGFloat
    let reduceMotion: Bool

    @State private var iconScale: CGFloat = 1
    @State private var highlightScale: CGFloat = 0.86
    @State private var highlightOpacity: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.10))
                .frame(width: diameter, height: diameter)
                .scaleEffect(highlightScale)
                .opacity(highlightOpacity)

            label
                .scaleEffect(iconScale)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .onAppear {
            apply(isPressed, animated: false)
        }
        .onChange(of: isPressed) { pressed in
            apply(pressed, animated: true)
        }
    }

    private func apply(_ pressed: Bool, animated: Bool) {
        guard animated, !reduceMotion else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                iconScale = pressed && !reduceMotion ? 0.8 : 1
                highlightScale = pressed ? 0.86 : 1
                highlightOpacity = pressed ? 1 : 0
            }
            return
        }

        if pressed {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                highlightScale = 0.86
            }
            withAnimation(.easeInOut(duration: 0.16)) {
                iconScale = 0.8
                highlightOpacity = 1
            }
        } else {
            withAnimation(.easeInOut(duration: 0.40)) { iconScale = 1 }
            withAnimation(.easeOut(duration: 0.18)) { highlightScale = 1 }
            withAnimation(.easeIn(duration: 0.40)) { highlightOpacity = 0 }
        }
    }
}

// MARK: - 进度条（MeloX NowPlayingProgressControl：52 高、无滑块圆点、时间 + 音质胶囊）

private struct ReferenceScrubber: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @ObservedObject private var networkQuality = NetworkQualityStore.shared
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        VStack(spacing: 2) {
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
            HStack {
                Text(beansTimeString(elapsed))
                Spacer(minLength: 4)
                Text("−" + beansTimeString(max(total - elapsed, 0)))
            }
            .overlay {
                qualityCapsule
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
        }
        .frame(height: 52)
    }

    private var qualityCapsule: some View {
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
            HStack(spacing: 5) {
                Image(systemName: "waveform")
                    .font(.system(size: 9, weight: .semibold))
                Text(networkQuality.resolvedQuality.displayName)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tint(.white)
    }
}

// MARK: - 音量（MeloX NowPlayingVolumeControl：高 42，系统音量条）

private struct ReferenceVolumeControl: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11))
            ReferenceSystemVolumeView()
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .layoutPriority(1)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12))
        }
        .foregroundStyle(.white.opacity(0.62))
        .frame(height: 42)
    }
}

private final class ReferenceAlignedVolumeView: MPVolumeView {
    override func volumeSliderRect(forBounds bounds: CGRect) -> CGRect {
        bounds
    }
}

private struct ReferenceSystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> ReferenceAlignedVolumeView {
        let view = ReferenceAlignedVolumeView(frame: CGRect(x: 0, y: 0, width: 200, height: 32))
        view.backgroundColor = .clear
        view.showsVolumeSlider = true
        view.showsRouteButton = false
        view.tintColor = .white
        return view
    }

    func updateUIView(_ uiView: ReferenceAlignedVolumeView, context: Context) {
        uiView.showsVolumeSlider = true
        uiView.tintColor = .white
    }
}

// MARK: - 跨页封面视图（MeloX ArtworkImage 的等价实现，可自由缩放）

private struct RefPlaybackArtwork: View {
    let url: URL?
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.beansGlassFill)
            .overlay {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        if url == nil {
                            placeholder
                        } else {
                            ZStack {
                                placeholder
                                ProgressView()
                                    .tint(.white.opacity(0.75))
                            }
                        }
                    @unknown default:
                        placeholder
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.beansGlassFill)
            Image(systemName: "waveform")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}
