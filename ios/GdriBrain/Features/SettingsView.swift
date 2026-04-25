import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var apiKeyInput: String = ""
    @State private var showAPIKey: Bool = false
    @State private var oauthMessage: String?
    @State private var isSigningIn = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: appState.hasAPIKey ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(appState.hasAPIKey ? .green : .orange)
                        Text("Anthropic API key")
                        Spacer()
                        Text(appState.hasAPIKey
                             ? KeychainStore.mask(KeychainStore.load(.anthropicAPIKey))
                             : "not set")
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Image(systemName: appState.driveAuthorised ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(appState.driveAuthorised ? .green : .orange)
                        Text("Google Drive")
                        Spacer()
                        Text(appState.driveAuthorised ? "linked" : "not linked")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Image(systemName: "tray")
                        Text("Pending queue")
                        Spacer()
                        Text("\(appState.queueCount)")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Status")
                }

                Section {
                    if showAPIKey {
                        TextField("sk-ant-…", text: $apiKeyInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote.monospaced())
                    } else {
                        SecureField("sk-ant-…", text: $apiKeyInput)
                            .textInputAutocapitalization(.never)
                    }
                    Toggle("Show characters while typing", isOn: $showAPIKey)
                    Button("Save API key") {
                        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        KeychainStore.save(.anthropicAPIKey, value: trimmed)
                        apiKeyInput = ""
                        appState.refreshFlags()
                    }
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if appState.hasAPIKey {
                        Button(role: .destructive) {
                            KeychainStore.delete(.anthropicAPIKey)
                            appState.refreshFlags()
                        } label: {
                            Text("Remove saved API key")
                        }
                    }
                } header: {
                    Text("Anthropic")
                } footer: {
                    Text("Stored in iOS Keychain (this device only). Pasted keys are not echoed back. If you suspect exposure, revoke the key at console.anthropic.com.")
                        .font(.footnote)
                }

                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            if isSigningIn { ProgressView() }
                            Text(appState.driveAuthorised ? "Re-authorise Google Drive" : "Sign in with Google")
                        }
                    }
                    .disabled(isSigningIn)
                    if appState.driveAuthorised {
                        Button(role: .destructive) {
                            GoogleOAuth.shared.signOut()
                            appState.refreshFlags()
                        } label: {
                            Text("Disconnect Google Drive")
                        }
                    }
                    if let oauthMessage {
                        Text(oauthMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Google Drive")
                } footer: {
                    Text("Scope is drive.file — this app can only see files it created in your Drive.")
                        .font(.footnote)
                }

                Section {
                    Button {
                        Task { await appState.drainQueue() }
                    } label: {
                        Text("Retry pending queue (\(appState.queueCount))")
                    }
                    .disabled(appState.queueCount == 0 || appState.isProcessing)
                } header: {
                    Text("Maintenance")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func signIn() async {
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await GoogleOAuth.shared.signIn()
            oauthMessage = "signed in"
            appState.refreshFlags()
            await appState.drainQueue()
        } catch {
            oauthMessage = "failed: \(error.localizedDescription)"
        }
    }
}
