import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Full-screen look at the photo the preview card is showing, the way a
/// photo library does it: pinch or double-tap to zoom, drag to pan, tap to
/// hide the controls, swipe down (or the close button) to leave. With an
/// HDR photo, pressing and holding shows the SDR base image, like on the
/// card; the hold never zooms or dismisses, and a tap never compares.
///
/// It takes the images the card already decoded, so opening it costs no
/// second decode and what is on screen matches the card exactly.
struct PhotoViewer: View {
    let image: PreviewCard.PreviewImage
    /// The SDR rendition for the hold; `nil` when there is no HDR to compare.
    let sdrImage: PreviewCard.PreviewImage?
    /// Whether `image` should be drawn with HDR headroom.
    let isHDR: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var showSDR = false
    @State private var controlsHidden = false

    private var canCompare: Bool { isHDR && sdrImage != nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            photo.ignoresSafeArea()
            controls
        }
        .sensoryFeedback(.selection, trigger: showSDR)
        #if os(iOS)
        .statusBarHidden(controlsHidden)
        .persistentSystemOverlays(controlsHidden ? .hidden : .automatic)
        #else
        .frame(minWidth: 900, idealWidth: 1200, minHeight: 640, idealHeight: 800)
        #endif
    }

    @ViewBuilder
    private var photo: some View {
        let shown = showSDR ? (sdrImage ?? image) : image
        #if os(iOS)
        ZoomScroll(image: shown, highDynamicRange: isHDR && !showSDR,
                   onTap: { withAnimation(.easeInOut(duration: 0.15)) { controlsHidden.toggle() } },
                   onHold: { holding in if canCompare { showSDR = holding } },
                   onDismiss: { dismiss() })
        #else
        MacZoomImage(image: shown, highDynamicRange: isHDR && !showSDR,
                     onHold: { holding in if canCompare { showSDR = holding } })
        #endif
    }

    private var controls: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("关闭")
                Spacer()
            }
            Spacer()
            if canCompare {
                HStack {
                    Spacer()
                    Label {
                        Text(verbatim: showSDR ? "SDR" : "HDR")
                    } icon: {
                        Image(systemName: "circle.lefthalf.filled")
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(showSDR ? AnyShapeStyle(.tint) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
                    .foregroundStyle(showSDR ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .allowsHitTesting(false)
                }
            }
        }
        .padding(16)
        .environment(\.colorScheme, .dark)
        .opacity(controlsHidden ? 0 : 1)
        .allowsHitTesting(!controlsHidden)
    }
}

#if os(iOS)
/// A `UIScrollView` around a `UIImageView`: the system's own zooming, with
/// the gestures told apart by their recognisers rather than by timers.
/// Double tap zooms, single tap (which waits for the double tap to fail)
/// toggles the controls, a 0.25 s stationary press is the SDR hold.
private struct ZoomScroll: UIViewRepresentable {
    let image: UIImage
    let highDynamicRange: Bool
    let onTap: () -> Void
    let onHold: (Bool) -> Void
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        apply(to: view)
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: ZoomScrollView) {
        view.onTap = onTap
        view.onHold = onHold
        view.onDismiss = onDismiss
        view.show(image, highDynamicRange: highDynamicRange)
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    var onTap: (() -> Void)?
    var onHold: ((Bool) -> Void)?
    var onDismiss: (() -> Void)?

    private let imageView = UIImageView()
    private var fittedBounds: CGSize = .zero
    private var imageSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        // So a pull at the fitted size has something to pull against.
        alwaysBounceVertical = true
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.25
        addGestureRecognizer(hold)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Swapping HDR for SDR keeps the zoom: both renditions have one size.
    func show(_ image: UIImage, highDynamicRange: Bool) {
        imageView.preferredImageDynamicRange = highDynamicRange ? .high : .standard
        guard imageView.image !== image else { return }
        imageView.image = image
        if image.size != imageSize {
            imageSize = image.size
            fittedBounds = .zero
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != fittedBounds, imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        // First layout, rotation, or a new image: back to the fitted size.
        fittedBounds = bounds.size
        zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: imageSize)
        contentSize = imageSize
        let fit = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        minimumZoomScale = fit
        // Up to one image pixel per point (several screen pixels), and never
        // less than 4× the fitted size for a small image.
        maximumZoomScale = max(fit * 4, 1)
        zoomScale = fit
        centre()
    }

    private var isFitted: Bool { zoomScale <= minimumZoomScale * 1.01 }

    private func centre() {
        let width = imageSize.width * zoomScale, height = imageSize.height * zoomScale
        let x = max((bounds.width - width) / 2, 0), y = max((bounds.height - height) / 2, 0)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centre() }

    /// A downward pull at the fitted size leaves, as in Photos.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard isFitted else { return }
        let pan = panGestureRecognizer
        if pan.translation(in: self).y > 90, pan.velocity(in: self).y >= 0 { onDismiss?() }
    }

    @objc private func singleTapped() { onTap?() }

    @objc private func doubleTapped(_ recogniser: UITapGestureRecognizer) {
        if !isFitted {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let target = min(maximumZoomScale, minimumZoomScale * 2.5)
        let point = recogniser.location(in: imageView)
        let size = CGSize(width: bounds.width / target, height: bounds.height / target)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height), animated: true)
    }

    @objc private func held(_ recogniser: UILongPressGestureRecognizer) {
        switch recogniser.state {
        case .began: onHold?(true)
        case .ended, .cancelled, .failed: onHold?(false)
        default: break
        }
    }
}
#else
/// macOS: pinch on the trackpad or double-click to zoom, drag to pan while
/// zoomed, press and hold for SDR.
private struct MacZoomImage: View {
    let image: CGImage
    let highDynamicRange: Bool
    let onHold: (Bool) -> Void

    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero
    @State private var holdTimer: Task<Void, Never>?

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFit()
            .allowedDynamicRange(highDynamicRange ? .high : .standard)
            .scaleEffect(scale)
            .offset(offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(MagnifyGesture()
                .onChanged { scale = min(max(settledScale * $0.magnification, 1), 8) }
                .onEnded { _ in
                    settledScale = scale
                    if scale == 1 { reset() }
                })
            .simultaneousGesture(DragGesture(minimumDistance: 4)
                .onChanged { value in
                    guard scale > 1 else { return }
                    offset = CGSize(width: settledOffset.width + value.translation.width,
                                    height: settledOffset.height + value.translation.height)
                }
                .onEnded { _ in settledOffset = offset })
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if scale > 1 { reset() } else { scale = 2.5; settledScale = 2.5 }
                }
            }
            .onLongPressGesture(minimumDuration: 3600, maximumDistance: 4) {
            } onPressingChanged: { pressing in
                holdTimer?.cancel()
                holdTimer = nil
                guard pressing else { onHold(false); return }
                holdTimer = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    if !Task.isCancelled { onHold(true) }
                }
            }
    }

    private func reset() {
        scale = 1; settledScale = 1
        offset = .zero; settledOffset = .zero
    }
}
#endif
