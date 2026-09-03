import AppKit
import KakaoLinearCore
import Sparkle
import SwiftUI

@main
struct KakaoToLinearApp: App {
  @StateObject private var state = AppState.shared
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    MenuBarExtra("KakaoToLinear", systemImage: "arrow.right.doc.on.clipboard") {
      MenuBarContent(state: state)
    }
    .menuBarExtraStyle(.menu)

    Settings {
      SettingsView(onSaved: {})
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var hotKey: GlobalHotKey?
  private var makerWindow: NSWindow?
  // Sparkle 자동 업데이트. 실제 배포 구성(SUFeedURL/SUPublicEDKey)이 채워진 경우에만 시작한다.
  private let updaterController: SPUStandardUpdaterController

  /// UI(설정/메뉴바)에서 업데이트 확인을 트리거하기 위한 노출.
  var updater: SPUUpdater { updaterController.updater }

  /// 지금 업데이트 확인 / 자동 확인 시작 가능한 배포 구성인지 (placeholder가 아닌지).
  var isUpdateConfigured: Bool {
    let bundle = Bundle.main
    guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
      !feed.isEmpty,
      feed.contains("<owner>") == false
    else { return false }
    guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
      !key.isEmpty,
      key.hasPrefix("REPLACE") == false
    else { return false }
    return true
  }

  /// "지금 업데이트 확인" UI에서 호출. 배포 미구성이면 조용히 무시한다.
  func checkForUpdates() {
    guard isUpdateConfigured else { return }
    updaterController.checkForUpdates(nil)
  }

  override init() {
    updaterController = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    super.init()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  // 실배포 구성을 갖췄을 때만 Sparkle을 시작한다.
  // 배포 전에는 SUFeedURL/SUPublicEDKey가 placeholder이므로 업데이터를 시작하지 않는다.
  private func startUpdaterIfConfigured() {
    guard isUpdateConfigured else { return }
    updaterController.updater.checkForUpdatesInBackground()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // 변경 전 정책 - startingUpdater:true로 생성해, Info.plist의 SUFeedURL이 placeholder인 개발
    //   상태에서도 업데이터가 강제로 시작돼 "업데이터 시작 실패" 오류를 띄웠다.
    // 변경 후 정책 - 업데이터를 시작하지 않은 채 생성하고, 실배포 구성(실제 URL/공개키)이 있으면
    //   그때만 백그라운드 업데이트 확인을 시작한다.
    // 변경 이유 - 배포 전 단계에서 Sparkle이 잘못된 feed URL로 실패하는 오류를 없애기 위해서다.
    // 영향 범위 - Sparkle 자동 업데이트 시작 조건. 배포 구성이 없으면 업데이트 확인을 하지 않는다.
    startUpdaterIfConfigured()
    NSApp.setActivationPolicy(.regular)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(showMakerWindow),
      name: .showKakaoToLinearMaker,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(reloadHotkey),
      name: .reloadKakaoLinearHotkey,
      object: nil
    )
    let hotKey = GlobalHotKey()
    hotKey.register()
    self.hotKey = hotKey
    Task { await loadConfiguredHotkey() }
    // 활성화 정책(.regular)이 확실히 적용된 뒤 창을 띄운다.
    DispatchQueue.main.async { self.showMakerWindow() }
  }

  // 시스템 설정(권한)에서 돌아와 앱이 다시 활성화되면 창을 최상단으로 되돌리고
  // 권한 상태를 갱신한다. 미적용 시 권한 버튼을 누른 뒤 창이 뒤로 밀려 보이지 않았다.
  func applicationDidBecomeActive(_ notification: Notification) {
    showMakerWindow()
    Task { await AppState.shared.refreshDoctor() }
  }

  @objc private func reloadHotkey() {
    Task { await loadConfiguredHotkey() }
  }

  private func loadConfiguredHotkey() async {
    if let config = try? await ConfigurationStore().load() {
      hotKey?.register(keyCode: config.hotkey.keyCode, modifiers: config.hotkey.modifiers)
    }
  }

  @objc func showMakerWindow() {
    if makerWindow == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
      )
      window.title = "KakaoToLinear"
      window.minSize = NSSize(width: 680, height: 600)
      window.isReleasedWhenClosed = false
      window.contentViewController = NSHostingController(
        rootView: MakerRootView(state: AppState.shared)
      )
      window.center()
      window.setFrameAutosaveName("KakaoToLinearMaker")
      makerWindow = window
    }
    bringMakerWindowToFront()
  }

  // 새 이슈/단축키로 호출될 때 창을 확실히 맨 앞으로 끌어올린다.
  // MenuBarExtra 메뉴가 닫히는 타이밍에 밀리는 것을 방지하기 위해 짧은 지연 후 재차 최상층으로 올린다.
  // LSUIElement(true)/accessory 앱에서는 NSApp.activate가 무시될 수 있어,
  // orderFrontRegardless로 다른 앱보다 앞에 오도록 보장한다.
  private func bringMakerWindowToFront() {
    guard let window = makerWindow else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    NSApp.activate(ignoringOtherApps: true)
    window.level = .normal
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      if window.isMiniaturized { window.deminiaturize(nil) }
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      window.orderFrontRegardless()
    }
  }
}

private struct MenuBarContent: View {
  @ObservedObject var state: AppState
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Button("새 Linear 이슈…") {
      NSApp.activate(ignoringOtherApps: true)
      (NSApp.delegate as? AppDelegate)?.showMakerWindow()
    }
    .keyboardShortcut("l", modifiers: [.command, .option])
    Button("업데이트 확인…") {
      (NSApp.delegate as? AppDelegate)?.checkForUpdates()
    }
    Divider()
    Button("설정…") {
      NSApp.activate(ignoringOtherApps: true)
      openSettings()
      // Settings 창이 생성된 직후 최상층으로 올려 가림을 방지한다.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        if let settingsWindow = NSApp.windows.sorted(by: { $0.level.rawValue > $1.level.rawValue })
          .first
        {
          settingsWindow.makeKeyAndOrderFront(nil)
          NSApp.activate(ignoringOtherApps: true)
        }
      }
    }
    Divider()
    Button("종료") { NSApp.terminate(nil) }
      .keyboardShortcut("q")
    Color.clear.frame(width: 0, height: 0)
      .onReceive(NotificationCenter.default.publisher(for: .showKakaoToLinearMaker)) { _ in
        (NSApp.delegate as? AppDelegate)?.showMakerWindow()
      }
  }
}
