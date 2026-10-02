import SwiftUI

/// One capture in the list: when it was made, and the status words from the plan's table.
struct StatusRow: View {
    let row: StatusItem
    let onResend: () -> Void
    let onDiscard: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: row.kind == .voice ? "waveform" : "text.alignleft")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(Self.title(row))
                    .font(.subheadline.weight(.semibold))
            }
            Text(row.words)
                .font(.callout)
                .foregroundStyle(.secondary)
            if row.askDiscard {
                HStack {
                    Button("Discard", role: .destructive) { onDiscard(true) }
                    Button("Keep and send") { onDiscard(false) }
                }
                .buttonStyle(.bordered)
            } else if row.canResend {
                Button("Send again", action: onResend)
                    .buttonStyle(.bordered)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func title(_ row: StatusItem) -> String {
        let when = row.when.formatted(date: .abbreviated, time: .shortened)
        return (row.kind == .voice ? "Voice note, " : "Text note, ") + when
    }
}
