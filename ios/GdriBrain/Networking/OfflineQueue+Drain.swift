import Foundation

/// Main-app-only extension that drains the queue through the NotesPipeline.
/// Compiled into the main target only — the Share Extension shouldn't have
/// the API key in scope.
extension OfflineQueue {
    /// Returns the number of drafts successfully ingested.
    @discardableResult
    func drain(using pipeline: NotesPipeline = .shared) async -> Int {
        var processed = 0
        for (url, draft) in pending() {
            do {
                _ = try await pipeline.ingest(draft)
                remove(url)
                processed += 1
            } catch {
                // Stop on the first failure: API outage, missing key, expired
                // refresh token, etc. Try again later — drafts are durable.
                break
            }
        }
        return processed
    }
}
