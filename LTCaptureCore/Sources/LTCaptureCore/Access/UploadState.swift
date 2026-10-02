import Foundation

/// The iCloud upload words after "sent", from the file's `URLResourceValues`
/// (`isUbiquitousItem`, `ubiquitousItemIsUploaded`, `ubiquitousItemIsUploading`,
/// `ubiquitousItemUploadingError`), which the app reads and passes in. nil means unreadable.
public nonisolated enum UploadState {
    public static func words(isUbiquitous: Bool?, uploaded: Bool?, uploading: Bool?, error: Bool) -> String {
        if error { return "upload failed, iCloud will retry" }
        guard let isUbiquitous else { return "upload state unknown" }
        if !isUbiquitous { return "saved, not an iCloud folder" }
        if uploaded == true { return "uploaded" }
        if uploading == true { return "uploading" }
        if uploaded == nil && uploading == nil { return "upload state unknown" }
        return "waiting to upload"
    }
}
