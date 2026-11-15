import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Full-screen look at the photos in the list, the way a photo library
/// does it: swipe sideways for the next photo, pinch or double-tap to zoom,
/// drag to pan, tap to hide the controls, swipe down (or the close button)
/// to leave. With an HDR photo, pressing and holding shows the SDR base
/// image, like on the card; the hold never zooms, pages or dismisses, and
/// a tap never compares.
///
/// It opens on the photo the card was showing, with the images the card
/// already decoded, so the first page costs no second decode.
struct PhotoViewer: View {
    typealias PreviewImage = PreviewCard.PreviewImage

    let items: [PhotoItem]
    /// The card's decoded images for the photo the viewer opens on.
    let opening: Loaded?

    struct Loaded {
        var image: PreviewImage
        /// The SDR rendition for the hold; `nil` when there is no HDR to compare.
        var sdrImage: PreviewImage?
        /// Whether `image` should be drawn with HDR headroom.
        var isHDR: Bool
    }

    @Environment(\.dismiss) private var dismiss
    private let start: PhotoItem.ID
    @State private var current: PhotoItem.ID
    @State private var controlsHidden = false
    /// The page the scroll view has settled on (iOS).
    @State private var settled: PhotoItem.ID?
    /// Set once the scroll view has jumped to the opening photo.
    @State private var positioned = false

    init(items: [PhotoItem], start: PhotoItem.ID, opening: Loaded?) {
        self.items = items
        self.opening = opening
        self.start = start
        _current = State(initialValue: start)
    }

    private var index: Int { items.firstIndex { $0.id == current } ?? 0 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pages.ignoresSafeArea()
            controls
        }
        #if os(iOS)
        .statusBarHidden(controlsHidden)
        .persistentSystemOverlays(controlsHidden ? .hidden : .automatic)
        #else
        .frame(minWidth: 900, idealWidth: 1200, minHeight: 640, idealHeight: 800)
        #endif
    }

    private func page(_ item: PhotoItem) -> some View {
        ViewerPage(item: item, isCurrent: item.id == current,
                   preloaded: item.id == start ? opening : nil,
                   controlsHidden: controlsHidden,
                   onTap: { withAnimation(.easeInOut(duration: 0.15)) { controlsHidden.toggle() } },
                   onDismiss: { dismiss() })
    }

    @ViewBuilder
    private var pages: some View {
        #if os(iOS)
        // A paging scroll view rather than a page-style TabView: the
        // TabView keeps its pages inside the safe area, which on a phone
        // with a side status area leaves the next photo showing at the edge.
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { item in
                        page(item)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $settled)
            .onChange(of: settled) { _, id in
                // Before the jump to the opening photo the scroll view
                // reports its first page; that is not a swipe.
                if positioned, let id { current = id }
            }
            .onAppear {
                proxy.scrollTo(start, anchor: .center)
                DispatchQueue.main.async { positioned = true }
            }
        }
        #else
        if let item = items.first(where: { $0.id == current }) {
            page(item).id(item.id)
        }
        #endif
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard items.indices.contains(next) else { return }
        current = items[next].id
    }

    private var controls: some View {
        VStack {
            ZStack {
                // Name and position, centred; the corners stay clear for
                // the close button and, on some phones, the status area.
                VStack(spacing: 2) {
                    Text(items.indices.contains(index) ? items[index].sourceName : "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                    if items.count > 1 {
                        Text(verbatim: "\(index + 1) / \(items.count)")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.horizontal, 52)
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
            }
            Spacer()
            #if os(macOS)
            // No swipe on a Mac: arrows, also on the arrow keys.
            if items.count > 1 {
                HStack {
                    Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .disabled(index == 0)
                    Spacer()
                    Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .disabled(index >= items.count - 1)
                }
                .buttonStyle(.plain)
                .background(.clear)
            }
            #endif
        }
        .padding(16)
        .environment(\.colorScheme, .dark)
        .opacity(controlsHidden ? 0 : 1)
        .allowsHitTesting(!controlsHidden)
    }
}

/// One photo. Only the page on screen holds full-size images (a 50 MP
/// photo is some 200 MB decoded, twice with its SDR rendition); its
/// neighbours show the list thumbnail until they are swiped to.
private struct ViewerPage: View {
    let item: PhotoItem
    let isCurrent: Bool
    let preloaded: PhotoViewer.Loaded?
    let controlsHidden: Bool
    let onTap: () -> Void
    let onDismiss: () -> Void

    @State private var loaded: PhotoViewer.Loaded?
    @State private var showSDR = false

    private var canCompare: Bool { loaded?.isHDR == true && loaded?.sdrImage != nil }

    var body: some View {
        ZStack {
            if let loaded {
                let shown = showSDR ? (loaded.sdrImage ?? loaded.image) : loaded.image
                #if os(iOS)
                ZoomScroll(image: shown, highDynamicRange: loaded.isHDR && !showSDR,
                           onTap: onTap,
                           onHold: { holding in if canCompare { showSDR = holding } },
                           onDismiss: onDismiss)
                #else
                MacZoomImage(image: shown, highDynamicRange: loaded.isHDR && !showSDR,
                             onHold: { holding in if canCompare { showSDR = holding } })
                #endif
            } else if let thumb = item.thumbnail {
                Image(decorative: thumb, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap() }
            } else {
                ProgressView().tint(.white)
            }
        }
        // Bottom centre: it travels with its photo while paging, and the
        // corners belong to the photo (an OPPO watermark strip ends there).
        .overlay(alignment: .bottom) {
            if canCompare {
                Label {
                    Text(verbatim: showSDR ? "SDR" : "HDR")
                } icon: {
                    Image(systemName: "circle.lefthalf.filled")
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(showSDR ? AnyShapeStyle(.tint) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
                .foregroundStyle(showSDR ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .environment(\.colorScheme, .dark)
                .padding(.bottom, 28)
                .opacity(controlsHidden ? 0 : 1)
                .allowsHitTesting(false)
            }
        }
        .sensoryFeedback(.selection, trigger: showSDR)
        .task(id: isCurrent) {
            showSDR = false
            guard isCurrent else {
                loaded = nil
                return
            }
            if loaded == nil { loaded = preloaded }
            if loaded == nil { loaded = await PreviewCard.load(item) }
        }
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
