import SwiftUI

struct MemoComposeView: View {
    @EnvironmentObject var appState: AppState
    @State private var text: String = ""
    @State private var tagsText: String = ""
    @State private var isSending = false
    @State private var lastResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Memo") {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                }
                Section("Tags (comma separated)") {
                    TextField("idea, work", text: $tagsText)
                        .textInputAutocapitalization(.never)
                }
                if let lastResult {
                    Section("Last save") {
                        Text(lastResult).font(.footnote).monospaced()
                    }
                }
                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            if isSending { ProgressView() }
                            Text(isSending ? "Saving…" : "Save")
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                }
            }
            .navigationTitle("Memo")
        }
    }

    private func save() async {
        isSending = true
        defer { isSending = false }
        let tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let draft = Draft(payload: .memo(text: text, tags: tags))

        guard appState.hasAPIKey, appState.driveAuthorised else {
            try? OfflineQueue.shared.enqueue(draft)
            lastResult = "queued — set API key + Google sign in"
            appState.refreshFlags()
            return
        }

        do {
            let note = try await NotesPipeline.shared.ingest(draft)
            lastResult = note.mergedInto != nil
                ? "merged into: \(note.title)"
                : "saved: \(note.title)"
            text = ""
            tagsText = ""
        } catch {
            try? OfflineQueue.shared.enqueue(draft)
            lastResult = "queued (error): \(error.localizedDescription)"
        }
        appState.refreshFlags()
    }
}
