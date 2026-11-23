import WebKit

/// Clears the website data of ONE service's store: nothing else in the app uses it, and no other store is touched.
@MainActor enum SessionClearing {
    struct ClearReport: Equatable { var remainingRecordCount: Int }

    /// Removes every website data type, then looks again to confirm. Callers release the service's web views first.
    @discardableResult static func clear(_ store: WKWebsiteDataStore) async -> ClearReport {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        let left = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        return ClearReport(remainingRecordCount: left.count)
    }
}
