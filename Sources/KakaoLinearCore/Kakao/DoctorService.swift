import AppKit
import ApplicationServices
import Foundation

public struct DoctorService: Sendable {
  private final class ResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ newValue: Value) {
      lock.lock()
      value = newValue
      lock.unlock()
    }

    func get() -> Value? {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }

  public init() {}

  public func run(adapter: any KakaoArchiveAdapter) -> DoctorReport {
    let kakaoRunning = !NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.kakao.KakaoTalkMac"
    ).isEmpty
    let accessibility = AXIsProcessTrusted()
    let fullDiskAccess =
      timed(timeout: 3) {
        let paths = KakaoPaths()
        return
          (try? FileManager.default.contentsOfDirectory(
            at: paths.container,
            includingPropertiesForKeys: nil
          )) != nil
      } ?? false
    let database =
      fullDiskAccess
      ? (timed(timeout: 20) { adapter.databaseIsReadable() } ?? false)
      : false
    return DoctorReport(
      kakaoRunning: kakaoRunning,
      accessibility: accessibility,
      fullDiskAccess: fullDiskAccess,
      kakaoDatabase: database
    )
  }

  public func run(
    adapter: any KakaoArchiveAdapter,
    aiProvider: (any AIProvider)?,
    linearClient: LinearClient?
  ) async -> DoctorReport {
    let local = run(adapter: adapter)
    async let ai = aiProvider?.healthCheck() ?? false
    async let linear = linearClient?.healthCheck() ?? false
    return await DoctorReport(
      kakaoRunning: local.kakaoRunning,
      accessibility: local.accessibility,
      fullDiskAccess: local.fullDiskAccess,
      kakaoDatabase: local.kakaoDatabase,
      linear: linear,
      ai: ai
    )
  }

  private func timed<Value: Sendable>(
    timeout: TimeInterval,
    operation: @escaping @Sendable () -> Value
  ) -> Value? {
    let box = ResultBox<Value>()
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      box.set(operation())
      semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
    return box.get()
  }
}
