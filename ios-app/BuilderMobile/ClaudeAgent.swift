import Foundation
import SwiftUI
import UIKit

// MARK: - Anthropic Messages API client

struct ClaudeClient {
    let apiKey: String

    struct Reply {
        let content: [[String: Any]]
        let stopReason: String
    }

    static let availableModels: [(id: String, title: String)] = [
        ("claude-sonnet-5-5", "Claude Sonnet 5.5 — سريع ومتوازن"),
        ("claude-opus-5-5", "Claude Opus 5.5 — الأقوى"),
        ("claude-haiku-5-5", "Claude Haiku 5.5 — الأسرع والأرخص")
    ]

    func complete(
        model: String,
        system: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        maxTokens: Int = 8192
    ) async throws -> Reply {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages
        ]
        if !tools.isEmpty { body["tools"] = tools }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard status == 200, let json else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? String(data: data, encoding: .utf8)
                ?? "فشل الطلب"
            var text = "Claude (\(status)): \(message)"
            if status == 401 { text += "\nتحقق من مفتاح API في الإعدادات." }
            throw NSError(domain: "Claude", code: status, userInfo: [NSLocalizedDescriptionKey: text])
        }

        let content = (json["content"] as? [[String: Any]] ?? []).filter {
            let type = $0["type"] as? String
            return type == "text" || type == "tool_use"
        }
        return Reply(content: content, stopReason: json["stop_reason"] as? String ?? "end_turn")
    }
}

// MARK: - Chat data

struct ChatAttachment: Identifiable {
    enum Kind { case image, text, binary }
    let id = UUID()
    let name: String
    let data: Data
    let kind: Kind
    var mediaType: String = "image/jpeg"
}

struct ChatItem: Identifiable {
    enum Role { case user, assistant, activity, error }
    let id = UUID()
    let role: Role
    var text: String
    var attachmentNames: [String] = []
}

// MARK: - Agent

@MainActor
final class AIChatModel: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var isRunning = false
    @Published var repository: GitHubRepository?

    private weak var app: AppModel?
    private var history: [[String: Any]] = []
    private var attachmentStore: [String: Data] = [:]
    private var task: Task<Void, Never>?
    private var didSendInitial = false

    func configure(app: AppModel, repository: GitHubRepository?) {
        self.app = app
        if self.repository == nil { self.repository = repository }
    }

    func sendInitialIfNeeded(_ prompt: String?) {
        guard let prompt, !prompt.isEmpty, !didSendInitial else { return }
        didSendInitial = true
        send(text: prompt, attachments: [])
    }

    func reset() {
        stop()
        items = []
        history = []
        attachmentStore = [:]
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    // MARK: Sending

    func send(text: String, attachments: [ChatAttachment]) {
        guard let app, !isRunning else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        guard app.aiReady else {
            items.append(ChatItem(role: .error, text: "أضف مفتاح الذكاء الاصطناعي أولاً من الإعدادات."))
            return
        }

        repairHistory()

        var blocks: [[String: Any]] = []
        var attachmentNotes: [String] = []
        for file in attachments {
            attachmentStore[file.name] = file.data
            switch file.kind {
            case .image:
                blocks.append([
                    "type": "image",
                    "source": ["type": "base64", "media_type": file.mediaType, "data": file.data.base64EncodedString()]
                ])
                attachmentNotes.append("صورة مرفقة: \(file.name) (يمكنك حفظها داخل المشروع بالأداة save_attachment)")
            case .text:
                let content = String(decoding: file.data, as: UTF8.self)
                blocks.append(["type": "text", "text": "ملف مرفق: \(file.name)\n```\n\(content)\n```"])
            case .binary:
                attachmentNotes.append("ملف مرفق ثنائي: \(file.name) (\(file.data.count) بايت) — يمكن حفظه بالأداة save_attachment")
            }
        }
        var message = trimmed
        if !attachmentNotes.isEmpty { message += "\n\n" + attachmentNotes.joined(separator: "\n") }
        if !message.isEmpty { blocks.append(["type": "text", "text": message]) }

        history.append(["role": "user", "content": blocks])
        items.append(ChatItem(role: .user, text: trimmed, attachmentNames: attachments.map(\.name)))

        isRunning = true
        task = Task { [weak self] in
            await self?.runLoop()
            self?.isRunning = false
        }
    }

    /// Makes sure every tool_use in the history has a matching tool_result (after a cancelled run).
    private func repairHistory() {
        guard let last = history.last,
              last["role"] as? String == "assistant",
              let content = last["content"] as? [[String: Any]] else { return }
        let uses = content.filter { $0["type"] as? String == "tool_use" }
        guard !uses.isEmpty else { return }
        let results: [[String: Any]] = uses.map {
            ["type": "tool_result", "tool_use_id": $0["id"] as? String ?? "", "content": "تم إيقاف العملية.", "is_error": true]
        }
        history.append(["role": "user", "content": results])
    }

    // MARK: Agent loop

    private func runLoop() async {
        guard let app else { return }
        var iterations = 0

        while iterations < 30, !Task.isCancelled {
            iterations += 1
            do {
                let reply: ClaudeClient.Reply
                if app.aiProvider == "claude" {
                    reply = try await ClaudeClient(apiKey: app.anthropicKey).complete(
                        model: app.aiModel,
                        system: systemPrompt(),
                        messages: history,
                        tools: Self.toolDefinitions
                    )
                } else if app.aiProvider == "gemini" {
                    reply = try await OpenAICompatClient(
                        apiKey: app.geminiKey,
                        baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"
                    ).complete(
                        model: app.geminiModel,
                        system: systemPrompt(),
                        messages: history,
                        tools: Self.toolDefinitions
                    )
                } else {
                    reply = try await OpenAICompatClient(apiKey: app.freeAIKey).complete(
                        model: app.freeModel,
                        system: systemPrompt(),
                        messages: history,
                        tools: Self.toolDefinitions
                    )
                }
                if Task.isCancelled { return }
                history.append(["role": "assistant", "content": reply.content])

                for block in reply.content where block["type"] as? String == "text" {
                    let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { items.append(ChatItem(role: .assistant, text: text)) }
                }

                guard reply.stopReason == "tool_use" else {
                    if reply.stopReason == "max_tokens" {
                        items.append(ChatItem(role: .error, text: "توقف الرد لأنه وصل للحد الأقصى. اكتب «أكمل» للمتابعة."))
                    }
                    return
                }

                var results: [[String: Any]] = []
                for block in reply.content where block["type"] as? String == "tool_use" {
                    let name = block["name"] as? String ?? ""
                    let id = block["id"] as? String ?? ""
                    let input = block["input"] as? [String: Any] ?? [:]
                    items.append(ChatItem(role: .activity, text: describe(tool: name, input: input)))
                    let (output, failed) = await execute(tool: name, input: input)
                    var result: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": output]
                    if failed {
                        result["is_error"] = true
                        items.append(ChatItem(role: .error, text: output))
                    }
                    results.append(result)
                }
                history.append(["role": "user", "content": results])
            } catch {
                if !Task.isCancelled {
                    items.append(ChatItem(role: .error, text: error.localizedDescription))
                }
                return
            }
        }
        if iterations >= 30 {
            items.append(ChatItem(role: .error, text: "توقفت المهمة بعد 30 خطوة. اكتب «أكمل» للمتابعة."))
        }
    }

    private func describe(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "list_files":
            let path = input["path"] as? String ?? ""
            return path.isEmpty ? "📂 عرض الملفات" : "📂 عرض الملفات في " + path
        case "read_file": return "📖 قراءة \(input["path"] as? String ?? "")"
        case "write_files":
            let files = input["files"] as? [[String: Any]] ?? []
            return "📝 كتابة \(files.count) ملف: " + files.prefix(4).compactMap { $0["path"] as? String }.joined(separator: "، ")
        case "delete_files": return "🗑 حذف: " + (input["paths"] as? [String] ?? []).joined(separator: "، ")
        case "create_repository": return "➕ إنشاء مشروع \(input["name"] as? String ?? "")"
        case "get_build_logs": return "🔎 قراءة سجل البناء والأخطاء"
        case "trigger_build": return "🔨 تشغيل بناء جديد"
        case "save_attachment": return "📎 حفظ المرفق \(input["name"] as? String ?? "")"
        default: return tool
        }
    }

    // MARK: System prompt

    private func systemPrompt() -> String {
        var context = "لا يوجد مشروع محدد حالياً؛ إذا طلب المستخدم مشروعاً جديداً فأنشئه بالأداة create_repository ثم اكتب ملفاته."
        if let repository {
            context = "المشروع الحالي: \(repository.fullName) — الفرع الافتراضي: \(repository.defaultBranch) — \(repository.isPrivate ? "خاص" : "عام")."
            if let category = app?.category(for: repository) { context += " التصنيف: \(category.singular)." }
        }
        return """
        You are the built-in AI engineer of "azawy coder", an iPhone app that manages GitHub projects, edits code and builds iOS apps through GitHub Actions. \
        Always answer in the user's language (Arabic by default) and keep replies short and practical.

        \(context)

        Rules:
        - Look before you edit: use list_files and read_file to understand the project, then change only what is needed.
        - Write COMPLETE, working files with write_files (one commit per logical change, send several files in one call). Never write partial snippets or placeholders into files.
        - To fix build problems call get_build_logs first, find the real cause, fix the files, then offer to run trigger_build.
        - New iOS apps: use Swift/SwiftUI and add a `project.yml` (XcodeGen) at the repository root; the build workflow generates the .xcodeproj from it automatically. Do not hand-write .pbxproj files.
        - Websites: create a self-contained index.html (plus css/js files if needed) that works when opened directly.
        - Never put secrets, tokens or certificates into repository files.
        - When you finish, summarise what changed in a few lines.
        """
    }

    // MARK: Tools

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "list_files",
            "description": "List files and folders of the current project at a path (empty path = root).",
            "input_schema": ["type": "object", "properties": ["path": ["type": "string"]]]
        ],
        [
            "name": "read_file",
            "description": "Read a text file from the current project.",
            "input_schema": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]]
        ],
        [
            "name": "write_files",
            "description": "Create or overwrite one or more text files in the current project in a single commit.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "files": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": ["path": ["type": "string"], "content": ["type": "string"]],
                            "required": ["path", "content"]
                        ]
                    ],
                    "commit_message": ["type": "string"]
                ],
                "required": ["files"]
            ]
        ],
        [
            "name": "delete_files",
            "description": "Delete files or folders (recursively) from the current project in a single commit.",
            "input_schema": [
                "type": "object",
                "properties": ["paths": ["type": "array", "items": ["type": "string"]], "commit_message": ["type": "string"]],
                "required": ["paths"]
            ]
        ],
        [
            "name": "create_repository",
            "description": "Create a new GitHub repository and make it the current project.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string"],
                    "description": ["type": "string"],
                    "private": ["type": "boolean"],
                    "category": ["type": "string", "enum": ["app", "source", "website"]]
                ],
                "required": ["name"]
            ]
        ],
        [
            "name": "get_build_logs",
            "description": "Show recent GitHub Actions runs of the current project and, for a failed run, the extracted errors and the end of the log. Optional run_id selects a specific run.",
            "input_schema": ["type": "object", "properties": ["run_id": ["type": "integer"]]]
        ],
        [
            "name": "trigger_build",
            "description": "Start an iOS IPA build on GitHub Actions for the current project.",
            "input_schema": [
                "type": "object",
                "properties": ["project_path": ["type": "string"], "scheme": ["type": "string"]]
            ]
        ],
        [
            "name": "save_attachment",
            "description": "Save a file the user attached in this chat (image, zip, binary...) into the current project at the given path.",
            "input_schema": [
                "type": "object",
                "properties": ["name": ["type": "string"], "path": ["type": "string"]],
                "required": ["name", "path"]
            ]
        ]
    ]

    private func execute(tool: String, input: [String: Any]) async -> (String, Bool) {
        guard let app else { return ("التطبيق غير جاهز.", true) }
        let api = GitHubAPI(token: app.token)

        func needRepo() -> GitHubRepository? { repository }
        let noRepo = ("لا يوجد مشروع محدد. أنشئ مشروعاً أولاً بالأداة create_repository.", true)

        do {
            switch tool {
            case "list_files":
                guard let repo = needRepo() else { return noRepo }
                let path = input["path"] as? String ?? ""
                let files = try await api.listProjectFiles(repository: repo, path: path)
                let lines = files
                    .sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name < $1.name }
                    .map { ($0.isDirectory ? "[dir]  " : "[file] ") + $0.path }
                return (lines.isEmpty ? "(فارغ)" : lines.joined(separator: "\n"), false)

            case "read_file":
                guard let repo = needRepo() else { return noRepo }
                let path = input["path"] as? String ?? ""
                let file = try await api.readProjectFile(repository: repo, path: path)
                guard let text = file.decodedText else { return ("الملف ثنائي أو كبير جداً للقراءة كنص.", true) }
                if text.count > 40_000 { return (String(text.prefix(40_000)) + "\n…(تم اقتطاع الملف)", false) }
                return (text, false)

            case "write_files":
                guard let repo = needRepo() else { return noRepo }
                let files = input["files"] as? [[String: Any]] ?? []
                var uploads: [GitHubAPI.UploadFile] = []
                for file in files {
                    guard let path = file["path"] as? String, !path.isEmpty,
                          let content = file["content"] as? String else { continue }
                    uploads.append(.init(path: path, data: Data(content.utf8)))
                }
                guard !uploads.isEmpty else { return ("لا توجد ملفات صالحة للكتابة.", true) }
                let message = (input["commit_message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Update from AI assistant"
                try await uploadWithRetry(api: api, uploads: uploads, repo: repo, message: message)
                return ("تمت كتابة \(uploads.count) ملف في commit واحد.", false)

            case "delete_files":
                guard let repo = needRepo() else { return noRepo }
                let paths = input["paths"] as? [String] ?? []
                let message = (input["commit_message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Delete files from AI assistant"
                let count = try await api.deletePaths(paths, in: repo, commitMessage: message)
                return ("تم حذف \(count) ملف.", false)

            case "create_repository":
                let name = input["name"] as? String ?? ""
                let description = input["description"] as? String ?? ""
                let isPrivate = input["private"] as? Bool ?? true
                let category = (input["category"] as? String).flatMap(ProjectCategory.init(rawValue:))
                let created = await app.createRepository(name: name, description: description, isPrivate: isPrivate, category: category)
                guard created, let repo = app.repositories.first else {
                    return (app.errorMessage ?? "تعذر إنشاء المشروع.", true)
                }
                repository = repo
                return ("تم إنشاء المشروع \(repo.fullName) (الفرع \(repo.defaultBranch)) وأصبح هو المشروع الحالي.", false)

            case "get_build_logs":
                guard let repo = needRepo() else { return noRepo }
                return (try await buildReport(api: api, repo: repo, runID: (input["run_id"] as? NSNumber)?.int64Value), false)

            case "trigger_build":
                guard let repo = needRepo() else { return noRepo }
                let path = (input["project_path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "."
                let scheme = input["scheme"] as? String ?? ""
                await app.prepareAndBuild(repo: repo, projectPath: path, scheme: scheme)
                if let error = app.errorMessage { return (error, true) }
                return ("تم تشغيل البناء. يمكن للمستخدم متابعته من «سجل البناء».", false)

            case "save_attachment":
                guard let repo = needRepo() else { return noRepo }
                let name = input["name"] as? String ?? ""
                let path = input["path"] as? String ?? name
                guard let data = attachmentStore[name] else { return ("لا يوجد مرفق بهذا الاسم.", true) }
                try await uploadWithRetry(
                    api: api,
                    uploads: [.init(path: path, data: data)],
                    repo: repo,
                    message: "Add \(path) from AI assistant"
                )
                return ("تم حفظ المرفق في \(path).", false)

            default:
                return ("أداة غير معروفة: \(tool)", true)
            }
        } catch {
            return (error.localizedDescription, true)
        }
    }

    private func uploadWithRetry(
        api: GitHubAPI,
        uploads: [GitHubAPI.UploadFile],
        repo: GitHubRepository,
        message: String
    ) async throws {
        var attempt = 0
        while true {
            do {
                try await api.uploadFiles(uploads, to: repo, commitMessage: message)
                return
            } catch let error as GitHubAPIError where [404, 409].contains(error.statusCode) && attempt < 3 {
                attempt += 1
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func buildReport(api: GitHubAPI, repo: GitHubRepository, runID: Int64?) async throws -> String {
        let runs = try await api.workflowRuns(for: repo)
        guard !runs.isEmpty else { return "لا توجد عمليات بناء بعد." }

        var report = "آخر العمليات:\n"
        for run in runs.prefix(6) {
            report += "- #\(run.runNumber) id=\(run.id) \(run.title): \(run.displayStatus)\n"
        }

        let target = runID.flatMap { id in runs.first { $0.id == id } } ?? runs.first(where: { $0.isFailure }) ?? runs[0]
        report += "\nالعملية المفحوصة: #\(target.runNumber) (\(target.displayStatus))\n"

        let jobs = try await api.jobs(for: repo, runID: target.id)
        for job in jobs {
            report += "\nJob: \(job.name) → \(job.conclusion ?? job.status)\n"
            for step in job.steps ?? [] where step.conclusion == "failure" {
                report += "  خطوة فاشلة: \(step.name)\n"
            }
        }

        for job in jobs where job.conclusion == "failure" {
            let raw = (try? await api.jobLog(for: repo, jobID: job.id)) ?? ""
            let errors = LogAnalyzer.errors(in: raw)
            report += "\n--- الأخطاء في \(job.name) ---\n" + (errors.isEmpty ? "(لم يتم استخراج أخطاء محددة)" : errors.prefix(60).joined(separator: "\n"))
            report += "\n--- نهاية السجل ---\n" + LogAnalyzer.tail(of: raw, lines: 40) + "\n"
        }
        return String(report.prefix(14_000))
    }
}

// MARK: - Image helper

enum ImagePreparer {
    static func jpeg(from data: Data, maxDimension: CGFloat = 1568) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: 0.8)
    }
}
