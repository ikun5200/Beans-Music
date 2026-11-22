import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Apple Music 26 / MeloX 默认播放页背景（appleMusicBackdrop）：
///
/// 图层顺序（参考 MeloX NowPlayingAppleMusicBackground）：
/// 1. 深灰底色（封面未加载时不露底）
/// 2. 封面放大铺满 + 80pt 高斯模糊 + 缓慢旋流（shader rotation 的等价实现）
/// 3. 白色 0.10 微光
/// 4. 底部黑色可读性渐变（0 → 0.4）
/// 5. 深色遮罩（dark 0.5 / light 0.35）
///
/// 全部在 UIKit 图层完成：切歌、模糊、旋转都不触发 SwiftUI 布局，
/// 旋转/呼吸由 Core Animation 合成，几乎零持续 CPU 开销。
struct NowPlayingBackdrop: UIViewRepresentable {
    let url: URL?
    /// 进入歌词页时轻微推近（MeloX pinchMix 的等价效果）
    let isBehindLyrics: Bool

    func makeUIView(context: Context) -> NowPlayingBackdropView {
        let view = NowPlayingBackdropView()
        view.load(url: url)
        view.setLyricsMode(isBehindLyrics, animated: false)
        return view
    }

    func updateUIView(_ uiView: NowPlayingBackdropView, context: Context) {
        uiView.load(url: url)
        uiView.setLyricsMode(isBehindLyrics, animated: true)
    }
}

final class NowPlayingBackdropView: UIView {
    private let rotationView = UIView()
    private let breatheView = UIView()
    private let zoomView = UIView()
    private let imageView = UIImageView()
    private let scrimView = UIView()
    private let glowView = UIView()
    private let gradientHost = UIView()
    private let gradientLayer = CAGradientLayer()

    private var currentURL: URL?
    private var lyricsMode = false

    private static let imageCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 12
        return cache
    }()
    private static let renderQueue = DispatchQueue(label: "beans.nowplaying.backdrop", qos: .utility)
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        backgroundColor = UIColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = false

        scrimView.isUserInteractionEnabled = false
        scrimView.backgroundColor = UIColor.black.withAlphaComponent(0.42)

        glowView.isUserInteractionEnabled = false
        glowView.backgroundColor = UIColor.white.withAlphaComponent(0.10)

        gradientHost.isUserInteractionEnabled = false
        gradientLayer.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.40).cgColor
        ]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.18)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        gradientHost.layer.addSublayer(gradientLayer)

        addSubview(rotationView)
        rotationView.addSubview(breatheView)
        breatheView.addSubview(zoomView)
        zoomView.addSubview(imageView)
        addSubview(glowView)
        addSubview(gradientHost)
        addSubview(scrimView)

        startAmbientAnimations()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 旋转容器比屏幕大 90%，保证任意角度都不露边
        let overscan = bounds.insetBy(dx: -bounds.width * 0.45, dy: -bounds.height * 0.45)
        rotationView.frame = overscan
        breatheView.frame = rotationView.bounds
        zoomView.frame = breatheView.bounds
        imageView.frame = zoomView.bounds
        glowView.frame = bounds
        gradientHost.frame = bounds
        gradientLayer.frame = bounds
        scrimView.frame = bounds
    }

    private func startAmbientAnimations() {
        rotationView.layer.removeAnimation(forKey: "beansBackdropRotation")
        breatheView.layer.removeAnimation(forKey: "beansBackdropBreathe")
        rotationView.layer.transform = CATransform3DIdentity
        breatheView.layer.transform = CATransform3DIdentity

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = Double.pi * 2
        rotation.duration = 240
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        rotationView.layer.add(rotation, forKey: "beansBackdropRotation")

        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 1.0
        breathe.toValue = 1.06
        breathe.duration = 18
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breatheView.layer.add(breathe, forKey: "beansBackdropBreathe")
    }

    func setLyricsMode(_ enabled: Bool, animated: Bool) {
        guard lyricsMode != enabled else { return }
        lyricsMode = enabled
        let apply = {
            self.zoomView.transform = enabled
                ? CGAffineTransform(scaleX: 1.10, y: 1.10)
                : .identity
            self.scrimView.backgroundColor = UIColor.black.withAlphaComponent(enabled ? 0.50 : 0.42)
        }
        guard animated else {
            apply()
            return
        }
        UIView.animate(
            withDuration: 0.40,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            apply()
        }
    }

    func load(url: URL?) {
        guard let url else {
            currentURL = nil
            imageView.image = nil
            return
        }
        if currentURL == url { return }
        currentURL = url

        if let cached = Self.imageCache.object(forKey: url as NSURL) {
            setImage(cached, animated: imageView.image != nil)
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let source = UIImage(data: data) else { return }
            Self.renderQueue.async {
                guard let blurred = Self.makeBackdropImage(source) else { return }
                Self.imageCache.setObject(blurred, forKey: url as NSURL)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.currentURL == url else { return }
                    self.setImage(blurred, animated: true)
                }
            }
        }.resume()
    }

    private func setImage(_ image: UIImage, animated: Bool) {
        guard animated, imageView.image != nil else {
            imageView.image = image
            return
        }
        UIView.transition(
            with: imageView,
            duration: 0.5,
            options: [.transitionCrossDissolve, .beginFromCurrentState]
        ) {
            self.imageView.image = image
        }
    }

    /// 缩小 → 高斯模糊 40 → 轻微提亮/增饱和，等价于 Apple Music 的 80pt 实时模糊质感。
    private static func makeBackdropImage(_ source: UIImage) -> UIImage? {
        let target = source.preparingThumbnail(of: CGSize(width: 640, height: 640)) ?? source
        guard let input = CIImage(image: target) else { return target }

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input.clampedToExtent()
        blur.radius = 40
        guard let blurred = blur.outputImage else { return target }

        let controls = CIFilter.colorControls()
        controls.inputImage = blurred
        controls.saturation = 1.18
        controls.brightness = 0.02
        controls.contrast = 1.02

        guard let output = controls.outputImage,
              let cg = ciContext.createCGImage(output, from: input.extent) else {
            return target
        }
        return UIImage(cgImage: cg)
    }
}
