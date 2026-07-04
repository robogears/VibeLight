import SwiftUI

/// The computer manager, opened from the top-right host chip. Lists up to four
/// computers (switchable), and adds a new one by IP address. Same card + focus
/// language as the session-ended and update cards.
struct HostMenuCard: View {
    @Environment(AppState.self) private var state
    @FocusState private var ipFieldFocused: Bool

    var body: some View {
        Group {
            if let pairing = state.pairing {
                PairingPanel(pairing: pairing)
            } else {
                computerList
            }
        }
        .padding(48)
        .frame(width: 520)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 24))
        // While the IP field has keyboard focus, stop the nav key monitor from
        // swallowing what the user types.
        .onChange(of: ipFieldFocused) { _, focused in
            state.controller.keyboardCaptureEnabled = !focused
        }
        .onDisappear { state.controller.keyboardCaptureEnabled = true }
    }

    private var computerList: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("Computers")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(state.hosts.count) of \(AppState.maxHosts)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }

            VStack(spacing: 10) {
                ForEach(state.hosts) { host in
                    HostRow(host: host)
                }
            }

            if state.hosts.count < AppState.maxHosts {
                addComputerField
            }

            if let error = state.addHostError {
                Text(error)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var addComputerField: some View {
        let ip = Binding(get: { state.addHostIP }, set: { state.addHostIP = $0 })
        return HStack(spacing: 12) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
            TextField("Add computer by IP address", text: ip)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .focused($ipFieldFocused)
                .onSubmit { state.addHost() }
            Button {
                state.addHost()
            } label: {
                Text("Add")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(state.focus.focusedItemID == "hostmenu:add" ? .white : Theme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        state.focus.focusedItemID == "hostmenu:add" ? Theme.accent : Theme.accent.opacity(0.15),
                        in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(.white.opacity(ipFieldFocused ? 0.3 : 0.08), lineWidth: 1)
        }
        .onTapGesture { ipFieldFocused = true }
    }
}

private struct HostRow: View {
    @Environment(AppState.self) private var state
    let host: StreamHost

    private var focusID: String { "hostmenu:\(host.id)" }
    private var isFocused: Bool { state.focus.focusedItemID == focusID }
    private var isSelected: Bool { state.selectedHostID == host.id }

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .shadow(color: statusColor.opacity(0.7), radius: isSelected && state.hostOnline ? 5 : 0)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(isFocused ? .white : Theme.textPrimary)
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isFocused ? .white.opacity(0.8) : Theme.textSecondary)
            }
            Spacer()
            // Wake-on-LAN for an asleep computer that stored a MAC.
            if host.macAddress != nil && !(isSelected && state.hostOnline) {
                Button {
                    state.wakeHost(host)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(isFocused ? .white : Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Wake this computer")
            }
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(isFocused ? .white : Theme.accent)
            }
            if state.isAddedHost(host) {
                Button {
                    state.removeAddedHost(host)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isFocused ? .white.opacity(0.85) : Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(
            isFocused ? Theme.accent : Theme.background.opacity(0.5),
            in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(.white.opacity(isFocused ? 0.3 : 0.06), lineWidth: 1)
        }
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(Theme.focusSpring, value: isFocused)
        .onHover { if $0 && state.inputMode == .pointer { state.focus.focus(itemID: focusID) } }
        .onTapGesture { state.pointerSelect(focusID) }
    }

    private var statusColor: Color {
        if isSelected && state.hostOnline { return .green }
        if !host.isPaired { return .orange }
        return .gray
    }

    private var statusText: String {
        if !host.isPaired { return "Not paired — select to pair" }
        if isSelected {
            if state.hostOnline { return "Online — selected" }
            return host.macAddress != nil ? "Asleep — selected" : "Offline — selected"
        }
        return host.candidateAddresses.first?.host ?? "Paired"
    }
}

/// The pairing panel: shows the PIN to enter on the host's web UI, then a
/// spinner / success / error as the handshake runs.
private struct PairingPanel: View {
    @Environment(AppState.self) private var state
    let pairing: AppState.PairingState

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("Pair \(pairing.hostName)")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
            }

            switch pairing.status {
            case .waiting:
                VStack(spacing: 14) {
                    Text("Enter this PIN on your PC")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 12) {
                        ForEach(Array(pairing.pin), id: \.self) { digit in
                            Text(String(digit))
                                .font(.system(size: 40, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 62, height: 78)
                                .background(Theme.accent.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    Text("Open your host's web UI at \(pairing.webUIURL) and type the PIN.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(Theme.accent)
                        Text("Waiting for pairing…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    OverlayButton(id: "pair:cancel", title: "Cancel", symbol: "xmark")
                }
            case .success:
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44)).foregroundStyle(.green)
                    Text("Paired! You can stream to this computer now.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                    OverlayButton(id: "pair:done", title: "Done", symbol: "checkmark")
                }
            default:
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36)).foregroundStyle(.orange)
                    Text(errorText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    OverlayButton(id: "pair:retry", title: "Try Again", symbol: "arrow.clockwise")
                    OverlayButton(id: "pair:cancel", title: "Cancel", symbol: "xmark")
                }
            }
        }
    }

    private var errorText: String {
        switch pairing.status {
        case .wrongPIN: "That PIN didn't match. Double-check and try again."
        case .unreachable: "Couldn't reach the computer. Make sure it's on and reachable."
        case .failed(let m): m
        default: ""
        }
    }
}
