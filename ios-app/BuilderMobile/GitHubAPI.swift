import Foundation

actor GitHubAPI {
    let token: String
    let baseURL = URL(string: "https://api.github.com")!

    let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(token: String) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Account

    func currentUser() async throws -> GitHubUser {
        try await get("/user")
    }

    // MARK: Repositories

    /// Loads every repository visible to the token, including private repositories.
    /// A fine-grained token must be granted access to the repositories by its owner.
    func repositories() async throws -> [GitHubRepository] {
        var all: [GitHubRepository] = []
        var page = 1
        let pageSize = 100

        while page <= 20 {
            let endpoint = "/user/repos?visibility=all&affiliation=owner,collaborator,organization_member&sort=updated&direction=desc&per_page=\(pageSize)&page=\(page)"
            let batch: [GitHubRepository] = try await get(endpoint)
            all.append(contentsOf: batch)
            if batch.count < pageSize { break }
            page += 1
        }

        var seen = Set<Int>()
        return all.filter { seen.insert($0.id).inserted }
    }

    func createRepository(
        name: String,
        description: String,
        isPrivate: Bool
    ) async throws -> GitHubRepository {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw makeError("اسم المشروع مطلوب.") }

        let body: [String: Any] = [
            "name": cleanName,
            "description": description,
            "private": isPrivate,
            "auto_init": true,
            "has_issues": true,
            "has_projects": true,
            "has_wiki": false
        ]

        return try await sendForResponse("/user/repos", method: "POST", json: body, expected: [201])
    }

    func setRepositoryVisibility(
        _ repository: GitHubRepository,
        isPrivate: Bool
    ) async throws {
        let body: [String: Any] = ["private": isPrivate]
        try await send(
            "/repos/\(repository.fullName)",
            method: "PATCH",
            json: body,
            expected: [200]
        )
    }

    // MARK: Repository files

    func listProjectFiles(
        repository: GitHubRepository,
        path: String = ""
    ) async throws -> [GitHubContentItem] {
        let cleanPath = encodePath(path)
        let endpoint = "/repos/\(repository.fullName)/contents" + (cleanPath.isEmpty ? "" : "/\(cleanPath)")
        return try await get(endpoint)
    }

    func readProjectFile(
        repository: GitHubRepository,
        path: String
    ) async throws -> GitHubFileContent {
        try await get("/repos/\(repository.fullName)/contents/\(encodePath(path))")
    }

    func createProjectFile(
        repository: GitHubRepository,
        path: String,
        content: String,
        commitMessage: String? = nil
    ) async throws {
        try await saveProjectFile(
            repository: repository,
            path: path,
            content: content,
            sha: nil,
            commitMessage: commitMessage ?? "Create \(path) from Builder Mobile"
        )
    }

    func saveProjectFile(
        repository: GitHubRepository,
        path: String,
        content: String,
        sha: String?,
        commitMessage: String? = nil
    ) async throws {
        let endpoint = "/repos/\(repository.fullName)/contents/\(encodePath(path))"
        var body: [String: Any] = [
            "message": (commitMessage?.isEmpty == false ? commitMessage! : "Update \(path) from Builder Mobile"),
            "content": Data(content.utf8).base64EncodedString(),
            "branch": repository.defaultBranch
        ]
        if let sha = sha { body["sha"] = sha }
        try await send(endpoint, method: "PUT", json: body, expected: [200, 201])
    }

    func deleteProjectFile(
        repository: GitHubRepository,
        path: String,
        sha: String,
        commitMessage: String? = nil
    ) async throws {
        let endpoint = "/repos/\(repository.fullName)/contents/\(encodePath(path))"
        let body: [String: Any] = [
            "message": commitMessage ?? "Delete \(path) from Builder Mobile",
            "sha": sha,
            "branch": repository.defaultBranch
        ]
        try await send(endpoint, method: "DELETE", json: body, expected: [200])
    }

    // MARK: Bulk upload (one Git commit)

    struct UploadFile {
        let path: String
        let data: Data
    }

    private struct GitReference: Decodable {
        struct Object: Decodable { let sha: String }
        let object: Object
    }

    private struct GitCommitResponse: Decodable {
        struct Tree: Decodable { let sha: String }
        let tree: Tree
    }

    private struct GitObjectResponse: Decodable { let sha: String }

    /// Uploads a collection of files as a single Git commit while preserving existing repository files.
    func uploadFiles(
        _ files: [UploadFile],
        to repository: GitHubRepository,
        parentPath: String = "",
        commitMessage: String = "Upload files from Builder Mobile"
    ) async throws {
        guard !files.isEmpty else { throw makeError("لا توجد ملفات لرفعها.") }
        guard files.count <= 300 else { throw makeError("الحد الأقصى في الرفع الواحد هو 300 ملف.") }
        let totalBytes = files.reduce(0) { $0 + $1.data.count }
        guard totalBytes <= 50 * 1024 * 1024 else {
            throw makeError("حجم الملفات يتجاوز 50 ميغابايت في عملية الرفع الواحدة.")
        }

        let refPath = "/repos/\(repository.fullName)/git/ref/heads/\(encodePath(repository.defaultBranch))"
        let reference: GitReference = try await get(refPath)
        let parentCommit: GitCommitResponse = try await get("/repos/\(repository.fullName)/git/commits/\(reference.object.sha)")

        var treeEntries: [[String: Any]] = []
        for file in files {
            let cleanRelativePath = file.path
                .replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/")
                .filter { !$0.isEmpty && $0 != "." }
                .joined(separator: "/")
            guard !cleanRelativePath.isEmpty,
                  !cleanRelativePath.split(separator: "/").contains("..") else {
                throw makeError("يوجد مسار ملف غير صالح داخل الملفات المختارة.")
            }
            let fullPath = [parentPath, cleanRelativePath].filter { !$0.isEmpty && $0 != "." }.joined(separator: "/")
            let blob: GitObjectResponse = try await sendForResponse(
                "/repos/\(repository.fullName)/git/blobs",
                method: "POST",
                json: ["content": file.data.base64EncodedString(), "encoding": "base64"],
                expected: [201]
            )
            treeEntries.append([
                "path": fullPath,
                "mode": "100644",
                "type": "blob",
                "sha": blob.sha
            ])
        }

        let tree: GitObjectResponse = try await sendForResponse(
            "/repos/\(repository.fullName)/git/trees",
            method: "POST",
            json: ["base_tree": parentCommit.tree.sha, "tree": treeEntries],
            expected: [201]
        )

        let commit: GitObjectResponse = try await sendForResponse(
            "/repos/\(repository.fullName)/git/commits",
            method: "POST",
            json: [
                "message": commitMessage,
                "tree": tree.sha,
                "parents": [reference.object.sha]
            ],
            expected: [201]
        )

        try await send(
            "/repos/\(repository.fullName)/git/refs/heads/\(encodePath(repository.defaultBranch))",
            method: "PATCH",
            json: ["sha": commit.sha],
            expected: [200]
        )
    }

    // MARK: GitHub Actions

    func workflowRuns(for repo: GitHubRepository) async throws -> [WorkflowRun] {
        let response: WorkflowRunsEnvelope = try await get(
            "/repos/\(repo.fullName)/actions/runs?per_page=30"
        )
        return response.workflowRuns
    }

    func artifacts(for repo: GitHubRepository, runID: Int64) async throws -> [BuildArtifact] {
        let response: ArtifactsEnvelope = try await get(
            "/repos/\(repo.fullName)/actions/runs/\(runID)/artifacts?per_page=100"
        )
        return response.artifacts
    }

    func installWorkflow(in repo: GitHubRepository) async throws {
        guard let fileURL = Bundle.main.url(forResource: "ios-build", withExtension: "yml"),
              let workflowText = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw makeError("ملف إعداد البناء غير موجود داخل التطبيق.")
        }

        let endpoint = "/repos/\(repo.fullName)/contents/.github/workflows/ios-build-from-phone.yml"
        struct ExistingFile: Decodable { let sha: String? }
        let existing: ExistingFile? = try? await get(endpoint)

        var body: [String: Any] = [
            "message": "Add or update iOS build workflow from Builder Mobile",
            "content": Data(workflowText.utf8).base64EncodedString(),
            "branch": repo.defaultBranch
        ]
        if let sha = existing?.sha { body["sha"] = sha }
        try await send(endpoint, method: "PUT", json: body, expected: [200, 201])
    }

    /// Adds everything the simulator screenshot run needs to ANY repository:
    /// the workflow plus the small helper files it copies at run time.
    /// The user's own project files are never modified.
    func installSimulatorPreviewWorkflow(in repo: GitHubRepository) async throws {
        guard let fileURL = Bundle.main.url(forResource: "ios-simulator-preview", withExtension: "yml"),
              let workflowText = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw makeError("ملف سير عمل معاينة المحاكي غير موجود داخل التطبيق. أضفه إلى Resources واربطه بملف Xcode project.pbxproj.")
        }

        let support: [(String, String)] = [
            (".github/screenshot-preview/ScreenshotTests.swift", PreviewSupportFiles.screenshotTests),
            (".github/screenshot-preview/HostApp.swift", PreviewSupportFiles.hostApp),
            (".github/screenshot-preview/make_runner.rb", PreviewSupportFiles.makeRunner),
            (".github/screenshot-preview/capture_web.cjs", PreviewSupportFiles.captureWeb)
        ]

        // Helper files first, workflow last, so the workflow never runs without them.
        for (path, text) in support {
            try await putRepositoryFile(
                in: repo,
                path: path,
                text: text,
                message: "Add screenshot preview helper (Builder Mobile)"
            )
        }

        try await putRepositoryFile(
            in: repo,
            path: ".github/workflows/ios-simulator-preview.yml",
            text: workflowText,
            message: "Add or update free iOS Simulator preview workflow"
        )
    }

    func putRepositoryFile(
        in repo: GitHubRepository,
        path: String,
        text: String,
        message: String
    ) async throws {
        let endpoint = "/repos/\(repo.fullName)/contents/\(path)"
        struct ExistingFile: Decodable { let sha: String? }
        let existing: ExistingFile? = try? await get(endpoint)
        var body: [String: Any] = [
            "message": message,
            "content": Data(text.utf8).base64EncodedString(),
            "branch": repo.defaultBranch
        ]
        if let sha = existing?.sha { body["sha"] = sha }
        try await send(endpoint, method: "PUT", json: body, expected: [200, 201])
    }

    func triggerSimulatorPreview(
        in repo: GitHubRepository,
        projectPath: String,
        scheme: String
    ) async throws {
        let endpoint = "/repos/\(repo.fullName)/actions/workflows/ios-simulator-preview.yml/dispatches"
        let body: [String: Any] = [
            "ref": repo.defaultBranch,
            "inputs": [
                "project_path": projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "." : projectPath,
                "scheme": scheme.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
        ]
        try await send(endpoint, method: "POST", json: body, expected: [204])
    }

    func triggerBuild(
        in repo: GitHubRepository,
        projectPath: String,
        scheme: String
    ) async throws {
        let endpoint = "/repos/\(repo.fullName)/actions/workflows/ios-build-from-phone.yml/dispatches"
        let buildID = "iphone-\(Int(Date().timeIntervalSince1970))"
        let body: [String: Any] = [
            "ref": repo.defaultBranch,
            "inputs": [
                "build_id": buildID,
                "project_path": projectPath.isEmpty ? "." : projectPath,
                "scheme": scheme,
                "configuration": "Release"
            ]
        ]
        try await send(endpoint, method: "POST", json: body, expected: [204])
    }

    // MARK: Artifact download

    func downloadArtifact(repo: GitHubRepository, artifact: BuildArtifact) async throws -> URL {
        let url = baseURL.appendingPathComponent("repos/\(repo.fullName)/actions/artifacts/\(artifact.id)/zip")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addHeaders(to: &request)
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw GitHubAPIError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1,
                message: "تعذر تنزيل ملف البناء."
            )
        }

        let safeRepo = repo.name.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeRepo)-\(artifact.name).zip")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: temporaryURL, to: destination)
        return destination
    }

    // MARK: Raw file download (screenshots)

    func rawFile(repository: GitHubRepository, path: String) async throws -> Data {
        var request = URLRequest(url: makeURL("/repos/\(repository.fullName)/contents/\(encodePath(path))"))
        request.httpMethod = "GET"
        addHeaders(to: &request)
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data, expected: [200])
        return data
    }

    // MARK: HTTP helpers

    func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: makeURL(path))
        request.httpMethod = "GET"
        addHeaders(to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data, expected: [200])
        return try decoder.decode(T.self, from: data)
    }

    func send(_ path: String, method: String, json: [String: Any], expected: [Int]) async throws {
        var request = URLRequest(url: makeURL(path))
        request.httpMethod = method
        addHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data, expected: expected)
    }

    func sendForResponse<T: Decodable>(
        _ path: String,
        method: String,
        json: [String: Any],
        expected: [Int]
    ) async throws -> T {
        var request = URLRequest(url: makeURL(path))
        request.httpMethod = method
        addHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data, expected: expected)
        return try decoder.decode(T.self, from: data)
    }

    func makeURL(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!
    }

    func encodePath(_ path: String) -> String {
        path.split(separator: "/").map { component in
            String(component).addingPercentEncoding(
                withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            ) ?? String(component)
        }.joined(separator: "/")
    }

    func addHeaders(to request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("BuilderMobile/1.1", forHTTPHeaderField: "User-Agent")
    }

    func validate(response: URLResponse, data: Data, expected: [Int]) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GitHubAPIError(statusCode: -1, message: "استجابة شبكة غير صالحة.")
        }
        guard expected.contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                ?? String(data: data, encoding: .utf8)
                ?? "طلب GitHub لم ينجح."
            throw GitHubAPIError(statusCode: http.statusCode, message: message)
        }
    }

    func makeError(_ message: String) -> NSError {
        NSError(domain: "BuilderMobile", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - Files added to a repository for simulator screenshots

enum PreviewSupportFiles {
    static let screenshotTests = #"""
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
"""#

    static let hostApp = #"""
import UIKit

@main
final class HostAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
}
"""#

    static let makeRunner = #"""
require 'xcodeproj'

dir = ENV['RUNNER_DIR']
path = File.join(dir, 'PreviewRunner.xcodeproj')

project = Xcodeproj::Project.new(path)

host = project.new_target(:application, 'PreviewHost', :ios, '15.0')
host_group = project.main_group.new_group('PreviewHost', 'PreviewHost')
host.add_file_references([host_group.new_file('HostApp.swift')])

ui = project.new_target(:ui_test_bundle, 'PreviewUITests', :ios, '15.0')
ui_group = project.main_group.new_group('PreviewUITests', 'PreviewUITests')
ui.add_file_references([ui_group.new_file('ScreenshotTests.swift')])
ui.add_dependency(host)

host.build_configurations.each do |configuration|
  s = configuration.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.preview.host'
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
  s['MARKETING_VERSION'] = '1.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['SWIFT_VERSION'] = '5.0'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['CODE_SIGNING_REQUIRED'] = 'NO'
end

ui.build_configurations.each do |configuration|
  s = configuration.build_settings
  s['PRODUCT_NAME'] = 'PreviewUITests'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.preview.PreviewUITests'
  s['TEST_TARGET_NAME'] = 'PreviewHost'
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['SWIFT_VERSION'] = '5.0'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['CODE_SIGNING_REQUIRED'] = 'NO'
end

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(host)
scheme.add_test_target(ui)
scheme.set_launch_target(host)
scheme.save_as(path, 'PreviewUI', true)

project.save
puts 'Runner project created'
"""#

    static let captureWeb = #"""
const { chromium, devices } = require('playwright');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const [, , root, out, base] = process.argv;
const skip = new Set(['node_modules', 'Pods', 'build', 'Screenshots', 'ios', 'android']);

function walk(dir, acc = [], depth = 0) {
  if (depth > 4) return acc;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) {
      if (!skip.has(e.name) && !e.name.startsWith('.')) {
        walk(path.join(dir, e.name), acc, depth + 1);
      }
    } else if (/\.html?$/i.test(e.name)) {
      acc.push(path.relative(root, path.join(dir, e.name)));
    }
  }
  return acc;
}

(async () => {
  const pages = walk(root)
    .sort((a, b) => a === 'index.html' ? -1 : b === 'index.html' ? 1 : a.localeCompare(b))
    .slice(0, 12);

  const browser = await chromium.launch();
  const context = await browser.newContext({ ...devices['iPhone 14'] });
  const page = await context.newPage();

  const lines = [];
  const seen = new Set();
  let n = 0;

  async function snap(slug, title, full) {
    if (n >= 40) return false;
    await page.waitForTimeout(700);
    const buf = await page.screenshot({ fullPage: !!full });
    const key = crypto.createHash('md5').update(buf).digest('hex');
    if (seen.has(key)) return false;
    seen.add(key);
    n += 1;
    const name = String(n).padStart(2, '0') + '-' + slug;
    fs.writeFileSync(path.join(out, name + '.png'), buf);
    lines.push(name + '|' + title.replace(/[|\n]/g, ' '));
    return true;
  }

  const selector = 'button, [role=button], a[href^="#"], a[href$=".html"], [onclick]';

  for (const [i, p] of pages.entries()) {
    const url = base + '/' + p.split(path.sep).map(encodeURIComponent).join('/');

    try {
      await page.goto(url, { waitUntil: 'networkidle', timeout: 20000 });
    } catch (e) {
      try { await page.goto(url, { timeout: 20000 }); } catch (e2) { continue; }
    }

    await snap('page' + (i + 1), 'صفحة ' + p, false);
    await snap('page' + (i + 1) + '-full', 'صفحة ' + p + ' (كاملة)', true);

    const count = Math.min(await page.locator(selector).count(), 10);

    for (let j = 0; j < count; j++) {
      const el = page.locator(selector).nth(j);
      let label = '';
      try {
        if (!(await el.isVisible())) continue;
        label = (await el.innerText({ timeout: 1000 })).trim().slice(0, 30);
        await el.click({ timeout: 2000, noWaitAfter: true });
      } catch (e) { continue; }

      await snap('page' + (i + 1) + '-a' + (j + 1),
        'صفحة ' + p + ' › ' + (label || 'عنصر ' + (j + 1)), false);

      try { await page.goto(url, { waitUntil: 'load', timeout: 20000 }); } catch (e) {}
    }
  }

  fs.writeFileSync(path.join(out, 'index.txt'), lines.join('\n') + '\n');
  await browser.close();
  console.log('TOTAL_SCREENSHOTS: ' + n);
})();
"""#
}
