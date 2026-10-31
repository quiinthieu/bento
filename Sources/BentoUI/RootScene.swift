import AppKit
import BentoCore
import Observation
import SwiftUI

@MainActor
@Observable
final class AppSceneBootstrap {
    static let shared = AppSceneBootstrap()

    var appModel: BentoAppModel?
    var startupError: String?
    private var didStart = false

    func startIfNeeded() async {
        guard !didStart else { return }
        didStart = true
        do {
            let launch = try LaunchConfiguration.parse()
            let created = try BentoAppModel(
                launchConfiguration: launch,
                enableLiveWatching: !launch.isFixtureMode
            )
            self.appModel = created
            await created.refreshAll()
        } catch {
            self.startupError = error.localizedDescription
        }
    }
}

/// Primary macOS window scene titled from `Product.name` (or `#if DEBUG` override).
public struct RootScene: Scene {
    private let configuration: RootWindowConfiguration
    private let bootstrap = AppSceneBootstrap.shared

    /// Creates the primary scene using the given window configuration.
    public init(configuration: RootWindowConfiguration = RootWindowConfiguration()) {
        self.configuration = configuration
    }

    public var body: some Scene {
        WindowGroup(effectiveWindowTitle) {
            Group {
                if let appModel = bootstrap.appModel {
                    RootView(configuration: configuration, model: appModel)
                } else if let startupError = bootstrap.startupError {
                    ContentUnavailableView(
                        "Unable to Start \(configuration.windowTitle)",
                        systemImage: "exclamationmark.triangle",
                        description: Text(startupError)
                    )
                    .frame(minWidth: 720, minHeight: 480)
                } else {
                    ProgressView("Loading \(configuration.windowTitle)…")
                        .frame(minWidth: 720, minHeight: 480)
                }
            }
            .task {
                if CommandLine.arguments.contains("--smoke-test-quit") {
                    NSApplication.shared.terminate(nil)
                    return
                }
                await bootstrap.startIfNeeded()
            }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            if let appModel = bootstrap.appModel {
                BentoMenuCommands(model: appModel)
            }
        }
    }

    private var effectiveWindowTitle: String {
        if let appModel = bootstrap.appModel, configuration.windowTitle == Product.name {
            return appModel.effectiveProductName
        }
        return configuration.windowTitle
    }
}
