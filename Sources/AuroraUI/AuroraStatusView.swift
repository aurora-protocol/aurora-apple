import AuroraKit
import SwiftUI

public struct AuroraStatusView: View {
    @ObservedObject private var controller: AuroraClientController
    @State private var endpointText: String

    public init(controller: AuroraClientController) {
        self.controller = controller
        _endpointText = State(initialValue: controller.configuration.endpoint.absoluteString)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server", text: $endpointText)
                        .autocorrectionDisabled()
                    LabeledContent("Route", value: controller.configuration.routePolicy)
                    LabeledContent("State", value: stateText)
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
                }

                if let status = controller.lastStatus {
                    Section {
                        LabeledContent("Ready", value: status.ready ? "yes" : "no")
                        LabeledContent("Issuer", value: status.issuer ? "available" : "unavailable")
                        LabeledContent("Cover", value: status.cover ? "available" : "unavailable")
                    }
                }
            }
            .navigationTitle("Aurora")
        }
    }

    private var isChecking: Bool {
        if case .checking = controller.state {
            return true
        }
        return false
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
}
