import UIKit
import UniformTypeIdentifiers

/// Share sheet entry: copies the shared photos into the app-group inbox and
/// tells the user to open XDRemux. No conversion happens here (extension
/// memory limits are far below what an 8K ProXDR decode needs).
///
/// The `public.heic` file representation is requested first: with the share
/// sheet's format option on "Automatic", Photos transcodes `public.image`
/// requests to JPEG, which would drop the ProXDR container this app exists
/// to convert. Ported from the Flutter runner's `ShareViewController`, minus
/// the receive_sharing_intent manifest contract (plan §3 P3).
final class ShareViewController: UIViewController {
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.font = .preferredFont(forTextStyle: .body)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = String(localized: "正在交给 XDRemux…")
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
        spinner.startAnimating()
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        })
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await process() }
    }

    private func process() async {
        let attachments = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []
        guard let inbox = SharedInbox.directory else {
            finish(String(localized: "无法访问共享收件箱。"))
            return
        }
        var accepted = 0
        var skipped = 0
        for attachment in attachments {
            if await copy(attachment, into: inbox) { accepted += 1 } else { skipped += 1 }
        }
        spinner.stopAnimating()
        let summary: String
        if accepted == 0 {
            summary = String(localized: "没有可用的 HEIC / JPEG 照片。")
        } else if skipped == 0 {
            summary = String(localized: "已加入 XDRemux：\(accepted) 张。打开 XDRemux 继续转换。")
        } else {
            summary = String(localized: "已加入 XDRemux：\(accepted) 张，跳过 \(skipped) 张非 HEIC / JPEG 文件。打开 XDRemux 继续转换。")
        }
        finish(summary)
    }

    /// Copies one attachment into the inbox. The provider-owned file is only
    /// valid inside the load callback, so the copy happens there.
    private func copy(_ attachment: NSItemProvider, into inbox: URL) async -> Bool {
        let candidates: [(UTType, String?)] = [(.heic, "heic"), (.heif, "heif"), (.jpeg, "jpg"), (.image, nil), (.fileURL, nil)]
        guard let (type, ext) = candidates.first(where: { attachment.hasItemConformingToTypeIdentifier($0.0.identifier) }) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            attachment.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { continuation.resume(returning: false); return }
                let lower = url.pathExtension.lowercased()
                guard ["heic", "heif", "jpg", "jpeg"].contains(lower) || ext != nil else {
                    continuation.resume(returning: false); return
                }
                var name = url.lastPathComponent
                if name.isEmpty { name = UUID().uuidString + "." + (ext ?? "dat") }
                else if let ext, lower != ext, !(ext == "jpg" && lower == "jpeg") {
                    // Photos may hand the original over with a generic name;
                    // keep the extension honest for the host's sniffing.
                    name = (name as NSString).deletingPathExtension + "." + ext
                }
                do {
                    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
                    let destination = SharedInbox.uniqueURL(inbox.appendingPathComponent(name))
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func finish(_ message: String) {
        label.text = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }
}
