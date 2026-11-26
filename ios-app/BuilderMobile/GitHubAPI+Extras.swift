import Foundation
import ZIPFoundation

// MARK: - Extra GitHub operations (delete, export, build logs, signing secrets)

extension GitHubAPI {

    // MARK: Repository deletion

    func deleteRepository(_ repository: GitHubRepository) async throws {
        var request = URLRequest(url: makeURL("/repos/\(repository.fullName)"))
        request.httpMethod = "DELETE"
        addHeaders(to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data, expected: [204])
    }

    // MARK: Git tree helpers

    private struct RefResponse: Decodable {
        struct Obj: Decodable { let sha: String }
        let object: Obj
    }

    private struct CommitResponse: Decodable {
        struct Tree: Decodable { let sha: String }
        let tree: Tree
    }

    private struct ShaResponse: Decodable { let sha: String }

    func fullTree(of repository: GitHubRepository) async throws -> [GitTreeEntry] {
        let branch = encodePath(repository.defaultBranch)
        let response: GitTreeResponse = try await get(
            "/repos/\(repository.fullName)/git/trees/\(branch)?recursive=1"
        )
        return response.tree
    }

    /// Deletes files and folders (recursively) in ONE commit.
    /// If nothing would be left in the repository a `.gitkeep` file is added so the branch is never empty.
    @discardableResult
    func deletePaths(
        _ paths: [String],
        in repository: GitHubRepository,
        commitMessage: String = "Delete files from Builder Mobile"
    ) async throws -> Int {
        let targets = paths.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }.filter { !$0.isEmpty }
        guard !targets.isEmpty else { throw makeError("لم يتم تحديد أي ملف للحذف.") }

        let entries = try await fullTree(of: repository)
        let blobs = entries.filter { $0.type == "blob" }
        let toDelete = blobs.filter { blob in
            targets.contains { blob.path == $0 || blob.path.hasPrefix($0 + "/") }
        }
        guard !toDelete.isEmpty else { throw makeError("لم يتم العثور على الملفات المحددة في المستودع.") }

        var treeEntries: [[String: Any]] = toDelete.map {
            ["path": $0.path, "mode": "100644", "type": "blob", "sha": NSNull()]
        }
        if toDelete.count == blobs.count {
            treeEntries.append(["path": ".gitkeep", "mode": "100644", "type": "blob", "content": "\n"])
        }

        let branch = encodePath(repository.defaultBranch)
        let ref: RefResponse = try await get("/repos/\(repository.fullName)/git/ref/heads/\(branch)")
        let parent: CommitResponse = try await get("/repos/\(repository.fullName)/git/commits/\(ref.object.sha)")

        let tree: ShaResponse = try await sendForResponse(
            "/repos/\(repository.fullName)/git/trees",
            method: "POST",
            json: ["base_tree": parent.tree.sha, "tree": treeEntries],
            expected: [201]
        )
        let commit: ShaResponse = try await sendForResponse(
            "/repos/\(repository.fullName)/git/commits",
            method: "POST",
            json: ["message": commitMessage, "tree": tree.sha, "parents": [ref.object.sha]],
            expected: [201]
        )
        try await send(
            "/repos/\(repository.fullName)/git/refs/heads/\(branch)",
            method: "PATCH",
            json: ["sha": commit.sha],
            expected: [200]
        )
        return toDelete.count
    }

    // MARK: Export (download)

    func downloadRepositoryZip(_ repository: GitHubRepository) async throws -> URL {
        let branch = encodePath(repository.defaultBranch)
        var request = URLRequest(url: makeURL("/repos/\(repository.fullName)/zipball/\(branch)"))
        request.httpMethod = "GET"
        addHeaders(to: &request)
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw GitHubAPIError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1,
                message: "تعذر تنزيل المشروع."
            )
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.safeName(repository.name)).zip")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// Prepares a file the user can save/share.
    /// - one file  -> the file itself
    /// - anything else (folders, many files, "everything") -> a ZIP
    func exportItems(
        _ items: [RepoItemRef],
        from repository: GitHubRepository,
        folderPath: String = ""
    ) async throws -> URL {
        let fm = FileManager.default

        if items.count == 1, let only = items.first, !only.isDirectory {
            let data = try await rawFile(repository: repository, path: only.path)
            let dir = fm.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(only.name)
            try data.write(to: url)
            return url
        }

        let zipball = try await downloadRepositoryZip(repository)
        defer { try? fm.removeItem(at: zipball) }

        let work = fm.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let extracted = work.appendingPathComponent("src", isDirectory: true)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        try fm.unzipItem(at: zipball, to: extracted)

        let tops = try fm.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "__MACOSX" }
        let root = (tops.count == 1) ? tops[0] : extracted

        let outputName: String
        let stage = work.appendingPathComponent("stage", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)

        if items.isEmpty {
            // Whole folder (or whole repository when folderPath is empty).
            let base = folderPath.isEmpty ? root : root.appendingPathComponent(folderPath, isDirectory: true)
            guard fm.fileExists(atPath: base.path) else { throw makeError("المجلد غير موجود في المستودع.") }
            outputName = folderPath.isEmpty ? repository.name : (folderPath as NSString).lastPathComponent
            let children = try fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            for child in children {
                try fm.copyItem(at: child, to: stage.appendingPathComponent(child.lastPathComponent))
            }
        } else {
            outputName = repository.name + "-selection"
            for item in items {
                let source = root.appendingPathComponent(item.path)
                guard fm.fileExists(atPath: source.path) else { continue }
                let destination = stage.appendingPathComponent(item.path)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: destination)
            }
        }

        let zipURL = fm.temporaryDirectory.appendingPathComponent("\(Self.safeName(outputName))-\(Int(Date().timeIntervalSince1970)).zip")
        try? fm.removeItem(at: zipURL)
        try fm.zipItem(at: stage, to: zipURL, shouldKeepParent: false)
        return zipURL
    }

    /// Downloads a build artifact and, when it contains an .ipa, returns the .ipa itself (ready to share).
    /// Otherwise returns the downloaded ZIP.
    func downloadShareable(repo: GitHubRepository, artifact: BuildArtifact) async throws -> URL {
        let zip = try await downloadArtifact(repo: repo, artifact: artifact)
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ipa-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.unzipItem(at: zip, to: work)
        } catch {
            return zip
        }
        guard let enumerator = fm.enumerator(at: work, includingPropertiesForKeys: nil),
              let ipa = enumerator.compactMap({ $0 as? URL }).first(where: { $0.pathExtension.lowercased() == "ipa" })
        else { return zip }

        let outDir = fm.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let destination = outDir.appendingPathComponent(ipa.lastPathComponent)
        try fm.copyItem(at: ipa, to: destination)
        return destination
    }

    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "-", options: .regularExpression)
        return cleaned.isEmpty ? "export" : cleaned
    }

    // MARK: Build history, jobs and logs

    func jobs(for repository: GitHubRepository, runID: Int64) async throws -> [WorkflowJob] {
        let response: WorkflowJobsEnvelope = try await get(
            "/repos/\(repository.fullName)/actions/runs/\(runID)/jobs?per_page=100"
        )
        return response.jobs
    }

    func jobLog(for repository: GitHubRepository, jobID: Int64) async throws -> String {
        var request = URLRequest(url: makeURL("/repos/\(repository.fullName)/actions/jobs/\(jobID)/logs"))
        request.httpMethod = "GET"
        addHeaders(to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data, expected: [200])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Signing workflow and secrets

    func actionsPublicKey(for repository: GitHubRepository) async throws -> ActionsPublicKey {
        try await get("/repos/\(repository.fullName)/actions/secrets/public-key")
    }

    func putSecret(_ name: String, value: Data, in repository: GitHubRepository) async throws {
        let publicKey = try await actionsPublicKey(for: repository)
        guard let keyData = Data(base64Encoded: publicKey.key) else {
            throw makeError("تعذر قراءة المفتاح العام من GitHub.")
        }
        let sealed = try SealedBox.seal(value, recipientPublicKey: keyData)
        try await send(
            "/repos/\(repository.fullName)/actions/secrets/\(name)",
            method: "PUT",
            json: ["encrypted_value": sealed.base64EncodedString(), "key_id": publicKey.keyID],
            expected: [201, 204]
        )
    }

    func installSigningWorkflow(in repository: GitHubRepository) async throws {
        guard let fileURL = Bundle.main.url(forResource: "ios-sign", withExtension: "yml"),
              let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw makeError("ملف سير عمل التوقيع غير موجود داخل التطبيق.")
        }
        try await putRepositoryFile(
            in: repository,
            path: ".github/workflows/ios-sign.yml",
            text: text,
            message: "Add or update iOS signing workflow (Builder Mobile)"
        )
    }

    func triggerSigning(
        in repository: GitHubRepository,
        buildRunID: Int64,
        artifactName: String,
        signedName: String,
        bundleID: String
    ) async throws {
        let endpoint = "/repos/\(repository.fullName)/actions/workflows/ios-sign.yml/dispatches"
        let body: [String: Any] = [
            "ref": repository.defaultBranch,
            "inputs": [
                "run_id": String(buildRunID),
                "artifact_name": artifactName,
                "signed_name": signedName,
                "bundle_id": bundleID
            ]
        ]
        try await send(endpoint, method: "POST", json: body, expected: [204])
    }

    func signingRuns(for repository: GitHubRepository) async throws -> [WorkflowRun] {
        let response: WorkflowRunsEnvelope = try await get(
            "/repos/\(repository.fullName)/actions/workflows/ios-sign.yml/runs?per_page=5&event=workflow_dispatch"
        )
        return response.workflowRuns
    }

    func run(_ runID: Int64, in repository: GitHubRepository) async throws -> WorkflowRun {
        try await get("/repos/\(repository.fullName)/actions/runs/\(runID)")
    }

    // MARK: Binary upload of a single file (used by the AI assistant)

    func saveBinaryFile(
        _ data: Data,
        path: String,
        in repository: GitHubRepository,
        message: String
    ) async throws {
        try await uploadFiles(
            [UploadFile(path: path, data: data)],
            to: repository,
            parentPath: "",
            commitMessage: message
        )
    }
}

// MARK: - Log analysis

enum LogAnalyzer {
    private static let timestamp = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T[\d:.]+Z\s?"#)

    static func clean(_ line: String) -> String {
        let range = NSRange(line.startIndex..., in: line)
        return timestamp.stringByReplacingMatches(in: line, range: range, withTemplate: "")
    }

    static func cleanedLog(_ raw: String) -> String {
        raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { clean(String($0)) }
            .joined(separator: "\n")
    }

    private static let markers = [
        "##[error]", ": error:", "error:", "fatal error", "** build failed **", "** archive failed **",
        "xcodebuild: error", "undefined symbols", "no such module", "command phasescriptexecution failed",
        "linker command failed", "the following build commands failed", "could not find", "exit code 1",
        "code signing is required", "provisioning profile", "cannot find", "failed with exit code"
    ]

    /// Returns the lines that explain why a build failed (deduplicated, in order).
    static func errors(in raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawLine in raw.split(separator: "\n") {
            let line = clean(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("##[group]") || lower.hasPrefix("##[endgroup]") { continue }
            if markers.contains(where: { lower.contains($0) }) {
                let key = line.replacingOccurrences(of: "##[error]", with: "")
                if seen.insert(key).inserted { result.append(line) }
            }
            if result.count >= 150 { break }
        }
        return result
    }

    static func tail(of raw: String, lines count: Int = 60) -> String {
        let all = raw.split(separator: "\n").map { clean(String($0)) }
        return all.suffix(count).joined(separator: "\n")
    }
}
