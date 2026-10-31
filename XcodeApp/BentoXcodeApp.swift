import BentoUI
import SwiftUI

/// Xcode `.app` bundle entry point wiring `SparkleUpdaterController` into `BentoUI.RootScene`.
@main
struct BentoXcodeApp: App {
    @State private var updater = SparkleUpdaterController()

    var body: some Scene {
        RootScene(updater: updater)
    }
}
