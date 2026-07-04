import SwiftUI

/// The "a new version is available" card, shown on launch and from Settings.
/// Reuses the same card + focusable-button language as the session-ended card.
struct UpdateCard: View {
    @Environment(AppState.self) private var state

    private var service: UpdateService { state.updateService }

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            content
        }
        .padding(48)
        .frame(width: 480)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder
    private var content: some View {
        switch service.phase {
        case .downloading(let fraction):
            VStack(spacing: 10) {
                ProgressView(value: fraction)
                    .tint(Theme.accent)
                    .frame(width: 320)
                Text("Downloading… \(Int(fraction * 100))%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
        case .installing:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large).tint(Theme.accent)
                Text("Installing — VibeLight will restart…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        case .failed(let message):
            VStack(spacing: 16) {
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                OverlayButton(id: "update:now", title: "Try Again", symbol: "arrow.clockwise")
                OverlayButton(id: "update:later", title: "Later", symbol: "clock")
            }
        default:  // .available
            VStack(spacing: 16) {
                if let notes = cleanedNotes {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What's New")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .tracking(1.2)
                            .foregroundStyle(Theme.accent)
                        ScrollView {
                            Text(notes)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150)
                    }
                    .padding(14)
                    .background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(spacing: 12) {
                    OverlayButton(id: "update:now",
                                  title: service.canSelfInstall ? "Update Now" : "Open Release Page",
                                  symbol: service.canSelfInstall ? "arrow.down.circle.fill" : "safari")
                    OverlayButton(id: "update:later", title: "Later", symbol: "clock")
                }
            }
        }
    }

    /// The release body, lightly de-marked for plain display (drop heading
    /// hashes, bullet stars, and the redundant leading "What's new" title).
    private var cleanedNotes: String? {
        guard let raw = service.available?.notes, !raw.isEmpty else { return nil }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var s = String(line)
            if s.hasPrefix("#") { s = String(s.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
            if s.hasPrefix("- ") { s = "•\(s.dropFirst())" }
            return s.replacingOccurrences(of: "**", with: "")
        }
        // Stop at the install/changelog boilerplate.
        var kept: [String] = []
        for line in lines {
            if line.hasPrefix("Install / update") || line.hasPrefix("Full Changelog")
                || line.hasPrefix("Requirements") { break }
            kept.append(line)
        }
        let text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private var title: String {
        switch service.phase {
        case .installing: "Updating VibeLight"
        case .failed: "Update Failed"
        default:
            if let v = service.available?.version { "Update Available — v\(v)" }
            else { "Update Available" }
        }
    }

    private var subtitle: String? {
        switch service.phase {
        case .downloading, .installing, .failed: nil
        default: "You're on v\(service.currentVersion). A newer version is ready to install."
        }
    }
}
