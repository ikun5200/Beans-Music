import SwiftUI

/// MeloX 迷你播放器（TabViewBottomAccessory 的等价实现）：
/// - 封面 40pt、圆角 6；标题 subheadline semibold；歌手 caption secondary
/// - 播放/下一首 36pt，图标 title3 semibold
/// - 横向滑动切歌（MeloX trackSwipeGesture）
struct MiniPlayerView: View {
    enum Presentation {
        case dock
        case accessory

        var showsCardSurface: Bool { self == .dock }
    }

    @EnvironmentObject private var player: PlayerManager
    @Binding var showPlayer: Bool
    var presentation: Presentation = .dock
    var transitionNamespace: Namespace.ID?

    private var coverSize: CGFloat { 40 }
    private var controlSize: CGFloat { 36 }
    private var containerRadius: CGFloat { 24 }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                BeansHaptics.tap()
                showPlayer = true
            } label: {
                HStack(spacing: 10) {
                    CoverImage(url: player.currentSong?.coverURL, size: coverSize, cornerRadius: 6)
                        .frame(width: coverSize, height: coverSize)
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                        .transitionSource(in: transitionNamespace)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(player.currentSong?.name ?? "未在播放")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                        Text(player.currentSong?.artists ?? "")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.currentSong?.name ?? "未在播放")
            .accessibilityValue(player.currentSong?.artists ?? "")

            Button {
                BeansHaptics.tap()
                player.togglePlayPause()
            } label: {
                PlayPauseMorphIcon(isPlaying: player.isPlaying, size: 20)
                    .foregroundStyle(Color.primary)
                    .frame(width: controlSize, height: controlSize)
                    .contentShape(Circle())
            }
            .buttonStyle(GlassPressButtonStyle())
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            Button {
                BeansHaptics.tap()
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: controlSize, height: controlSize)
                    .contentShape(Circle())
            }
            .buttonStyle(GlassPressButtonStyle())
            .accessibilityLabel("下一首")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            if presentation.showsCardSurface {
                BeansGlass(
                    shape: RoundedRectangle(cornerRadius: containerRadius, style: .continuous),
                    controlSurface: true,
                    interactive: true
                )
            } else {
                RoundedRectangle(cornerRadius: containerRadius, style: .continuous)
                    .fill(.clear)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: containerRadius, style: .continuous))
        .shadow(color: presentation.showsCardSurface ? .black.opacity(0.10) : .clear, radius: 14, y: 6)
        .scaleEffect(showPlayer ? 0.985 : 1)
        .animation(.beansSnappy, value: showPlayer)
        .simultaneousGesture(trackSwipeGesture)
        .padding(.horizontal, presentation.showsCardSurface ? 14 : 0)
    }

    /// MeloX：左右滑动切换上一首 / 下一首
    private var trackSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 28)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                BeansHaptics.tap()
                if value.translation.width < 0 {
                    player.next()
                } else {
                    player.previous()
                }
            }
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
