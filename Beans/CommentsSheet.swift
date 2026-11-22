import SwiftUI

// MARK: - 相对时间

func beansRelativeTime(_ date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    if interval < 60 { return NSLocalizedString("刚刚", comment: "") }
    if interval < 3600 { return String(format: NSLocalizedString("%d 分钟前", comment: ""), Int(interval / 60)) }
    if interval < 86400 { return String(format: NSLocalizedString("%d 小时前", comment: ""), Int(interval / 3600)) }
    if interval < 86400 * 30 { return String(format: NSLocalizedString("%d 天前", comment: ""), Int(interval / 86400)) }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private func beansCommentCountText(songName: String, platform: String? = nil, count: Int) -> String {
    if let platform {
        return String(format: NSLocalizedString("《%@》 · %@ %d 条评论", comment: ""), songName, NSLocalizedString(platform, comment: ""), count)
    }
    return String(format: NSLocalizedString("《%@》 · 共 %d 条评论", comment: ""), songName, count)
}

// MARK: - 评论区

struct CommentsSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    let song: Song

    @State private var qqComments: [SongComment] = []
    @State private var qqTotal = 0
    @State private var qqPageNum = 0
    @State private var loading = true
    @State private var errorMessage: String?

    private let limit = 30
    /// QQ 音乐每页条数（接口单页上限 25）
    private let qqPageSize = 25

    var body: some View {
        let _ = theme.accent
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            BeansNavigationStack {
                Group {
                    if loading {
                        LoadingStateView()
                    } else if let errorMessage {
                        ErrorStateView(message: errorMessage) {
                            Task { await load(reset: true) }
                        }
                    } else {
                        qqCommentList
                    }
                }
                .navigationTitle("评论")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        if reset {
            qqComments = []
            qqTotal = 0
            qqPageNum = 0
            loading = true
        }
        errorMessage = nil
        do {
            let result = try await QQMusicAPI.shared.comments(songID: song.id, limit: qqPageSize, pagenum: qqPageNum)
            if reset {
                qqComments = result.comments
            } else {
                qqComments.append(contentsOf: result.comments)
            }
            qqTotal = result.total
            loading = false
        } catch {
            errorMessage = error.localizedDescription
            loading = false
        }
    }

    /// QQ 音乐评论列表（分页加载更多）
    private var qqCommentList: some View {
        Group {
            if qqComments.isEmpty {
                EmptyStateView(icon: "bubble.left", text: "暂无评论")
            } else {
                List {
                    Section {
                        Text(beansCommentCountText(songName: song.name, platform: "QQ 音乐", count: qqTotal > 0 ? qqTotal : qqComments.count))
                            .font(BeansFont.appFont(12))
                            .foregroundStyle(Color.beansComment)
                    }
                    .listRowBackground(Color.clear)
                    Section("评论") {
                        ForEach(qqComments) { comment in
                            CommentRow(comment: comment)
                                .listRowBackground(Color.clear)
                        }
                    }
                    if qqTotal <= 0 || qqComments.count < qqTotal {
                        Section {
                            Button {
                                Task { await loadQQMore() }
                            } label: {
                                Text("加载更多")
                                    .font(BeansFont.appFont(14, .semibold))
                                    .foregroundStyle(Color.beansAmber)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .beansScrollContentBackgroundHidden()
            }
        }
    }

    /// QQ 评论翻页
    private func loadQQMore() async {
        qqPageNum += 1
        await load(reset: false)
    }

}

// MARK: - 评论行

struct CommentRow: View {
    @EnvironmentObject private var theme: ThemeStore
    let comment: SongComment

    var body: some View {
        let _ = theme.accent
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: comment.avatarURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.beansComment)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            .background(Color.beansGlassFill, in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(comment.nickname)
                        .font(BeansFont.appFont(13, .medium))
                        .foregroundStyle(Color.beansComment)
                        .lineLimit(1)
                    if comment.isHot {
                        Text("热评")
                            .font(BeansFont.appFont(9, .bold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(LinearGradient.beansAccent, in: Capsule())
                    }
                    Spacer()
                    Text(beansRelativeTime(comment.time))
                        .font(BeansFont.appFont(11))
                        .foregroundStyle(Color.beansComment.opacity(0.8))
                }
                Text(comment.content)
                    .font(BeansFont.appFont(14))
                    .foregroundStyle(Color.beansLabel)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Label("\(comment.likedCount)", systemImage: "heart")
                        .font(BeansFont.appFont(11, .medium))
                        .foregroundStyle(Color.beansComment)
                        .labelStyle(.trailingIcon)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }
}

// 图标在文字后面
extension LabelStyle where Self == TrailingIconLabelStyle {
    static var trailingIcon: TrailingIconLabelStyle { TrailingIconLabelStyle() }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}
