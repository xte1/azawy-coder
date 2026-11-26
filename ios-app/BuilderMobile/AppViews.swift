import SwiftUI
import PhotosUI
import WebKit
import UniformTypeIdentifiers
import ZIPFoundation

// MARK: - Root

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.user == nil {
                ConnectView()
            } else {
                MainTabView()
            }
        }
        .task { await model.restoreSession() }
        .alert("تنبيه", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("حسناً", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Connection

struct ConnectView: View {
    @EnvironmentObject private var model: AppModel
    @State private var token = ""
    @State private var showToken = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 35)
                    Image(systemName: "hammer.circle.fill")
                        .font(.system(size: 76)).foregroundStyle(.cyan)
                    Text("Builder Mobile").font(.largeTitle.bold())
                    Text("أنشئ مشاريعك وأدر ملفاتها وابنِ تطبيقات iOS من هاتفك عبر GitHub Actions")
                        .font(.headline).multilineTextAlignment(.center).foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("رمز الوصول الشخصي من GitHub").font(.headline)
                        Group {
                            if showToken { TextField("github_pat_…", text: $token) }
                            else { SecureField("github_pat_…", text: $token) }
                        }
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(14).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                        Toggle("إظهار الرمز", isOn: $showToken)
                        Text("يُحفظ الرمز في Keychain على جهازك، ولا يُكتب داخل ملفات المستودع.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await model.connect(using: token) }
                    } label: {
                        HStack {
                            if model.isBusy { ProgressView().tint(.black) }
                            Text("اتصال بـ GitHub")
                        }
                        .frame(maxWidth: .infinity).padding().font(.headline).foregroundStyle(.black)
                        .background(.cyan, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(model.isBusy || token.isEmpty)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("الصلاحيات المطلوبة للرمز").font(.subheadline.bold())
                        Text("Repository access: All repositories (أو اختر كل المستودعات المطلوبة)\nAdministration: Read and write (لحذف المشاريع)\nContents: Read and write\nActions: Read and write\nWorkflows: Read and write\nSecrets: Read and write (للتوقيع)\nMetadata: Read")
                            .font(.caption).foregroundStyle(.secondary)
                        Link("إدارة Fine-grained tokens", destination: URL(string: "https://github.com/settings/personal-access-tokens")!)
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 30)
                }
                .padding(24)
            }
            .navigationBarHidden(true)
        }
    }
}

// MARK: - Repository list

struct RepositoryListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""
    @State private var categoryFilter: ProjectCategory?
    @State private var showNewProject = false
    @State private var repoToDelete: GitHubRepository?

    private var counts: [ProjectCategory: Int] {
        var result: [ProjectCategory: Int] = [:]
        for repo in model.repositories {
            if let category = model.category(for: repo) { result[category, default: 0] += 1 }
        }
        return result
    }

    private var filtered: [GitHubRepository] {
        model.repositories.filter { repo in
            let matchesSearch = searchText.isEmpty || repo.fullName.localizedCaseInsensitiveContains(searchText)
            let matchesCategory = categoryFilter == nil || model.category(for: repo) == categoryFilter
            return matchesSearch && matchesCategory
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("\(categoryFilter?.title ?? "كل المشاريع") (\(filtered.count))") {
                    ForEach(filtered) { repo in
                        NavigationLink {
                            RepositoryWorkspaceView(repository: repo)
                        } label: {
                            RepositoryRow(repository: repo, category: model.category(for: repo))
                        }
                        .listRowBackground(Color.white.opacity(0.035))
                        .contextMenu { categoryMenu(for: repo) }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { repoToDelete = repo } label: {
                                Label("حذف", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            ForEach(ProjectCategory.allCases) { category in
                                Button { model.setCategory(category, for: repo) } label: {
                                    Label(category.singular, systemImage: category.icon)
                                }
                                .tint(.cyan)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "ابحث عن مشروع")
            .navigationTitle("مشاريعي")
            .safeAreaInset(edge: .top, spacing: 0) {
                CategoryBar(selection: $categoryFilter, counts: counts, total: model.repositories.count)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await model.reloadRepositories() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isBusy)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showNewProject = true } label: {
                        Image(systemName: "plus.circle.fill").foregroundStyle(.cyan)
                    }
                    Menu {
                        Text("@\(model.user?.login ?? "")")
                        Button("تسجيل الخروج", role: .destructive) { model.disconnect() }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
            .sheet(isPresented: $showNewProject) {
                NewProjectView(defaultCategory: categoryFilter).environmentObject(model)
            }
            .sheet(item: $repoToDelete) { repo in
                DeleteRepositoryView(repository: repo).environmentObject(model)
            }
            .overlay {
                if model.repositories.isEmpty && !model.isBusy {
                    ContentUnavailableView(
                        "لا توجد مستودعات ظاهرة",
                        systemImage: "folder",
                        description: Text("حدّث القائمة أو تحقق من صلاحيات المستودعات في Fine-grained token.")
                    )
                } else if filtered.isEmpty && !model.isBusy {
                    ContentUnavailableView(
                        "لا توجد مشاريع في هذا القسم",
                        systemImage: categoryFilter?.icon ?? "folder",
                        description: Text("اضغط مطولاً على أي مشروع واختر «تصنيف» لإضافته إلى هذا القسم.")
                    )
                }
            }
            .overlay {
                if model.isBusy {
                    ProgressView().padding().background(.ultraThinMaterial, in: Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private func categoryMenu(for repo: GitHubRepository) -> some View {
        ForEach(ProjectCategory.allCases) { category in
            Button {
                model.setCategory(category, for: repo)
            } label: {
                Label("تمييز كـ \(category.singular)", systemImage: category.icon)
            }
        }
        if model.category(for: repo) != nil {
            Button(role: .destructive) {
                model.setCategory(nil, for: repo)
            } label: {
                Label("إزالة التصنيف", systemImage: "tag.slash")
            }
        }
    }
}

private struct RepositoryRow: View {
    let repository: GitHubRepository
    var category: ProjectCategory? = nil
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category?.icon ?? (repository.isPrivate ? "lock.fill" : "globe"))
                .font(.title3).foregroundStyle(.cyan).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(repository.name).font(.headline)
                Text(repository.fullName).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text("الفرع: \(repository.defaultBranch)")
                    Text("•")
                    Text(repository.isPrivate ? "خاص" : "عام")
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let category {
                    Text(category.singular).font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.cyan.opacity(0.18), in: Capsule()).foregroundStyle(.cyan)
                }
                if repository.isPrivate {
                    Text("PRIVATE").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - New repository

struct NewProjectView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var defaultCategory: ProjectCategory? = nil
    @State private var category: ProjectCategory?
    @State private var didSetDefault = false
    @State private var projectName = ""
    @State private var projectDescription = ""
    @State private var isPrivate = true
    @State private var isCreating = false
    @State private var appName = ""
    @State private var bundleID = ""
    @State private var iconItem: PhotosPickerItem?
    @State private var iconData: Data?
    @State private var createStarter = true
    @State private var lastSuggestedName = ""

    private var isApp: Bool { category == .app }

    private var identityIsValid: Bool {
        !isApp || !createStarter ||
        (!appName.trimmingCharacters(in: .whitespaces).isEmpty && ProjectTemplate.isValidBundleID(bundleID.trimmingCharacters(in: .whitespaces)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("معلومات المشروع") {
                    TextField("اسم المشروع", text: $projectName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("وصف المشروع (اختياري)", text: $projectDescription, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section("القسم") {
                    Picker("القسم", selection: $category) {
                        Text("بدون تصنيف").tag(ProjectCategory?.none)
                        ForEach(ProjectCategory.allCases) { item in
                            Label(item.singular, systemImage: item.icon).tag(ProjectCategory?.some(item))
                        }
                    }
                    .pickerStyle(.segmented)
                }
                if isApp {
                    Section {
                        Toggle("إنشاء مشروع iOS جاهز للبناء", isOn: $createStarter)
                        if createStarter {
                            HStack(spacing: 14) {
                                PhotosPicker(selection: $iconItem, matching: .images) {
                                    Group {
                                        if let iconData, let image = UIImage(data: iconData) {
                                            Image(uiImage: image).resizable().scaledToFill()
                                        } else {
                                            Image(systemName: "photo.badge.plus").font(.title2).foregroundStyle(.cyan)
                                        }
                                    }
                                    .frame(width: 72, height: 72)
                                    .background(.white.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                }
                                Text("صورة التطبيق (أيقونة). إن لم تختر صورة تُنشأ أيقونة تلقائية.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            TextField("اسم التطبيق (يظهر تحت الأيقونة)", text: $appName)
                                .onChange(of: appName) { _, value in
                                    if bundleID.isEmpty || bundleID == ProjectTemplate.suggestedBundleID(from: lastSuggestedName) {
                                        bundleID = ProjectTemplate.suggestedBundleID(from: value)
                                    }
                                    lastSuggestedName = value
                                }
                            TextField("المعرّف مثل com.azawy.icerf", text: $bundleID)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .environment(\.layoutDirection, .leftToRight)
                            if !bundleID.isEmpty && !ProjectTemplate.isValidBundleID(bundleID) {
                                Text("المعرّف غير صالح. استخدم حروفاً إنجليزية وأرقاماً ونقاطاً مثل com.azawy.icerf")
                                    .font(.caption).foregroundStyle(.red)
                            }
                        }
                    } header: {
                        Text("هوية التطبيق")
                    } footer: {
                        Text("يُنشأ مشروع SwiftUI بهذا الاسم والمعرّف والأيقونة، ثم تبنيه من «بناء تطبيق IPA».")
                    }
                }
                Section("خصوصية المستودع") {
                    Picker("الخصوصية", selection: $isPrivate) {
                        Label("خاص — أنا ومن أمنحهم الإذن فقط", systemImage: "lock.fill").tag(true)
                        Label("عام — يمكن للجميع رؤيته", systemImage: "globe").tag(false)
                    }
                    .pickerStyle(.inline)
                    Text(isPrivate ? "سيُنشأ المشروع خاصاً على GitHub." : "سيكون المشروع مرئياً للعامة. لا تضع أسراراً أو مفاتيح وصول في مستودع عام.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        Task { await createProject() }
                    } label: {
                        HStack {
                            Spacer()
                            if isCreating { ProgressView() }
                            else { Label("إنشاء المشروع", systemImage: "plus.circle.fill") }
                            Spacer()
                        }
                    }
                    .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating || !identityIsValid)
                }
            }
            .navigationTitle("مشروع جديد")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if !didSetDefault { category = defaultCategory; didSetDefault = true }
            }
            .onChange(of: iconItem) { _, item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self) { iconData = data }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("إلغاء") { dismiss() } }
            }
        }
    }

    private func createProject() async {
        isCreating = true
        defer { isCreating = false }
        let success = await model.createRepository(
            name: projectName.trimmingCharacters(in: .whitespacesAndNewlines),
            description: projectDescription,
            isPrivate: isPrivate,
            category: category,
            appIdentity: (isApp && createStarter)
                ? AppIdentity(
                    displayName: appName.trimmingCharacters(in: .whitespaces),
                    bundleID: bundleID.trimmingCharacters(in: .whitespaces),
                    iconData: iconData
                )
                : nil
        )
        if success { dismiss() }
    }
}

// MARK: - Repository workspace

struct RepositoryWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let repository: GitHubRepository
    @State private var showVisibilityConfirmation = false
    @State private var isChangingVisibility = false
    @State private var isPrivateOverride: Bool?
    @State private var showDelete = false
    @State private var shareItem: ShareItem?
    @State private var isExporting = false

    private var currentIsPrivate: Bool { isPrivateOverride ?? repository.isPrivate }

    var body: some View {
        List {
            Section("مساحة العمل") {
                NavigationLink {
                    FileBrowserView(repository: repository, path: "")
                } label: {
                    Label("الملفات ومحرر الأكواد", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                NavigationLink {
                    ProjectPreviewView(repository: repository)
                } label: {
                    Label("معاينة التطبيق والصفحات", systemImage: "eye.fill")
                }
                NavigationLink {
                    ScreenshotsGalleryView(repository: repository)
                } label: {
                    Label("لقطات كل الصفحات والأزرار", systemImage: "photo.stack")
                }
                NavigationLink {
                    ProjectBuildView(repository: repository)
                } label: {
                    Label("بناء تطبيق IPA وسجل البناء", systemImage: "hammer.fill")
                }
                NavigationLink {
                    BuildHistoryView(repository: repository)
                } label: {
                    Label("كل عمليات البناء والأخطاء", systemImage: "list.bullet.rectangle")
                }
                NavigationLink {
                    AIChatView(repository: repository)
                } label: {
                    Label("الذكاء الاصطناعي: تعديل وإصلاح", systemImage: "sparkles")
                }
            }

            Section("القسم") {
                Picker("تصنيف المشروع", selection: Binding(
                    get: { model.category(for: repository) },
                    set: { model.setCategory($0, for: repository) }
                )) {
                    Text("بدون تصنيف").tag(ProjectCategory?.none)
                    ForEach(ProjectCategory.allCases) { category in
                        Label(category.singular, systemImage: category.icon).tag(ProjectCategory?.some(category))
                    }
                }
            }

            Section("إعدادات المستودع") {
                LabeledContent("المستودع", value: repository.fullName)
                LabeledContent("الفرع", value: repository.defaultBranch)
                LabeledContent("الخصوصية", value: currentIsPrivate ? "خاص" : "عام")
                Button {
                    showVisibilityConfirmation = true
                } label: {
                    Label(
                        currentIsPrivate ? "تحويل إلى مستودع عام" : "تحويل إلى مستودع خاص",
                        systemImage: currentIsPrivate ? "globe" : "lock.fill"
                    )
                }
                .disabled(isChangingVisibility)
            }
            Section {
                Link(destination: URL(string: "https://github.com/\(repository.fullName)")!) {
                    Label("فتح المستودع في GitHub", systemImage: "arrow.up.right.square")
                }
                Button {
                    Task { await exportProject() }
                } label: {
                    HStack {
                        Label("تنزيل المشروع كاملاً (ZIP)", systemImage: "arrow.down.circle")
                        if isExporting { Spacer(); ProgressView() }
                    }
                }
                .disabled(isExporting)
            }

            Section {
                Button(role: .destructive) {
                    showDelete = true
                } label: {
                    Label("حذف المشروع", systemImage: "trash.fill")
                }
            } footer: {
                Text("يحذف المستودع نهائياً من GitHub مع كل ملفاته.")
            }
        }
        .navigationTitle(repository.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareItem) { ShareSheet(url: $0.url) }
        .sheet(isPresented: $showDelete) {
            DeleteRepositoryView(repository: repository) { dismiss() }.environmentObject(model)
        }
        .confirmationDialog(
            currentIsPrivate ? "جعل المشروع عاماً؟" : "جعل المشروع خاصاً؟",
            isPresented: $showVisibilityConfirmation,
            titleVisibility: .visible
        ) {
            Button(currentIsPrivate ? "نعم، اجعله عاماً" : "نعم، اجعله خاصاً", role: currentIsPrivate ? .destructive : nil) {
                Task { await changeVisibility() }
            }
            Button("إلغاء", role: .cancel) { }
        } message: {
            Text(currentIsPrivate
                 ? "سيتمكن أي شخص من رؤية محتويات هذا المستودع بعد تحويله إلى عام."
                 : "سيصبح المستودع متاحاً فقط لك ولمن تمنحهم صلاحية الوصول.")
        }
    }

    private func exportProject() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let url = try await GitHubAPI(token: model.token).downloadRepositoryZip(repository)
            shareItem = ShareItem(url: url)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func changeVisibility() async {
        isChangingVisibility = true
        defer { isChangingVisibility = false }
        let newValue = !currentIsPrivate
        if await model.changeVisibility(for: repository, isPrivate: newValue) {
            isPrivateOverride = newValue
        }
    }
}

// MARK: - File browser

struct FileBrowserView: View {
    @EnvironmentObject private var model: AppModel
    let repository: GitHubRepository
    let path: String

    @State private var files: [GitHubContentItem] = []
    @State private var isLoading = false
    @State private var showNewItem = false
    @State private var showImporter = false
    @State private var isUploading = false
    @State private var loadError: String?
    @State private var uploadMessage: String?
    @State private var uploadError: String?
    @State private var selection = Set<String>()
    @State private var editMode: EditMode = .inactive
    @State private var shareItem: ShareItem?
    @State private var isWorking = false
    @State private var pendingDelete: PendingDelete?

    struct PendingDelete: Identifiable {
        let id = UUID()
        let title: String
        let items: [RepoItemRef]
        let isEverything: Bool
    }

    private var isSelecting: Bool { editMode == .active }

    private func ref(_ file: GitHubContentItem) -> RepoItemRef {
        RepoItemRef(path: file.path, isDirectory: file.isDirectory)
    }

    private var selectedRefs: [RepoItemRef] {
        sortedFiles.filter { selection.contains($0.path) }.map(ref)
    }

    private var sortedFiles: [GitHubContentItem] {
        files.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                Button { showImporter = true } label: {
                    Label("رفع ملفات أو ZIP أو صور", systemImage: "square.and.arrow.up")
                        .foregroundStyle(.cyan)
                }
                .disabled(isUploading || model.isBusy)

                Button { showNewItem = true } label: {
                    Label("إنشاء ملف أو مجلد", systemImage: "plus")
                }
            }

            if let uploadMessage {
                Section {
                    Text(uploadMessage)
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            }
            if let uploadError {
                Section {
                    Text(uploadError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("محتويات المجلد") {
                if isLoading {
                    HStack { Spacer(); ProgressView("تحميل الملفات..."); Spacer() }
                }

                ForEach(sortedFiles) { file in
                    if file.isDirectory {
                        NavigationLink {
                            FileBrowserView(repository: repository, path: file.path)
                        } label: {
                            Label(file.name, systemImage: "folder.fill").foregroundStyle(.cyan)
                        }
                        .tag(file.path)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { askDelete([ref(file)]) } label: {
                                Label("حذف", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button { Task { await download([ref(file)]) } } label: {
                                Label("تنزيل", systemImage: "arrow.down.circle")
                            }
                            .tint(.cyan)
                        }
                    } else {
                        NavigationLink {
                            CodeFileEditorView(repository: repository, file: file)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: iconFor(file.name)).foregroundStyle(.cyan)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(file.name)
                                    Text(file.size.map { "\($0) bytes" } ?? "ملف")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tag(file.path)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { askDelete([ref(file)]) } label: {
                                Label("حذف", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button { Task { await download([ref(file)]) } } label: {
                                Label("تنزيل", systemImage: "arrow.down.circle")
                            }
                            .tint(.cyan)
                        }
                    }
                }
            }
        }
        .overlay {
            if files.isEmpty && !isLoading {
                ContentUnavailableView(
                    "المجلد فارغ",
                    systemImage: "folder",
                    description: Text("ارفع ZIP أو ملفات وصور، أو أنشئ ملفاً أو مجلداً جديداً.")
                )
            }
        }
        .overlay(alignment: .bottom) {
            if isUploading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("جارٍ تجهيز الملفات ورفعها إلى GitHub…")
                        .font(.footnote)
                }
                .padding().background(.ultraThinMaterial, in: Capsule()).padding()
            } else if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.red).padding().background(.ultraThinMaterial)
            }
        }
        .onChange(of: showImporter) { _, newValue in
            guard newValue else { return }
            showImporter = false
            DocumentPickerPresenter.shared.present { result in
                handleImport(result)
            }
        }
        .navigationTitle(path.isEmpty ? repository.name : URL(fileURLWithPath: path).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .onChange(of: editMode) { _, mode in
            if mode != .active { selection.removeAll() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { withAnimation { editMode = isSelecting ? .inactive : .active } } label: {
                    Text(isSelecting ? "تم" : "تحديد")
                }
                Menu {
                    Button { showNewItem = true } label: { Label("إنشاء ملف أو مجلد", systemImage: "plus") }
                    Button { Task { await loadFiles() } } label: { Label("تحديث", systemImage: "arrow.clockwise") }
                    Divider()
                    Button { Task { await download([]) } } label: {
                        Label(path.isEmpty ? "تنزيل كل الملفات (ZIP)" : "تنزيل هذا المجلد (ZIP)", systemImage: "arrow.down.circle")
                    }
                    Button(role: .destructive) {
                        askDelete(sortedFiles.map(ref), everything: true)
                    } label: {
                        Label(path.isEmpty ? "حذف كل الملفات" : "حذف كل محتويات المجلد", systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(isLoading || isUploading || isWorking)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                HStack(spacing: 12) {
                    Button {
                        selection = selection.count == sortedFiles.count ? [] : Set(sortedFiles.map(\.path))
                    } label: {
                        Text(selection.count == sortedFiles.count && !sortedFiles.isEmpty ? "إلغاء التحديد" : "تحديد الكل")
                    }
                    Spacer()
                    if isWorking { ProgressView() }
                    Button { Task { await download(selectedRefs) } } label: {
                        Label("تنزيل (\(selection.count))", systemImage: "arrow.down.circle")
                    }
                    .disabled(selection.isEmpty || isWorking)
                    Button(role: .destructive) { askDelete(selectedRefs) } label: {
                        Label("حذف (\(selection.count))", systemImage: "trash")
                    }
                    .disabled(selection.isEmpty || isWorking)
                }
                .font(.subheadline.bold())
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.bar)
            }
        }
        .sheet(item: $shareItem) { ShareSheet(url: $0.url) }
        .alert(
            pendingDelete?.title ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { request in
            Button("حذف", role: .destructive) { Task { await performDelete(request) } }
            Button("إلغاء", role: .cancel) { }
        } message: { request in
            Text(request.isEverything
                 ? "سيتم حذف كل الملفات والمجلدات في هذا المستوى بـ commit واحد."
                 : "سيتم حذف \(request.items.count) عنصر (المجلدات تُحذف مع كل محتوياتها).")
        }
        .sheet(isPresented: $showNewItem, onDismiss: { Task { await loadFiles() } }) {
            NewProjectFileView(repository: repository, parentPath: path).environmentObject(model)
        }
        .task { await loadFiles() }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            uploadError = nil
            uploadMessage = "تم اختيار \(urls.count) ملف… جارٍ التجهيز والرفع"
            Task { await importFiles(from: urls) }
        case .failure(let error):
            uploadError = error.localizedDescription
            model.errorMessage = error.localizedDescription
        }
    }

    private func importFiles(from urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isUploading = true
        uploadMessage = nil
        defer { isUploading = false }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuilderMobileImport-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }

            var uploadItems: [GitHubAPI.UploadFile] = []
            for url in urls {
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

                if url.pathExtension.lowercased() == "zip" {
                    let extracted = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
                    guard let archive = Archive(url: url, accessMode: .read) else {
                        throw NSError(domain: "BuilderMobile", code: 20, userInfo: [NSLocalizedDescriptionKey: "تعذر فتح ملف ZIP."])
                    }
                    for entry in archive {
                        guard entry.type == .file else { continue }
                        let safePath = entry.path.replacingOccurrences(of: "\\", with: "/")
                        let components = safePath.split(separator: "/")
                        guard !components.isEmpty, !components.contains(".."), !safePath.hasPrefix("/") else { continue }
                        if components.first == "__MACOSX" || safePath.hasSuffix("/.DS_Store") || safePath == ".DS_Store" { continue }
                        let destination = extracted.appendingPathComponent(safePath)
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        _ = try archive.extract(entry, to: destination)
                    }
                    let basePath = extracted.resolvingSymlinksInPath().path
                    let enumerator = FileManager.default.enumerator(at: extracted, includingPropertiesForKeys: [.isRegularFileKey], options: [])
                    var extractedFiles: [URL] = []
                    while let fileURL = enumerator?.nextObject() as? URL {
                        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                        if values.isRegularFile == true { extractedFiles.append(fileURL.resolvingSymlinksInPath()) }
                    }
                    let relativePaths = extractedFiles.map {
                        String($0.path.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    }
                    let firstComponents = relativePaths.compactMap { $0.split(separator: "/").first.map(String.init) }
                    let commonWrapper = firstComponents.first.flatMap { first in
                        firstComponents.count == relativePaths.count && firstComponents.allSatisfy { $0 == first }
                            && relativePaths.allSatisfy { $0.contains("/") } ? first : nil
                    }
                    for (fileURL, originalPath) in zip(extractedFiles, relativePaths) {
                        let relative = commonWrapper.map { String(originalPath.dropFirst($0.count + 1)) } ?? originalPath
                        guard !relative.isEmpty else { continue }
                        let data = try Data(contentsOf: fileURL)
                        uploadItems.append(.init(path: relative, data: data))
                    }
                } else {
                    let data = try Data(contentsOf: url)
                    uploadItems.append(.init(path: url.lastPathComponent, data: data))
                }
            }

            guard !uploadItems.isEmpty else {
                throw NSError(domain: "BuilderMobile", code: 21, userInfo: [NSLocalizedDescriptionKey: "لم يتم العثور على ملفات قابلة للرفع داخل الاختيار."])
            }

            try await GitHubAPI(token: model.token).uploadFiles(
                uploadItems,
                to: repository,
                parentPath: path,
                commitMessage: "Upload \(uploadItems.count) files from Builder Mobile"
            )
            uploadMessage = "تم رفع \(uploadItems.count) ملفاً بنجاح إلى المشروع."
            await loadFiles()
        } catch {
            var text = error.localizedDescription
            if let api = error as? GitHubAPIError, [401, 403, 404].contains(api.statusCode) {
                text += "\nتأكد أن الرمز (Token) يملك صلاحية Contents: Read and write على هذا المستودع."
            }
            uploadMessage = nil
            uploadError = text
            model.errorMessage = text
        }
    }

    private func loadFiles() async {
        isLoading = true
        defer { isLoading = false }
        do {
            files = try await GitHubAPI(token: model.token).listProjectFiles(repository: repository, path: path)
            loadError = nil
        } catch { loadError = error.localizedDescription }
    }

    private func askDelete(_ items: [RepoItemRef], everything: Bool = false) {
        guard !items.isEmpty else { return }
        let title = everything
            ? "حذف كل الملفات؟"
            : (items.count == 1 ? "حذف «\(items[0].name)»؟" : "حذف \(items.count) عناصر؟")
        pendingDelete = PendingDelete(title: title, items: items, isEverything: everything)
    }

    private func performDelete(_ request: PendingDelete) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let count = try await GitHubAPI(token: model.token).deletePaths(
                request.items.map(\.path),
                in: repository,
                commitMessage: "Delete \(request.items.count) item(s) from Builder Mobile"
            )
            uploadMessage = "تم حذف \(count) ملف."
            selection.removeAll()
            editMode = .inactive
            await loadFiles()
        } catch { model.errorMessage = error.localizedDescription }
    }

    /// `items` empty = the whole current folder.
    private func download(_ items: [RepoItemRef]) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let url = try await GitHubAPI(token: model.token).exportItems(items, from: repository, folderPath: path)
            shareItem = ShareItem(url: url)
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func iconFor(_ name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "swift": return "swift"
        case "json": return "curlybraces"
        case "html", "htm": return "globe"
        case "css": return "paintpalette"
        case "js", "ts", "tsx", "jsx": return "curlybraces"
        case "yml", "yaml": return "gearshape"
        case "png", "jpg", "jpeg", "gif", "webp", "svg": return "photo"
        case "md": return "doc.richtext"
        default: return "doc.text"
        }
    }
}

// MARK: - Create file or folder

struct NewProjectFileView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let repository: GitHubRepository
    let parentPath: String
    @State private var name = ""
    @State private var content = ""
    @State private var createFolder = false
    @State private var commitMessage = "Create file from Builder Mobile"
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("نوع العنصر") {
                    Picker("النوع", selection: $createFolder) {
                        Text("ملف").tag(false)
                        Text("مجلد").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                Section("الاسم") {
                    TextField(createFolder ? "اسم المجلد" : "اسم الملف مثل ContentView.swift", text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if !createFolder {
                    Section("محتوى الملف") {
                        TextEditor(text: $content)
                            .frame(minHeight: 190)
                            .font(.system(size: 14, design: .monospaced))
                    }
                }
                Section("رسالة الحفظ على GitHub") {
                    TextField("رسالة Commit", text: $commitMessage)
                }
            }
            .navigationTitle(createFolder ? "مجلد جديد" : "ملف جديد")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("إنشاء") { Task { await createItem() } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
    }

    private func createItem() async {
        isSaving = true
        defer { isSaving = false }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.contains("/"), cleanName != ".", cleanName != ".." else {
            model.errorMessage = "اكتب اسماً صالحاً دون / أو مسارات نسبية."
            return
        }
        let relativePath = createFolder ? "\(cleanName)/.gitkeep" : cleanName
        let fullPath = parentPath.isEmpty ? relativePath : "\(parentPath)/\(relativePath)"
        do {
            try await GitHubAPI(token: model.token).createProjectFile(
                repository: repository,
                path: fullPath,
                content: content,
                commitMessage: commitMessage
            )
            dismiss()
        } catch { model.errorMessage = error.localizedDescription }
    }
}

// MARK: - Code editor

struct CodeFileEditorView: View {
    @EnvironmentObject private var model: AppModel
    let repository: GitHubRepository
    let file: GitHubContentItem
    @State private var code = ""
    @State private var fileSHA: String?
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var savedMessage: String?
    @State private var commitMessage = "Update file from Builder Mobile"
    @State private var showFindReplace = false
    @State private var searchText = ""
    @State private var replacementText = ""

    private var fileExtension: String { URL(fileURLWithPath: file.name).pathExtension.lowercased() }
    private var isHTML: Bool { ["html", "htm"].contains(fileExtension) }
    private var lineCount: Int { max(1, code.components(separatedBy: .newlines).count) }
    private var matchCount: Int { searchText.isEmpty ? 0 : code.components(separatedBy: searchText).count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(file.name, systemImage: "doc.text").font(.caption.bold()).lineLimit(1)
                Spacer()
                Text("\(lineCount) سطر").font(.caption2).foregroundStyle(.secondary)
                if isSaving { ProgressView() }
                else {
                    Button { Task { await saveFile() } } label: {
                        Label("حفظ ورفع", systemImage: "arrow.up.circle.fill").font(.subheadline.bold())
                    }
                    .disabled(isLoading || fileSHA == nil)
                }
            }
            .padding(.horizontal).padding(.vertical, 10)
            Divider()

            if showFindReplace {
                VStack(spacing: 8) {
                    TextField("بحث داخل الملف", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    TextField("استبدال بـ", text: $replacementText)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Text("النتائج: \(matchCount)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("استبدال الكل") {
                            guard !searchText.isEmpty else { return }
                            code = code.replacingOccurrences(of: searchText, with: replacementText)
                        }
                        .disabled(searchText.isEmpty)
                    }
                }
                .padding()
                Divider()
            }

            if isLoading {
                ProgressView("تحميل الملف...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $code)
                    .font(.system(size: 14, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("رسالة Commit على GitHub", text: $commitMessage)
                    .font(.caption).textFieldStyle(.roundedBorder)
                if let savedMessage = savedMessage {
                    Text(savedMessage).font(.caption).foregroundStyle(.green)
                }
                if let errorMessage = errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(.horizontal).padding(.vertical, 8)
        }
        .navigationTitle("محرر الأكواد")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showFindReplace.toggle() } label: { Image(systemName: "magnifyingglass") }
                if isHTML {
                    NavigationLink { HTMLPreviewView(html: code) } label: {
                        Label("معاينة", systemImage: "eye")
                    }
                }
            }
        }
        .task { await loadFile() }
    }

    private func loadFile() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await GitHubAPI(token: model.token).readProjectFile(repository: repository, path: file.path)
            guard let text = result.decodedText else {
                throw NSError(domain: "BuilderMobile", code: 10, userInfo: [NSLocalizedDescriptionKey: "تعذر قراءة الملف كنص. قد يكون ملفاً ثنائياً أو أكبر من الحد المدعوم."])
            }
            code = text
            fileSHA = result.sha
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func saveFile() async {
        guard let fileSHA else { errorMessage = "لم يتم تحميل معلومات الملف بعد."; return }
        isSaving = true
        defer { isSaving = false }
        do {
            let api = GitHubAPI(token: model.token)
            try await api.saveProjectFile(
                repository: repository,
                path: file.path,
                content: code,
                sha: fileSHA,
                commitMessage: commitMessage
            )
            let updated = try await api.readProjectFile(repository: repository, path: file.path)
            self.fileSHA = updated.sha
            savedMessage = "تم حفظ التعديلات ورفع Commit إلى GitHub بنجاح."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            savedMessage = nil
        }
    }
}

// MARK: - Project preview

private struct PreviewScreenshot: Identifiable {
    let id: String
    let title: String
    let data: Data?
}

struct ProjectPreviewView: View {
    @EnvironmentObject private var model: AppModel
    let repository: GitHubRepository
    @State private var htmlFiles: [GitHubContentItem] = []
    @State private var selectedPath = ""
    @State private var html = ""
    @State private var isLoading = false
    @State private var message: String?
    @State private var projectPath = "."
    @State private var scheme = ""
    @State private var showSimulatorSettings = false
    @State private var previewShots: [PreviewScreenshot] = []
    @State private var isLoadingShots = false

    var body: some View {
        VStack(spacing: 0) {
            if !htmlFiles.isEmpty {
                Picker("صفحة المعاينة", selection: $selectedPath) {
                    ForEach(htmlFiles) { file in Text(file.path).tag(file.path) }
                }
                .pickerStyle(.menu).padding(.horizontal)
                .onChange(of: selectedPath) { _, newValue in
                    Task { await loadHTML(path: newValue) }
                }
            }
            if isLoading {
                ProgressView("تحميل المعاينة...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !html.isEmpty {
                VStack(spacing: 12) {
                    HTMLWebView(html: html)
                    screenshotSection
                }
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        ContentUnavailableView(
                            "لا توجد صفحة HTML للمعاينة",
                            systemImage: "eye.slash",
                            description: Text(message ?? "يمكنك مشاهدة لقطات تطبيق iOS التي يلتقطها المحاكي أدناه.")
                        )
                        screenshotSection
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .navigationTitle("معاينة التطبيق")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showSimulatorSettings = true } label: {
                    Image(systemName: "iphone.gen3")
                }
                Button { Task { await loadFiles(); await loadPreviewScreenshots(); await model.loadRuns(for: repository) } } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right").foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("محاكي iPhone عبر GitHub Actions").font(.subheadline.bold())
                        Text("تشغيل مجاني حسب حصة دقائق GitHub المتاحة").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("تشغيل") { Task { await runSimulator() } }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        .disabled(model.isBusy)
                }
                if let status = model.statusMessage {
                    Text(status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let run = model.runsByRepository[repository.fullName]?.first {
                    HStack {
                        Text("آخر تشغيل: \(run.displayStatus)").font(.caption)
                        Spacer()
                        if let url = run.htmlURL { Link("سجل GitHub", destination: url).font(.caption) }
                        Button("تنزيل المخرجات") {
                            Task { await model.downloadNewestArtifact(repo: repository, run: run) }
                        }
                        .font(.caption)
                        .disabled(model.isBusy || run.status != "completed" || run.conclusion != "success")
                    }
                }
                if let file = model.downloadedArtifactURL {
                    ShareLink(item: file) {
                        Label(file.pathExtension.lowercased() == "ipa" ? "مشاركة ملف IPA" : "مشاركة الملف", systemImage: "square.and.arrow.up")
                    }
                        .font(.caption)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial)
        }
        .sheet(isPresented: $showSimulatorSettings) {
            NavigationStack {
                Form {
                    Section("مسار المشروع") {
                        TextField("مثال: . أو ios-app", text: $projectPath)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("اكتب . إذا كان مشروع Xcode في جذر المستودع.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Xcode Scheme") {
                        TextField("اتركه فارغاً للاكتشاف التلقائي", text: $scheme)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Section {
                        Text("يعمل المحاكي على خادم macOS مؤقت ضمن GitHub Actions. يلتقط لقطات لكل الصفحات والأزرار ويحفظها في مجلد Screenshots داخل المشروع، وتشاهدها من «لقطات كل الصفحات والأزرار». وليس جلسة تحكم مباشر. قد تنطبق حدود الاستخدام المجاني لحساب GitHub.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("إعدادات المحاكي")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("إغلاق") { showSimulatorSettings = false } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("تشغيل المحاكي") {
                            showSimulatorSettings = false
                            Task { await runSimulator() }
                        }
                        .disabled(model.isBusy)
                    }
                }
            }
        }
        .task { await loadFiles(); await loadPreviewScreenshots(); await model.loadRuns(for: repository) }
    }

    @ViewBuilder
    private var screenshotSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("لقطات صفحات التطبيق").font(.headline)
                Spacer()
                if isLoadingShots { ProgressView().controlSize(.small) }
                Button("تحديث") { Task { await loadPreviewScreenshots() } }
                    .font(.caption)
                    .disabled(isLoadingShots)
            }
            if previewShots.isEmpty {
                Text("ستظهر لقطات المحاكي هنا بعد نجاح تشغيله وحفظ الصور في مجلد Screenshots.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(previewShots) { shot in
                            VStack(spacing: 6) {
                                if let data = shot.data, let image = UIImage(data: data) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 150, height: 280)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                } else {
                                    ProgressView().frame(width: 150, height: 280)
                                }
                                Text(shot.title)
                                    .font(.caption2)
                                    .lineLimit(2)
                                    .frame(width: 150)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private func loadPreviewScreenshots() async {
        isLoadingShots = true
        defer { isLoadingShots = false }
        let api = GitHubAPI(token: model.token)
        do {
            let files = try await api.listProjectFiles(repository: repository, path: "Screenshots")
            var titles: [String: String] = [:]
            if let index = try? await api.rawFile(repository: repository, path: "Screenshots/index.txt"),
               let text = String(data: index, encoding: .utf8) {
                for line in text.split(whereSeparator: \.isNewline) {
                    let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                    if parts.count == 2 { titles[parts[0]] = parts[1] }
                }
            }
            let pngs = files.filter { $0.name.lowercased().hasSuffix(".png") }.sorted { $0.name < $1.name }
            var loaded: [PreviewScreenshot] = []
            for file in pngs {
                let data = try? await api.rawFile(repository: repository, path: file.path)
                let key = String(file.name.dropLast(4))
                loaded.append(PreviewScreenshot(
                    id: file.path,
                    title: titles[key] ?? key,
                    data: data
                ))
            }
            previewShots = loaded
        } catch {
            previewShots = []
        }
    }

    private func runSimulator() async {
        await model.prepareAndRunSimulatorPreview(
            repo: repository,
            projectPath: projectPath,
            scheme: scheme
        )
    }

    private func loadFiles() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let items = try await GitHubAPI(token: model.token).listProjectFiles(repository: repository)
            htmlFiles = items.filter {
                ["html", "htm"].contains(URL(fileURLWithPath: $0.name).pathExtension.lowercased())
            }
            guard !htmlFiles.isEmpty else {
                html = ""
                message = "لم يتم العثور على ملفات HTML في المجلد الرئيسي. يمكنك استخدام محاكي iOS السحابي للمشاريع الأصلية."
                return
            }
            let preferred = htmlFiles.first(where: { $0.name.lowercased() == "index.html" }) ?? htmlFiles[0]
            selectedPath = preferred.path
            await loadHTML(path: preferred.path)
        } catch { message = error.localizedDescription }
    }

    private func loadHTML(path: String) async {
        guard !path.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let file = try await GitHubAPI(token: model.token).readProjectFile(repository: repository, path: path)
            html = file.decodedText ?? ""
            if html.isEmpty { message = "تعذر قراءة الصفحة كنص." }
        } catch { message = error.localizedDescription }
    }
}

struct HTMLPreviewView: View {
    let html: String
    var body: some View {
        HTMLWebView(html: html)
            .navigationTitle("معاينة الواجهة")
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct HTMLWebView: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.isInspectable = true
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        return webView
    }
    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}

// MARK: - Build

struct ProjectBuildView: View {
    @EnvironmentObject private var model: AppModel
    let repository: GitHubRepository
    @State private var projectPath = "."
    @State private var scheme = ""

    private var runs: [WorkflowRun] { model.runsByRepository[repository.fullName] ?? [] }

    var body: some View {
        Form {
            Section("المستودع") {
                LabeledContent("الاسم", value: repository.fullName)
                LabeledContent("الفرع", value: repository.defaultBranch)
                LabeledContent("الخصوصية", value: repository.isPrivate ? "خاص" : "عام")
            }
            Section("إعداد البناء") {
                TextField("مسار المشروع", text: $projectPath)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("اكتب . للمشروع الموجود في الجذر، أو مسار مجلد التطبيق.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("اسم Xcode Scheme (اختياري)", text: $scheme)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button {
                    Task { await model.prepareAndBuild(repo: repository, projectPath: projectPath, scheme: scheme) }
                } label: {
                    Label("تجهيز وتشغيل بناء IPA", systemImage: "hammer.fill").frame(maxWidth: .infinity)
                }
                .disabled(model.isBusy)
                if let message = model.statusMessage {
                    Text(message).font(.footnote).foregroundStyle(.cyan)
                }
            }
            Section("كل عمليات البناء (\(runs.count))") {
                if runs.isEmpty {
                    Text("لا توجد عمليات بناء محمّلة بعد.").foregroundStyle(.secondary)
                }
                ForEach(runs.prefix(10)) { run in
                    NavigationLink {
                        BuildRunView(repository: repository, run: run)
                    } label: {
                        BuildRunRow(run: run)
                    }
                }
                if runs.count > 10 {
                    NavigationLink("عرض كل العمليات (\(runs.count))") {
                        BuildHistoryView(repository: repository)
                    }
                }
                Button("تحديث السجل") { Task { await model.loadRuns(for: repository) } }
            }
            Section {
                Text("يتم البناء على خوادم macOS عبر GitHub Actions. سير العمل الحالي ينتج IPA غير موقّع؛ يلزم إضافة إعدادات شهادة Apple وملف Provisioning Profile إلى سير العمل إذا أردت تثبيته مباشرة.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("بناء التطبيق")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadRuns(for: repository) }
    }
}

// MARK: - Screenshots gallery

struct ScreenshotsGalleryView: View {
    @EnvironmentObject private var model: AppModel
    let repository: GitHubRepository

    struct Shot: Identifiable {
        let id: String
        let title: String
        var data: Data?
    }

    @State private var shots: [Shot] = []
    @State private var isLoading = false
    @State private var message: String?
    @State private var selected: Shot?

    var body: some View {
        Group {
            if isLoading && shots.isEmpty {
                ProgressView("جارٍ تحميل اللقطات…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shots.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48)).foregroundStyle(.secondary)
                    Text(message ?? "لا توجد لقطات بعد. شغّل المحاكي من «معاينة التطبيق والصفحات» وانتظر انتهاءه.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 16) {
                        ForEach(shots) { shot in
                            Button { selected = shot } label: {
                                VStack(spacing: 6) {
                                    if let data = shot.data, let image = UIImage(data: data) {
                                        Image(uiImage: image).resizable().scaledToFit()
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    } else {
                                        RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.2))
                                            .aspectRatio(9.0 / 19.5, contentMode: .fit)
                                            .overlay(ProgressView())
                                    }
                                    Text(shot.title).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("لقطات التطبيق")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(isLoading)
            }
        }
        .sheet(item: $selected) { shot in
            NavigationStack {
                ScrollView {
                    if let data = shot.data, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit().padding()
                    }
                }
                .navigationTitle(shot.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("إغلاق") { selected = nil } }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        message = nil
        defer { isLoading = false }
        let api = GitHubAPI(token: model.token)
        do {
            let items = try await api.listProjectFiles(repository: repository, path: "Screenshots")
            var titles: [String: String] = [:]
            var order: [String] = []
            if let indexData = try? await api.rawFile(repository: repository, path: "Screenshots/index.txt"),
               let text = String(data: indexData, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        titles[parts[0]] = parts[1]
                        order.append(parts[0])
                    }
                }
            }
            let pngs = items
                .filter { $0.name.lowercased().hasSuffix(".png") }
                .sorted { a, b in
                    let ia = order.firstIndex(of: String(a.name.dropLast(4))) ?? Int.max
                    let ib = order.firstIndex(of: String(b.name.dropLast(4))) ?? Int.max
                    return ia == ib ? a.name < b.name : ia < ib
                }
            shots = pngs.map { item in
                Shot(id: item.path, title: titles[String(item.name.dropLast(4))] ?? item.name, data: nil)
            }
            if shots.isEmpty { message = "مجلد Screenshots فارغ." }
            for index in shots.indices {
                if let data = try? await api.rawFile(repository: repository, path: shots[index].id) {
                    shots[index].data = data
                }
            }
        } catch {
            shots = []
            message = "لا توجد لقطات بعد، أو تعذر تحميلها.\n\(error.localizedDescription)"
        }
    }
}

// MARK: - Status

struct StatusPill: View {
    let status: String
    var body: some View {
        Text(status.replacingOccurrences(of: "_", with: " "))
            .font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 5)
            .background(status == "success" ? Color.green.opacity(0.18) : Color.cyan.opacity(0.15), in: Capsule())
            .foregroundStyle(status == "success" ? .green : .cyan)
    }
}

// MARK: - Document picker (copy mode, no security-scope issues)

final class DocumentPickerPresenter: NSObject, UIDocumentPickerDelegate {
    static let shared = DocumentPickerPresenter()
    private var completion: ((Result<[URL], Error>) -> Void)?

    func present(completion: @escaping (Result<[URL], Error>) -> Void) {
        present(types: [.item], completion: completion)
    }

    func present(types: [UTType], completion: @escaping (Result<[URL], Error>) -> Void) {
        self.completion = completion
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self

        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        top?.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let done = completion
        completion = nil
        DispatchQueue.main.async { done?(.success(urls)) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion = nil
    }
}
