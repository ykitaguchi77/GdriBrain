import MobileCoreServices
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        Task { @MainActor in
            let payload = await extractPayload()
            let host = UIHostingController(
                rootView: ShareComposeView(
                    initial: payload,
                    onDone: { [weak self] in self?.complete() },
                    onCancel: { [weak self] in self?.cancel() }
                )
            )
            host.modalPresentationStyle = .formSheet
            present(host, animated: true)
        }
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "cancelled", code: 0))
    }

    private func extractPayload() async -> SharePayload {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            return .empty
        }
        for item in items {
            guard let providers = item.attachments else { continue }
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let urlString = await loadString(from: provider, type: UTType.url.identifier) {
                        return .link(url: urlString, title: item.attributedContentText?.string)
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let image = await loadImage(from: provider) {
                        let ocr = (try? await OCR.recognise(image: image)) ?? ""
                        return .screenshot(image: image, ocrText: ocr)
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let text = await loadString(from: provider, type: UTType.plainText.identifier) {
                        return .memo(text: text)
                    }
                }
            }
        }
        return .empty
    }

    private func loadString(from provider: NSItemProvider, type: String) async -> String? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                if let url = item as? URL { cont.resume(returning: url.absoluteString) }
                else if let s = item as? String { cont.resume(returning: s) }
                else { cont.resume(returning: nil) }
            }
        }
    }

    private func loadImage(from provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                if let url = item as? URL, let data = try? Data(contentsOf: url) {
                    cont.resume(returning: UIImage(data: data))
                } else if let data = item as? Data {
                    cont.resume(returning: UIImage(data: data))
                } else if let img = item as? UIImage {
                    cont.resume(returning: img)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}
