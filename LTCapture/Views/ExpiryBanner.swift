import SwiftUI

/// From 36 hours before the signing profile lapses (F8, F67). A free-team app stops opening on
/// that date until it is run from Xcode again, and the outbox is kept across the reinstall.
struct ExpiryBanner: View {
    let expiry: Date

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("LT Capture stops opening \(expiry.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline.weight(.semibold))
                Text("Connect the phone to the Mac and run the app from Xcode again. Notes on the phone are kept.")
                    .font(.footnote)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .accessibilityElement(children: .combine)
    }
}
