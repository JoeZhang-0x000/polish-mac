import SwiftUI
import AppKit

struct SettingsView: View {
    var openAccessibility: () -> Void

    var body: some View {
        TabView {
            GeneralTab(openAccessibility: openAccessibility)
                .tabItem { Label("通用", systemImage: "gearshape") }
            TonesTab()
                .tabItem { Label("语气与提示词", systemImage: "text.quote") }
            ProvidersTab()
                .tabItem { Label("模型服务", systemImage: "server.rack") }
            HelpTab()
                .tabItem { Label("使用说明", systemImage: "questionmark.circle") }
        }
        .padding(12)
        .frame(minWidth: 680, minHeight: 480)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var store: ConfigStore
    var openAccessibility: () -> Void

    @State private var trusted = FocusInspector.isTrusted
    @State private var customLanguage = false
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    private static let customTag = "__custom__"

    private var isPresetLanguage: Bool {
        Defaults.languages.contains { $0.promptName == store.config.targetLanguage }
    }

    private var languageSelection: Binding<String> {
        Binding(
            get: { (customLanguage || !isPresetLanguage) ? Self.customTag : store.config.targetLanguage },
            set: { v in
                if v == Self.customTag {
                    customLanguage = true
                } else {
                    customLanguage = false
                    store.config.targetLanguage = v
                }
            })
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { "\(store.config.activeProviderID?.uuidString ?? "")|\(store.config.activeModel)" },
            set: { v in
                let parts = v.split(separator: "|", maxSplits: 1).map(String.init)
                if parts.count == 2, let id = UUID(uuidString: parts[0]) { store.select(providerID: id, model: parts[1]) }
            })
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: trusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trusted ? .green : .orange)
                    Text(trusted ? "辅助功能权限已授权" : "需要「辅助功能」权限才能监听双击空格并替换文字")
                    Spacer()
                    if !trusted { Button("去授权") { openAccessibility() } }
                }
            } header: { Text("权限") }

            Section {
                Toggle("启用双击空格润色", isOn: $store.config.enabled)
                Picker("目标语言", selection: languageSelection) {
                    ForEach(Defaults.languages) { Text($0.display).tag($0.promptName) }
                    Divider()
                    Text("自定义…").tag(Self.customTag)
                }
                if customLanguage || !isPresetLanguage {
                    TextField("自定义语言（建议用英文名，如 Italian）", text: $store.config.targetLanguage)
                }
                Picker("语气", selection: $store.config.activeToneID) {
                    ForEach(store.config.tones) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("模型", selection: modelSelection) {
                    ForEach(store.config.providers) { p in
                        Section(p.name) {
                            ForEach(p.models, id: \.self) { m in
                                Text(m).tag("\(p.id.uuidString)|\(m)")
                            }
                        }
                    }
                }
            } header: { Text("润色") }

            Section {
                LabeledContent("双击空格间隔") {
                    HStack {
                        Slider(value: $store.config.doubleSpaceInterval, in: 0.2...0.6, step: 0.05)
                        Text(String(format: "%.2f 秒", store.config.doubleSpaceInterval))
                            .monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                Toggle("润色后的第一次 ⌘Z 恢复原文（对所有应用都有效，⇧⌘Z 重做）", isOn: $store.config.takeOverUndo)
                Toggle("无法识别输入框类型时也触发（部分 Electron / 网页应用需要）", isOn: $store.config.triggerInUnknownFields)
                Stepper("单次最多 \(store.config.maxChars) 字", value: $store.config.maxChars, in: 500...50000, step: 500)
                LabeledContent("Temperature（仅 OpenAI 兼容）") {
                    HStack {
                        Slider(value: $store.config.temperature, in: 0...1, step: 0.1)
                        Text(String(format: "%.1f", store.config.temperature))
                            .monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
            } header: { Text("触发与撤销") }

            Section {
                ForEach(store.config.excludedBundleIDs, id: \.self) { bid in
                    HStack {
                        Text(appName(bid))
                        Text(bid).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            store.config.excludedBundleIDs.removeAll { $0 == bid }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Menu("添加正在运行的应用…") {
                    ForEach(runningApps(), id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                            if let bid = app.bundleIdentifier, !store.config.excludedBundleIDs.contains(bid) {
                                store.config.excludedBundleIDs.append(bid)
                            }
                        }
                    }
                }
                .fixedSize()
            } header: {
                Text("排除的应用（终端、代码编辑器等常需要连续空格的应用）")
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in trusted = FocusInspector.isTrusted }
    }

    private func appName(_ bid: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return bid }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                && $0.processIdentifier != getpid()
                && !store.config.excludedBundleIDs.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

// MARK: - Tones & prompts

private struct TonesTab: View {
    @EnvironmentObject var store: ConfigStore
    @State private var selection: UUID?

    private func index(_ id: UUID?) -> Int? { store.config.tones.firstIndex { $0.id == id } }

    private func field(_ kp: WritableKeyPath<Tone, String>) -> Binding<String> {
        Binding(
            get: { index(selection).map { store.config.tones[$0][keyPath: kp] } ?? "" },
            set: { v in if let i = index(selection) { store.config.tones[i][keyPath: kp] = v } })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.config.tones) { t in
                        HStack {
                            Text(t.name)
                            Spacer()
                            if t.id == store.config.activeTone?.id {
                                Text("当前").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(t.id)
                    }
                    .onMove { store.config.tones.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                HStack(spacing: 4) {
                    Button { addTone() } label: { Image(systemName: "plus") }
                    Button { removeTone() } label: { Image(systemName: "minus") }
                        .disabled(selection == nil || store.config.tones.count <= 1)
                    Spacer()
                    Menu {
                        Button("恢复内置语气（保留自定义）") { restoreBuiltins() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 180)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))

            VStack(alignment: .leading, spacing: 8) {
                if index(selection) != nil {
                    HStack {
                        TextField("语气名称", text: field(\.name)).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                        Spacer()
                        Button("设为当前语气") { store.config.activeToneID = selection }
                            .disabled(selection == store.config.activeTone?.id)
                    }
                    Text("语气提示词（会替换模板中的 {tone}）").font(.headline)
                    TextEditor(text: field(\.prompt))
                        .font(.body)
                        .frame(minHeight: 80, maxHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                } else {
                    Text("在左侧选择一个语气进行编辑").foregroundStyle(.secondary).frame(height: 40)
                }

                Divider().padding(.vertical, 4)

                HStack {
                    Text("系统提示词模板").font(.headline)
                    Spacer()
                    Button("恢复默认模板") { store.config.systemPromptTemplate = Defaults.systemPromptTemplate }
                        .disabled(store.config.systemPromptTemplate == Defaults.systemPromptTemplate)
                }
                Text("占位符：{language} → 目标语言，{tone} → 当前语气提示词。待润色文本会以 <text>…</text> 的形式作为用户消息发送。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $store.config.systemPromptTemplate)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }
        }
        .padding(8)
        .onAppear { if selection == nil { selection = store.config.activeTone?.id } }
    }

    private func addTone() {
        let t = Tone(name: "新语气", prompt: "Describe the desired tone here, e.g. \"Persuasive: confident and compelling.\"")
        store.config.tones.append(t)
        selection = t.id
    }

    private func removeTone() {
        guard let i = index(selection), store.config.tones.count > 1 else { return }
        let removed = store.config.tones.remove(at: i)
        if store.config.activeToneID == removed.id { store.config.activeToneID = store.config.tones.first?.id }
        selection = store.config.tones[min(i, store.config.tones.count - 1)].id
    }

    private func restoreBuiltins() {
        let existing = Set(store.config.tones.map(\.name))
        store.config.tones.append(contentsOf: Defaults.tones().filter { !existing.contains($0.name) })
    }
}

// MARK: - Providers & models

private struct ProvidersTab: View {
    @EnvironmentObject var store: ConfigStore
    @State private var selection: UUID?
    @State private var newModel = ""
    @State private var showKey = false
    @State private var testModel = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var fetching = false
    @State private var fetchError: String?
    @State private var fetched: FetchedModels?

    private func index(_ id: UUID?) -> Int? { store.config.providers.firstIndex { $0.id == id } }

    private func field<T>(_ kp: WritableKeyPath<Provider, T>, _ fallback: T) -> Binding<T> {
        Binding(
            get: { index(selection).map { store.config.providers[$0][keyPath: kp] } ?? fallback },
            set: { v in if let i = index(selection) { store.config.providers[i][keyPath: kp] = v } })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.config.providers) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name)
                            Text(p.style.label + (p.id == store.config.activeProviderID ? " · 当前" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(p.id)
                    }
                    .onMove { store.config.providers.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                HStack(spacing: 4) {
                    Menu {
                        ForEach(Defaults.providerTemplates) { t in
                            Button(t.name) { add(t) }
                        }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    Button { remove() } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                        .disabled(selection == nil)
                    Spacer()
                }
                .padding(6)
            }
            .frame(width: 180)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))

            if let i = index(selection) {
                editor(i)
            } else {
                Text("在左侧选择或添加一个模型服务").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
        .onAppear { if selection == nil { selection = store.config.activeProviderID ?? store.config.providers.first?.id } }
        .sheet(item: $fetched) { f in
            ModelPickerSheet(providerName: f.providerName, available: f.ids, existing: Set(f.existing)) { picked in
                guard let i = index(f.providerID) else { return }
                for m in picked where !store.config.providers[i].models.contains(m) {
                    store.config.providers[i].models.append(m)
                }
                if selection == f.providerID, testModel.isEmpty { testModel = store.config.providers[i].models.first ?? "" }
            }
        }
        .onChange(of: selection) { _ in
            testResult = nil
            fetchError = nil
            newModel = ""
            showKey = false
            testModel = index(selection).flatMap { store.config.providers[$0].models.first } ?? ""
        }
    }

    @ViewBuilder
    private func editor(_ i: Int) -> some View {
        let p = store.config.providers[i]
        Form {
            TextField("名称", text: field(\.name, ""))
            Picker("接口类型", selection: field(\.style, .openai)) {
                ForEach(APIStyle.allCases) { Text($0.label).tag($0) }
            }
            TextField("Base URL", text: field(\.baseURL, ""))
            Text(p.style == .openai
                 ? "请求 {Base URL}/chat/completions，例如 https://api.openai.com/v1"
                 : "请求 {Base URL}/v1/messages，例如 https://api.anthropic.com")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if showKey {
                    TextField("API Key", text: field(\.apiKey, ""))
                } else {
                    SecureField("API Key", text: field(\.apiKey, ""))
                }
                Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless)
            }
            if p.style == .anthropic {
                Picker("思考强度 (effort)", selection: field(\.effort, "")) {
                    Text("默认（不发送）").tag("")
                    Text("low（更快）").tag("low")
                    Text("medium").tag("medium")
                    Text("high").tag("high")
                }
            }

            Section("模型") {
                ForEach(p.models, id: \.self) { m in
                    HStack {
                        Text(m).textSelection(.enabled)
                        if p.id == store.config.activeProviderID && m == store.config.activeModel {
                            Text("当前").font(.caption).foregroundStyle(.green)
                        }
                        Spacer()
                        Button("使用") { store.select(providerID: p.id, model: m) }
                            .disabled(p.id == store.config.activeProviderID && m == store.config.activeModel)
                        Button {
                            store.config.providers[i].models.removeAll { $0 == m }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("手动添加模型 ID，如 gpt-4.1-mini", text: $newModel)
                        .onSubmit(addModel)
                    Button("添加", action: addModel)
                        .disabled(newModel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    Button {
                        fetchModels(p)
                    } label: {
                        Label(fetching ? "正在获取…" : "从服务获取模型列表…", systemImage: "arrow.down.circle")
                    }
                    .disabled(fetching || (p.needsKey && p.style == .anthropic))
                    if fetching { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let e = fetchError {
                    Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("测试") {
                HStack {
                    Picker("模型", selection: $testModel) {
                        ForEach(p.models, id: \.self) { Text($0).tag($0) }
                    }
                    Button(testing ? "测试中…" : "测试润色") { runTest(p) }
                        .disabled(testing || testModel.isEmpty || !p.models.contains(testModel))
                }
                if let r = testResult {
                    Text(r.text)
                        .font(.callout)
                        .foregroundStyle(r.ok ? Color.primary : Color.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add(_ template: Provider) {
        var p = template
        p.id = UUID()
        store.config.providers.append(p)
        selection = p.id
    }

    private func remove() {
        guard let i = index(selection) else { return }
        let removed = store.config.providers.remove(at: i)
        if store.config.activeProviderID == removed.id, let first = store.config.providers.first {
            store.select(providerID: first.id, model: first.models.first ?? "")
        }
        selection = store.config.providers.isEmpty ? nil : store.config.providers[min(i, store.config.providers.count - 1)].id
    }

    private func addModel() {
        let m = newModel.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty, let i = index(selection) else { return }
        if !store.config.providers[i].models.contains(m) { store.config.providers[i].models.append(m) }
        if testModel.isEmpty { testModel = m }
        newModel = ""
    }

    private func fetchModels(_ p: Provider) {
        fetching = true
        fetchError = nil
        Task { @MainActor in
            defer { fetching = false }
            do {
                let ids = try await LLMClient.listModels(provider: p)
                if ids.isEmpty {
                    fetchError = "服务没有返回任何模型，请手动添加"
                } else {
                    let current = index(p.id).map { store.config.providers[$0].models } ?? p.models
                    fetched = FetchedModels(providerID: p.id, providerName: p.name, ids: ids, existing: current)
                }
            } catch {
                fetchError = "获取失败：" + error.localizedDescription + "（该服务可能不支持 /models，可手动添加）"
            }
        }
    }

    private func runTest(_ p: Provider) {
        testing = true
        testResult = nil
        var cfg = store.config
        cfg.activeProviderID = p.id
        cfg.activeModel = testModel
        let start = Date()
        Task { @MainActor in
            do {
                let out = try await LLMClient.polish("this are a example sentence that need to polish.", config: cfg)
                testResult = (true, String(format: "✓ %.1f 秒：%@", Date().timeIntervalSince(start), out))
            } catch {
                testResult = (false, "✗ " + error.localizedDescription)
            }
            testing = false
        }
    }
}

// MARK: - Model picker

private struct FetchedModels: Identifiable {
    let id = UUID()
    let providerID: UUID
    let providerName: String
    let ids: [String]
    let existing: [String]
}

private struct ModelPickerSheet: View {
    let providerName: String
    let available: [String]
    let existing: Set<String>
    let onAdd: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var chatOnly = true
    @State private var picked = Set<String>()

    private var visible: [String] {
        available.filter { id in
            (!chatOnly || LLMClient.looksLikeChatModel(id))
                && (query.isEmpty || id.localizedCaseInsensitiveContains(query))
        }
        .sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(providerName) 提供 \(available.count) 个模型").font(.headline)
            HStack {
                TextField("搜索", text: $query).textFieldStyle(.roundedBorder)
                Toggle("隐藏非对话模型", isOn: $chatOnly)
            }
            List {
                ForEach(visible, id: \.self) { id in
                    if existing.contains(id) {
                        HStack {
                            Image(systemName: "checkmark.square.fill").foregroundStyle(.secondary)
                            Text(id).foregroundStyle(.secondary)
                            Spacer()
                            Text("已添加").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Toggle(id, isOn: Binding(
                            get: { picked.contains(id) },
                            set: { on in if on { picked.insert(id) } else { picked.remove(id) } }))
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(minHeight: 280)
            HStack {
                Button("全选当前列表") { picked.formUnion(visible.filter { !existing.contains($0) }) }
                Button("清空选择") { picked.removeAll() }.disabled(picked.isEmpty)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("添加 \(picked.count) 个模型") {
                    onAdd(available.filter { picked.contains($0) })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520, height: 460)
    }
}

// MARK: - Help

private struct HelpTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Group {
                    Text("怎么用").font(.title3.bold())
                    Text("在任意应用的输入框里写完文字后，**快速连按两次空格**。Polish 会读取整个输入框的内容，按当前的目标语言和语气交给大模型润色，然后替换回输入框。")
                    Text("润色过程中按 **Esc** 取消；继续打字也会自动取消。")
                    Text("替换完成后按 **⌘Z** 恢复原文，再按 **⇧⌘Z** 重新应用润色。")
                }
                Group {
                    Text("工作方式").font(.title3.bold())
                    Text("Polish 通过模拟 ⌘A / ⌘C 读取输入框，通过 ⌘V 写回，完成后会恢复你原来的剪贴板内容。因此它会处理**整个输入框**的文字；在长文档编辑器中请谨慎使用（可以把这类应用加入「排除的应用」）。")
                    Text("在列表、按钮、网页正文等非输入区域连按空格不会触发；终端和代码编辑器默认被排除。")
                }
                Group {
                    Text("权限").font(.title3.bold())
                    Text("需要在「系统设置 › 隐私与安全性 › 辅助功能」中允许 Polish。重新编译 / 替换 App 后，可能需要把旧条目删除后重新授权。")
                    Text("配置（含 API Key）保存在 ~/Library/Application Support/Polish/config.json，文件权限为仅当前用户可读。")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}
