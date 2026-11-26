import XCTest

final class ScreenshotTests: XCTestCase {

    let app = XCUIApplication(bundleIdentifier: "__TARGET_BUNDLE_ID__")

    let maxShots = 40
    let maxDepth = 3
    let limits = [8, 5, 3]
    let deadline = Date().addingTimeInterval(20 * 60)

    var counter = 0
    var seen = Set<Int>()
    var dirs: [URL] = []
    var indexLines: [String] = []

    let blocked = [
        "delete", "remove", "sign out", "log out", "logout",
        "reset", "erase", "back", "close", "cancel", "done",
        "حذف", "مسح", "إزالة", "خروج", "تسجيل الخروج",
        "رجوع", "إغلاق", "إلغاء", "تم", "إعادة ضبط"
    ]

    override func setUp() {
        super.setUp()
        continueAfterFailure = true

        var candidates = [
            URL(fileURLWithPath: "/tmp/PreviewScreenshots", isDirectory: true)
        ]

        if let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first {
            candidates.append(
                docs.appendingPathComponent("PreviewScreenshots", isDirectory: true)
            )
        }

        for url in candidates {
            try? FileManager.default.removeItem(at: url)
            do {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
                dirs.append(url)
            } catch {
                print("DIR_FAILED: \(url.path)")
            }
        }

        addUIInterruptionMonitor(withDescription: "System alerts") { alert in
            for name in ["Allow", "Allow While Using App", "Allow Once", "OK", "Continue"] {
                let button = alert.buttons[name]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
    }

    func pause(_ seconds: Double = 1.0) {
        Thread.sleep(forTimeInterval: seconds)
    }

    func launch() {
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()
        pause(3)
    }

    @discardableResult
    func snap(_ slug: String, _ title: String) -> Bool {
        guard counter < maxShots else { return false }

        pause(1.0)

        let shot = XCUIScreen.main.screenshot()
        let data = shot.pngRepresentation
        let hash = data.hashValue

        if seen.contains(hash) { return false }
        seen.insert(hash)

        counter += 1
        let name = String(format: "%02d-%@", counter, slug)

        for dir in dirs {
            try? data.write(
                to: dir.appendingPathComponent(name + ".png"),
                options: .atomic
            )
        }

        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let clean = title
            .replacingOccurrences(of: "|", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        indexLines.append("\(name)|\(clean)")

        let text = indexLines.joined(separator: "\n") + "\n"
        for dir in dirs {
            try? text.write(
                to: dir.appendingPathComponent("index.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        print("SCREENSHOT_SAVED: \(name)")
        return true
    }

    func isBlocked(_ label: String) -> Bool {
        let lower = label.lowercased()
        return blocked.contains { lower == $0 || lower.hasPrefix($0 + " ") }
    }

    func apply(_ step: String) -> Bool {
        let kind = String(step.prefix(2))
        let value = String(step.dropFirst(2))

        switch kind {
        case "t:":
            let button = app.tabBars.buttons[value]
            guard button.waitForExistence(timeout: 4), button.isHittable else {
                return false
            }
            button.tap()

        case "i:":
            let index = Int(value) ?? 0
            let buttons = app.tabBars.buttons
            guard index < buttons.count else { return false }
            let button = buttons.element(boundBy: index)
            guard button.exists, button.isHittable else { return false }
            button.tap()

        case "b:":
            let button = app.buttons.matching(
                NSPredicate(format: "label == %@", value)
            ).firstMatch
            guard button.waitForExistence(timeout: 3), button.isHittable else {
                return false
            }
            button.tap()

        case "c:":
            let index = Int(value) ?? 0
            guard index < app.cells.count else { return false }
            let cell = app.cells.element(boundBy: index)
            guard cell.exists, cell.isHittable else { return false }
            cell.tap()

        default:
            return false
        }

        pause(1.5)
        return true
    }

    func reach(_ path: [String]) -> Bool {
        launch()
        for step in path {
            if !apply(step) { return false }
        }
        return true
    }

    func candidates(tabLabels: Set<String>) -> [String] {
        var result: [String] = []
        var used = Set<String>()

        for button in app.buttons.allElementsBoundByIndex.prefix(40) {
            guard button.exists, button.isHittable else { continue }

            let label = button.label
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if label.isEmpty || tabLabels.contains(label)
                || isBlocked(label) || used.contains(label) {
                continue
            }

            used.insert(label)
            result.append("b:" + label)
        }

        let cellCount = min(app.cells.count, 5)
        for index in 0..<cellCount {
            let cell = app.cells.element(boundBy: index)
            guard cell.exists, cell.isHittable else { continue }
            if isBlocked(cell.label) { continue }
            result.append("c:\(index)")
        }

        return result
    }

    func describe(_ step: String) -> String {
        let value = String(step.dropFirst(2))
        if step.hasPrefix("c:") { return "صف رقم \(Int(value).map { $0 + 1 } ?? 1)" }
        return value
    }

    func explore(
        path: [String],
        slug: String,
        title: String,
        depth: Int,
        tabLabels: Set<String>
    ) {
        guard depth < maxDepth, counter < maxShots, Date() < deadline else {
            return
        }

        guard reach(path) else { return }

        let found = candidates(tabLabels: tabLabels)
        let letters = ["a", "b", "c"]

        var needReach = false

        for (offset, step) in found.prefix(limits[depth]).enumerated() {
            guard counter < maxShots, Date() < deadline else { return }

            if needReach {
                guard reach(path) else { continue }
            }
            needReach = true

            guard apply(step) else { continue }

            let childSlug = "\(slug)-\(letters[depth])\(offset + 1)"
            let childTitle = "\(title) › \(describe(step))"

            if snap(childSlug, childTitle) {
                explore(
                    path: path + [step],
                    slug: childSlug,
                    title: childTitle,
                    depth: depth + 1,
                    tabLabels: tabLabels
                )
            }
        }
    }

    func testCaptureApplicationScreens() {
        launch()
        snap("launch", "شاشة البداية")

        let labels = app.tabBars.buttons.allElementsBoundByIndex.map { $0.label }
        let tabSet = Set(labels.filter { !$0.isEmpty })

        if labels.isEmpty {
            app.swipeUp()
            snap("main-scroll", "الشاشة الرئيسية بعد التمرير")

            explore(
                path: [],
                slug: "main",
                title: "الشاشة الرئيسية",
                depth: 0,
                tabLabels: tabSet
            )
        } else {
            for (index, label) in labels.enumerated() {
                let step = label.isEmpty ? "i:\(index)" : "t:" + label
                let title = label.isEmpty ? "تبويب \(index + 1)" : "صفحة \(label)"
                let slug = "tab\(index + 1)"

                guard reach([step]) else { continue }

                snap(slug, title)

                app.swipeUp()
                snap(slug + "-scroll", title + " بعد التمرير")

                explore(
                    path: [step],
                    slug: slug,
                    title: title,
                    depth: 0,
                    tabLabels: tabSet
                )
            }
        }

        print("TOTAL_SCREENSHOTS: \(counter)")

        XCTAssertGreaterThan(counter, 0, "No screenshots were captured")
    }
}