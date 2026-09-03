import CryptoKit
import Foundation

public struct CodexCLIProvider: AIProvider {
  private let executable: URL?
  private let model: String
  private let runner: SubprocessRunner

  public init(
    commandPath: String?,
    model: String
  ) {
    executable = CommandLocator.locate("codex", configuredPath: commandPath)
    self.model = model
    runner = SubprocessRunner()
  }

  public func analyzeEvidence(
    source: SourceBundle,
    agentsInstructions: String?
  ) async throws -> EvidenceAnalysis {
    guard let executable else {
      throw KakaoLinearError.aiProvider(
        "Codex CLI를 찾지 못했습니다. codex를 설치하거나 ai.command-path를 지정해주세요.")
    }
    let support = CLIProviderSupport()
    let workspace = try support.makeWorkspace()
    defer { support.cleanup(workspace) }
    let schemaURL = workspace.appending(path: "evidence-schema.json")
    let outputURL = workspace.appending(path: "evidence-output.json")
    try support.evidenceSchemaData().write(to: schemaURL, options: .atomic)
    let images = support.writeOptimizedImages(source: source, to: workspace)
    let arguments = codexArguments(
      schemaURL: schemaURL, outputURL: outputURL, workspace: workspace, images: images)
    let prompt = support.evidencePrompt(
      source: source, agentsInstructions: agentsInstructions)
    let output = try await runPrompt(prompt: prompt, arguments: arguments, executable: executable)
    let payload = try support.decodeEvidencePayload(output)
    let hash = try Self.sourceHash(source)
    return support.makeEvidence(payload: payload, source: source, sourceHash: hash)
  }

  public func composeIssue(
    source: SourceBundle,
    evidence: EvidenceAnalysis,
    agentsInstructions: String?
  ) async throws -> IssueDraft {
    guard let executable else {
      throw KakaoLinearError.aiProvider(
        "Codex CLI를 찾지 못했습니다. codex를 설치하거나 ai.command-path를 지정해주세요.")
    }
    let support = CLIProviderSupport()
    let workspace = try support.makeWorkspace()
    defer { support.cleanup(workspace) }
    let schemaURL = workspace.appending(path: "draft-schema.json")
    let outputURL = workspace.appending(path: "draft-output.json")
    try support.draftSchemaData().write(to: schemaURL, options: .atomic)
    let images = support.writeOptimizedImages(source: source, to: workspace)
    let arguments = codexArguments(
      schemaURL: schemaURL, outputURL: outputURL, workspace: workspace, images: images)
    let prompt = try support.synthesisPrompt(
      source: source, evidence: evidence, current: nil, instruction: nil,
      agentsInstructions: agentsInstructions)
    let output = try await runPrompt(prompt: prompt, arguments: arguments, executable: executable)
    let payload = try support.decodePayload(output)
    return support.makeDraft(payload: payload, source: source, current: nil)
  }

  public func reviseIssue(
    source: SourceBundle,
    evidence: EvidenceAnalysis,
    current: IssueDraft,
    instruction: String,
    agentsInstructions: String?
  ) async throws -> IssueDraft {
    let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw KakaoLinearError.invalidInput("revision instruction은 비어 있을 수 없습니다.")
    }
    guard let executable else {
      throw KakaoLinearError.aiProvider(
        "Codex CLI를 찾지 못했습니다. codex를 설치하거나 ai.command-path를 지정해주세요.")
    }
    let support = CLIProviderSupport()
    let workspace = try support.makeWorkspace()
    defer { support.cleanup(workspace) }
    let schemaURL = workspace.appending(path: "draft-schema.json")
    let outputURL = workspace.appending(path: "draft-output.json")
    try support.draftSchemaData().write(to: schemaURL, options: .atomic)
    let images = support.writeOptimizedImages(source: source, to: workspace)
    let arguments = codexArguments(
      schemaURL: schemaURL, outputURL: outputURL, workspace: workspace, images: images)
    let prompt = try support.synthesisPrompt(
      source: source, evidence: evidence, current: current, instruction: trimmed,
      agentsInstructions: agentsInstructions)
    let output = try await runPrompt(prompt: prompt, arguments: arguments, executable: executable)
    let payload = try support.decodePayload(output)
    return support.makeDraft(payload: payload, source: source, current: current)
  }

  public func healthCheck() async -> Bool {
    guard let executable else { return false }
    let support = CLIProviderSupport()
    guard let workspace = try? support.makeWorkspace() else { return false }
    defer { support.cleanup(workspace) }
    guard
      let result = try? await runner.run(
        executable: executable,
        arguments: ["login", "status"],
        currentDirectory: workspace,
        timeout: 10
      )
    else { return false }
    return result.exitCode == 0
  }

  private func codexArguments(
    schemaURL: URL,
    outputURL: URL,
    workspace: URL,
    images: [URL]
  ) -> [String] {
    var arguments = [
      "exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
      "--sandbox", "read-only", "--color", "never", "--output-schema", schemaURL.path,
      "--output-last-message", outputURL.path, "--cd", workspace.path,
    ]
    if !model.isEmpty { arguments.append(contentsOf: ["--model", model]) }
    for image in images { arguments.append(contentsOf: ["--image", image.path]) }
    arguments.append("-")
    return arguments
  }

  private func runPrompt(
    prompt: String,
    arguments: [String],
    executable: URL
  ) async throws -> Data {
    let cwd: URL
    if let index = arguments.firstIndex(of: "--cd") {
      cwd = URL(fileURLWithPath: arguments[index + 1])
    } else {
      cwd = FileManager.default.temporaryDirectory
    }
    let result = try await runner.run(
      executable: executable,
      arguments: arguments,
      stdin: Data(prompt.utf8),
      currentDirectory: cwd,
      timeout: 180
    )
    guard result.exitCode == 0 else {
      throw KakaoLinearError.aiProvider(
        safeFailure(prefix: "Codex CLI", stderr: result.stderr))
    }
    guard let data = try? Data(contentsOf: outputURL(for: arguments)), !data.isEmpty else {
      throw KakaoLinearError.aiProvider("Codex CLI가 final output을 만들지 않았습니다.")
    }
    return data
  }

  private func outputURL(for arguments: [String]) -> URL {
    let options = Array(arguments)
    for (index, arg) in options.enumerated() where arg == "--output-last-message" {
      return URL(fileURLWithPath: options[index + 1])
    }
    return URL(fileURLWithPath: options[options.count - 1])
  }

  private static func sourceHash(_ source: SourceBundle) throws -> String {
    let ids = source.messages.map(\.id).joined(separator: "|")
    let attIds = source.resolvedAttachments.map(\.attachment.id).joined(separator: "|")
    let lines = [
      source.room.id,
      ids,
      attIds,
      source.attachmentFailures.map(\.attachmentId).joined(separator: "|"),
    ]
    let data = Data(lines.joined(separator: "\u{1E}").utf8)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func safeFailure(prefix: String, stderr: Data) -> String {
    let text = String(decoding: stderr, as: UTF8.self)
      .split(separator: "\n")
      .suffix(3)
      .joined(separator: " ")
    return text.isEmpty ? "\(prefix) 실행에 실패했습니다." : "\(prefix) 실행 실패: \(text.prefix(500))"
  }
}
