import Foundation

extension ReassemblyStore {
    /// The app's single store: persisted via the spilled defaults, part files under `MediaStore`'s dir.
    static let shared = ReassemblyStore(defaults: .shared, storageDir: { MediaStore.storageDir })
}
