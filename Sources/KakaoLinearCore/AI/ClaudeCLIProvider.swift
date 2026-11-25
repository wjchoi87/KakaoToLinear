import Foundation

/*
 Claude Code CLI(`claude -p`)로 evidence 분석·이슈 합성을 실행한다.
 - credential: Claude Code CLI가 소유한다(Claude Pro/Max 구독 로그인, 또는 CLI에 설정된 API key).
   KakaoToLinear는 token/OAuth를 읽거나 저장하지 않는다. `--bare`는 OAuth·keychain을 읽지 않아
   구독 로그인이 무시되므로 쓰지 않는다.
 - 격리: `--safe-mode`(CLAUDE.md·hooks·plugins·MCP 비활성), `--tools ""`(도구 없음), `--strict-mcp-config`,
   `--no-session-persistence`(선택한 원문 transcript를 디스크에 남기지 않음), 빈 임시 workspace를 cwd로 쓴다.
 - 이미지: `claude -p`에는 image flag가 없어 stream-json 입력의 base64 image block으로 넘긴다.
   stream-json 입력은 stream-json 출력을 강제하므로 마지막 result event의 structured_output을 읽는다.
 */
public struct ClaudeCLIProvider: AIProvider {
  private let executable: URL?
  private let model: String
  private let runner: SubprocessRunner

  public init(
    commandPath: String?,
    model: String
  ) {
    executable = CommandLocator.locate("claude", configuredPath: commandPath)
    self.model = model
    runner = SubprocessRunner()
  }

  public func analyzeEvidence(
    source: SourceBundle,
    agentsInstructions: String?
  ) async throws -> EvidenceAnalysis {
    let executable = try requireExecutable()
    let support = CLIProviderSupport()
    let prompt = support.evidencePrompt(source: source, agentsInstructions: agentsInstructions)
    let output = try await runPrompt(
      prompt: prompt, schema: try support.evidenceSchemaData(), source: source,
      executable: executable)
    let payload = try support.decodeEvidencePayload(output)
    return support.makeEvidence(
      payload: payload, source: source, sourceHash: support.sourceHash(source))
  }

  public func composeIssue(
    source: SourceBundle,
    evidence: EvidenceAnalysis,
    agentsInstructions: String?
  ) async throws -> IssueDraft {
    let executable = try requireExecutable()
    let support = CLIProviderSupport()
    let prompt = try support.synthesisPrompt(
      source: source, evidence: evidence, current: nil, instruction: nil,
      agentsInstructions: agentsInstructions)
    let output = try await runPrompt(
      prompt: prompt, schema: try support.draftSchemaData(), source: source,
      executable: executable)
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
    let executable = try requireExecutable()
    let support = CLIProviderSupport()
    let prompt = try support.synthesisPrompt(
      source: source, evidence: evidence, current: current, instruction: trimmed,
      agentsInstructions: agentsInstructions)
    let output = try await runPrompt(
      prompt: prompt, schema: try support.draftSchemaData(), source: source,
      executable: executable)
    let payload = try support.decodePayload(output)
    return support.makeDraft(payload: payload, source: source, current: current)
  }

  /// `claude auth status --json`의 loggedIn으로 판단한다. 구독(claude.ai)·API key 로그인 모두 true다.
  public func healthCheck() async -> Bool {
    guard let executable else { return false }
    let support = CLIProviderSupport()
    guard let workspace = try? support.makeWorkspace() else { return false }
    defer { support.cleanup(workspace) }
    guard
      let result = try? await runner.run(
        executable: executable,
        arguments: ["auth", "status", "--json"],
        currentDirectory: workspace,
        timeout: 10
      ),
      result.exitCode == 0,
      let status = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
    else { return false }
    return status["loggedIn"] as? Bool == true
  }

  private func requireExecutable() throws -> URL {
    guard let executable else {
      throw KakaoLinearError.aiProvider(
        "Claude CLI를 찾지 못했습니다. Claude Code를 설치하거나 ai.command-path를 지정해주세요.")
    }
    return executable
  }

  private func claudeArguments(schema: Data) -> [String] {
    var arguments = [
      "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
      "--json-schema", String(decoding: schema, as: UTF8.self),
      "--no-session-persistence", "--safe-mode", "--strict-mcp-config", "--tools", "",
    ]
    if !model.isEmpty { arguments.append(contentsOf: ["--model", model]) }
    return arguments
  }

  private func runPrompt(
    prompt: String,
    schema: Data,
    source: SourceBundle,
    executable: URL
  ) async throws -> Data {
    let support = CLIProviderSupport()
    let workspace = try support.makeWorkspace()
    defer { support.cleanup(workspace) }
    let images = support.writeOptimizedImages(source: source, to: workspace)
    let result = try await runner.run(
      executable: executable,
      arguments: claudeArguments(schema: schema),
      stdin: try Self.streamInput(prompt: prompt, images: images),
      currentDirectory: workspace,
      timeout: 180
    )
    let event = Self.resultEvent(in: result.stdout)
    guard result.exitCode == 0, let event, event["is_error"] as? Bool != true else {
      throw KakaoLinearError.aiProvider(Self.failureMessage(event: event, stderr: result.stderr))
    }
    if let structured = event["structured_output"] as? [String: Any] {
      return try JSONSerialization.data(withJSONObject: structured)
    }
    // structured_output이 없으면 result text를 쓴다. decodePayload가 ```json fence를 정리한다.
    if let text = event["result"] as? String,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return Data(text.utf8)
    }
    throw KakaoLinearError.aiProvider("Claude CLI가 final output을 만들지 않았습니다.")
  }

  /// stream-json user message 1줄. 이미지(JPEG base64) 블록을 먼저, prompt text를 마지막에 둔다.
  private static func streamInput(prompt: String, images: [URL]) throws -> Data {
    var content: [[String: Any]] = images.compactMap { url in
      guard let data = try? Data(contentsOf: url) else { return nil }
      return [
        "type": "image",
        "source": [
          "type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString(),
        ],
      ]
    }
    content.append(["type": "text", "text": prompt])
    let message: [String: Any] = [
      "type": "user",
      "message": ["role": "user", "content": content],
    ]
    var data = try JSONSerialization.data(withJSONObject: message)
    data.append(0x0A)
    return data
  }

  /// stream-json stdout에서 마지막 `type == "result"` event를 찾는다.
  private static func resultEvent(in stdout: Data) -> [String: Any]? {
    String(decoding: stdout, as: UTF8.self)
      .split(whereSeparator: \.isNewline)
      .reversed()
      .lazy
      .compactMap { line in
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      }
      .first { $0["type"] as? String == "result" }
  }

  /// is_error result는 CLI가 준 오류 문구(로그인 필요, 사용량 한도 등)를, 없으면 stderr 요약을 쓴다.
  private static func failureMessage(event: [String: Any]?, stderr: Data) -> String {
    if event?["is_error"] as? Bool == true,
      let text = (event?["result"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    {
      return "Claude CLI 실행 실패: \(text.prefix(500))"
    }
    return CLIProviderSupport().safeFailure(prefix: "Claude CLI", stderr: stderr)
  }
}
