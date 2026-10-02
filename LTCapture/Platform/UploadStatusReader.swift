import Foundation
import LTCaptureCore

/// The iCloud upload words shown after "sent", read from the file in the inbox (plan `### Status
/// words`). Called inside `withAccess(.inbox)`, so the security scope is already started.
enum UploadStatusReader {
    static func words(for url: URL) -> String {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
                                         .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey]
        guard let v = try? url.resourceValues(forKeys: keys) else {
            return UploadState.words(isUbiquitous: nil, uploaded: nil, uploading: nil, error: false)
        }
        return UploadState.words(isUbiquitous: v.isUbiquitousItem, uploaded: v.ubiquitousItemIsUploaded,
                                 uploading: v.ubiquitousItemIsUploading, error: v.ubiquitousItemUploadingError != nil)
    }
}
