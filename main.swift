// 진의 데스크 — 맥 앱(보통 창) + 로컬 페이지 호스트 + WidgetKit 위젯 데이터
// pages 폴더의 HTML(Claude로 만든 Artifact 소스 포함)을 WKWebView로 띄우고, 네이티브 기능(window.jin)과
// Google API 직접 연결(window.claude.use("mcp") 흉내)을 붙인다 → claude.ai 로그인·게시·샌드박스 제약 없이 돈다.
// 설정 remoteURL(claude.ai에 게시한 Artifact 주소)이 있으면 "claude.ai 게시본" 페이지로 그 주소를 그대로 띄울 수 있다.
import Cocoa
import WebKit
import Carbon.HIToolbox
import UserNotifications

// 예: defaults write com.jin.desk remoteURL https://claude.ai/artifact/<id>
let DESK_URL = UserDefaults.standard.string(forKey: "remoteURL").flatMap(URL.init(string:))
let REMOTE = "@remote"                 // 페이지 목록에서 claude.ai 게시본을 뜻하는 값
let DEFAULT_PAGE = "jin-desk.html"
let TESTING = CommandLine.arguments.contains("--eval")
func arg(_ k: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: k), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}
let MAIN_SIZE = NSSize(width: 540, height: 900)
// launchd(로그인 자동 실행)로 켜졌는지: 이때는 앱 창을 띄우지 않는다 (위젯 데이터만 계속 만든다)
let BY_LAUNCHD = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "com.jin.desk"

final class App: NSObject, NSApplicationDelegate, WKUIDelegate, WKNavigationDelegate, NSMenuDelegate, WKScriptMessageHandler,
                 WKDownloadDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate {
    var item: NSStatusItem!
    var web: WKWebView!                 // 앱 창의 웹뷰 (고른 페이지)
    var mainWin: NSWindow!
    var hotKey: EventHotKeyRef?
    let bridge = Bridge()
    var pageMTime: Date?
    // 지금 띄운 페이지: pages 폴더의 파일 이름 또는 REMOTE. 기본값은 게시본 주소가 있고 Google 로그인 전이면 게시본, 아니면 로컬 대시보드
    var page: String {
        get {
            if let p = arg("--page") { return p }
            if let p = UserDefaults.standard.string(forKey: "page") { return p }
            return DESK_URL == nil || Google.shared.saved()?["refresh_token"] != nil ? DEFAULT_PAGE : REMOTE
        }
        set { UserDefaults.standard.set(newValue, forKey: "page") }
    }
    var currentURL: URL { page == REMOTE ? (DESK_URL ?? pageURL(DEFAULT_PAGE)) : pageURL(page) }

    func applicationDidFinishLaunching(_ n: Notification) {
        for d in [PAGES_DIR, DATA_DIR] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()                 // 로그인 쿠키·localStorage 유지
        cfg.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        cfg.setURLSchemeHandler(bridge, forURLScheme: SCHEME)
        cfg.userContentController.addUserScript(WKUserScript(source: BRIDGE_JS, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        cfg.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "jin")
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        if CommandLine.arguments.contains("--snapshot") { addDiagnostics(cfg) }
        web = WKWebView(frame: NSRect(origin: .zero, size: MAIN_SIZE), configuration: cfg)
        web.uiDelegate = self
        web.navigationDelegate = self
        if #available(macOS 13.3, *) { web.isInspectable = true }   // Safari → 개발 메뉴에서 웹 속성 보기
        bridge.openPage = { [weak self] f in self?.openPage(f) }
        bridge.googleLogin = { [weak self] in try await self?.connectGoogle() ?? "" }
        bridge.showApp = { [weak self] in self?.showMain() }
        UNUserNotificationCenter.current().delegate = self
        // 상시 실행 인스턴스가 켜질 때 알림 권한을 한 번 묻는다 (이미 정했으면 아무 일 없음)
        if !TESTING {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, err in
                print("[notify] 권한 요청 결과 ok=\(ok) err=\(err.map { "\($0)" } ?? "-")")
            }
        }
        loadPage()
        // 페이지 파일이 바뀌면 자동 새로고침 (Claude가 파일을 고치면 바로 반영)
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkReload() }
        buildMainWindow()
        buildMainMenu()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "진의 데스크")
            b.toolTip = "진의 데스크 (⌃⌥J)"
            b.target = self
            b.action = #selector(click(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        registerHotKey()
        if TESTING { runEval(); return }
        WidgetFeed.shared.start()                       // WidgetKit 위젯용 데이터 (JinDesk/widget/data.json)
        MailCalendar.shared.notify = { [weak self] t, b in Task { _ = try? await self?.bridge.notify(t, b) } }
        // 점검용: --mailcal-test [메일ID] → 캘린더에 넣지 않고 무엇을 넣을지 미리보기만 출력
        if let i = CommandLine.arguments.firstIndex(of: "--mailcal-test") {
            let id = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil
            MailCalendar.shared.runOnce(dryRun: true, onlyMessage: id) { r in r.forEach { print($0) }; if r.isEmpty { print("(규칙에 맞는 일정 없음)") }; exit(0) }
            return
        }
        if CommandLine.arguments.contains("--mailcal-daum-test") {
            MailCalendar.shared.daumTest { r in r.forEach { print($0) }; if r.isEmpty { print("(규칙에 맞는 일정 없음)") }; exit(0) }
        }
        if CommandLine.arguments.contains("--mailcal-selftest") {
            Task { let r = await MailCalendar.shared.selfTest(); print(r); exit(0) }
            return
        }
        MailCalendar.shared.start()                     // 새 메일에서 일정 찾아 캘린더에 자동 추가 (10분마다)
        if CommandLine.arguments.contains("--feed-test") { DispatchQueue.main.asyncAfter(deadline: .now() + 15) { exit(0) } }
        if !BY_LAUNCHD && !CommandLine.arguments.contains("--window-test") { showMain() }   // 직접 실행하면 창을 띄운다
        // 점검용: --window-test → 앱 창 위치와 ⌃⌥J 열기/닫기, jindesk://open을 출력 (설정은 안 바꿈)
        if CommandLine.arguments.contains("--window-test") {
            func report(_ tag: String) {
                let info = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
                    .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int ?? 0) != 25 }
                    .compactMap { d -> String? in
                        guard (d[kCGWindowIsOnscreen as String] as? Int ?? 0) == 1 else { return nil }
                        let b = d[kCGWindowBounds as String] as? [String: Any] ?? [:]
                        return "layer=\(d[kCGWindowLayer as String] ?? "-") \(b["Width"] ?? 0)x\(b["Height"] ?? 0)@\(b["X"] ?? 0),\(b["Y"] ?? 0)"
                    }
                print(tag, "main=\(self.mainWin.isVisible) front=\(self.mainFrontmost()) active=\(NSApp.isActive) key=\(self.mainWin.isKeyWindow) policy=\(NSApp.activationPolicy().rawValue)", info)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                report("start")
                self.hotKeyFired(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    report("1st ⌃⌥J(열기)")
                    self.hotKeyFired(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        report("2nd ⌃⌥J(숨기기)")
                        self.application(NSApp, open: [URL(string: "jindesk://open")!]); DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            report("jindesk://open(위젯 누르기와 같음)"); exit(0)
                        }
                    }
                }
            }
        }
        // 점검용: --snapshot <경로> [초] → 지정 시간(기본 10초) 뒤 앱 창 화면을 PNG로 저장하고 종료
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            let wait = i + 2 < CommandLine.arguments.count ? Double(CommandLine.arguments[i + 2]) ?? 10 : 10
            let target: WKWebView = web
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                target.takeSnapshot(with: nil) { img, _ in
                    if let t = img?.tiffRepresentation, let r = NSBitmapImageRep(data: t),
                       let png = r.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                    }
                    print("url:", target.url?.absoluteString ?? "-", "title:", target.title ?? "-")
                    exit(0)
                }
            }
        }
    }

    // ---- 앱 창 ----
    func buildMainWindow() {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: MAIN_SIZE),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "진의 데스크"
        w.minSize = NSSize(width: 380, height: 480)
        w.isReleasedWhenClosed = false            // 닫기 = 숨기기 (앱은 계속 돌며 위젯 데이터를 만든다)
        w.delegate = self
        w.contentView = web
        w.center()
        w.setFrameAutosaveName("JinDeskMain")     // 옮긴 위치·크기를 기억
        w.tabbingMode = .disallowed
        mainWin = w
    }
    func showMain() {
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        mainWin.makeKeyAndOrderFront(nil)
        mainWin.orderFrontRegardless()           // 앱 활성화가 막혀도(단축키·위젯에서 열 때) 창은 맨 앞으로
    }
    // ⌃⌥J·메뉴 막대 아이콘: 앱 창이 맨 앞이면 숨기고, 아니면(숨었거나 다른 창에 가려졌으면) 앞으로
    func toggleMain() {
        if mainWin.isVisible && (NSApp.isActive || mainFrontmost()) { mainWin.orderOut(nil) } else { showMain() }
    }
    // 화면의 보통 창(층 0) 중 맨 앞이 이 앱 창인지 (앱 활성화가 막혀도 판단되게 실제 창 순서로 본다)
    func mainFrontmost() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let top = list.first { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0 }
        return (top?[kCGWindowNumber as String] as? Int) == mainWin.windowNumber
    }
    // Dock 아이콘을 누르면 (창이 닫혀 있어도) 창을 띄운다
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMain(); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    // 메뉴 막대(화면 맨 위) 메뉴: 편집 메뉴가 있어야 웹뷰 입력칸에서 ⌘C·⌘V가 된다
    func buildMainMenu() {
        let bar = NSMenu()
        func sub(_ title: String) -> NSMenu { let i = bar.addItem(withTitle: title, action: nil, keyEquivalent: ""); let m = NSMenu(title: title); i.submenu = m; return m }
        let appM = sub("진의 데스크")
        appM.addItem(withTitle: "진의 데스크 숨기기", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appM.addItem(.separator())
        appM.addItem(withTitle: "진의 데스크 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let ed = sub("편집")
        ed.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        ed.addItem(withTitle: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "Z")
        ed.addItem(.separator())
        ed.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        ed.addItem(withTitle: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        ed.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        ed.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let vw = sub("보기")
        vw.delegate = self                        // 열 때마다 페이지 목록·체크 상태를 새로 채운다
        vw.identifier = NSUserInterfaceItemIdentifier("view")
        let win = sub("윈도우")
        win.addItem(withTitle: "최소화", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = bar
        NSApp.windowsMenu = win
    }
    // 보기 메뉴·메뉴 막대 아이콘 메뉴에 공통으로 들어가는 항목
    func fillCommon(_ m: NSMenu, shortcuts: Bool) {
        m.addItem(withTitle: "새로고침", action: #selector(reload), keyEquivalent: shortcuts ? "r" : "").target = self
        let pm = NSMenu()
        for p in listPages() {
            let i = pm.addItem(withTitle: p.title, action: #selector(menuPage(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = p.file; i.state = page == p.file ? .on : .off
        }
        if DESK_URL != nil {
            pm.addItem(.separator())
            let ri = pm.addItem(withTitle: "claude.ai 게시본 (커넥터 사용)", action: #selector(menuPage(_:)), keyEquivalent: "")
            ri.target = self; ri.representedObject = REMOTE; ri.state = page == REMOTE ? .on : .off
        }
        pm.addItem(.separator())
        pm.addItem(withTitle: "페이지 폴더 열기", action: #selector(openPagesFolder), keyEquivalent: "").target = self
        m.addItem(withTitle: "페이지", action: nil, keyEquivalent: "").submenu = pm
        m.addItem(.separator())
        if let email = Google.shared.saved()?["email"] as? String {
            m.addItem(withTitle: "Google 연결됨: \(email)", action: nil, keyEquivalent: "").isEnabled = false
            m.addItem(withTitle: "Google 연결 해제", action: #selector(menuGoogleLogout), keyEquivalent: "").target = self
        } else {
            m.addItem(withTitle: "Google 계정 연결…", action: #selector(menuGoogleLogin), keyEquivalent: "").target = self
        }
        if DESK_URL != nil { m.addItem(withTitle: "claude.ai에서 열기", action: #selector(openInBrowser), keyEquivalent: "").target = self }
        m.addItem(.separator())
        let mc = m.addItem(withTitle: "메일 일정 → 캘린더 자동 추가", action: #selector(toggleMailCal), keyEquivalent: "")
        mc.target = self; mc.state = MailCalendar.shared.enabled ? .on : .off
        m.addItem(withTitle: "지금 메일 확인", action: #selector(runMailCal), keyEquivalent: "").target = self
        m.addItem(withTitle: "자동 추가 기록 보기", action: #selector(openMailCalLog), keyEquivalent: "").target = self
    }
    func menuNeedsUpdate(_ m: NSMenu) {
        guard m.identifier?.rawValue == "view" else { return }
        m.removeAllItems(); fillCommon(m, shortcuts: true)
    }

    @objc func menuShowMain() { showMain() }
    @objc func toggleMailCal() { MailCalendar.shared.enabled.toggle(); if MailCalendar.shared.enabled { MailCalendar.shared.runOnce() } }
    @objc func runMailCal() { MailCalendar.shared.runOnce() }
    @objc func openMailCalLog() {
        if !FileManager.default.fileExists(atPath: MAILCAL_LOG.path) { MailCalendar.shared.log("기록 시작") }
        NSWorkspace.shared.open(MAILCAL_LOG)
    }

    // ---- 페이지 ----
    func loadPage() {
        pageMTime = page == REMOTE ? nil : mtime(page)
        web.load(URLRequest(url: currentURL))
    }
    func openPage(_ f: String) {
        page = f
        loadPage()
    }
    func mtime(_ f: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: PAGES_DIR.appendingPathComponent(f).path))?[.modificationDate] as? Date
    }
    func checkReload() {
        guard page != REMOTE, let m = mtime(page), m != pageMTime else { return }
        if TESTING { print("[reload] \(page)") }
        loadPage()
    }

    // 점검용: --eval <JS> [초] → 페이지를 띄우고 기다린 뒤 JS(await 가능, return 값 출력)를 실행하고 종료
    func runEval() {
        let js = arg("--eval") ?? "return document.title"
        let wait = CommandLine.arguments.firstIndex(of: "--eval").flatMap { i in i + 2 < CommandLine.arguments.count ? Double(CommandLine.arguments[i + 2]) : nil } ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            self.web.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { r in
                switch r {
                case .success(let v):
                    if JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]) {
                        print(String(decoding: d, as: UTF8.self))
                    } else { print(v) }
                case .failure(let e): print("[eval error]", e)
                }
                exit(0)
            }
        }
    }

    // ---- Google 계정 ----
    func connectGoogle() async throws -> String {
        let email = try await Google.shared.login()
        await MainActor.run {
            if self.page == REMOTE, FileManager.default.fileExists(atPath: PAGES_DIR.appendingPathComponent(DEFAULT_PAGE).path) { self.page = DEFAULT_PAGE }
            self.loadPage(); WidgetFeed.shared.refreshAll()
        }
        return email
    }
    @objc func menuGoogleLogin() {
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        let started = Date()
        Task {
            do {
                let email = try await connectGoogle()
                _ = try? await bridge.notify("진의 데스크", "Google 계정 연결됨: \(email)")
            } catch {
                // 이 시도가 실패해도 그사이 다른 시도로 연결됐으면(토큰 파일이 더 새로우면) 알리지 않는다
                let saved = (try? FileManager.default.attributesOfItem(atPath: TOKEN_FILE.path))?[.modificationDate] as? Date
                if let saved, saved > started { return }
                await MainActor.run {
                    let a = NSAlert(); a.messageText = "Google 계정을 연결하지 못했습니다"
                    a.informativeText = (error as? GErr)?.message ?? error.localizedDescription
                    a.runModal()
                }
            }
        }
    }
    @objc func menuGoogleLogout() {
        Task { await Google.shared.logout(); await MainActor.run { self.loadPage(); WidgetFeed.shared.refreshAll() } }
    }
    @objc func menuPage(_ i: NSMenuItem) { if let f = i.representedObject as? String { openPage(f) } }
    @objc func openPagesFolder() { NSWorkspace.shared.open(PAGES_DIR) }

    // open 'jindesk://pages/파일.html' → 그 페이지로 전환 (터미널·Claude Code에서 결과 바로 보기)
    // jindesk://open → 앱 창, jindesk://go?u=<주소> → 브라우저로 (WidgetKit 위젯에서 누름), jindesk://pages/<파일> → 그 페이지
    func application(_ a: NSApplication, open urls: [URL]) {
        guard let u = urls.first, u.scheme == SCHEME else { return }
        switch u.host {
        case "go":
            if let s = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "u" })?.value,
               let t = URL(string: s), ["https", "http"].contains(t.scheme ?? "") { NSWorkspace.shared.open(t) }
        case "pages":
            openPage(String(u.path.dropFirst())); showMain()
        default:
            showMain()
        }
    }

    // 점검 모드 전용: 모든 프레임의 주소·로딩 상태·오류를 표준 출력으로 (내용은 읽지 않음)
    func addDiagnostics(_ cfg: WKWebViewConfiguration) {
        let js = """
        (function(){
          var post = function(k, v){ try{ webkit.messageHandlers.diag.postMessage(k + " " + location.origin + location.pathname.slice(0,40) + " " + v); }catch(e){} };
          post("load", "top=" + (window === top) + " ready=" + document.readyState);
          addEventListener("error", function(e){ post("error", String(e.message || (e.target && (e.target.src || e.target.href)) || e)); }, true);
          addEventListener("unhandledrejection", function(e){ post("reject", String(e.reason && (e.reason.message || e.reason.code) || e.reason)); });
          var ce = console.error; console.error = function(){ post("console", Array.prototype.join.call(arguments, " ").slice(0,200)); return ce.apply(console, arguments); };
          // 대시보드 프레임이면 패널별 상태만 요약 (제목·본문 같은 내용은 보내지 않음)
          [20000, 50000].forEach(function(ms){ setTimeout(function(){
            var st = document.getElementById("statusText"); if(!st) return;
            var sum = ["cal","mail","drive"].map(function(k){
              var sec = document.querySelector(".panel." + k); if(!sec) return k + ":-";
              return k + ": rows=" + sec.querySelectorAll(".row").length + " sampleTag=" + sec.querySelectorAll(".tag.sample").length +
                " bad=" + sec.querySelectorAll(".note.bad").length + " stale=" + sec.querySelectorAll(".note.stale").length +
                " empty=" + sec.querySelectorAll(".empty").length + " meta='" + (sec.querySelector(".pmeta")||{}).textContent + "'";
            });
            var bad = Array.prototype.map.call(document.querySelectorAll(".note.bad,.note.stale"), function(n){ return n.textContent.slice(0,120); });
            post("status@" + ms/1000 + "s", "'" + st.textContent + "' | " + sum.join(" | ") + (bad.length ? " | notes: " + bad.join(" / ") : ""));
          }, ms); });
          setTimeout(function(){ post("t+8s", "iframes=" + document.querySelectorAll("iframe").length + " nodes=" + document.getElementsByTagName("*").length + " w=" + innerWidth + " h=" + innerHeight); }, 8000);
        })();
        """
        cfg.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController.add(self, name: "diag")
    }
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) { print("[diag]", m.body) }

    // 메뉴 막대 아이콘: 왼쪽 클릭 = 앱 창 열기/숨기기, 오른쪽 클릭 = 메뉴
    @objc func click(_ s: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { toggleMain() }
    }

    func showMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "진의 데스크 열기  (⌃⌥J)", action: #selector(menuShowMain), keyEquivalent: "").target = self
        m.addItem(.separator())
        fillCommon(m, shortcuts: false)
        m.addItem(.separator())
        m.addItem(withTitle: "종료", action: #selector(quit), keyEquivalent: "").target = self
        m.delegate = self
        item.menu = m
        item.button?.performClick(nil)
    }
    func menuDidClose(_ menu: NSMenu) { if menu === item.menu { item.menu = nil } }   // 왼쪽 클릭은 다시 창 열기로

    @objc func reload() { loadPage() }
    @objc func openInBrowser() { if let u = DESK_URL { NSWorkspace.shared.open(u) } }
    @objc func quit() { NSApp.terminate(nil) }

    // 메일·파일 링크(target=_blank)는 기본 브라우저로
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration,
                 for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        if let u = a.request.url, u.scheme != SCHEME { NSWorkspace.shared.open(u) }
        return nil
    }

    // 로컬 페이지에서 바깥 링크를 누르면 기본 브라우저로, <a download>는 다운로드 폴더로
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, preferences p: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if a.shouldPerformDownload { decisionHandler(.download, p); return }
        if page != REMOTE, a.targetFrame?.isMainFrame ?? false, a.navigationType == .linkActivated,
           let u = a.request.url, u.scheme != SCHEME {
            NSWorkspace.shared.open(u); decisionHandler(.cancel, p); return
        }
        decisionHandler(.allow, p)
    }
    func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(r.canShowMIMEType ? .allow : .download)
    }
    func webView(_ w: WKWebView, navigationAction a: WKNavigationAction, didBecome d: WKDownload) { d.delegate = self }
    func webView(_ w: WKWebView, navigationResponse r: WKNavigationResponse, didBecome d: WKDownload) { d.delegate = self }
    func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename name: String, completionHandler: @escaping (URL?) -> Void) {
        completionHandler(uniqueDownload(name))
    }
    func downloadDidFinish(_ d: WKDownload) {
        if TESTING { print("[download] done") }
    }

    // alert / confirm / prompt / 파일 선택을 네이티브 창으로
    func modal(_ msg: String, _ buttons: [String], field: NSTextField? = nil) -> Int {
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        let a = NSAlert(); a.messageText = msg
        buttons.forEach { a.addButton(withTitle: $0) }
        a.accessoryView = field
        if let f = field { a.window.initialFirstResponder = f }
        return a.runModal() == .alertFirstButtonReturn ? 0 : 1
    }
    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) {
        if TESTING { print("[alert]", m); completionHandler(); return }
        _ = modal(m, ["확인"]); completionHandler()
    }
    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        if TESTING { print("[confirm]", m); completionHandler(true); return }
        completionHandler(modal(m, ["확인", "취소"]) == 0)
    }
    func webView(_ w: WKWebView, runJavaScriptTextInputPanelWithPrompt m: String, defaultText t: String?, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        if TESTING { print("[prompt]", m); completionHandler(t ?? ""); return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); field.stringValue = t ?? ""
        completionHandler(modal(m, ["확인", "취소"], field: field) == 0 ? field.stringValue : nil)
    }
    func webView(_ w: WKWebView, runOpenPanelWith p: WKOpenPanelParameters, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        let o = NSOpenPanel()
        o.allowsMultipleSelection = p.allowsMultipleSelection; o.canChooseDirectories = p.allowsDirectories
        completionHandler(o.runModal() == .OK ? o.urls : nil)
    }

    // 앱이 앞에 있어도 알림 배너를 띄운다
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification, withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) {
        h([.banner, .sound])
    }

    func hotKeyFired() { toggleMain() }

    // ⌃⌥J 전역 단축키 (Carbon 핫키는 손쉬운 사용 권한이 필요 없다)
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ud in
            let me = Unmanaged<App>.fromOpaque(ud!).takeUnretainedValue()
            DispatchQueue.main.async { me.hotKeyFired() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x4A444B31), id: 1)   // 'JDK1'
        RegisterEventHotKey(UInt32(kVK_ANSI_J), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKey)
    }
}

setvbuf(stdout, nil, _IONBF, 0)   // 점검 출력이 exit(0) 전에 잘리지 않게
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)   // 보통 앱: Dock 아이콘·⌘Tab·메뉴 막대 메뉴
app.run()
