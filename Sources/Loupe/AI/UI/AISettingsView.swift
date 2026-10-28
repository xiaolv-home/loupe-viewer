import SwiftUI
import AppKit
import LoupeCore

/// 设置 › AI: the local server, cloud keys, and what the AI may do.
struct AISettingsView: View {
    @ObservedObject var config = AIConfig.shared
    @State private var keyDraft = ""
    @State private var localStatus = ""
    @State private var testStatus = ""
    @State private var testing = false

    var body: some View {
        Form {
            Section("使用哪种模式") {
                Picker("模式", selection: $config.mode) {
                    Text("本地（文件不出本机）").tag(AIConfig.Mode.local)
                    Text("云端 API").tag(AIConfig.Mode.cloud)
                }
                .pickerStyle(.radioGroup)
            }
            Section("本地模型（LM Studio / Ollama / llama.cpp）") {
                HStack {
                    TextField("接口地址", text: $config.localBaseURL).font(Theme.mono(11.5))
                    Button("自动查找") { detect() }
                }
                LabeledContent("模型") {
                    Text(config.localModel.isEmpty ? "未选择" : config.localModel).font(Theme.mono(11.5)).textSelection(.enabled)
                }
                if !localStatus.isEmpty { Text(localStatus).font(.system(size: 11)).foregroundStyle(.secondary) }
                Text("在 AI 面板顶部的模型菜单里选择具体模型。需要模型支持工具调用（Qwen、DeepSeek、GLM、Llama 3.1+ 等都可以）。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("云端 API") {
                Picker("服务", selection: $config.providerID) {
                    ForEach(CloudProvider.all) { p in Text(p.name).tag(p.id) }
                }
                let p = config.provider
                HStack {
                    SecureField(config.apiKey(p) == nil ? "粘贴 API Key" : "已保存（重新粘贴可替换）", text: $keyDraft)
                        .onSubmit { saveKey() }
                    Button("保存") { saveKey() }.disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if config.apiKey(p) != nil {
                        Button("删除") { config.setAPIKey("", for: p) }
                    }
                }
                if !p.keyPage.isEmpty {
                    Link("去「\(p.name)」申请 API Key", destination: URL(string: p.keyPage)!).font(.system(size: 11))
                }
                TextField("接口地址", text: Binding(get: { config.cloudBaseURL(p) }, set: { config.cloudBaseURLs[p.id] = $0 }))
                    .font(Theme.mono(11.5))
                TextField("模型", text: Binding(get: { config.cloudModel(p) }, set: { config.cloudModels[p.id] = $0 }))
                    .font(Theme.mono(11.5))
                HStack {
                    Button(testing ? "测试中…" : "测试连接") { test() }.disabled(testing)
                    Text(testStatus).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("API Key 只保存在这台 Mac 上（仅你的账户可读），不会弹出钥匙串密码。云端模式会把你让 AI 处理的文件内容发给该服务。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("AI 能做的事") {
                Toggle("允许 AI 运行终端命令（每条命令都要你点「允许」）", isOn: $config.allowCommands)
                Text("开启后，依赖 Python 脚本的技能（例如部分 Office 文档技能）才能完整运行。AI 只能写入你的个人文件夹，覆盖已有文件前会先问你。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("管理技能…") { AISkillsWindow.show() }
            }
        }
        .formStyle(.grouped)
        .onChange(of: config.providerID) { _, _ in keyDraft = ""; testStatus = "" }
    }

    private func saveKey() {
        config.setAPIKey(keyDraft, for: config.provider)
        keyDraft = ""
        test()
    }

    private func detect() {
        localStatus = "查找中…"
        Task {
            if let found = await config.detectLocal() {
                config.localBaseURL = found.base
                if !found.models.contains(config.localModel) { config.localModel = AIModelList.preferred(found.models) }
                localStatus = "找到 \(found.models.count) 个模型：" + found.models.prefix(6).joined(separator: "、")
            } else {
                localStatus = "没找到正在运行的本地模型服务。请打开 LM Studio（开发者 › 启动服务）或 Ollama。"
            }
        }
    }

    private func test() {
        testing = true
        testStatus = ""
        let p = config.provider
        Task {
            defer { testing = false }
            guard let key = config.apiKey(p), let u = URL(string: config.cloudBaseURL(p)) else { testStatus = "先保存 API Key"; return }
            let e = AIEndpoint(proto: p.proto, baseURL: u, model: config.cloudModel(p), apiKey: key)
            do {
                let models = try await AIClients.listModels(e)
                testStatus = "✓ 连接成功" + (models.isEmpty ? "" : "，可用模型 \(models.count) 个")
            } catch {
                testStatus = AIHTTP.describe(error, endpoint: e)
            }
        }
    }
}
