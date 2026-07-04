import SwiftUI

/// First-launch prompt to move VibeLight into /Applications. Same card + button
/// language as the other overlays. Moving there is what lets the app keep itself
/// updated (and stops macOS from running it from a read-only quarantine copy).
struct RelocateCard: View {
    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 8) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accent)
                Text("Move to Applications?")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Keep VibeLight in your Applications folder so it stays\nout of Downloads and can update itself automatically.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                OverlayButton(id: "relocate:move", title: "Move to Applications", symbol: "folder.fill")
                OverlayButton(id: "relocate:later", title: "Not Now", symbol: "clock")
            }
        }
        .padding(48)
        .frame(width: 480)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 24))
    }
}
