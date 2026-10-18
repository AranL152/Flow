import Foundation

enum AppResources {
    /// Installed bundles must not depend on SwiftPM's absolute build directory.
    static let bundle: Bundle = {
        if let url = Bundle.main.url(forResource: "Flow_FlowApp", withExtension: "bundle"),
           let bundled = Bundle(url: url) { return bundled }
        return Bundle.module
    }()
}
