import ImageIO
import SwiftUI
import UIKit

struct DecodedReviewImage: @unchecked Sendable {
    let image: CGImage
}

enum ReviewImageDecoder {
    nonisolated static func read(_ url: URL) throws -> DecodedReviewImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CaptureError.photoDataUnavailable }
        try Task.checkCancellation()
        // Full source dimensions: ImageIO only applies EXIF orientation here.
        return DecodedReviewImage(image: image)
    }
}

/// UIKit supplies native pinch, pan, bouncing, double-tap and zoom anchoring.
/// The thumbnail appears immediately; decoding the source never blocks UI.
struct ZoomableReviewImage: UIViewRepresentable {
    var preview: UIImage
    var url: URL?
    var pixelSize: CGSize?

    func makeUIView(context: Context) -> ReviewImageHost {
        let view = ReviewImageHost()
        view.configure(preview: preview, url: url, pixelSize: pixelSize)
        return view
    }

    func updateUIView(_ view: ReviewImageHost, context: Context) {
        view.configure(preview: preview, url: url, pixelSize: pixelSize)
    }

    static func dismantleUIView(_ view: ReviewImageHost, coordinator: ()) { view.cancelLoading() }
}

final class ReviewImageHost: UIView, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    let imageView = UIImageView()
    private let loading = UIActivityIndicatorView(style: .medium)
    private let failure = UILabel()
    private var loadTask: Task<Void, Never>?
    private var sourceURL: URL?
    private var imageSize = CGSize.zero
    private var lastViewport = CGSize.zero
    private var isLoading = false
    private(set) var hasFullResolutionImage = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = true
        imageView.contentMode = .scaleToFill
        scrollView.addSubview(imageView)
        addSubview(scrollView)
        loading.hidesWhenStopped = true
        addSubview(loading)
        failure.font = .preferredFont(forTextStyle: .footnote)
        failure.adjustsFontForContentSizeCategory = true
        failure.textColor = .secondaryLabel
        failure.textAlignment = .center
        failure.numberOfLines = 0
        failure.isHidden = true
        failure.text = Locale.current.captureLanguageIsFrench ? "Détails de l’image indisponibles" : "Image details unavailable"
        addSubview(failure)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(zoomAtTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = Locale.current.captureLanguageIsFrench ? "Photo finale" : "Final photo"
        imageView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: Locale.current.captureLanguageIsFrench ? "Afficher les détails" : "Show details",
                target: self, selector: #selector(showDetails)),
            UIAccessibilityCustomAction(name: Locale.current.captureLanguageIsFrench ? "Afficher toute la photo" : "Show whole photo",
                target: self, selector: #selector(showWholePhoto))
        ]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(preview: UIImage, url: URL?, pixelSize: CGSize?) {
        guard sourceURL != url || imageView.image == nil else { return }
        cancelLoading()
        sourceURL = url
        hasFullResolutionImage = false
        failure.isHidden = true
        imageSize = pixelSize ?? preview.size
        imageView.image = preview
        scrollView.setZoomScale(1, animated: false)
        imageView.frame = CGRect(origin: .zero, size: imageSize)
        scrollView.contentSize = imageSize
        lastViewport = .zero
        setNeedsLayout()
        guard let url else { return }
        isLoading = true
        loadTask = Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) {
                Result { try ReviewImageDecoder.read(url) }
            }.value
            guard !Task.isCancelled, let self, self.sourceURL == url else { return }
            self.isLoading = false
            self.loading.stopAnimating()
            switch decoded {
            case .success(let result):
                self.imageView.image = UIImage(cgImage: result.image)
                self.hasFullResolutionImage = true
            case .failure:
                self.failure.isHidden = false
            }
            self.loadTask = nil
        }
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        loading.stopAnimating()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        loading.center = CGPoint(x: bounds.midX, y: bounds.maxY - 24)
        failure.frame = CGRect(x: 12, y: max(0, bounds.height - 48), width: max(0, bounds.width - 24), height: 44)
        guard bounds.width > 0, bounds.height > 0, imageSize.width > 0, imageSize.height > 0 else { return }
        guard lastViewport != bounds.size else { return }
        let wasFit = lastViewport == .zero || abs(scrollView.zoomScale - scrollView.minimumZoomScale) < 0.001
        let relativeZoom = scrollView.zoomScale / max(scrollView.minimumZoomScale, 1e-8)
        let center = scrollView.convert(CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: imageView)
        scrollView.frame = bounds
        let fit = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        scrollView.minimumZoomScale = fit
        // One image pixel per screen pixel is always reachable, even for a
        // large file. Extra magnification remains available for inspection.
        scrollView.maximumZoomScale = max(1, fit * 4)
        scrollView.setZoomScale(wasFit ? fit : min(scrollView.maximumZoomScale, relativeZoom * fit), animated: false)
        if !wasFit {
            let point = imageView.convert(center, to: scrollView)
            scrollView.contentOffset = CGPoint(x: point.x - bounds.width / 2, y: point.y - bounds.height / 2)
        }
        lastViewport = bounds.size
        centerImage()
        let inset = scrollView.contentInset
        scrollView.contentOffset = CGPoint(
            x: min(max(scrollView.contentOffset.x, -inset.left), max(-inset.left, scrollView.contentSize.width - bounds.width + inset.right)),
            y: min(max(scrollView.contentOffset.y, -inset.top), max(-inset.top, scrollView.contentSize.height - bounds.height + inset.bottom)))
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        if isLoading, scrollView.zoomScale > scrollView.minimumZoomScale * 1.5 { loading.startAnimating() }
        else { loading.stopAnimating() }
    }

    private func centerImage() {
        scrollView.contentInset = UIEdgeInsets(
            top: max(0, (bounds.height - scrollView.contentSize.height) / 2), left: max(0, (bounds.width - scrollView.contentSize.width) / 2),
            bottom: max(0, (bounds.height - scrollView.contentSize.height) / 2), right: max(0, (bounds.width - scrollView.contentSize.width) / 2))
    }

    @objc private func zoomAtTap(_ recognizer: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale * 1.05 { _ = showWholePhoto(); return }
        let scale = max(scrollView.minimumZoomScale * 2, 1 / max(1, window?.screen.scale ?? traitCollection.displayScale))
        let point = recognizer.location(in: imageView)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                  width: size.width, height: size.height), animated: true)
    }

    @objc private func showDetails() -> Bool {
        scrollView.setZoomScale(max(scrollView.minimumZoomScale * 2,
                                   1 / max(1, window?.screen.scale ?? traitCollection.displayScale)), animated: true)
        return true
    }

    @objc private func showWholePhoto() -> Bool {
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        return true
    }
}
