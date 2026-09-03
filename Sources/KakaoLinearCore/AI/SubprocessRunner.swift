import Darwin
import Foundation

struct SubprocessResult: Sendable {
  let exitCode: Int32
  let stdout: Data
  let stderr: Data
}

struct SubprocessRunner: Sendable {
  func run(
    executable: URL,
    arguments: [String],
    stdin: Data = Data(),
    currentDirectory: URL,
    timeout: TimeInterval
  ) async throws -> SubprocessResult {
    let captureDirectory = FileManager.default.temporaryDirectory.appending(
      path: "kakaotolinear-process-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
    let stdoutURL = captureDirectory.appending(path: "stdout")
    let stderrURL = captureDirectory.appending(path: "stderr")
    _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: stdoutURL.path
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: stderrURL.path
    )
    let outputHandle = try FileHandle(forWritingTo: stdoutURL)
    let errorHandle = try FileHandle(forWritingTo: stderrURL)
    let inputPipe = Pipe()
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    process.standardInput = inputPipe
    process.standardOutput = outputHandle
    process.standardError = errorHandle

    return try await withCheckedThrowingContinuation { continuation in
      let completion = ProcessCompletion(
        process: process,
        continuation: continuation,
        stdoutURL: stdoutURL,
        stderrURL: stderrURL,
        captureDirectory: captureDirectory,
        outputHandle: outputHandle,
        errorHandle: errorHandle
      )
      process.terminationHandler = { process in
        completion.finish(exitCode: process.terminationStatus)
      }
      do {
        try process.run()
        inputPipe.fileHandleForWriting.write(stdin)
        try? inputPipe.fileHandleForWriting.close()
      } catch {
        completion.fail(error)
        return
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
        completion.timeout()
      }
    }
  }
}

private final class ProcessCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private let process: Process
  private var continuation: CheckedContinuation<SubprocessResult, Error>?
  private let stdoutURL: URL
  private let stderrURL: URL
  private let captureDirectory: URL
  private let outputHandle: FileHandle
  private let errorHandle: FileHandle
  private var timedOut = false

  init(
    process: Process,
    continuation: CheckedContinuation<SubprocessResult, Error>,
    stdoutURL: URL,
    stderrURL: URL,
    captureDirectory: URL,
    outputHandle: FileHandle,
    errorHandle: FileHandle
  ) {
    self.process = process
    self.continuation = continuation
    self.stdoutURL = stdoutURL
    self.stderrURL = stderrURL
    self.captureDirectory = captureDirectory
    self.outputHandle = outputHandle
    self.errorHandle = errorHandle
  }

  func timeout() {
    lock.lock()
    guard continuation != nil else {
      lock.unlock()
      return
    }
    timedOut = true
    lock.unlock()
    if process.isRunning {
      process.terminate()
      let processId = process.processIdentifier
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
        if self.process.isRunning { Darwin.kill(processId, SIGKILL) }
      }
    }
  }

  func finish(exitCode: Int32) {
    lock.lock()
    guard let continuation else {
      lock.unlock()
      return
    }
    self.continuation = nil
    let didTimeOut = timedOut
    lock.unlock()

    try? outputHandle.close()
    try? errorHandle.close()
    let stdout = (try? Data(contentsOf: stdoutURL)) ?? Data()
    let stderr = (try? Data(contentsOf: stderrURL)) ?? Data()
    cleanup()
    if didTimeOut {
      continuation.resume(throwing: KakaoLinearError.aiProvider("AI CLI 실행 시간이 초과되었습니다."))
    } else {
      continuation.resume(
        returning: SubprocessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
      )
    }
  }

  func fail(_ error: Error) {
    lock.lock()
    guard let continuation else {
      lock.unlock()
      return
    }
    self.continuation = nil
    lock.unlock()
    try? outputHandle.close()
    try? errorHandle.close()
    cleanup()
    continuation.resume(throwing: error)
  }

  private func cleanup() {
    try? FileManager.default.removeItem(at: captureDirectory)
  }
}

enum CommandLocator {
  static func locate(_ name: String, configuredPath: String?) -> URL? {
    var candidates: [String] = []
    if let configuredPath, !configuredPath.isEmpty { candidates.append(configuredPath) }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    candidates.append(contentsOf: [
      "\(home)/.local/bin/\(name)",
      "\(home)/.opencode/bin/\(name)",
      "/opt/homebrew/bin/\(name)",
      "/usr/local/bin/\(name)",
      "/usr/bin/\(name)",
    ])
    if let path = ProcessInfo.processInfo.environment["PATH"] {
      candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/\(name)" })
    }
    return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
      .map { URL(fileURLWithPath: $0) }
  }
}
