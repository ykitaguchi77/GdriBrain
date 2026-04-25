import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var hasAPIKey: Bool = false
    @Published var driveAuthorised: Bool = false
    @Published var queueCount: Int = 0
    @Published var lastError: String?
    @Published var isProcessing: Bool = false

    func bootstrap() async {
        refreshFlags()
        await drainQueue()
    }

    func refreshFlags() {
        hasAPIKey = (KeychainStore.load(.anthropicAPIKey)?.isEmpty == false)
        let refresh = KeychainStore.load(.googleRefreshToken) ?? ""
        driveAuthorised = !refresh.isEmpty
        queueCount = OfflineQueue.shared.count
    }

    @discardableResult
    func drainQueue() async -> Int {
        guard hasAPIKey, driveAuthorised else { return 0 }
        isProcessing = true
        defer {
            isProcessing = false
            refreshFlags()
        }
        return await OfflineQueue.shared.drain()
    }
}
