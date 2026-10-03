// Google API 직접 연결 — claude.ai 커넥터 없이 Gmail·Drive·Calendar를 읽는다.
// OAuth: 데스크톱 앱 방식(루프백 리디렉트 + PKCE). 클라이언트 정보는 google_client.json(Google Cloud 콘솔에서 받은 파일),
// 갱신 토큰은 google_token.json(권한 600)에 둔다.
import Foundation
import Network
import CryptoKit
import AppKit

let SUPPORT: URL = {
    if let h = ProcessInfo.processInfo.environment["JINDESK_HOME"] { return URL(fileURLWithPath: h) }   // 점검용 대체 경로
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/JinDesk")
}()
let PAGES_DIR = SUPPORT.appendingPathComponent("pages")
let DATA_DIR = SUPPORT.appendingPathComponent("data")
let CLIENT_FILE = SUPPORT.appendingPathComponent("google_client.json")
let TOKEN_FILE = SUPPORT.appendingPathComponent("google_token.json")
let SCOPES = [
    "https://www.googleapis.com/auth/gmail.modify",          // 읽기 + 읽음 표시 같은 라벨 변경 (삭제 권한은 없음). 예전 토큰은 gmail.readonly
    "https://www.googleapis.com/auth/drive.metadata.readonly",
    "https://www.googleapis.com/auth/calendar.events",      // 일정 읽기 + 메일에서 찾은 일정 추가 (예전 토큰은 calendar.readonly)
].joined(separator: " ")

// 페이지 쪽 오류 코드는 claude.ai 커넥터 규칙(needs_reauth, server_not_connected …)에 맞춘다
enum GErr: Error {
    case notConfigured, notLoggedIn, reauth, unsupported(String), http(Int, String), network(String), bad(String)
    var code: String {
        switch self {
        case .notConfigured, .notLoggedIn: return "server_not_connected"
        case .reauth: return "needs_reauth"
        case .unsupported: return "server_not_found"
        case .http(let s, _): return s == 429 ? "rate_limited" : s >= 500 ? "server_unavailable" : "tool_error"
        case .network: return "server_unavailable"
        case .bad: return "tool_error"
        }
    }
    var retryable: Bool { code == "rate_limited" || code == "server_unavailable" }
    var message: String {
        let menu = "메뉴 막대의 진의 데스크 아이콘을 오른쪽 클릭 → 'Google 계정 연결'"
        switch self {
        case .notConfigured: return "Google API 설정 파일이 없습니다. google_client.json을 ~/Library/Application Support/JinDesk/에 넣은 뒤 \(menu)을 눌러 주세요."
        case .notLoggedIn: return "Google 계정이 연결되어 있지 않습니다. \(menu)을 눌러 주세요."
        case .reauth: return "Google 로그인이 만료되었습니다. \(menu)으로 다시 로그인해 주세요."
        case .unsupported(let s): return "진의 데스크 앱은 아직 \(s)을(를) 지원하지 않습니다."
        case .http(let s, let m): return s == 429 ? "Google 요청 한도를 넘었습니다. 잠시 뒤 다시 시도합니다." : "Google 오류 \(s): \(m)"
        case .network(let m): return "Google에 연결할 수 없습니다 (\(m)). 곧 다시 시도합니다."
        case .bad(let m): return m
        }
    }
}

actor Google {
    static let shared = Google()
    private var access: String?
    private var expiry = Date.distantPast
    private var refreshing: Task<String, Error>?
    private var email: String?

    // ---- 설정·토큰 파일 ----
    nonisolated func client() throws -> (id: String, secret: String) {
        guard let d = try? Data(contentsOf: CLIENT_FILE),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let c = (j["installed"] ?? j["web"] ?? j) as? [String: Any],
              let id = c["client_id"] as? String, let secret = c["client_secret"] as? String
        else { throw GErr.notConfigured }
        return (id, secret)
    }
    nonisolated func saved() -> [String: Any]? {
        guard let d = try? Data(contentsOf: TOKEN_FILE) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
    private func store(_ j: [String: Any]) throws {
        try FileManager.default.createDirectory(at: SUPPORT, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: j).write(to: TOKEN_FILE, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: TOKEN_FILE.path)
    }

    func status() -> [String: Any] {
        let s = saved()
        return ["configured": (try? client()) != nil, "loggedIn": s?["refresh_token"] != nil, "email": (s?["email"] as? String) ?? NSNull(),
                "canModify": canModify(), "canWriteCalendar": canWriteCalendar()]
    }
    // 저장된 토큰이 메일 변경(gmail.modify) 권한을 받았는지. 없으면 'Google 계정 연결'을 다시 해야 한다
    nonisolated func canModify() -> Bool { ((saved()?["scope"] as? String) ?? "").contains("gmail.modify") }
    nonisolated func canWriteCalendar() -> Bool { ((saved()?["scope"] as? String) ?? "").contains("calendar.events") }

    // 검색에 걸리는 메일을 읽음으로 표시. 처리 전에 대상 메시지 ID를 data/에 백업해 되돌릴 수 있게 한다
    // dryRun이면 개수만 센다. undo 파일을 주면 그 ID들을 다시 안 읽음으로.
    func markRead(query: String, dryRun: Bool, undoFile: String? = nil) async throws -> [String: Any] {
        if !dryRun && !canModify() { throw GErr.bad("메일 변경 권한이 없습니다. 메뉴 → Google 연결 해제 → Google 계정 연결로 다시 로그인해 권한을 허용해 주세요.") }
        var ids: [String] = []
        if let f = undoFile {
            ids = (try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: f))) as? [String: Any])?["messageIds"] as? [String] ?? []
        } else {
            var token: String? = nil
            repeat {
                let pg = try await get("https://gmail.googleapis.com/gmail/v1/users/me/messages",
                                       [("q", query), ("maxResults", "500"), ("pageToken", token), ("fields", "messages/id,nextPageToken")])
                ids += ((pg["messages"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
                token = pg["nextPageToken"] as? String
            } while token != nil && ids.count < 20000
        }
        if dryRun { return ["query": query, "messages": ids.count] }
        var backup = ""
        if undoFile == nil {
            let f = DATA_DIR.appendingPathComponent("읽음처리-백업-\(Int(Date().timeIntervalSince1970)).json")
            try FileManager.default.createDirectory(at: DATA_DIR, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["query": query, "at": ISO8601DateFormatter().string(from: Date()), "messageIds": ids]).write(to: f)
            backup = f.path
        }
        var done = 0
        for chunk in stride(from: 0, to: ids.count, by: 1000).map({ Array(ids[$0..<min($0 + 1000, ids.count)]) }) {
            let body: [String: Any] = undoFile == nil ? ["ids": chunk, "removeLabelIds": ["UNREAD"]] : ["ids": chunk, "addLabelIds": ["UNREAD"]]
            _ = try await request(URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/batchModify")!, method: "POST", body: body)
            done += chunk.count
        }
        cache.removeAll(); counts.removeAll()   // 화면이 바로 새 수를 받게
        return ["query": query, "messages": done, "backup": backup, "undo": undoFile != nil]
    }

    func logout() async {
        if let t = saved()?["refresh_token"] as? String {   // 가능하면 Google 쪽 권한도 회수 (실패해도 무시)
            var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            r.httpMethod = "POST"; r.httpBody = form(["token": t])
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            _ = try? await URLSession.shared.data(for: r)
        }
        try? FileManager.default.removeItem(at: TOKEN_FILE)
        access = nil; expiry = .distantPast; email = nil
    }

    // ---- 로그인: 기본 브라우저로 Google 동의 화면 → 127.0.0.1 임시 서버가 code를 받는다 ----
    func login(open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) async throws -> String {
        let c = try client()
        let verifier = randomURLSafe(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = randomURLSafe(16)
        let server = try OneShotHTTP()
        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)"
        var u = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        u.queryItems = [
            .init(name: "client_id", value: c.id), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: SCOPES),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state),
        ]
        if ProcessInfo.processInfo.environment["JINDESK_OAUTH_PRINT"] != nil { print("[oauth]", u.url!.absoluteString) } else { open(u.url!) }   // 점검용
        let q = try await server.wait(timeout: 300)
        if let e = q["error"] { throw GErr.bad("Google 로그인이 취소되었습니다 (\(e)).") }
        guard q["state"] == state, let code = q["code"] else { throw GErr.bad("Google 로그인 응답이 올바르지 않습니다.") }
        let j = try await tokenRequest(["code": code, "client_id": c.id, "client_secret": c.secret,
                                        "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier])
        guard let rt = j["refresh_token"] as? String else { throw GErr.bad("갱신 토큰을 받지 못했습니다. 다시 시도해 주세요.") }
        take(j)
        email = nil
        try store(["refresh_token": rt, "scope": j["scope"] ?? SCOPES])
        let me = try await myEmail()
        try store(["refresh_token": rt, "scope": j["scope"] ?? SCOPES, "email": me])
        return me
    }

    private func take(_ j: [String: Any]) {
        access = j["access_token"] as? String
        expiry = Date().addingTimeInterval(Double(j["expires_in"] as? Int ?? 3600) - 120)
    }

    private func tokenRequest(_ f: [String: String]) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        r.httpMethod = "POST"; r.httpBody = form(f)
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (d, resp): (Data, URLResponse)
        do { (d, resp) = try await URLSession.shared.data(for: r) } catch { throw GErr.network(error.localizedDescription) }
        let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        let s = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if s == 200 { return j }
        if (j["error"] as? String) == "invalid_grant" { throw GErr.reauth }
        throw GErr.http(s, (j["error_description"] as? String) ?? (j["error"] as? String) ?? "토큰 요청 실패")
    }

    private func token(force: Bool = false) async throws -> String {
        if !force, let a = access, Date() < expiry { return a }
        if let t = refreshing { return try await t.value }   // 동시에 여러 요청이 와도 갱신은 한 번만
        let c = try client()
        guard let rt = saved()?["refresh_token"] as? String else { throw GErr.notLoggedIn }
        let t = Task { () throws -> String in
            let j = try await self.tokenRequest(["client_id": c.id, "client_secret": c.secret, "refresh_token": rt, "grant_type": "refresh_token"])
            self.take(j)
            return j["access_token"] as? String ?? ""
        }
        refreshing = t
        defer { refreshing = nil }
        return try await t.value
    }

    // 인증된 Google API 요청 (401이면 토큰을 새로 받아 한 번 더)
    // 401이면 토큰을 새로 받아 한 번 더, 한도 초과(429·403 rateLimit)면 1·2·4초 쉬고 다시
    func request(_ url: URL, method: String = "GET", body: Any? = nil) async throws -> Any {
        var forced = false
        for attempt in 0..<4 {
            var r = URLRequest(url: url)
            r.httpMethod = method
            r.setValue("Bearer \(try await token(force: forced))", forHTTPHeaderField: "Authorization")
            if let b = body {
                r.httpBody = try JSONSerialization.data(withJSONObject: b)
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (d, resp): (Data, URLResponse)
            do { (d, resp) = try await URLSession.shared.data(for: r) } catch { throw GErr.network(error.localizedDescription) }
            let s = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if s == 401 && !forced { forced = true; continue }
            let j = d.isEmpty ? [String: Any]() : (try? JSONSerialization.jsonObject(with: d)) ?? String(decoding: d, as: UTF8.self)
            if (200..<300).contains(s) { return j }
            if s == 401 { throw GErr.reauth }
            let err = (j as? [String: Any])?["error"] as? [String: Any]
            let reason = ((err?["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? ""
            if (s == 429 || (s == 403 && reason.lowercased().contains("ratelimit"))) && attempt < 3 {
                try? await Task.sleep(nanoseconds: UInt64((pow(2, Double(attempt)) + Double.random(in: 0...0.5)) * 1e9))
                continue
            }
            throw GErr.http(s, err?["message"] as? String ?? "요청 실패")
        }
        throw GErr.http(429, "요청 실패")
    }
    private func get(_ base: String, _ q: [(String, String?)] = []) async throws -> [String: Any] {
        var u = URLComponents(string: base)!
        u.queryItems = q.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        // '+'는 URLComponents가 그대로 두는데 서버는 공백으로 읽는다
        u.percentEncodedQuery = u.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return try await request(u.url!) as? [String: Any] ?? [:]
    }

    private func myEmail() async throws -> String {
        if let e = email { return e }
        if let e = saved()?["email"] as? String { email = e; return e }
        let p = try await get("https://gmail.googleapis.com/gmail/v1/users/me/profile")
        email = p["emailAddress"] as? String ?? ""
        return email!
    }

    // ---- 커넥터 도구 흉내: 응답을 claude.ai 커넥터와 같은 모양으로 돌려준다 (CLAUDE.md 4.3) ----
    // 앱 창과 위젯이 같은 요청을 거의 동시에 보내므로 15초 동안은 결과를 같이 쓰고, 진행 중인 요청은 합친다
    private var cache: [String: (at: Date, value: [String: Any])] = [:]
    private var inflight: [String: Task<[String: Any], Error>] = [:]
    func call(server: String, tool: String, input i: [String: Any]) async throws -> [String: Any] {
        let key = server + "|" + tool + "|" + String(decoding: (try? JSONSerialization.data(withJSONObject: i, options: .sortedKeys)) ?? Data(), as: UTF8.self)
        if let c = cache[key], Date().timeIntervalSince(c.at) < 15 { return c.value }
        if let t = inflight[key] { return try await t.value }
        let t = Task { try await self.fetch(server: server, tool: tool, input: i) }
        inflight[key] = t
        defer { inflight[key] = nil }
        let v = try await t.value
        cache[key] = (Date(), v)
        return v
    }
    private func fetch(server: String, tool: String, input i: [String: Any]) async throws -> [String: Any] {
        switch (server, tool) {
        case ("Gmail", "search_threads"): return try await gmailSearch(i)
        case ("Google Drive", "list_recent_files"): return try await driveRecent(i)
        case ("Google Calendar", "list_events"): return try await calEvents(i)
        default: throw GErr.unsupported("\(server) / \(tool)")
        }
    }

    private func gmailSearch(_ i: [String: Any]) async throws -> [String: Any] {
        let n = min(max(num(i["pageSize"]) ?? 20, 1), 50)
        let list = try await get("https://gmail.googleapis.com/gmail/v1/users/me/threads",
                                 [("q", i["query"] as? String), ("maxResults", String(n)), ("pageToken", i["pageToken"] as? String)])
        let ids = (list["threads"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let me = (try? await myEmail()) ?? ""
        let link = { (tid: String) in "https://mail.google.com/mail/?authuser=\(me.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")#all/\(tid)" }
        // 스레드 응답 → 커넥터 모양 (messages: 보낸 사람·제목·날짜·라벨·링크)
        func thread(_ k: Int, _ t: [String: Any]) -> [String: Any] {
            let msgs = (t["messages"] as? [[String: Any]] ?? []).map { m -> [String: Any] in
                let hs = (m["payload"] as? [String: Any])?["headers"] as? [[String: Any]] ?? []
                func h(_ n: String) -> String? { hs.first { ($0["name"] as? String)?.lowercased() == n }?["value"] as? String }
                let ms = Double(m["internalDate"] as? String ?? "") ?? 0
                let tid = m["threadId"] as? String ?? ids[k]
                return ["id": m["id"] ?? "", "threadId": tid,
                        "date": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ms / 1000)),
                        "internalDate": m["internalDate"] ?? "", "sender": h("from") ?? "", "subject": h("subject") ?? "",
                        "snippet": m["snippet"] ?? "", "labelIds": m["labelIds"] ?? [],
                        "toRecipients": (h("to") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                        "viewUrl": link(tid)]
            }
            return ["id": ids[k], "viewUrl": link(ids[k]), "messages": msgs]
        }
        var threads = [[String: Any]?](repeating: nil, count: ids.count)
        try await withThrowingTaskGroup(of: (Int, [String: Any]).self) { g in
            for (k, id) in ids.enumerated() {
                if k >= 4, let (j, t) = try await g.next() { threads[j] = thread(j, t) }   // 동시에 4개까지만 (Gmail 초당 한도)
                g.addTask {
                    let t = try await self.get("https://gmail.googleapis.com/gmail/v1/users/me/threads/\(id)",
                                               [("format", "metadata"), ("metadataHeaders", "From"), ("metadataHeaders", "Subject"), ("metadataHeaders", "To")])
                    return (k, t)
                }
            }
            for try await (k, t) in g { threads[k] = thread(k, t) }
        }
        var out: [String: Any] = [:]
        let got = threads.compactMap { $0 }
        if !got.isEmpty { out["threads"] = got }
        // Gmail의 resultSizeEstimate는 201 같은 대충 값 → 검색에 걸리는 스레드 ID를 끝까지 받아 정확히 센다.
        // 수천 개면 몇 초 걸리므로 한 번 센 값은 기억해 두고 바로 돌려준 뒤, 1분 넘었으면 뒤에서 다시 센다.
        var count = ids.count, exact = true
        if list["nextPageToken"] != nil {
            let q = i["query"] as? String ?? ""
            if let c = counts[q] {
                (count, exact) = (c.n, c.exact)
                if Date().timeIntervalSince(c.at) > 60 && !counting.contains(q) {
                    counting.insert(q)
                    Task { defer { self.counting.remove(q) }; if let r = try? await self.countThreads(q) { self.counts[q] = (r.0, r.1, Date()) } }
                }
            } else {
                (count, exact) = try await countThreads(q)
                counts[q] = (count, exact, Date())
            }
        }
        out["resultCountEstimate"] = String(count)
        out["resultCountExact"] = exact              // 진의 데스크 앱에서만 붙는 필드 (claude.ai 커넥터에는 없음)
        if let t = list["nextPageToken"] { out["nextPageToken"] = t }
        return out
    }

    private var counts: [String: (n: Int, exact: Bool, at: Date)] = [:]
    private var counting = Set<String>()
    private func countThreads(_ q: String) async throws -> (Int, Bool) {
        var n = 0; var token: String? = nil
        for _ in 0..<10 {   // 500개씩 최대 5000
            let pg = try await get("https://gmail.googleapis.com/gmail/v1/users/me/threads",
                                   [("q", q), ("maxResults", "500"), ("pageToken", token), ("fields", "threads/id,nextPageToken")])
            n += (pg["threads"] as? [Any])?.count ?? 0
            token = pg["nextPageToken"] as? String
            if token == nil { return (n, true) }
        }
        return (n, false)
    }

    private func driveRecent(_ i: [String: Any]) async throws -> [String: Any] {
        let n = min(max(num(i["pageSize"]) ?? 20, 1), 100)
        let order: String = {
            switch i["orderBy"] as? String {
            case nil, "recency": return "recency desc"
            case "lastModifiedByMe": return "modifiedByMeTime desc"
            case let o?: return o
            }
        }()
        let j = try await get("https://www.googleapis.com/drive/v3/files", [
            ("pageSize", String(n)), ("orderBy", order), ("q", "trashed = false"), ("pageToken", i["pageToken"] as? String),
            ("fields", "nextPageToken,files(id,name,mimeType,fileExtension,size,owners(emailAddress),createdTime,modifiedTime,viewedByMeTime,parents,webViewLink,capabilities(canAddChildren))"),
        ])
        let files = (j["files"] as? [[String: Any]] ?? []).map { f -> [String: Any] in
            var o: [String: Any] = ["id": f["id"] ?? "", "title": f["name"] ?? "", "mimeType": f["mimeType"] ?? "",
                                    "owner": ((f["owners"] as? [[String: Any]])?.first?["emailAddress"]) ?? "",
                                    "createdTime": f["createdTime"] ?? "", "modifiedTime": f["modifiedTime"] ?? "",
                                    "parentId": (f["parents"] as? [String])?.first ?? "",
                                    "canAddChildren": (f["capabilities"] as? [String: Any])?["canAddChildren"] ?? false,
                                    "viewUrl": f["webViewLink"] ?? ""]
            if let v = f["viewedByMeTime"] { o["viewedByMeTime"] = v }
            if let v = f["fileExtension"] { o["fileExtension"] = v }
            if let v = f["size"] { o["fileSize"] = v }
            return o
        }
        var out: [String: Any] = ["files": files]
        if let t = j["nextPageToken"] { out["nextPageToken"] = t }
        return out
    }

    private func calEvents(_ i: [String: Any]) async throws -> [String: Any] {
        let cal = (i["calendarId"] as? String) ?? "primary"
        let enc = cal.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cal
        let order = (i["orderBy"] as? String) ?? "startTime"
        var j = try await get("https://www.googleapis.com/calendar/v3/calendars/\(enc)/events", [
            ("timeMin", i["startTime"] as? String), ("timeMax", i["endTime"] as? String),
            ("singleEvents", "true"), ("orderBy", order), ("maxResults", String(min(max(num(i["pageSize"]) ?? 50, 1), 250))),
            ("q", i["fullText"] as? String), ("timeZone", i["timeZone"] as? String), ("pageToken", i["pageToken"] as? String),
        ])
        // 커넥터는 items 대신 events, 일정이 없으면 키 자체가 없다
        if let items = j.removeValue(forKey: "items") as? [Any], !items.isEmpty { j["events"] = items }
        j.removeValue(forKey: "kind"); j.removeValue(forKey: "etag")
        return j
    }
}

private func num(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue ?? (v as? String).flatMap { Int($0) } }
private func form(_ f: [String: String]) -> Data {
    var ok = CharacterSet.alphanumerics; ok.insert(charactersIn: "-._~")
    return Data(f.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: ok) ?? "")" }.joined(separator: "&").utf8)
}
private func randomURLSafe(_ n: Int) -> String {
    Data((0..<n).map { _ in UInt8.random(in: 0...255) }).base64URL
}
extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

// 127.0.0.1에서 OAuth 리디렉트 요청 하나만 받고 닫는 임시 서버
final class OneShotHTTP: @unchecked Sendable {
    private let listener: NWListener
    private let q = DispatchQueue(label: "jindesk.oauth")
    private var ready: CheckedContinuation<UInt16, Error>?
    private var got: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    init() throws {
        let p = NWParameters.tcp
        p.requiredInterfaceType = .loopback
        listener = try NWListener(using: p, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { c in
            q.async {
                self.ready = c
                self.listener.stateUpdateHandler = { [weak self] st in
                    guard let self else { return }
                    switch st {
                    case .ready: self.ready?.resume(returning: self.listener.port?.rawValue ?? 0); self.ready = nil
                    case .failed(let e): self.ready?.resume(throwing: e); self.ready = nil; self.finish(.failure(e))
                    default: break
                    }
                }
                self.listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
                self.listener.start(queue: self.q)
            }
        }
    }

    func wait(timeout: Double) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { c in
            q.async {
                if let r = self.result { c.resume(with: r); return }
                self.got = c
                self.q.asyncAfter(deadline: .now() + timeout) { self.finish(.failure(GErr.bad("Google 로그인 대기 시간(5분)이 지났습니다."))) }
            }
        }
    }

    private func finish(_ r: Result<[String: String], Error>) {
        guard result == nil else { return }
        result = r
        got?.resume(with: r); got = nil
        listener.cancel()
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: q)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let line = String(decoding: data ?? Data(), as: UTF8.self).split(separator: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            let target = parts.count > 1 ? String(parts[1]) : "/"
            let items = URLComponents(string: "http://127.0.0.1" + target)?.queryItems ?? []
            var q: [String: String] = [:]
            items.forEach { q[$0.name] = $0.value ?? "" }
            let isAuth = q["code"] != nil || q["error"] != nil
            let body = isAuth
                ? "<!doctype html><meta charset=utf-8><title>진의 데스크</title><body style='font:16px -apple-system;padding:40px'><h2>Google 연결 정보를 받았습니다</h2><p>이 탭은 닫아도 됩니다. 메뉴 막대의 진의 데스크로 돌아가세요.</p>"
                : "not found"
            let head = "HTTP/1.1 \(isAuth ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(Data(body.utf8).count)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in conn.cancel() })
            if isAuth { self.finish(.success(q)) }
        }
    }
}
