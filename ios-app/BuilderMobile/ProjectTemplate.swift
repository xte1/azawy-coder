import Foundation
import UIKit

/// Name, bundle identifier and icon chosen when creating an iOS app project.
struct AppIdentity {
    var displayName: String
    var bundleID: String
    var iconData: Data?
}

/// Generates a ready-to-build SwiftUI starter project (XcodeGen `project.yml`) with the chosen identity.
enum ProjectTemplate {
    static func isValidBundleID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
    }

    /// Suggests a bundle id from a name, e.g. "Ice RF" -> com.azawy.icerf
    static func suggestedBundleID(from name: String) -> String {
        let slug = name.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return "com.azawy." + (slug.isEmpty ? "app" : slug)
    }

    /// A valid Swift/Xcode identifier for the target.
    static func targetName(for identity: AppIdentity) -> String {
        func clean(_ text: String) -> String {
            text.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
        var candidate = clean(identity.displayName)
        if candidate.isEmpty { candidate = clean(identity.bundleID.split(separator: ".").last.map(String.init) ?? "") }
        if candidate.isEmpty { candidate = "App" }
        if let first = candidate.first, first.isNumber { candidate = "App" + candidate }
        return candidate.prefix(1).uppercased() + candidate.dropFirst()
    }

    private static func yamlQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func swiftQuoted(_ text: String) -> String { yamlQuoted(text) }

    static func files(for identity: AppIdentity) -> [GitHubAPI.UploadFile] {
        let target = targetName(for: identity)
        let icon = iconPNG(from: identity.iconData, fallbackText: identity.displayName)

        let projectYML = """
        name: \(target)
        options:
          bundleIdPrefix: \(identity.bundleID.split(separator: ".").dropLast().joined(separator: "."))
          deploymentTarget:
            iOS: "17.0"
        targets:
          \(target):
            type: application
            platform: iOS
            sources:
              - Sources
            settings:
              base:
                PRODUCT_BUNDLE_IDENTIFIER: \(identity.bundleID)
                PRODUCT_NAME: \(target)
                MARKETING_VERSION: "1.0"
                CURRENT_PROJECT_VERSION: "1"
                SWIFT_VERSION: "5.0"
                TARGETED_DEVICE_FAMILY: "1,2"
                GENERATE_INFOPLIST_FILE: YES
                INFOPLIST_KEY_CFBundleDisplayName: \(yamlQuoted(identity.displayName))
                INFOPLIST_KEY_UILaunchScreen_Generation: YES
                INFOPLIST_KEY_UIApplicationSceneManifest_Generation: YES
                INFOPLIST_KEY_UISupportedInterfaceOrientations: "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
                ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        """

        let appSwift = """
        import SwiftUI

        @main
        struct \(target)App: App {
            var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }
        """

        let contentView = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack(spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                    Text(\(swiftQuoted(identity.displayName)))
                        .font(.largeTitle.bold())
                    Text("Built with azawy coder")
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
        """

        let catalog = #"{"info":{"author":"xcode","version":1}}"#
        let appIconContents = #"{"images":[{"filename":"icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}"#

        func file(_ path: String, _ text: String) -> GitHubAPI.UploadFile {
            .init(path: path, data: Data(text.utf8))
        }

        return [
            file("project.yml", projectYML + "\n"),
            file("Sources/\(target)App.swift", appSwift + "\n"),
            file("Sources/ContentView.swift", contentView + "\n"),
            file("Sources/Assets.xcassets/Contents.json", catalog + "\n"),
            file("Sources/Assets.xcassets/AppIcon.appiconset/Contents.json", appIconContents + "\n"),
            .init(path: "Sources/Assets.xcassets/AppIcon.appiconset/icon.png", data: icon)
        ]
    }

    /// 1024x1024 opaque PNG (App Store icons must not contain transparency).
    static func iconPNG(from data: Data?, fallbackText: String) -> Data {
        let size = CGSize(width: 1024, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let image = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            if let data, let source = UIImage(data: data) {
                // Aspect-fill, centered.
                let scale = max(size.width / source.size.width, size.height / source.size.height)
                let drawSize = CGSize(width: source.size.width * scale, height: source.size.height * scale)
                let origin = CGPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
                source.draw(in: CGRect(origin: origin, size: drawSize))
            } else {
                let colors = [UIColor.systemCyan.cgColor, UIColor.systemBlue.cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                    context.cgContext.drawLinearGradient(
                        gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: []
                    )
                }
                let letter = String(fallbackText.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 560, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
                let text = NSAttributedString(string: letter.isEmpty ? "A" : letter, attributes: attributes)
                let textSize = text.size()
                text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2))
            }
        }
        return image.pngData() ?? Data()
    }
}
