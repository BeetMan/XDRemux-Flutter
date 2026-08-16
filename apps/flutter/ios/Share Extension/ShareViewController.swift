import receive_sharing_intent
import Social
import UniformTypeIdentifiers
import UIKit

/// Share extension controller.
///
/// Replaces RSIShareViewController: the plugin loads image attachments as
/// `public.image`, and when the share sheet's format option is "Automatic"
/// Photos transcodes HEIC originals to JPEG. For XDRemux the whole point is
/// preserving the original HEIC, so this controller requests the
/// `public.heic` file representation first and falls back to the plugin's
/// behavior otherwise. The app-group handoff (container copy + ShareKey
/// manifest + ShareMedia-<bundleId> URL) matches the plugin contract byte
/// for byte.
class ShareViewController: SLComposeServiceViewController {

    private var appGroupId: String = ""
    private var hostAppBundleIdentifier: String = ""
    private var sharedMedia: [SharedMediaFile] = []
    private let pendingCount = NSLock()
    private var pending = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        loadIds()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Transparent ancestors (the system sheet container is opaque).
        var ancestor = view.superview
        while let current = ancestor {
            current.backgroundColor = .clear
            current.isOpaque = false
            ancestor = current.superview
        }
        processSharedContent()
    }

    // MARK: - Content processing

    private func processSharedContent() {
        guard let content = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = content.attachments, !attachments.isEmpty else {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            return
        }
        pendingCount.lock()
        pending = attachments.count
        pendingCount.unlock()
        for attachment in attachments {
            loadAttachment(attachment)
        }
    }

    private func loadAttachment(_ attachment: NSItemProvider) {
        // Prefer the original HEIC representation. When the asset is a HEIC
        // original, Photos hands over the untouched file regardless of the
        // share sheet's "Automatic" format option (the transcoding only
        // applies to public.image requests).
        if attachment.hasItemConformingToTypeIdentifier(UTType.heic.identifier) {
            attachment.loadFileRepresentation(forTypeIdentifier: UTType.heic.identifier) {
                [weak self] url, error in
                guard let self, error == nil, let url else {
                    self?.attachmentFailed()
                    return
                }
                self.handleFile(url, type: .image, preferredExtension: "heic")
            }
            return
        }
        if attachment.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            attachment.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) {
                [weak self] url, error in
                guard let self, error == nil, let url else {
                    self?.attachmentFailed()
                    return
                }
                self.handleFile(url, type: .image, preferredExtension: nil)
            }
            return
        }
        if attachment.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            attachment.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) {
                [weak self] url, error in
                guard let self, error == nil, let url else {
                    self?.attachmentFailed()
                    return
                }
                self.handleFile(url, type: .video, preferredExtension: nil)
            }
            return
        }
        if attachment.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            attachment.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) {
                [weak self] url, error in
                guard let self, error == nil, let url else {
                    self?.attachmentFailed()
                    return
                }
                self.handleFile(url, type: .file, preferredExtension: nil)
            }
            return
        }
        attachmentFailed()
    }

    private func attachmentFailed() {
        // Keep the manifest consistent: skip the attachment but still let
        // the batch finish, so one unreadable item cannot strand the rest.
        completeOneAttachment()
    }

    private func handleFile(_ url: URL, type: SharedMediaType, preferredExtension: String?) {
        // loadFileRepresentation returns a provider-owned file that is only
        // valid inside this callback - copy it into the app group container
        // before leaving the scope.
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            completeOneAttachment()
            return
        }
        var fileName = url.lastPathComponent
        if fileName.isEmpty {
            fileName = UUID().uuidString + "." + (preferredExtension ?? "dat")
        } else if let preferredExtension, url.pathExtension.lowercased() != preferredExtension {
            // Photos sometimes serves the original with a generic name;
            // keep the extension accurate so the host app's sniffing and
            // file_picker filters see .heic.
            fileName = (fileName as NSString).deletingPathExtension + "." + preferredExtension
        }
        let destination = container.appendingPathComponent(fileName)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            let decoded = destination.absoluteString.removingPercentEncoding
                ?? destination.absoluteString
            sharedMedia.append(
                SharedMediaFile(
                    path: decoded,
                    mimeType: mimeType(for: destination, type: type),
                    type: type))
        } catch {
            print("[XDRemux][share] failed to copy shared file: \(error)")
        }
        completeOneAttachment()
    }

    private func completeOneAttachment() {
        pendingCount.lock()
        pending -= 1
        let done = pending <= 0
        pendingCount.unlock()
        if done {
            saveAndRedirect()
        }
    }

    private func mimeType(for url: URL, type: SharedMediaType) -> String? {
        switch url.pathExtension.lowercased() {
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        default:
            return type == .image ? "image/jpeg" : nil
        }
    }

    // MARK: - Handoff (plugin contract)

    private func loadIds() {
        let shareExtensionAppBundleIdentifier = Bundle.main.bundleIdentifier!
        let lastIndexOfPoint = shareExtensionAppBundleIdentifier.lastIndex(of: ".")
        hostAppBundleIdentifier = String(
            shareExtensionAppBundleIdentifier[..<lastIndexOfPoint!])
        let customAppGroupId = Bundle.main.object(
            forInfoDictionaryKey: kAppGroupIdKey) as? String
        appGroupId = customAppGroupId ?? "group.\(hostAppBundleIdentifier)"
    }

    private func saveAndRedirect(message: String? = nil) {
        let userDefaults = UserDefaults(suiteName: appGroupId)
        if let data = try? JSONEncoder().encode(sharedMedia) {
            userDefaults?.set(data, forKey: kUserDefaultsKey)
        }
        userDefaults?.set(message, forKey: kUserDefaultsMessageKey)
        userDefaults?.synchronize()
        redirectToHostApp()
    }

    private func redirectToHostApp() {
        let url = URL(string: "\(kSchemePrefix)-\(hostAppBundleIdentifier):share")
        var responder = self as UIResponder?
        if #available(iOS 18.0, *) {
            while responder != nil {
                if let application = responder as? UIApplication {
                    application.open(url!, options: [:], completionHandler: nil)
                }
                responder = responder?.next
            }
        } else {
            let selectorOpenURL = sel_registerName("openURL:")
            while responder != nil {
                if (responder?.responds(to: selectorOpenURL))! {
                    _ = responder?.perform(selectorOpenURL, with: url)
                }
                responder = responder!.next
            }
        }
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    // MARK: - Compose UI plumbing (unused; we always auto-redirect)

    override func isContentValid() -> Bool { true }

    override func didSelectPost() { saveAndRedirect(message: contentText) }

    override func didSelectCancel() {
        extensionContext?.cancelRequest(withError: NSError(
            domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}
