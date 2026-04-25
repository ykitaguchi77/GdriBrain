import SwiftData
import SwiftUI

struct NotesListView: View {
    @Query(sort: \IndexedNote.updated, order: .reverse) private var notes: [IndexedNote]
    @State private var selected: Set<String> = []
    @State private var summary: String = ""
    @State private var isSummarising = false
    @State private var error: String?
    @State private var usePremium: Bool = false

    var body: some View {
        NavigationStack {
            List {
                if !summary.isEmpty {
                    Section("Summary") {
                        Text(summary)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
                Section("Notes") {
                    if notes.isEmpty {
                        Text("No notes yet — write one in the Memo tab or share something to GdriBrain.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(notes) { note in
                            HStack(alignment: .top) {
                                Image(systemName: selected.contains(note.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(note.id) ? .accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.title).font(.headline)
                                    if !note.summary.isEmpty {
                                        Text(note.summary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    HStack(spacing: 4) {
                                        Text(note.source).font(.caption2).foregroundStyle(.tertiary)
                                        if !note.tags.isEmpty {
                                            Text("·").foregroundStyle(.tertiary)
                                            Text(note.tags.joined(separator: " · "))
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selected.contains(note.id) { selected.remove(note.id) }
                                else { selected.insert(note.id) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Use Opus 4.7 (premium)", isOn: $usePremium)
                        Button {
                            Task { await summarise() }
                        } label: {
                            Label("Summarise selected (\(selected.count))", systemImage: "wand.and.stars")
                        }
                        .disabled(selected.isEmpty || isSummarising)
                    } label: {
                        if isSummarising { ProgressView() }
                        else { Image(systemName: "wand.and.stars") }
                    }
                }
            }
            .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func summarise() async {
        isSummarising = true
        defer { isSummarising = false }
        do {
            summary = try await GraphService.shared.summariseCluster(
                noteIDs: Array(selected),
                usePremium: usePremium
            )
        } catch {
            self.error = error.localizedDescription
        }
    }
}
