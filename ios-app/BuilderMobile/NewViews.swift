import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Main tabs

struct MainTabView: View {
    var body: some View {
        TabView {
            RepositoryListView()
                .tabItem { Label("المشاريع", systemImage: "folder.fill") }

            NavigationStack { AIChatView(repository: nil) }
                .tabItem { Label("الذكاء الاصطناعي", systemImage: "sparkles") }

            SigningHubView()
                .tabItem { Label("التوقيع والتنزيل", systemImage: "signature") }

            SettingsView()
                .tabItem { Label("الإعدادات", systemImage: "gearshape.fill") }
        }
    }
}

// MARK: - Share sheet

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Category chips (top bar of the home screen)

struct CategoryBar: View {
    @Binding var selection: ProjectCategory?
    let counts: [ProjectCategory: Int]
    let total: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "الكل", icon: "square.grid.2x2.fill", count: total, isSelected: selection == nil) {
                    selection = nil
                }
                ForEach(ProjectCategory.allCases) { category in
                    chip(
                        title: category.title,
                        icon: category.icon,
                        count: counts[category] ?? 0,
                        isSelected: selection == category
                    ) { selection = category }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func chip(title: String, icon: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption)
                Text(title).font(.subheadline.bold())
                Text("\(count)").font(.caption2).opacity(0.7)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(isSelected ? Color.black : Color.primary)
            .background(isSelected ? Color.cyan : Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Delete project (requires typing the name)

struct DeleteRepositoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let repository: GitHubRepository
    var onDeleted: () -> Void = {}
    @State private var typedName = ""
    @State private var isDeleting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("حذف نهائي", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.headline)
                    Text("سيتم حذف المستودع «\(repository.fullName)» من GitHub مع كل ملفاته وسجل البناء. لا يمكن التراجع عن هذه العملية.")
                        .font(.footnote)
                }
                Section("اكتب اسم المشروع للتأكيد") {
                    TextField(repository.name, text: $typedName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Button(role: .destructive) {
                        Task {
                            isDeleting = true
                            let ok = await model.deleteRepository(repository)
                            isDeleting = false
                            if ok { dismiss(); onDeleted() }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isDeleting { ProgressView() } else { Label("حذف المشروع نهائياً", systemImage: "trash.fill") }
                            Spacer()
                        }
                    }
                    .disabled(typedName != repository.name || isDeleting)
                }
            }
            .navigationTitle("حذف المشروع")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("إلغاء") { dismiss() } } }
        }
    }
}

// MARK: - AI chat

struct AIChatView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var chat = AIChatModel()

    let repository: GitHubRepository?
    var initialPrompt: String? = nil

    @State private var input = ""
    @State private var attachments: [ChatAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var keyInput = ""
    @FocusState private var inputFocused: Bool
    @Environment(\.dismiss) private var dismiss

    /// Pushed from a project (or shown as a sheet) => needs its own back button.
    private var canGoBack: Bool { repository != nil }

    var body: some View {
        VStack(spacing: 0) {
            if !model.aiReady {
                keyCard
            } else {
                messagesList
                inputBar
            }
        }
        .navigationTitle(chat.repository.map { "ذكاء — \($0.name)" } ?? "الذكاء الاصطناعي")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(canGoBack)
        .toolbar {
            if canGoBack {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { inputFocused = false; dismiss() } label: {
                        Label("رجوع", systemImage: "chevron.forward")
                    }
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button { chat.reset() } label: { Image(systemName: "square.and.pencil") }
                    .disabled(chat.items.isEmpty)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("إخفاء الكيبورد") { inputFocused = false }
            }
        }
        .onAppear {
            chat.configure(app: model, repository: repository)
            if model.aiReady { chat.sendInitialIfNeeded(initialPrompt) }
        }
        .onChange(of: photoItems) { _, items in
            Task { await loadPhotos(items) }
        }
    }

    // MARK: Pieces

    private var keyCard: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "sparkles").font(.system(size: 54)).foregroundStyle(.cyan)
                Text("فعّل الذكاء الاصطناعي").font(.title3.bold())
                Picker("المزوّد", selection: Binding(get: { model.aiProvider }, set: { model.saveAIProvider($0) })) {
                    Text("Gemini").tag("gemini")
                    Text("OpenRouter").tag("free")
                    Text("Claude").tag("claude")
                }
                .pickerStyle(.segmented)

                if model.aiProvider == "gemini" {
                    Text("مفتاح Google AI Studio مجاني بحد يومي. الصقه هنا وسيُحفظ في Keychain على جهازك فقط.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    SecureField("AQ.… أو AIza…", text: $keyInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(14).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    saveButton { model.saveGeminiKey(keyInput) }
                    Link("مفاتيح Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .font(.footnote)
                } else

                if model.aiProvider == "free" {
                    Text("نموذج برمجة مجاني (Qwen3 Coder) عبر OpenRouter. تحتاج مفتاحاً مجانياً يُنشأ خلال دقيقة بدون بطاقة بنكية.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    SecureField("sk-or-…", text: $keyInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(14).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    saveButton { model.saveFreeKey(keyInput) }
                    Link("إنشاء مفتاح مجاني من openrouter.ai/keys", destination: URL(string: "https://openrouter.ai/keys")!)
                        .font(.footnote)
                    Text("الحد المجاني محدود بعدد الطلبات يومياً، وقد يتغير أو يتوقف النموذج المجاني؛ يمكنك تغيير معرّف النموذج من الإعدادات. ما ترسله من كود يمر عبر OpenRouter.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else {
                    Text("أدخل مفتاح Anthropic API ليعمل Claude. لا تسمح Anthropic بتسجيل الدخول بحساب Claude Pro/Max في تطبيقات الأطراف الثالثة، والاستخدام مدفوع حسب API.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    SecureField("sk-ant-…", text: $keyInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(14).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    saveButton { model.saveAnthropicKey(keyInput) }
                    Link("إنشاء مفتاح من console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.footnote)
                }
            }
            .padding(24)
        }
    }

    private func saveButton(_ action: @escaping () -> Void) -> some View {
        Button {
            action()
            keyInput = ""
            chat.configure(app: model, repository: repository)
            chat.sendInitialIfNeeded(initialPrompt)
        } label: {
            Text("حفظ المفتاح").frame(maxWidth: .infinity).padding().font(.headline)
                .foregroundStyle(.black).background(.cyan, in: RoundedRectangle(cornerRadius: 14))
        }
        .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.items.isEmpty { emptyState }
                    ForEach(chat.items) { item in
                        ChatBubble(item: item).id(item.id)
                    }
                    if chat.isRunning {
                        HStack(spacing: 8) { ProgressView(); Text("Claude يعمل…").font(.caption).foregroundStyle(.secondary) }
                            .padding(.horizontal, 12).id("running")
                    }
                }
                .padding(12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { inputFocused = false }
            .onChange(of: chat.items.count) { _, _ in
                let target: AnyHashable? = chat.isRunning
                    ? AnyHashable("running")
                    : chat.items.last.map { AnyHashable($0.id) }
                if let target { withAnimation { proxy.scrollTo(target, anchor: .bottom) } }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 40)).foregroundStyle(.cyan)
            Text(chat.repository == nil ? "اطلب مشروعاً جديداً" : "اطلب تعديلاً أو إصلاح خطأ").font(.headline)
            Text(chat.repository == nil
                 ? "مثال: أنشئ تطبيق iOS لقائمة مهام بتصميم داكن"
                 : "مثال: أضف زر مشاركة، أو اقرأ سجل البناء وأصلح الأخطاء")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(attachments) { file in
                            HStack(spacing: 6) {
                                Image(systemName: file.kind == .image ? "photo" : "doc")
                                Text(file.name).lineLimit(1).font(.caption)
                                Button { attachments.removeAll { $0.id == file.id } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.white.opacity(0.1), in: Capsule())
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 5, matching: .images) {
                    Image(systemName: "photo.on.rectangle").font(.title3)
                }
                Button { pickFiles() } label: { Image(systemName: "paperclip").font(.title3) }

                if inputFocused {
                    Button { inputFocused = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down").font(.title3)
                    }
                }

                TextField("اكتب رسالتك…", text: $input, axis: .vertical)
                    .focused($inputFocused)
                    .lineLimit(1...6)
                    .padding(10)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))

                if chat.isRunning {
                    Button { chat.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.title).foregroundStyle(.red)
                    }
                } else {
                    Button { sendNow() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title).foregroundStyle(.cyan)
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                }
            }
        }
        .padding(10)
        .background(.bar)
    }

    // MARK: Actions

    private func sendNow() {
        inputFocused = false
        chat.send(text: input, attachments: attachments)
        input = ""
        attachments = []
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let jpeg = ImagePreparer.jpeg(from: data) {
                attachments.append(ChatAttachment(
                    name: "image-\(Int(Date().timeIntervalSince1970))-\(attachments.count + 1).jpg",
                    data: jpeg,
                    kind: .image
                ))
            }
        }
        photoItems = []
    }

    private func pickFiles() {
        DocumentPickerPresenter.shared.present(types: [.item]) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                let ext = url.pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext) {
                    if let jpeg = ImagePreparer.jpeg(from: data) {
                        attachments.append(ChatAttachment(name: url.lastPathComponent, data: jpeg, kind: .image))
                    }
                } else if data.count < 200_000, String(data: data, encoding: .utf8) != nil {
                    attachments.append(ChatAttachment(name: url.lastPathComponent, data: data, kind: .text))
                } else {
                    attachments.append(ChatAttachment(name: url.lastPathComponent, data: data, kind: .binary))
                }
            }
        }
    }
}

private struct ChatBubble: View {
    let item: ChatItem

    var body: some View {
        switch item.role {
        case .user:
            VStack(alignment: .leading, spacing: 6) {
                if !item.attachmentNames.isEmpty {
                    Text("📎 " + item.attachmentNames.joined(separator: "، ")).font(.caption2).foregroundStyle(.black.opacity(0.7))
                }
                if !item.text.isEmpty { markdown(item.text).foregroundStyle(.black) }
            }
            .padding(12)
            .background(Color.cyan, in: RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            markdown(item.text)
                .textSelection(.enabled)
                .padding(12)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .activity:
            Text(item.text).font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            Text(item.text).font(.caption).foregroundStyle(.red)
                .padding(10).background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func markdown(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }
}

// MARK: - Build history (ALL runs, not only the latest)

struct BuildHistoryView: View {
    @EnvironmentObject private var model: AppModel
    let repository: GitHubRepository

    private var runs: [WorkflowRun] { model.runsByRepository[repository.fullName] ?? [] }

    var body: some View {
        List {
            Section("كل عمليات البناء (\(runs.count))") {
                if runs.isEmpty {
                    Text("لا توجد عمليات بناء بعد.").foregroundStyle(.secondary)
                }
                ForEach(runs) { run in
                    NavigationLink {
                        BuildRunView(repository: repository, run: run)
                    } label: {
                        BuildRunRow(run: run)
                    }
                }
            }
        }
        .navigationTitle("سجل البناء")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.loadRuns(for: repository) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await model.loadRuns(for: repository) } } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .task { await model.loadRuns(for: repository) }
    }
}

struct BuildRunRow: View {
    let run: WorkflowRun

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("#\(run.runNumber)").font(.subheadline.bold())
                Text(run.title).font(.subheadline).lineLimit(1)
            }
            HStack(spacing: 8) {
                StatusPill(status: run.displayStatus)
                if let branch = run.headBranch { Text(branch).font(.caption).foregroundStyle(.secondary) }
                if let event = run.event { Text(event).font(.caption2).foregroundStyle(.secondary) }
            }
            if let date = run.createdAt {
                Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Build run details: jobs, errors, logs, AI fix

struct BuildRunView: View {
    @EnvironmentObject private var model: AppModel
    let repository: GitHubRepository
    let run: WorkflowRun

    @State private var jobs: [WorkflowJob] = []
    @State private var fullLog = ""
    @State private var errorLines: [String] = []
    @State private var isLoading = false
    @State private var loadMessage: String?
    @State private var shareItem: ShareItem?
    @State private var showAI = false

    private var hasErrors: Bool { !errorLines.isEmpty || run.isFailure }

    var body: some View {
        List {
            Section {
                HStack {
                    StatusPill(status: run.displayStatus)
                    Spacer()
                    if let branch = run.headBranch { Text(branch).font(.caption).foregroundStyle(.secondary) }
                }
                if let date = run.createdAt {
                    LabeledContent("التاريخ", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if let url = run.htmlURL { Link("فتح في GitHub", destination: url) }
            }

            if !errorLines.isEmpty {
                Section {
                    ForEach(Array(errorLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                } header: {
                    Label("الأخطاء (\(errorLines.count))", systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
                }
            }

            Section("الإجراءات") {
                Button {
                    showAI = true
                } label: {
                    Label("إصلاح الأخطاء بالذكاء الاصطناعي", systemImage: "sparkles")
                }
                .disabled(!hasErrors)

                Button { exportLog(errorsOnly: false) } label: {
                    Label("تنزيل السجل الكامل (log)", systemImage: "arrow.down.doc")
                }
                .disabled(fullLog.isEmpty)

                Button { exportLog(errorsOnly: true) } label: {
                    Label("تنزيل الأخطاء فقط", systemImage: "exclamationmark.triangle")
                }
                .disabled(errorLines.isEmpty)

                Button {
                    Task { await model.downloadNewestArtifact(repo: repository, run: run) }
                } label: {
                    Label("تنزيل ملف البناء (IPA)", systemImage: "arrow.down.circle.fill")
                }
                .disabled(model.isBusy || !run.isSuccess)

                if let file = model.downloadedArtifactURL {
                    ShareLink(item: file) {
                        Label(file.pathExtension.lowercased() == "ipa" ? "مشاركة ملف IPA" : "مشاركة الملف", systemImage: "square.and.arrow.up")
                    }
                }
            }

            Section("المهام والخطوات") {
                if isLoading { HStack { Spacer(); ProgressView("تحميل السجل…"); Spacer() } }
                if let loadMessage { Text(loadMessage).font(.footnote).foregroundStyle(.secondary) }
                ForEach(jobs) { job in
                    DisclosureGroup {
                        ForEach(job.steps ?? [], id: \.number) { step in
                            HStack {
                                Image(systemName: icon(for: step.conclusion ?? step.status))
                                    .foregroundStyle(color(for: step.conclusion ?? step.status))
                                Text(step.name).font(.footnote)
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: icon(for: job.conclusion ?? job.status))
                                .foregroundStyle(color(for: job.conclusion ?? job.status))
                            Text(job.name)
                        }
                    }
                }
            }
        }
        .navigationTitle("بناء #\(run.runNumber)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareItem) { ShareSheet(url: $0.url) }
        .sheet(isPresented: $showAI) {
            NavigationStack {
                AIChatView(repository: repository, initialPrompt: aiPrompt())
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { Button("إغلاق") { showAI = false } }
                    }
            }
            .environmentObject(model)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: Loading

    private func load() async {
        isLoading = true
        loadMessage = nil
        defer { isLoading = false }
        let api = GitHubAPI(token: model.token)
        do {
            jobs = try await api.jobs(for: repository, runID: run.id)
            var combined = ""
            var errors: [String] = []
            for job in jobs {
                guard job.status == "completed" else { continue }
                if let raw = try? await api.jobLog(for: repository, jobID: job.id) {
                    combined += "===== \(job.name) (\(job.conclusion ?? job.status)) =====\n"
                    combined += LogAnalyzer.cleanedLog(raw) + "\n\n"
                    if job.conclusion != "success" && job.conclusion != "skipped" {
                        errors += LogAnalyzer.errors(in: raw)
                    }
                }
            }
            fullLog = combined
            errorLines = errors
            if combined.isEmpty && !run.isFinished { loadMessage = "العملية لم تنتهِ بعد. اسحب للتحديث لاحقاً." }
            else if combined.isEmpty { loadMessage = "لا يتوفر سجل لهذه العملية (قد يكون منتهي الصلاحية)." }
        } catch {
            loadMessage = error.localizedDescription
        }
    }

    // MARK: Export and AI

    private func exportLog(errorsOnly: Bool) {
        let text = errorsOnly ? errorLines.joined(separator: "\n") : fullLog
        let name = "\(GitHubAPI.safeName(repository.name))-build-\(run.runNumber)-\(errorsOnly ? "errors" : "log").txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            shareItem = ShareItem(url: url)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func aiPrompt() -> String {
        let errors = errorLines.prefix(60).joined(separator: "\n")
        return """
        فشلت عملية البناء #\(run.runNumber) (id: \(run.id)) في هذا المشروع. هذه هي الأخطاء المستخرجة من السجل:

        \(errors.isEmpty ? "(لم تُستخرج أخطاء محددة — استخدم get_build_logs لقراءة السجل)" : errors)

        اقرأ الملفات المعنية وأصلح السبب الحقيقي للخطأ، ثم اعرض عليّ تشغيل بناء جديد.
        """
    }

    private func icon(for state: String) -> String {
        switch state {
        case "success": return "checkmark.circle.fill"
        case "failure", "timed_out", "startup_failure": return "xmark.octagon.fill"
        case "skipped", "cancelled": return "minus.circle.fill"
        default: return "clock.fill"
        }
    }

    private func color(for state: String) -> Color {
        switch state {
        case "success": return .green
        case "failure", "timed_out", "startup_failure": return .red
        case "skipped", "cancelled": return .gray
        default: return .cyan
        }
    }
}

// MARK: - Signing & downloading apps

struct SigningHubView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedRepoID: Int?
    @State private var showAddCertificate = false

    private var appRepos: [GitHubRepository] {
        let apps = model.repositories.filter { model.category(for: $0) == .app }
        return apps.isEmpty ? model.repositories : apps
    }

    private var selectedRepo: GitHubRepository? {
        appRepos.first { $0.id == selectedRepoID } ?? appRepos.first
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        CertificatesView()
                    } label: {
                        HStack {
                            Label("الشهادات وملفات التوقيع", systemImage: "key.fill")
                            Spacer()
                            Text("\(model.certificates.certificates.count)").foregroundStyle(.secondary)
                        }
                    }
                }

                Section("المشروع") {
                    if appRepos.isEmpty {
                        Text("لا توجد مشاريع.").foregroundStyle(.secondary)
                    } else {
                        Picker("المستودع", selection: Binding(
                            get: { selectedRepo?.id ?? 0 },
                            set: { selectedRepoID = $0 }
                        )) {
                            ForEach(appRepos) { repo in Text(repo.name).tag(repo.id) }
                        }
                        .pickerStyle(.menu)
                    }
                }

                if let repo = selectedRepo {
                    BuiltAppsSection(repository: repo).id(repo.id)
                }
            }
            .navigationTitle("التوقيع والتنزيل")
        }
    }
}

private struct BuiltApp: Identifiable {
    let run: WorkflowRun
    let artifact: BuildArtifact
    var id: Int64 { artifact.id }
}

private struct BuiltAppsSection: View {
    @EnvironmentObject private var model: AppModel
    let repository: GitHubRepository

    @State private var apps: [BuiltApp] = []
    @State private var isLoading = false
    @State private var message: String?
    @State private var shareItem: ShareItem?
    @State private var signTarget: BuiltApp?
    @State private var progress: String?
    @State private var busyArtifact: Int64?

    var body: some View {
        Section {
            if isLoading { HStack { Spacer(); ProgressView("جارٍ البحث عن التطبيقات المبنية…"); Spacer() } }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            if let progress {
                HStack(spacing: 8) { ProgressView(); Text(progress).font(.footnote) }
            }

            ForEach(apps) { app in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "shippingbox.fill").foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("بناء #\(app.run.runNumber)").font(.subheadline.bold())
                            Text(ByteCountFormatter.string(fromByteCount: app.artifact.sizeInBytes, countStyle: .file))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let date = app.run.createdAt {
                            Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 10) {
                        Button { Task { await download(app) } } label: {
                            Label("تنزيل", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.bordered)

                        Button { signTarget = app } label: {
                            Label("توقيع", systemImage: "signature")
                        }
                        .buttonStyle(.borderedProminent).tint(.cyan)
                    }
                    .disabled(busyArtifact != nil)
                }
                .padding(.vertical, 4)
            }
        } header: {
            HStack {
                Text("التطبيقات المبنية")
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.disabled(isLoading)
            }
        } footer: {
            Text("يتم البناء على GitHub Actions ثم تظهر هنا ملفات IPA الجاهزة. التوقيع يتم على خادم macOS في GitHub باستخدام شهادتك المرفوعة كأسرار مشفّرة.")
        }
        .sheet(item: $shareItem) { ShareSheet(url: $0.url) }
        .sheet(item: $signTarget) { target in
            SignSheet(repository: repository, app: target) { url in
                shareItem = ShareItem(url: url)
            }
            .environmentObject(model)
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        message = nil
        defer { isLoading = false }
        let api = GitHubAPI(token: model.token)
        do {
            let runs = try await api.workflowRuns(for: repository)
            await model.loadRuns(for: repository)
            var found: [BuiltApp] = []
            for run in runs.filter({ $0.isSuccess }).prefix(12) {
                let artifacts = (try? await api.artifacts(for: repository, runID: run.id)) ?? []
                for artifact in artifacts where !artifact.expired && artifact.name.hasPrefix("ios-ipa") {
                    found.append(BuiltApp(run: run, artifact: artifact))
                }
            }
            apps = found
            if found.isEmpty { message = "لا توجد ملفات IPA جاهزة. شغّل «بناء تطبيق IPA» من صفحة المشروع أولاً." }
        } catch {
            message = error.localizedDescription
        }
    }

    private func download(_ app: BuiltApp) async {
        busyArtifact = app.id
        progress = "جارٍ تنزيل الملف…"
        defer { busyArtifact = nil; progress = nil }
        do {
            let url = try await GitHubAPI(token: model.token).downloadShareable(repo: repository, artifact: app.artifact)
            shareItem = ShareItem(url: url)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

private struct SignSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let repository: GitHubRepository
    let app: BuiltApp
    let onFinished: (URL) -> Void

    @State private var certificateID: UUID?
    @State private var bundleID = ""
    @State private var progress: String?
    @State private var errorText: String?
    @State private var isSigning = false

    private var certificates: [SigningCertificate] { model.certificates.certificates }
    private var selected: SigningCertificate? { certificates.first { $0.id == certificateID } ?? certificates.first }

    var body: some View {
        NavigationStack {
            Form {
                if certificates.isEmpty {
                    Section {
                        Text("أضف شهادة أولاً من «الشهادات وملفات التوقيع».").foregroundStyle(.secondary)
                    }
                } else {
                    Section("الشهادة") {
                        Picker("الشهادة", selection: Binding(get: { selected?.id ?? UUID() }, set: { certificateID = $0 })) {
                            ForEach(certificates) { cert in Text(cert.name).tag(cert.id) }
                        }
                        if let cert = selected {
                            LabeledContent("الفريق", value: cert.teamName)
                            LabeledContent("Profile", value: cert.profileName)
                            LabeledContent("App ID", value: cert.profileAppID)
                            if cert.isExpired {
                                Text("هذا الـ Profile منتهي الصلاحية.").font(.footnote).foregroundStyle(.red)
                            }
                        }
                    }
                    Section {
                        TextField("اتركه فارغاً لاستخدام معرّف الـ Profile", text: $bundleID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: {
                        Text("Bundle ID (اختياري)")
                    } footer: {
                        Text("يجب أن يطابق معرّف التطبيق ما يسمح به ملف الـ Provisioning Profile.")
                    }
                    Section {
                        Button {
                            Task { await sign() }
                        } label: {
                            HStack {
                                Spacer()
                                if isSigning { ProgressView() } else { Label("ابدأ التوقيع", systemImage: "signature") }
                                Spacer()
                            }
                        }
                        .disabled(isSigning || selected == nil)
                        if let progress { Text(progress).font(.footnote).foregroundStyle(.cyan) }
                        if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
                    } footer: {
                        Text("يحتاج الرمز (Token) صلاحية Secrets: Read and write إضافة إلى Actions وWorkflows وContents. يستغرق التوقيع عادةً دقيقة إلى ثلاث دقائق.")
                    }
                }
            }
            .navigationTitle("توقيع التطبيق")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("إغلاق") { dismiss() }.disabled(isSigning) } }
            .interactiveDismissDisabled(isSigning)
        }
    }

    private func sign() async {
        guard let cert = selected else { return }
        isSigning = true
        errorText = nil
        defer { isSigning = false }
        do {
            let url = try await model.signBuild(
                repo: repository,
                run: app.run,
                artifact: app.artifact,
                certificate: cert,
                bundleID: bundleID.trimmingCharacters(in: .whitespacesAndNewlines),
                progress: { progress = $0 }
            )
            dismiss()
            onFinished(url)
        } catch {
            var text = error.localizedDescription
            if let api = error as? GitHubAPIError, [403, 404].contains(api.statusCode) {
                text += "\nتأكد أن الرمز يملك صلاحيات Secrets وActions وWorkflows وContents (Read and write)."
            }
            errorText = text
            progress = nil
        }
    }
}

// MARK: - Certificates

struct CertificatesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showAdd = false

    var body: some View {
        List {
            Section {
                ForEach(model.certificates.certificates) { cert in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: cert.isExpired ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                                .foregroundStyle(cert.isExpired ? .red : .green)
                            Text(cert.name).font(.headline)
                        }
                        Text(cert.subject).font(.caption).foregroundStyle(.secondary)
                        Text("Profile: \(cert.profileName) • \(cert.profileAppID)").font(.caption2).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            if let expiry = cert.expiresAt {
                                Text("ينتهي: \(expiry.formatted(date: .abbreviated, time: .omitted))").font(.caption2)
                            }
                            if let devices = cert.deviceCount {
                                Text("\(devices) جهاز").font(.caption2)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .swipeActions {
                        Button(role: .destructive) { model.certificates.remove(cert) } label: {
                            Label("حذف", systemImage: "trash")
                        }
                    }
                }
                if model.certificates.certificates.isEmpty {
                    Text("لم تُضف أي شهادة بعد.").foregroundStyle(.secondary)
                }
            } footer: {
                Text("تُحفظ الشهادة وكلمة مرورها في Keychain على جهازك فقط، وتُرفع إلى مستودعك كأسرار GitHub مشفّرة عند التوقيع.")
            }
        }
        .navigationTitle("الشهادات")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus.circle.fill") }
            }
        }
        .sheet(isPresented: $showAdd) { AddCertificateView().environmentObject(model) }
    }
}

struct AddCertificateView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var password = ""
    @State private var p12Data: Data?
    @State private var p12Name: String?
    @State private var profileData: Data?
    @State private var profileName: String?
    @State private var errorText: String?
    @State private var warningText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("اسم الشهادة") {
                    TextField("مثال: شهادتي الشخصية", text: $name)
                }
                Section("ملف الشهادة (.p12)") {
                    Button { pick(extension: "p12") { data, file in p12Data = data; p12Name = file } } label: {
                        Label(p12Name ?? "اختيار ملف .p12", systemImage: "doc.badge.plus")
                    }
                    SecureField("كلمة مرور الشهادة", text: $password)
                }
                Section("ملف Provisioning Profile") {
                    Button { pick(extension: "mobileprovision") { data, file in profileData = data; profileName = file } } label: {
                        Label(profileName ?? "اختيار ملف .mobileprovision", systemImage: "doc.badge.plus")
                    }
                }
                if let warningText { Section { Text(warningText).font(.footnote).foregroundStyle(.orange) } }
                if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red) } }
                Section {
                    Button { save() } label: {
                        HStack { Spacer(); Label("حفظ الشهادة", systemImage: "checkmark.circle.fill"); Spacer() }
                    }
                    .disabled(p12Data == nil || profileData == nil)
                }
            }
            .navigationTitle("إضافة شهادة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("إلغاء") { dismiss() } } }
        }
    }

    private func pick(extension ext: String, completion: @escaping (Data, String) -> Void) {
        let type = UTType(filenameExtension: ext) ?? .data
        DocumentPickerPresenter.shared.present(types: [type, .data]) { result in
            guard case .success(let urls) = result, let url = urls.first,
                  let data = try? Data(contentsOf: url) else { return }
            completion(data, url.lastPathComponent)
        }
    }

    private func save() {
        guard let p12Data, let profileData else { return }
        do {
            let (_, warning) = try model.certificates.add(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                p12: p12Data,
                password: password,
                profile: profileData
            )
            if let warning {
                warningText = warning
                errorText = nil
            } else {
                dismiss()
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var keyInput = ""
    @State private var customModel = ""
    @State private var geminiModels: [String] = []
    @State private var loadingModels = false
    @State private var modelsError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("حساب GitHub") {
                    LabeledContent("الحساب", value: "@\(model.user?.login ?? "")")
                    Button("تسجيل الخروج", role: .destructive) { model.disconnect() }
                }

                Section {
                    Picker("المزوّد", selection: Binding(get: { model.aiProvider }, set: { model.saveAIProvider($0) })) {
                        Text("Gemini (مجاني)").tag("gemini")
                        Text("OpenRouter (مجاني)").tag("free")
                        Text("Claude (مدفوع)").tag("claude")
                    }
                    if model.aiProvider == "gemini" {
                        SecureField(model.geminiKey.isEmpty ? "مفتاح Google AI Studio" : "••••••••  (محفوظ)", text: $keyInput)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("حفظ المفتاح") { model.saveGeminiKey(keyInput); keyInput = "" }
                            .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        if !model.geminiKey.isEmpty {
                            Button("حذف المفتاح", role: .destructive) { model.saveGeminiKey("") }
                        }
                        LabeledContent("النموذج الحالي", value: model.geminiModel)
                        TextField("اكتب معرّف نموذج ثم Return", text: $customModel)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit { model.saveGeminiModel(customModel); customModel = "" }
                        Button {
                            Task { await loadGeminiModels() }
                        } label: {
                            HStack {
                                Text("عرض النماذج المتاحة لمفتاحي")
                                if loadingModels { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(model.geminiKey.isEmpty || loadingModels)
                        if let modelsError { Text(modelsError).font(.caption).foregroundStyle(.red) }
                        if !geminiModels.isEmpty {
                            Picker("اختر نموذجاً", selection: Binding(
                                get: { model.geminiModel },
                                set: { model.saveGeminiModel($0) }
                            )) {
                                ForEach(geminiModels, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.navigationLink)
                        }
                    } else if model.aiProvider == "free" {
                        SecureField(model.freeAIKey.isEmpty ? "مفتاح OpenRouter المجاني" : "••••••••  (محفوظ)", text: $keyInput)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("حفظ المفتاح") { model.saveFreeKey(keyInput); keyInput = "" }
                            .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        if !model.freeAIKey.isEmpty {
                            Button("حذف المفتاح", role: .destructive) { model.saveFreeKey("") }
                        }
                        TextField(model.freeModel, text: $customModel)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit {
                                model.saveFreeModel(customModel); customModel = ""
                            }
                        Link("مفتاح مجاني: openrouter.ai/keys", destination: URL(string: "https://openrouter.ai/keys")!)
                    } else {
                        SecureField(model.anthropicKey.isEmpty ? "sk-ant-…" : "••••••••  (محفوظ)", text: $keyInput)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("حفظ المفتاح") { model.saveAnthropicKey(keyInput); keyInput = "" }
                            .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        if !model.anthropicKey.isEmpty {
                            Button("حذف المفتاح", role: .destructive) { model.saveAnthropicKey("") }
                        }
                        Picker("النموذج", selection: Binding(get: { model.aiModel }, set: { model.saveAIModel($0) })) {
                            ForEach(ClaudeClient.availableModels, id: \.id) { Text($0.title).tag($0.id) }
                            if !ClaudeClient.availableModels.contains(where: { $0.id == model.aiModel }) {
                                Text(model.aiModel).tag(model.aiModel)
                            }
                        }
                    }
                } header: {
                    Text("الذكاء الاصطناعي")
                } footer: {
                    Text("المجاني: نموذج Qwen3 Coder عبر OpenRouter بمفتاح مجاني وحد يومي، ويمكن تغيير معرّف النموذج إذا توقف. Claude: مفتاح Anthropic API مدفوع، ولا يدعم تسجيل الدخول بحساب Claude Pro/Max.")
                }

                Section("التوقيع") {
                    NavigationLink {
                        CertificatesView()
                    } label: {
                        HStack {
                            Label("الشهادات وملفات التوقيع", systemImage: "key.fill")
                            Spacer()
                            Text("\(model.certificates.certificates.count)").foregroundStyle(.secondary)
                        }
                    }
                }

                Section("الصلاحيات المطلوبة للرمز") {
                    Text("Contents • Actions • Workflows • Administration (لحذف المشاريع) • Secrets (للتوقيع): كلها Read and write، مع Metadata: Read")
                        .font(.caption).foregroundStyle(.secondary)
                }

                DeveloperInfoSection()

                Section {
                    LabeledContent("الإصدار", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                }
            }
            .navigationTitle("الإعدادات")
        }
    }
}

extension SettingsView {
    fileprivate func loadGeminiModels() async {
        loadingModels = true
        modelsError = nil
        defer { loadingModels = false }
        do {
            let all = try await OpenAICompatClient(
                apiKey: model.geminiKey,
                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"
            ).listModels()
            geminiModels = all.filter { $0.hasPrefix("gemini") }
            if geminiModels.isEmpty { modelsError = "لم يتم العثور على نماذج Gemini." }
        } catch {
            modelsError = error.localizedDescription
        }
    }
}

struct DeveloperInfoSection: View {
    private struct Contact: Identifiable {
        let id: String
        let title: String
        let value: String
        let icon: String
        let url: String
    }

    private let contacts = [
        Contact(id: "instagram", title: "إنستجرام", value: "eng_azawy", icon: "camera.fill", url: "https://instagram.com/eng_azawy"),
        Contact(id: "telegram", title: "تليجرام", value: "bavarite", icon: "paperplane.fill", url: "https://t.me/bavarite"),
        Contact(id: "tiktok", title: "تيك توك", value: "eyesiq", icon: "music.note", url: "https://www.tiktok.com/@eyesiq"),
        Contact(id: "snapchat", title: "سناب", value: "eng_azawy", icon: "bubble.left.fill", url: "https://www.snapchat.com/add/eng_azawy"),
        Contact(id: "whatsapp", title: "واتساب", value: "+9647760090321", icon: "phone.bubble.fill", url: "https://wa.me/9647760090321")
    ]

    var body: some View {
        Section("معلومات المطور") {
            HStack(spacing: 12) {
                Image(systemName: "hammer.circle.fill").font(.system(size: 34)).foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("azawy coder").font(.headline)
                    Text("تواصل مع المطور").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(contacts) { contact in
                if let url = URL(string: contact.url) {
                    Link(destination: url) {
                        HStack {
                            Image(systemName: contact.icon).foregroundStyle(.cyan).frame(width: 26)
                            Text(contact.title)
                            Spacer()
                            Text(contact.value).foregroundStyle(.secondary).environment(\.layoutDirection, .leftToRight)
                        }
                    }
                    .contextMenu {
                        Button { UIPasteboard.general.string = contact.value } label: { Label("نسخ", systemImage: "doc.on.doc") }
                    }
                }
            }
        }
    }
}
