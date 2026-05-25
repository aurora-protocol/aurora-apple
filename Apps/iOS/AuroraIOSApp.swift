import AuroraKit
import AuroraUI
import SwiftUI

@main
struct AuroraIOSApp: App {
    @StateObject private var controller = AuroraClientController(
        configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!)
    )

    var body: some Scene {
        WindowGroup {
            AuroraStatusView(controller: controller)
        }
    }
}
