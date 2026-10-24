// 로컬 페이지 호스트: jindesk:// 로 pages 폴더의 HTML을 띄우고, 페이지에 네이티브 기능(window.jin)과
// claude.ai 런타임 흉내(window.claude.use("mcp"))를 붙인다. → Claude로 만든 Artifact HTML을 그대로 넣으면 돈다.
import Cocoa
import WebKit
import UserNotifications

let SCHEME = "jindesk"

func pageURL(_ file: String) -> URL {
    var c = URLComponents(); c.scheme = SCHEME; c.host = "pages"; c.path = "/" + file
    return c.url!
}

// 페이지에 주입하는 스크립트 (jindesk:// 메인 프레임에서만 동작)
let BRIDGE_JS = #"""
(function(){
  if (location.protocol !== "jindesk:" || window.jin) return;
  var h = window.webkit && webkit.messageHandlers && webkit.messageHandlers.jin;
  if (!h) return;
  function call(method, args){ return h.postMessage({method: method, args: args || {}}); }

  var jin = {
    native: true,
    call: call,
    notify: function(title, body){ return call("notify", {title: String(title||""), body: body==null ? "" : String(body)}); },
    run: function(cmd, opts){ return call("run", Object.assign({cmd: cmd}, opts||{})); },
    readFile: function(path, opts){ return call("readFile", Object.assign({path: path}, opts||{})); },
    writeFile: function(path, text, opts){ return call("writeFile", Object.assign({path: path, text: text}, opts||{})); },
    listDir: function(path){ return call("listDir", {path: path||""}); },
    clipboard: { read: function(){ return call("clipboardRead"); }, write: function(t){ return call("clipboardWrite", {text: String(t)}); } },
    open: function(url){ return call("open", {url: String(url)}); },
    save: function(name, text, opts){ return call("save", Object.assign({name: name, text: text}, opts||{})); },
    fetch: function(url, opts){ return call("fetch", Object.assign({url: String(url)}, opts||{})); },
    google: {
      status: function(){ return call("googleStatus"); },
      login: function(){ return call("googleLogin"); },
      api: function(url, opts){ return call("googleApi", Object.assign({url: String(url)}, opts||{})); }
    },
    pages: { list: function(){ return call("pagesList"); }, open: function(file){ return call("pagesOpen", {file: file}); } },
    showApp: function(){ return call("showApp"); }
  };
  window.jin = Object.freeze(jin);

  // ---- claude.ai 런타임의 mcp capability 흉내 (callTool / watchTool / invalidate) ----
  var watchers = [];
  function callTool(server, tool, input){
    return call("mcp", {server: server, tool: tool, input: input||{}}).then(function(r){
      if (r && r.error) { var e = new Error(r.error.message || r.error.code); Object.assign(e, r.error); throw e; }
      return r;
    });
  }
  function fire(w){
    if (w.busy) { w.again = true; return w.busy; }
    w.busy = callTool(w.server, w.tool, w.input).then(
      function(r){ if (!w.dead) w.cb({type: "data", result: r}); },
      function(e){ if (!w.dead) w.cb({type: "error", error: {code: e.code || "upstream_error", message: e.message, retryable: !!e.retryable, native: true}}); }
    ).then(function(){ w.busy = null; if (w.again && !w.dead) { w.again = false; return fire(w); } });
    return w.busy;
  }
  var mcp = {
    callTool: callTool,
    watchTool: function(server, tool, input, cb, opts){
      var w = {server: server, tool: tool, input: input||{}, cb: cb, dead: false};
      watchers.push(w); fire(w);
      var every = opts && opts.refetchInterval;
      if (every) w.timer = setInterval(function(){ fire(w); }, Math.max(every, 5000));
      return function(){ w.dead = true; clearInterval(w.timer); watchers = watchers.filter(function(x){ return x !== w; }); };
    },
    invalidate: function(server, tool, input){
      var k = input === undefined ? null : JSON.stringify(input);
      return Promise.all(watchers.filter(function(w){
        return w.server === server && (!tool || w.tool === tool) && (k === null || JSON.stringify(w.input) === k);
      }).map(fire)).then(function(){});
    }
  };
  if (!window.claude) window.claude = { native: true, use: function(name){ return Promise.resolve(name === "mcp" ? mcp : null); } };
})();
"""#

struct BErr: LocalizedError { let errorDescription: String?; init(_ m: String) { errorDescription = m } }

final class Bridge: NSObject, WKURLSchemeHandler, WKScriptMessageHandlerWithReply {
    var openPage: (String) -> Void = { _ in }
    var googleLogin: () async throws -> String = { try await Google.shared.login() }
    var showApp: () -> Void = {}

    // ---- jindesk://pages/<파일> ----
    func webView(_ w: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let file = PAGES_DIR.appendingPathComponent(url.path).standardizedFileURL
        guard file.path.hasPrefix(PAGES_DIR.standardizedFileURL.path + "/"), var data = try? Data(contentsOf: file) else {
            let r = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain; charset=utf-8"])!
            task.didReceive(r); task.didReceive(Data("없는 파일: \(url.path)".utf8)); task.didFinish()
            return
        }
        let ext = file.pathExtension.lowercased()
        if ext == "html" || ext == "htm" {
            // Artifact 소스는 <html>·<head> 없는 조각이다 → 표준 모드·UTF-8로 읽히게 머리만 붙인다
            let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
            if !head.contains("<!doctype") && !head.contains("<html") {
                data = Data("<!doctype html><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n".utf8) + data
            }
        }
        let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                headerFields: ["Content-Type": mime(ext), "Cache-Control": "no-store"])!
        task.didReceive(r); task.didReceive(data); task.didFinish()
    }
    func webView(_ w: WKWebView, stop task: WKURLSchemeTask) {}

    func mime(_ ext: String) -> String {
        let m = ["html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8",
                 "mjs": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8", "json": "application/json; charset=utf-8",
                 "txt": "text/plain; charset=utf-8", "md": "text/markdown; charset=utf-8", "csv": "text/csv; charset=utf-8",
                 "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
                 "webp": "image/webp", "ico": "image/x-icon", "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf",
                 "mp3": "audio/mpeg", "mp4": "video/mp4", "pdf": "application/pdf", "wasm": "application/wasm"]
        return m[ext] ?? "application/octet-stream"
    }

    // ---- window.jin 호출 처리 ----
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        // 로컬 페이지(jindesk://)의 메인 프레임만 허용: claude.ai·외부 iframe은 못 부른다
        guard m.frameInfo.isMainFrame, m.frameInfo.securityOrigin.protocol == SCHEME,
              let body = m.body as? [String: Any], let method = body["method"] as? String else {
            replyHandler(nil, "이 페이지에서는 jin API를 쓸 수 없습니다"); return
        }
        let args = body["args"] as? [String: Any] ?? [:]
        Task {
            do {
                let r = try await self.handle(method, args)
                await MainActor.run { replyHandler(r, nil) }
            } catch {
                await MainActor.run { replyHandler(nil, (error as? GErr)?.message ?? error.localizedDescription) }
            }
        }
    }

    func handle(_ method: String, _ a: [String: Any]) async throws -> Any {
        func s(_ k: String) -> String? { a[k] as? String }
        switch method {
        case "mcp":
            do {
                let p = try await Google.shared.call(server: s("server") ?? "", tool: s("tool") ?? "", input: a["input"] as? [String: Any] ?? [:])
                return ["payload": p, "cache": ["storedAt": Date().timeIntervalSince1970 * 1000]]
            } catch let e as GErr {
                return ["error": ["code": e.code, "message": e.message, "retryable": e.retryable]]
            } catch {
                return ["error": ["code": "upstream_error", "message": error.localizedDescription, "retryable": true]]
            }
        case "notify":
            return try await notify(s("title") ?? "", s("body") ?? "")
        case "run":
            guard let cmd = s("cmd") else { throw BErr("cmd가 없습니다") }
            return await runShell(cmd, cwd: s("cwd"), timeout: (a["timeout"] as? NSNumber)?.doubleValue ?? 60)
        case "readFile":
            let d = try Data(contentsOf: path(s("path")))
            return (a["base64"] as? Bool ?? false) ? d.base64EncodedString() : String(decoding: d, as: UTF8.self)
        case "writeFile":
            let url = path(s("path"))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let d = s("base64").flatMap { Data(base64Encoded: $0) } ?? Data((s("text") ?? "").utf8)
            if a["append"] as? Bool ?? false, let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(d); try h.close()
            } else { try d.write(to: url, options: .atomic) }
            return url.path
        case "listDir":
            let url = path(s("path"))
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys).map { f -> [String: Any] in
                let v = try? f.resourceValues(forKeys: Set(keys))
                return ["name": f.lastPathComponent, "path": f.path, "dir": v?.isDirectory ?? false, "size": v?.fileSize ?? 0,
                        "mtime": (v?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000]
            }.sorted { ($0["name"] as! String) < ($1["name"] as! String) }
        case "clipboardRead":
            return await MainActor.run { NSPasteboard.general.string(forType: .string) ?? "" }
        case "clipboardWrite":
            await MainActor.run { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s("text") ?? "", forType: .string) }
            return true
        case "open":
            guard let u = s("url").flatMap({ URL(string: $0) }) else { throw BErr("url이 올바르지 않습니다") }
            await MainActor.run { _ = NSWorkspace.shared.open(u.scheme == nil ? URL(fileURLWithPath: path(u.path).path) : u) }
            return true
        case "save":   // 다운로드 폴더에 저장 (같은 이름이 있으면 번호를 붙임)
            let d = s("base64").flatMap { Data(base64Encoded: $0) } ?? Data((s("text") ?? "").utf8)
            let url = uniqueDownload(s("name") ?? "download.txt")
            try d.write(to: url)
            if a["reveal"] as? Bool ?? false { await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            return url.path
        case "fetch":   // CORS 없이 요청
            guard let u = s("url").flatMap({ URL(string: $0) }) else { throw BErr("url이 올바르지 않습니다") }
            var r = URLRequest(url: u)
            r.httpMethod = s("method") ?? "GET"
            (a["headers"] as? [String: String])?.forEach { r.setValue($1, forHTTPHeaderField: $0) }
            if let b = s("body") { r.httpBody = Data(b.utf8) }
            let (d, resp) = try await URLSession.shared.data(for: r)
            let h = resp as? HTTPURLResponse
            var out: [String: Any] = ["status": h?.statusCode ?? 0, "url": resp.url?.absoluteString ?? "",
                                      "headers": (h?.allHeaderFields as? [String: String]) ?? [:]]
            if a["base64"] as? Bool ?? false { out["base64"] = d.base64EncodedString() } else { out["text"] = String(decoding: d, as: UTF8.self) }
            return out
        case "googleStatus":
            return await Google.shared.status()
        case "googleLogin":
            return try await googleLogin()
        case "googleApi":   // 인증된 Google API 직접 호출 (커넥터에 없는 기능용)
            guard let u = s("url").flatMap({ URL(string: $0) }) else { throw BErr("url이 올바르지 않습니다") }
            return try await Google.shared.request(u, method: s("method") ?? "GET", body: a["body"])
        case "gmailMarkRead":   // {query, dryRun} 또는 {undo: 백업파일} → 읽음/안 읽음 표시
            return try await Google.shared.markRead(query: s("query") ?? "in:inbox is:unread", dryRun: a["dryRun"] as? Bool ?? true, undoFile: s("undo"))
        case "setPref":   // 페이지 설정을 앱에도 알림 (지금은 hideAds → WidgetKit 위젯에 반영)
            if s("key") == "hideAds", let v = a["value"] as? Bool {
                await MainActor.run { if WidgetFeed.shared.hideAds != v { WidgetFeed.shared.hideAds = v; WidgetFeed.shared.refreshMail() } }
            }
            return true
        case "refreshWidget":   // 일정 추가 직후 위젯 즉시 갱신
            await MainActor.run { WidgetFeed.shared.refreshAll() }
            return true
        case "daumStatus":
            return await DaumMail.shared.status()
        case "daumSave":   // 로그인 시험 후 키체인에 저장 (비밀번호는 로그에 남기지 않음)
            return try await DaumMail.shared.save(user: s("user") ?? "", password: s("password") ?? "")
        case "daumBody":
            return try await DaumMail.shared.body(uid: (a["uid"] as? NSNumber)?.intValue ?? 0)
        case "daumMarkRead":   // {dryRun} 또는 {undo: 백업파일} → 받은편지함 안 읽은 메일을 읽음으로 / 되돌리기
            let r = try await DaumMail.shared.markRead(dryRun: a["dryRun"] as? Bool ?? true, undoFile: s("undo"))
            if !(a["dryRun"] as? Bool ?? true) { await MainActor.run { WidgetFeed.shared.refreshMail() } }
            return r
        case "daumClear":
            await DaumMail.shared.clear(); return true
        case "daumList":
            return try await DaumMail.shared.list(unread: a["unread"] as? Bool ?? true, limit: (a["limit"] as? NSNumber)?.intValue ?? 15, offset: (a["offset"] as? NSNumber)?.intValue ?? 0)
        case "showApp":   // 앱 창 열기 (위젯에서)
            await MainActor.run { showApp() }
            return true
        case "pagesList":
            return listPages().map { ["file": $0.file, "title": $0.title] }
        case "pagesOpen":
            guard let f = s("file"), FileManager.default.fileExists(atPath: PAGES_DIR.appendingPathComponent(f).path) else { throw BErr("없는 페이지입니다") }
            await MainActor.run { openPage(f) }
            return true
        default:
            throw BErr("알 수 없는 기능: \(method)")
        }
    }

    // 상대 경로는 data 폴더 기준, ~ 는 홈
    func path(_ p: String?) -> URL {
        let p = (p ?? "") as NSString
        let e = p.expandingTildeInPath
        return e.hasPrefix("/") ? URL(fileURLWithPath: e) : DATA_DIR.appendingPathComponent(e)
    }

    func notify(_ title: String, _ body: String) async throws -> String {
        let c = UNUserNotificationCenter.current()
        let st = await c.notificationSettings().authorizationStatus
        // 처음이면 권한을 묻되 답을 기다리지 않는다 (묻는 동안 페이지가 멈추지 않게)
        if st == .notDetermined { Task { _ = try? await c.requestAuthorization(options: [.alert, .sound]) } }
        if st == .authorized || st == .provisional {
            let n = UNMutableNotificationContent()
            n.title = title; n.body = body; n.sound = .default
            try await c.add(UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil))
            return "notification"
        }
        // 알림 권한이 없으면 AppleScript 알림으로 대신
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        _ = await runShell("osascript -e " + shellQuote("display notification \(q(body)) with title \(q(title))"), cwd: nil, timeout: 10)
        return "osascript(권한 상태 \(st.rawValue): 0=미결정 1=거부)"
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func uniqueDownload(_ name: String) -> URL {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    let safe = (name as NSString).lastPathComponent.isEmpty ? "download" : (name as NSString).lastPathComponent
    var url = dir.appendingPathComponent(safe)
    let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"); n += 1
    }
    return url
}

// zsh 로그인 셸로 실행 (Homebrew 경로 등이 잡힌다). 제한 시간이 지나면 종료
func runShell(_ cmd: String, cwd: String?, timeout: Double) async -> [String: Any] {
    await withCheckedContinuation { c in
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", cmd]
            p.currentDirectoryURL = cwd.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? FileManager.default.homeDirectoryForCurrentUser
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { c.resume(returning: ["code": -1, "stdout": "", "stderr": error.localizedDescription]); return }
            let g = DispatchGroup()
            var o = Data(), e = Data()
            g.enter(); DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
            g.enter(); DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
            var timedOut = false
            let kill = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: kill)
            p.waitUntilExit(); kill.cancel(); g.wait()
            c.resume(returning: ["code": Int(p.terminationStatus), "stdout": String(decoding: o, as: UTF8.self),
                                 "stderr": String(decoding: e, as: UTF8.self), "timedOut": timedOut])
        }
    }
}

// pages 폴더의 HTML 목록 (제목은 <title>, 없으면 파일 이름)
func listPages() -> [(file: String, title: String)] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: PAGES_DIR.path)) ?? []
    // _로 시작하는 파일(위젯 등 내부 페이지)은 목록에서 뺀다
    return files.filter { $0.lowercased().hasSuffix(".html") && !$0.hasPrefix(".") && !$0.hasPrefix("_") }.sorted().map { f in
        let head = (try? FileHandle(forReadingFrom: PAGES_DIR.appendingPathComponent(f)))
            .map { h -> String in defer { try? h.close() }; return String(decoding: h.readData(ofLength: 16384), as: UTF8.self) } ?? ""
        var title = (f as NSString).deletingPathExtension
        if let r = head.range(of: "<title[^>]*>([^<]*)</title>", options: [.regularExpression, .caseInsensitive]) {
            let t = head[r].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { title = t }
        }
        return (f, title)
    }
}
