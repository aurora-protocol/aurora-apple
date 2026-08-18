import AuroraKit
import AuroraUI
import SwiftUI

@main
struct AuroraIOSApp: App {
    @StateObject private var controller = AuroraClientController(
        configuration: AuroraConfiguration(endpoint: AuroraConfiguration.defaultLoopbackEndpoint),
        profileStore: AuroraUserDefaultsProfileStore(
            appGroupIdentifier: AuroraAppleSharedContainer.appGroupIdentifier()
        )
    )

    var body: some Scene {
        WindowGroup {
            AuroraStatusView(controller: controller)
        }
    }
}
