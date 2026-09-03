import AppKit
import KakaoLinearCore
import SwiftUI

struct SettingsView: View {
  let onSaved: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var aiBaseURL = ""
  @State private var aiModel = ""
  @State private var visionModel = ""
  @State private var aiProvider: AIProviderKind = .codexSubscription
  @State private var commandPath = ""
  @State private var availableModels: [AIModelInfo] = []
  @State private var loadingModels = false
  @State private var linearEndpoint = ""
  @State private var linearKey = ""
  @State private var aiKey = ""
  @State private var linearKeySaved = false
  @State private var aiKeySaved = false
  @State private var hotkeyChoice = "option-command-l"
  @State private var agentsMd: String = ""
  @State private var message: String?
  @State private var autoUpdate = false
  private let runtime = KakaoLinearRuntime()

  var body: some View {
    Form {
      Section("권한") {
        HStack {
          Text("KakaoTalk database와 현재 채팅방을 읽기 위한 macOS 권한입니다.")
          Spacer()
          Button("Full Disk Access") { openPrivacy("Privacy_AllFiles") }
          Button("Accessibility") { openPrivacy("Privacy_Accessibility") }
        }
      }
      Section("AGENTS.md") {
        Text("AI 프롬프트에 포함되는 사전지침입니다. 비우면 기본 프롬프트만 사용됩니다.")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextEditor(text: $agentsMd)
          .font(.body.monospaced())
          .frame(height: 160)
          .scrollContentBackground(.visible)
        // 글자수는 입력 폼 아래 별도 행의 우측에 배치해 입력 영역과 겹치지 않게 한다.
        HStack {
          Spacer()
          Text("\(agentsMd.count)자")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      Section("AI Provider") {
        Picker("Provider", selection: $aiProvider) {
          ForEach(AIProviderKind.allCases) { provider in
            Text(provider.displayName).tag(provider)
          }
        }
        .onChange(of: aiProvider) { _, provider in
          aiModel = provider.suggestedModel
          if !provider.suggestedBaseURL.isEmpty { aiBaseURL = provider.suggestedBaseURL }
          aiKey = ""
          aiKeySaved = aiKeyExists(for: provider)
          Task { await loadModels() }
        }
        if availableModels.isEmpty {
          TextField("Model  ·  비우면 provider 기본값", text: $aiModel)
        } else {
          Picker("Model", selection: $aiModel) {
            ForEach(availableModels) { model in
              Text(model.name).tag(model.id)
            }
          }
        }
        if loadingModels { ProgressView().controlSize(.small) }
        if aiProvider == .alibabaTokenPlan
          || aiProvider == .liteLLM
          || aiProvider == .openAICompatible
        {
          TextField("Base URL", text: $aiBaseURL)
        }
        if aiProvider == .alibabaTokenPlan
          || aiProvider == .liteLLM
          || aiProvider == .openAICompatible
        {
          TextField("Vision Model (선택)", text: $visionModel)
        }
        if aiProvider != .codexSubscription {
          LabeledContent("Credential owner", value: "macOS Keychain")
          SecretStatusField(
            placeholder: "API Key",
            text: $aiKey,
            isSaved: aiKeySaved,
            savedLabel: aiKeySaved ? "설정됨 · 키 입력 시 대체" : (aiKey.isEmpty ? "설정 안 됨" : "설정됨 예정")
          )
          Button("모델 새로고침") { Task { await loadModels() } }
        } else {
          LabeledContent("Credential owner", value: "Codex CLI")
          HStack {
            Text(aiProvider.setupHint).font(.callout.monospaced()).textSelection(.enabled)
            Spacer()
            Button("복사") { copy(aiProvider.setupHint) }
          }
          Text("KakaoToLinear는 해당 CLI의 token/OAuth 파일을 읽거나 복사하지 않습니다.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if aiProvider == .codexSubscription {
          TextField("CLI path override (선택)", text: $commandPath)
        }
      }
      Section("Linear") {
        TextField("GraphQL Endpoint", text: $linearEndpoint)
        SecretStatusField(
          placeholder: "API Key",
          text: $linearKey,
          isSaved: linearKeySaved,
          savedLabel: linearKeySaved ? "설정됨 · 키 입력 시 대체" : (linearKey.isEmpty ? "설정 안 됨" : "설정됨 예정")
        )
      }
      Section("단축키") {
        Picker("Global Hotkey", selection: $hotkeyChoice) {
          Text("⌥⌘L").tag("option-command-l")
          Text("⌥⌘I").tag("option-command-i")
          Text("⇧⌘L").tag("shift-command-l")
        }
      }
      Section("업데이트") {
        Toggle("자동으로 업데이트 확인", isOn: $autoUpdate)
          .onChange(of: autoUpdate) { _, newValue in
            (NSApp.delegate as? AppDelegate)?.updater.automaticallyChecksForUpdates = newValue
          }
        HStack {
          Button("지금 업데이트 확인…") {
            (NSApp.delegate as? AppDelegate)?.checkForUpdates()
          }
          Spacer()
          if !updaterConfigured {
            Text("업데이트 서버가 아직 구성되지 않았습니다.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      if let message { Text(message).foregroundStyle(.secondary) }
      HStack {
        Spacer()
        Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("저장") { Task { await save() } }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
    }
    .formStyle(.grouped)
    .frame(width: 620, height: 620)
    .task { await load() }
  }

  private var updaterConfigured: Bool {
    (NSApp.delegate as? AppDelegate)?.isUpdateConfigured ?? false
  }

  private func load() async {
    do {
      let config = try await runtime.configuration.load()
      autoUpdate = (NSApp.delegate as? AppDelegate)?.updater.automaticallyChecksForUpdates ?? false
      aiProvider = config.ai.provider
      aiBaseURL = config.ai.baseURL
      aiModel = config.ai.model
      visionModel = config.ai.visionModel ?? ""
      commandPath = config.ai.commandPath ?? ""
      linearEndpoint = config.linear.endpoint
      hotkeyChoice = choice(for: config.hotkey)
      // 키 저장 여부 상태 초기화 (비어있으면 "설정 안 됨" 표시)
      aiKeySaved = aiKeyExists(for: config.ai.provider)
      linearKeySaved = (try? runtime.secrets.get(.linearAPIKey)) != nil
      if let saved = config.linear.agentsMd, !saved.isEmpty {
        agentsMd = saved
      } else {
        agentsMd = defaultAgentsMd()
      }
      await loadModels()
    } catch {
      message = error.localizedDescription
    }
  }

  // 프로젝트의 docs/AGENTS.md 내용을 기본 사전지침으로 사용한다.
  // 소스 파일이 Sources/KakaoLinearApp/Views/ 아래 있으므로 그 상위 3단계가 프로젝트 루트다.
  private func defaultAgentsMd() -> String {
    // 1st: 소스 경로 기반 (빌드 전 개발 환경)
    var candidates: [URL] = []
    let sourceBased = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Views
      .deletingLastPathComponent()  // KakaoLinearApp
      .deletingLastPathComponent()  // Sources
      .appending(path: "docs/AGENTS.md")
    candidates.append(sourceBased)
    // 2nd: 실행 파일이 있는 .build/debug 디렉토리 기준으로 상위 탐색
    if let cwd = ProcessInfo.processInfo.environment["PWD"] {
      candidates.append(URL(fileURLWithPath: "\(cwd)/docs/AGENTS.md"))
    }
    // 3rd: 홈/Application Support 위치에 사용자가 직접 넣은 경우
    candidates.append(
      FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "docs/AGENTS.md")
    )
    for u in candidates {
      if let content = try? String(contentsOf: u, encoding: .utf8),
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return content
      }
    }
    return ""
  }

  private func save() async {
    do {
      var config = try await runtime.configuration.load()
      config.ai.provider = aiProvider
      config.ai.baseURL = aiBaseURL
      config.ai.model = aiModel
      config.ai.visionModel = visionModel.isEmpty ? nil : visionModel
      config.ai.commandPath = commandPath.isEmpty ? nil : commandPath
      config.linear.endpoint = linearEndpoint
      config.linear.agentsMd = agentsMd.isEmpty ? nil : agentsMd
      config.hotkey = hotkey(for: hotkeyChoice)
      try await runtime.configuration.save(config)
      if aiProvider != .codexSubscription, !aiKey.isEmpty {
        try runtime.setAISecret(aiKey, for: aiProvider)
        aiKeySaved = true
        aiKey = ""
      }
      if !linearKey.isEmpty {
        try runtime.secrets.set(linearKey, for: .linearAPIKey)
        linearKeySaved = true
        linearKey = ""
      }
      message = "저장했습니다."
      NotificationCenter.default.post(name: .reloadKakaoLinearHotkey, object: nil)
      onSaved()
      dismiss()
    } catch {
      message = error.localizedDescription
    }
  }

  private func openPrivacy(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
      NSWorkspace.shared.open(url)
    }
  }

  private func aiKeyExists(for provider: AIProviderKind) -> Bool {
    if provider == .codexSubscription { return true }  // Codex는 CLI가 credential을 소유
    return (try? runtime.aiSecret(for: provider)) != nil
  }

  private func loadModels() async {
    loadingModels = true
    defer { loadingModels = false }
    do {
      availableModels = try await AIProviderCatalog().models(
        provider: aiProvider,
        baseURL: aiBaseURL,
        apiKey: aiKey.isEmpty ? try runtime.aiSecret(for: aiProvider) : aiKey,
        configuredModel: aiModel
      )
      if !availableModels.contains(where: { $0.id == aiModel }) {
        aiModel = availableModels.first?.id ?? aiProvider.suggestedModel
      }
    } catch {
      availableModels = []
      message = error.localizedDescription
    }
  }

  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  private func choice(for hotkey: AppConfiguration.Hotkey) -> String {
    if hotkey.keyCode == 34 { return "option-command-i" }
    if hotkey.modifiers == 768 { return "shift-command-l" }
    return "option-command-l"
  }

  private func hotkey(for choice: String) -> AppConfiguration.Hotkey {
    switch choice {
    case "option-command-i": .init(keyCode: 34, modifiers: 2_304)
    case "shift-command-l": .init(keyCode: 37, modifiers: 768)
    default: .init(keyCode: 37, modifiers: 2_304)
    }
  }
}

/*
 변경 전 정책 - API Key SecureField는 placeholder만 있고 저장 여부를 알 수 없었다.
 변경 후 정책 - 저장된 키 여부 상태(isSaved/savedLabel)를 표시하고, 입력 중에는 "설정됨 예정"을 보여준다.
 변경 이유 - 설정창에서 키가 저장됐는지 안 됐는지 사용자가 구분할 수 있어야 한다.
 영향 범위 - AI Provider / Linear 섹션의 API Key 입력 UI.
 */
private struct SecretStatusField: View {
  let placeholder: String
  @Binding var text: String
  let isSaved: Bool
  let savedLabel: String

  var body: some View {
    HStack(spacing: 8) {
      SecureField("\(placeholder)  ·  비우면 기존 값 유지", text: $text)
      statusBadge
    }
  }

  private var statusBadge: some View {
    let (label, color): (String, Color)
    if isSaved {
      label = savedLabel
      color = text.isEmpty ? .green : .orange
    } else {
      label = text.isEmpty ? "설정 안 됨" : "설정됨 예정"
      color = text.isEmpty ? .red : .orange
    }
    return Text(label)
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(0.15))
      .foregroundColor(color)
      .clipShape(Capsule())
      .fixedSize()
  }
}
