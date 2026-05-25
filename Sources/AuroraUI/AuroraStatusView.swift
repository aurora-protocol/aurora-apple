import AuroraKit
import SwiftUI

public struct AuroraStatusView: View {
    @ObservedObject private var controller: AuroraClientController
    @State private var endpointText: String
    @State private var profileText: String
    @State private var didLoadStoredProfile = false

    public init(controller: AuroraClientController) {
        self.controller = controller
        _endpointText = State(initialValue: controller.configuration.endpoint.absoluteString)
        _profileText = State(initialValue: "")
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server", text: $endpointText)
                        .autocorrectionDisabled()
                    LabeledContent("Route", value: controller.configuration.routePolicy)
                    LabeledContent("State", value: stateText)
                    LabeledContent("Credential", value: credentialText)
                    LabeledContent("Packet", value: packetExchangeText)
                    LabeledContent("Tunnel", value: tunnelStateText)
                }

                Section {
                    Button {
                        if controller.updateEndpoint(endpointText) {
                            Task { await controller.refreshStatus() }
                        }
                    } label: {
                        Label("Check Server", systemImage: "network")
                    }
                    .disabled(isChecking)

                    Button {
                        if controller.updateEndpoint(endpointText) {
                            Task { await controller.checkPacketExchange() }
                        }
                    } label: {
                        Label("Packet Check", systemImage: "arrow.left.arrow.right")
                    }
                    .disabled(isPacketChecking)

                    Button {
                        if controller.updateEndpoint(endpointText) {
                            Task { await controller.issueAdmissionToken() }
                        }
                    } label: {
                        Label("Issue Token", systemImage: "key")
                    }
                    .disabled(isCredentialIssuing)
                }

                Section {
                    Button {
                        if controller.updateEndpoint(endpointText) {
                            Task { await controller.installTunnel() }
                        }
                    } label: {
                        Label("Install", systemImage: "gearshape")
                    }
                    .disabled(isTunnelBusy)

                    Button {
                        if controller.updateEndpoint(endpointText) {
                            Task { await controller.connectTunnel() }
                        }
                    } label: {
                        Label("Connect", systemImage: "play.fill")
                    }
                    .disabled(isTunnelBusy)

                    Button(role: .destructive) {
                        Task { await controller.stopTunnel() }
                    } label: {
                        Label("Disconnect", systemImage: "stop.fill")
                    }
                    .disabled(isTunnelBusy)
                }

                if let status = controller.lastStatus {
                    Section {
                        LabeledContent("Ready", value: status.ready ? "yes" : "no")
                        LabeledContent("Issuer", value: status.issuer ? "available" : "unavailable")
                        LabeledContent("Cover", value: status.cover ? "available" : "unavailable")
                    }
                }

                if !controller.redactedDiagnosticLine.isEmpty {
                    Section("Diagnostics") {
                        Text(controller.redactedDiagnosticLine)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                Section {
                    TextEditor(text: $profileText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 120)

                    HStack {
                        Button {
                            if controller.importPortableProfile(profileText) {
                                endpointText = controller.configuration.endpoint.absoluteString
                            }
                        } label: {
                            Label("Import Profile", systemImage: "square.and.arrow.down")
                        }

                        Spacer()

                        Button {
                            profileText = controller.exportPortableProfile()
                        } label: {
                            Label("Export Profile", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .navigationTitle("Aurora")
            .task {
                loadStoredProfileIfNeeded()
            }
        }
    }

    private var isChecking: Bool {
        if case .checking = controller.state {
            return true
        }
        return false
    }

    private var isPacketChecking: Bool {
        if case .checking = controller.packetExchangeState {
            return true
        }
        return false
    }

    private var isCredentialIssuing: Bool {
        if case .issuing = controller.credentialState {
            return true
        }
        return false
    }

    private var isTunnelBusy: Bool {
        switch controller.tunnelState {
        case .installing, .connecting, .disconnecting:
            return true
        case .disconnected, .installed, .connected, .unavailable:
            return false
        }
    }

    private var stateText: String {
        switch controller.state {
        case .idle:
            return "idle"
        case .checking:
            return "checking"
        case .ready:
            return "ready"
        case .unavailable(let reason):
            return reason
        }
    }

    private var credentialText: String {
        switch controller.credentialState {
        case .idle:
            return "idle"
        case .issuing:
            return "issuing"
        case .ready:
            return "ready"
        case .unavailable(let reason):
            return reason
        }
    }

    private var tunnelStateText: String {
        switch controller.tunnelState {
        case .disconnected:
            return "disconnected"
        case .installing:
            return "installing"
        case .installed:
            return "installed"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .disconnecting:
            return "disconnecting"
        case .unavailable(let reason):
            return reason
        }
    }

    private var packetExchangeText: String {
        switch controller.packetExchangeState {
        case .idle:
            return "idle"
        case .checking:
            return "checking"
        case .ready(let packetCount):
            return "\(packetCount) packet"
        case .unavailable(let reason):
            return reason
        }
    }

    @MainActor
    private func loadStoredProfileIfNeeded() {
        guard !didLoadStoredProfile else {
            return
        }
        didLoadStoredProfile = true
        if controller.loadStoredPortableProfile() {
            endpointText = controller.configuration.endpoint.absoluteString
            profileText = controller.exportPortableProfile()
        }
    }
}
