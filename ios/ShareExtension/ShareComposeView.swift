import SwiftUI
import UIKit

struct ShareComposeView: View {
    let initial: SharePayload
    let onDone: () -> Void
    let onCancel: () -> Void

    @State private var note: String = ""
    @State private var tagsText: String = ""
    @State private var ocrText: String = ""
    @State private var imageBase64: String?
    @State private var previewImage: UIImage?
    @State private var urlString: String = ""
    @State private var title: String = ""
    @State private var isEnqueuing = false

    var body: some View {
        NavigationStack {
            Form {
                switch initial {
                case .empty, .memo:
                    Section("Memo") {
                        TextEditor(text: $note).frame(minHeight: 120)
                    }
                case .link:
                    Section("Link") {
                        TextField("URL", text: $urlString)
                        TextField("Title", text: $title)
                        TextField("Note", text: $note, axis: .vertical)
                    }
                case .screenshot:
                    if let image = previewImage {
                        Section("Screenshot") {
                            Image(uiImage: image)
                                .resizable().scaledToFit().frame(maxHeight: 180)
                        }
                    }
                    Section("OCR (on-device)") {
                        TextEditor(text: $ocrText).frame(minHeight: 80)
                    }
                    Section("Note") {
                        TextField("Why you're saving this", text: $note, axis: .vertical)
                    }
                }
                Section("Tags (comma separated)") {
                    TextField("idea, work", text: $tagsText)
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("GdriBrain")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await enqueue() }
                    } label: {
                        if isEnqueuing { ProgressView() }
                        else { Text("Save") }
                    }
                }
            }
        }
        .onAppear { prefill() }
    }

    private func prefill() {
        switch initial {
        case .empty: break
        case .memo(let text): note = text
        case .link(let url, let t):
            urlString = url
            if let t { title = t }
        case .screenshot(let image, let ocr):
            previewImage = image
            ocrText = ocr
            if let data = image.jpegData(compressionQuality: 0.8) {
                imageBase64 = data.base64EncodedString()
            }
        }
    }

    private func enqueue() async {
        isEnqueuing = true
        defer { isEnqueuing = false }
        let tags = tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let payload: DraftPayload
        switch initial {
        case .empty, .memo:
            payload = .memo(text: note, tags: tags)
        case .link(let url, _):
            payload = .link(
                url: urlString.isEmpty ? url : urlString,
                title: title.isEmpty ? nil : title,
                selectedText: nil,
                note: note.isEmpty ? nil : note,
                tags: tags
            )
        case .screenshot:
            guard let imageBase64 else { return }
            payload = .screenshot(
                imageBase64: imageBase64,
                ocrText: ocrText.isEmpty ? nil : ocrText,
                note: note.isEmpty ? nil : note,
                tags: tags
            )
        }
        let draft = Draft(payload: payload)
        try? OfflineQueue.shared.enqueue(draft)
        onDone()
    }
}
