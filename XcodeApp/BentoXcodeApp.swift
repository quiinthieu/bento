import BentoUI
import SwiftUI

/// Xcode `.app` bundle entry point delegating directly to `BentoUI.RootScene`.
@main
struct BentoXcodeApp: App {
    var body: some Scene {
        RootScene()
    }
}
