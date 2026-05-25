import AuroraKit
import AuroraUI
import SwiftUI

@main
struct AuroraMacApp: App {
    @StateObject private var controller = AuroraClientController(
        configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
        profileStore: AuroraUserDefaultsProfileStore(
            appGroupIdentifier: AuroraAppleSharedContainer.appGroupIdentifier()
        )
    )

    var body: some Scene {
        WindowGroup {
            AuroraStatusView(controller: controller)
                .frame(minWidth: 420, minHeight: 360)
        }
    }
}
