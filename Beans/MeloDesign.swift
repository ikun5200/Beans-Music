import SwiftUI
import UIKit

/// MeloX / Apple Music 风格设计规范。
///
/// 视觉基线（参考 MeloX 公开截图与 Apple Music iOS 26）：
/// - 页面纯白 / 纯黑背景，内容直接排版，不使用大面积玻璃卡片
/// - 大标题页头 + 胶囊分类 chips
/// - 卡片 24pt 连续圆角、封面 8~10pt 圆角
/// - 强调色为红色，仅用于选中态、播放按钮、进度
/// - 控件层使用 Liquid Glass（iOS 26 原生 glassEffect），内容层保持克制
/// - 动效使用系统原生 spring，保持流体感
enum MeloDesign {
    // MARK: - 圆角

    /// 大卡片 / 推荐卡
    static let cardRadius: CGFloat = 24
    /// 歌单网格卡
    static let gridRadius: CGFloat = 20
    /// 专辑 / 歌曲封面
    static let coverRadius: CGFloat = 10
    /// 迷你播放器 / 浮动底栏胶囊
    static let barRadius: CGFloat = 26

    // MARK: - 间距

    static let pageHorizontal: CGFloat = 20
    static let sectionSpacing: CGFloat = 28
    static let listRowSpacing: CGFloat = 10

    // MARK: - 字体（跟随系统，MeloX 使用 SF Pro）

    static func pageTitle() -> Font { .system(size: 34, weight: .bold) }
    static func sectionTitle() -> Font { .system(size: 22, weight: .bold) }
    static func rowTitle() -> Font { .system(size: 16, weight: .semibold) }
    static func rowSubtitle() -> Font { .system(size: 12.5, weight: .regular) }
    static func caption() -> Font { .system(size: 11, weight: .medium) }

    // MARK: - 颜色

    /// 页面背景（纯白 / 纯黑）
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : .white
    }

    /// 次级填充（chips 未选中、分段控件底色）
    static func fill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.055)
    }

    /// 列表分隔线
    static func separator(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07)
    }

    /// 强调色（MeloX 红）
    static let accent = Color(red: 0.98, green: 0.18, blue: 0.28)

    /// 次级文字
    static func secondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.58) : Color.black.opacity(0.55)
    }
}
