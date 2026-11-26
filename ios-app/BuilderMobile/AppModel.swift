
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var token: String = KeychainStore.loadToken() ?? ""
    @Published var user: GitHubUser?
    @Published var repositories: [GitHubRepository] = []
    @Published var runsByRepository: [String: [WorkflowRun]] = [:]
    @Published var isBusy = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var downloadedArtifactURL: URL?
    @Published var categories: [String: String] = UserDefaults.standard.dictionary(forKey: "repoCategories") as? [String: String] ?? [:]
    @Published var anthropicKey: String = KeychainStore.loadString(account: KeychainStore.anthropicAccount) ?? ""
    @Published var aiModel: String = UserDefaults.standard.string(forKey: "aiModel") ?? "claude-sonnet-5-5"
    /// "free" = free coding model through OpenRouter, "claude" = Anthropic API.
    @Published var aiProvider: String = UserDefaults.standard.string(forKey: "aiProvider") ?? "free"
    @Published var freeAIKey: String = KeychainStore.loadString(account: "openrouter-api-key") ?? ""
    @Published var freeModel: String = UserDefaults.standard.string(forKey: "freeModel") ?? OpenAICompatClient.defaultModel

    @Published var geminiKey: String = KeychainStore.loadString(account: "gemini-api-key") ?? ""
    @Published var geminiModel: String = UserDefaults.standard.string(forKey: "geminiModel").flatMap { $0 == "gemini-2.5-flash" ? nil : $0 } ?? "gemini-3.8-flash"

    var aiReady: Bool {
        switch aiProvider {
        case "claude": return !anthropicKey.isEmpty
        case "gemini": return !geminiKey.isEmpty
        default: return !freeAIKey.isEmpty
        }
    }

    func saveGeminiKey(_ key: String) {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
        geminiKey = cleaned
        if cleaned.isEmpty { KeychainStore.delete(account: "gemini-api-key") }
        else { try? KeychainStore.saveString(cleaned, account: "gemini-api-key") }
    }

    func saveGeminiModel(_ value: String) {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        geminiModel = cleaned.isEmpty ? "gemini-3.8-flash" : cleaned
        UserDefaults.standard.set(geminiModel, forKey: "geminiModel")
    }

    func saveAIProvider(_ value: String) {
        aiProvider = value
        UserDefaults.standard.set(value, forKey: "aiProvider")
    }

    func saveFreeKey(_ key: String) {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
        freeAIKey = cleaned
        if cleaned.isEmpty { KeychainStore.delete(account: "openrouter-api-key") }
        else { try? KeychainStore.saveString(cleaned, account: "openrouter-api-key") }
    }

    func saveFreeModel(_ value: String) {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        freeModel = cleaned.isEmpty ? OpenAICompatClient.defaultModel : cleaned
        UserDefaults.standard.set(freeModel, forKey: "freeModel")
    }

    let certificates = CertificateStore()

    private var api: GitHubAPI { GitHubAPI(token: token) }
    var github: GitHubAPI { GitHubAPI(token: token) }

    // MARK: - Categories (apps / sources / websites)

    func category(for repo: GitHubRepository) -> ProjectCategory? {
        categories[String(repo.id)].flatMap(ProjectCategory.init(rawValue:))
    }

    func setCategory(_ category: ProjectCategory?, for repo: GitHubRepository) {
        if let category { categories[String(repo.id)] = category.rawValue }
        else { categories.removeValue(forKey: String(repo.id)) }
        UserDefaults.standard.set(categories, forKey: "repoCategories")
    }

    // MARK: - AI settings

    func saveAnthropicKey(_ key: String) {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
        anthropicKey = cleaned
        if cleaned.isEmpty { KeychainStore.delete(account: KeychainStore.anthropicAccount) }
        else { try? KeychainStore.saveString(cleaned, account: KeychainStore.anthropicAccount) }
    }

    func saveAIModel(_ model: String) {
        aiModel = model
        UserDefaults.standard.set(model, forKey: "aiModel")
    }

    // MARK: - Delete project

    func deleteRepository(_ repo: GitHubRepository) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            try await api.deleteRepository(repo)
            repositories.removeAll { $0.id == repo.id }
            runsByRepository.removeValue(forKey: repo.fullName)
            setCategory(nil, for: repo)
            statusMessage = "تم حذف المشروع \(repo.name) نهائياً."
            return true
        } catch {
            var text = error.localizedDescription
            if let apiError = error as? GitHubAPIError, [403, 404].contains(apiError.statusCode) {
                text += "\nلحذف المستودع يلزم أن يملك الرمز صلاحية Administration: Read and write (أو delete_repo في الرمز الكلاسيكي)."
            }
            errorMessage = text
            return false
        }
    }

    func restoreSession() async {
        guard !token.isEmpty, user == nil else { return }
        await connect(using: token, persist: false)
    }

    func connect(using suppliedToken: String, persist: Bool = true) async {
        let cleaned = suppliedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            errorMessage = "أدخل رمز GitHub أولاً."
            return
        }

        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            let client = GitHubAPI(token: cleaned)
            let profile = try await client.currentUser()
            let repos = try await client.repositories()

            token = cleaned
            user = profile
            repositories = repos.sorted {
                ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            }

            if persist {
                try KeychainStore.saveToken(cleaned)
            }

            statusMessage = "تم الاتصال بحساب @\(profile.login)، وتم تحميل المستودعات المتاحة."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadRepositories() async {
        guard !token.isEmpty else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            let repos = try await api.repositories()
            repositories = repos.sorted {
                ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createRepository(
        name: String,
        description: String,
        isPrivate: Bool,
        category: ProjectCategory? = nil,
        appIdentity: AppIdentity? = nil
    ) async -> Bool {
        guard !token.isEmpty else {
            errorMessage = "اتصل بـ GitHub أولاً."
            return false
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let created = try await api.createRepository(
                name: name,
                description: description,
                isPrivate: isPrivate
            )

            repositories.removeAll { $0.id == created.id }
            repositories.insert(created, at: 0)
            if let category { setCategory(category, for: created) }

            if let appIdentity {
                var attempt = 0
                while true {
                    do {
                        try await api.uploadFiles(
                            ProjectTemplate.files(for: appIdentity),
                            to: created,
                            commitMessage: "Create iOS app \(appIdentity.displayName) (\(appIdentity.bundleID))"
                        )
                        break
                    } catch let error as GitHubAPIError where [404, 409].contains(error.statusCode) && attempt < 4 {
                        attempt += 1
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                }
            }

            statusMessage = "تم إنشاء المستودع \(created.fullName) بنجاح."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func changeVisibility(
        for repository: GitHubRepository,
        isPrivate: Bool
    ) async -> Bool {
        isBusy = true
        defer { isBusy = false }

        do {
            try await api.setRepositoryVisibility(
                repository,
                isPrivate: isPrivate
            )

            await reloadRepositories()

            statusMessage = isPrivate
                ? "أصبح المشروع خاصاً."
                : "أصبح المشروع عاماً ويمكن للجميع رؤيته."

            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func loadRuns(for repo: GitHubRepository) async {
        do {
            runsByRepository[repo.fullName] =
                try await api.workflowRuns(for: repo)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - IPA Build

    func prepareAndBuild(
        repo: GitHubRepository,
        projectPath: String,
        scheme: String
    ) async {
        isBusy = true
        errorMessage = nil
        statusMessage = "جارٍ تجهيز سير عمل البناء في المستودع…"

        defer { isBusy = false }

        do {
            try await api.installWorkflow(in: repo)

            statusMessage = "تم تجهيز سير العمل. جارٍ إرسال طلب البناء…"

            try await api.triggerBuild(
                in: repo,
                projectPath: projectPath,
                scheme: scheme
            )

            statusMessage = "تم تشغيل البناء على GitHub Actions. سيتم تحديث آخر سجل بعد لحظات."

            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await loadRuns(for: repo)

        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }

    // MARK: - iOS Simulator Preview

    func prepareAndRunSimulatorPreview(
        repo: GitHubRepository,
        projectPath: String,
        scheme: String
    ) async {
        guard !token.isEmpty else {
            errorMessage = "اتصل بـ GitHub أولاً."
            return
        }

        isBusy = true
        errorMessage = nil
        statusMessage = "جارٍ تجهيز معاينة محاكي iPhone المجانية…"

        defer { isBusy = false }

        do {
            try await api.installSimulatorPreviewWorkflow(in: repo)

            statusMessage = "تمت إضافة ملفات اللقطات إلى المستودع. جارٍ تشغيل المحاكي على GitHub Actions…"

            try await api.triggerSimulatorPreview(
                in: repo,
                projectPath: projectPath,
                scheme: scheme
            )

            statusMessage = "بدأ تشغيل المحاكي. بعد انتهائه (من 5 إلى 15 دقيقة) افتح «لقطات كل الصفحات والأزرار» لتشاهدها داخل المشروع."

            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await loadRuns(for: repo)

        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }

    // MARK: - Artifact Download

    func downloadNewestArtifact(
        repo: GitHubRepository,
        run: WorkflowRun
    ) async {
        isBusy = true
        errorMessage = nil

        defer { isBusy = false }

        do {
            let artifacts = try await api.artifacts(
                for: repo,
                runID: run.id
            )

            guard let artifact = artifacts.first(where: { !$0.expired }) else {
                throw NSError(
                    domain: "BuilderMobile",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "لا يوجد ملف بناء صالح لهذا التشغيل بعد."
                    ]
                )
            }

            downloadedArtifactURL = try await api.downloadShareable(
                repo: repo,
                artifact: artifact
            )

            if artifact.name.lowercased().contains("preview") {
                statusMessage = "اكتمل تنزيل المعاينة. احفظ ZIP وافتحه لاستخراج preview.png و preview.mp4."
            } else {
                statusMessage = "اكتمل التنزيل. احفظ ملف ZIP في تطبيق الملفات ثم فك ضغطه لاستخراج IPA."
            }

        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Disconnect

    func disconnect() {
        KeychainStore.deleteToken()

        token = ""
        user = nil
        repositories = []
        runsByRepository = [:]
        statusMessage = nil
        errorMessage = nil
        downloadedArtifactURL = nil
    }

    // MARK: - Sign a built IPA on GitHub Actions

    /// Uploads the chosen certificate as encrypted repository secrets, installs the signing workflow,
    /// starts it and waits until the signed IPA artifact is ready. Returns the downloaded ZIP.
    func signBuild(
        repo: GitHubRepository,
        run: WorkflowRun,
        artifact: BuildArtifact,
        certificate: SigningCertificate,
        bundleID: String,
        progress: @escaping (String) -> Void
    ) async throws -> URL {
        guard let secrets = certificates.secrets(for: certificate) else {
            throw NSError(domain: "BuilderMobile", code: 30, userInfo: [NSLocalizedDescriptionKey: "تعذر قراءة بيانات الشهادة المحفوظة."])
        }
        let client = GitHubAPI(token: token)

        progress("جارٍ تشفير الشهادة ورفعها كأسرار مشفّرة إلى المستودع…")
        try await client.putSecret("SIGN_P12_BASE64", value: Data(secrets.p12.base64EncodedString().utf8), in: repo)
        try await client.putSecret("SIGN_P12_PASSWORD", value: Data(secrets.password.utf8), in: repo)
        try await client.putSecret("SIGN_PROFILE_BASE64", value: Data(secrets.profile.base64EncodedString().utf8), in: repo)

        progress("جارٍ تجهيز سير عمل التوقيع…")
        try await client.installSigningWorkflow(in: repo)

        let signedName = "signed-\(run.runNumber)-\(Int(Date().timeIntervalSince1970))"
        let startedAt = Date().addingTimeInterval(-15)

        progress("جارٍ بدء التوقيع على GitHub Actions…")
        var attempt = 0
        while true {
            do {
                try await client.triggerSigning(
                    in: repo,
                    buildRunID: run.id,
                    artifactName: artifact.name,
                    signedName: signedName,
                    bundleID: bundleID
                )
                break
            } catch let error as GitHubAPIError where error.statusCode == 404 && attempt < 8 {
                attempt += 1
                try await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }

        // Find the run we just started.
        var signingRun: WorkflowRun?
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let runs = try await client.signingRuns(for: repo)
            signingRun = runs.first { ($0.createdAt ?? .distantPast) >= startedAt }
            if signingRun != nil { break }
        }
        guard var current = signingRun else {
            throw NSError(domain: "BuilderMobile", code: 31, userInfo: [NSLocalizedDescriptionKey: "لم يبدأ سير عمل التوقيع. افتح Actions في GitHub وتأكد أن Workflows مفعّلة."])
        }

        progress("التوقيع جارٍ على خادم macOS…")
        for _ in 0..<120 {
            if current.isFinished { break }
            try await Task.sleep(nanoseconds: 5_000_000_000)
            current = try await client.run(current.id, in: repo)
        }

        guard current.isSuccess else {
            await loadRuns(for: repo)
            throw NSError(domain: "BuilderMobile", code: 32, userInfo: [NSLocalizedDescriptionKey: "فشل التوقيع (\(current.displayStatus)). افتح «سجل البناء» لقراءة الأخطاء وإصلاحها بالذكاء الاصطناعي."])
        }

        progress("اكتمل التوقيع. جارٍ تنزيل الملف الموقّع…")
        let artifacts = try await client.artifacts(for: repo, runID: current.id)
        guard let signed = artifacts.first(where: { !$0.expired && $0.name.hasPrefix("signed-ios-") }) else {
            throw NSError(domain: "BuilderMobile", code: 33, userInfo: [NSLocalizedDescriptionKey: "لم يتم العثور على الملف الموقّع."])
        }
        return try await client.downloadShareable(repo: repo, artifact: signed)
    }
}
