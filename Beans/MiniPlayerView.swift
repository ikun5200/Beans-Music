import SwiftUI

struct MiniPlayerView: View {
    enum Presentation {
        case dock
        case accessory

        var showsCardSurface: Bool { self == .dock }
    }

    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @Binding var showPlayer: Bool
    var presentation: Presentation = .dock
    var transitionNamespace: Namespace.ID?
    @State private var miniLyrics: [LyricLine] = []
    @AppStorage("beans.lyricOffset") private var lyricOffset = 0.0
    @AppStorage("beans.uiStyle") private var uiStyleRaw = BeansUIStyle.liquid.rawValue

    private var coverSize: CGFloat { 44 }
    private var controlSize: CGFloat { 34 }
    private var containerRadius: CGFloat { 24 }
    private var verticalPadding: CGFloat { 7 }

    /// 二分查找当前播放到的歌词行（歌词按时间升序）
    private var currentLyricLine: LyricLine? {
        guard !miniLyrics.isEmpty else { return nil }
        var low = 0
        var high = miniLyrics.count - 1
        var answer: LyricLine?
        while low <= high {
            let mid = (low + high) / 2
            if miniLyrics[mid].time <= LyricTiming.effectiveProgress(clock.progress, userOffset: lyricOffset) {
                answer = miniLyrics[mid]
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }

    private var progressFraction: CGFloat {
        guard player.duration > 0 else { return 0 }
        return CGFloat(min(max(clock.progress / player.duration, 0), 1))
    }

    var body: some View {
        let _ = theme.accent
        Button {
            BeansHaptics.tap()
            showPlayer = true
        } label: {
            HStack(spacing: 12) {
                CoverImage(url: player.currentSong?.coverURL, size: coverSize, cornerRadius: 8)
                    .frame(width: coverSize, height: coverSize)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentSong?.name ?? "未在播放")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(currentLyricLine?.text ?? player.currentSong?.artists ?? "")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .animation(.beansSmooth, value: currentLyricLine?.text)
                }
                Spacer(minLength: 8)

                Button {
                    BeansHaptics.tap()
                    player.togglePlayPause()
                } label: {
                    PlayPauseMorphIcon(isPlaying: player.isPlaying, size: 19)
                        .foregroundStyle(Color.primary)
                        .frame(width: controlSize, height: controlSize)
                        .contentShape(Circle())
                }
                .buttonStyle(GlassPressButtonStyle())

                Button {
                    BeansHaptics.tap()
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .frame(width: controlSize, height: controlSize)
                        .contentShape(Circle())
                }
                .buttonStyle(GlassPressButtonStyle())
            }
            .padding(.leading, 9)
            .padding(.trailing, 10)
            .padding(.vertical, verticalPadding)
            .background {
                if presentation.showsCardSurface {
                    BeansGlass(
                        shape: RoundedRectangle(cornerRadius: containerRadius, style: .continuous),
                        controlSurface: true,
                        interactive: true
                    )
                    .overlay(alignment: .bottom) {
                        // MeloX 风格：胶囊底部细进度线
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.08))
                                Capsule()
                                    .fill(MeloDesign.accent)
                                    .frame(width: max(0, geo.size.width * progressFraction))
                            }
                        }
                        .frame(height: 2.5)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 4)
                        .allowsHitTesting(false)
                    }
                } else {
                    RoundedRectangle(cornerRadius: containerRadius, style: .continuous)
                        .fill(.clear)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: containerRadius, style: .continuous))
            .shadow(color: presentation.showsCardSurface ? .black.opacity(0.10) : .clear, radius: 14, y: 6)
            .scaleEffect(showPlayer ? 0.985 : 1)
            .animation(.beansSnappy, value: showPlayer)
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.98))
        .transitionSource(in: transitionNamespace)
        .padding(.horizontal, presentation.showsCardSurface ? 14 : 0)
        .task(id: player.currentSong?.identityKey) {
            await loadMiniLyrics()
        }
    }

    private func loadMiniLyrics() async {
        miniLyrics = []
        guard let song = player.currentSong else { return }
        let identity = song.identityKey
        var raw: String?
        if let mid = song.qqMid {
            raw = try? await QQMusicAPI.shared.lyric(songmid: mid)
        }
        guard let raw else { return }
        guard player.currentSong?.identityKey == identity else { return }
        miniLyrics = LyricParser.parse(raw)
    }
}

enum BeansNowPlayingTransitionID {
    static let surface = "beans-now-playing-surface"
}

private struct BeansTransitionSourceModifier: ViewModifier {
    let namespace: Namespace.ID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace, #available(iOS 18.0, *) {
            content.matchedTransitionSource(
                id: BeansNowPlayingTransitionID.surface,
                in: namespace
            )
        } else {
            content
        }
    }
}

private extension View {
    @ViewBuilder
    func transitionSource(in namespace: Namespace.ID?) -> some View {
        modifier(BeansTransitionSourceModifier(namespace: namespace))
    }
}
