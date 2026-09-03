import Foundation

/// AI provider의 실패(특히 structured decode 실패) 시 raw 응답을 별도 로그 파일에 남긴다.
/// 운영 로그에는 원본 요청 내용(메시지/사진 등)이 포함되지 않고, 디버깅에 필요한 최소 진단 정보만 기록한다.
struct AIErrorLogger: Sendable {
  private let paths: AppSupportPaths

  init(paths: AppSupportPaths = AppSupportPaths()) {
    self.paths = paths
  }

  /// raw 응답과 디코딩 오류를 `logs/ai-errors.log`에 append로 남긴다.
  /// 로그 파일을 만들 수 없어도 호출 흐름은 깨지지 않도록 best-effort로 동작한다.
  func logDecodeFailure(rawResponse: String, error: Error) {
    let line = """
      [\(timestamp())] structured decode failed
      error: \(error)
      raw response:
      \(String(rawResponse.prefix(4000)))
      ----------------------------------------

      """
    append(line)
  }

  /// 범용 실패 로그. 메시지/첨부 본문(app용 원문)을 넣지 말 것.
  func log(_ component: String, message: String) {
    let line = "[\(timestamp())] [\(component)] \(message)\n---\n"
    append(line)
  }

  private func append(_ text: String) {
    do {
      try FileManager.default.createDirectory(
        at: paths.logs, withIntermediateDirectories: true)
      // 파일이 없으면 먼저 생성한다(forWritingTo는 존재하지 않는 파일을 열지 못함).
      if !FileManager.default.fileExists(atPath: paths.aiErrorLog.path) {
        FileManager.default.createFile(atPath: paths.aiErrorLog.path, contents: Data())
      }
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: paths.aiErrorLog.path)
      let handle = try FileHandle(forWritingTo: paths.aiErrorLog)
      defer { try? handle.close() }
      try handle.seekToEnd()
      handle.write(Data(text.utf8))
    } catch {
      // 파일을 만들 수 없거나 열지 못한 경우 로그 파일이 없다는 stderr 한 줄만 남긴다.
      FileHandle.standardError.write(
        Data("[kakao-linear] ai-errors.log를 쓸 수 없습니다: \(error.localizedDescription)\n".utf8))
    }
  }

  private func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
  }
}
