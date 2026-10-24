// Daum 메일(IMAP) — 직접 만든 최소 IMAP 클라이언트(Network.framework, TLS 993). 앱 비밀번호는 맥 키체인에만 저장.
// 목록: UID SEARCH → UID FETCH (FROM SUBJECT DATE + FLAGS), 읽기 전용(EXAMINE).
// 메일을 바꾸는 건 markRead(전체 읽음) 하나뿐: SELECT + UID STORE \Seen, 하기 전에 UID 백업을 남겨 되돌릴 수 있다.
import Foundation
import Security
import Network

actor DaumMail {
    static let shared = DaumMail()
    private let service = "com.jin.desk.daum"
    private let userFile = SUPPORT.appendingPathComponent("daum_user.txt")   // 주소만 (비밀 아님)
    // 점검용: JINDESK_DAUM_URL=imap://127.0.0.1:포트 (TLS 없이) 로 가짜 서버에 붙인다
    private var base: String { ProcessInfo.processInfo.environment["JINDESK_DAUM_URL"] ?? "imaps://imap.daum.net" }

    private func user() -> String? {
        (try? String(contentsOf: userFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    private func query(_ user: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: user]
    }
    private func password(_ user: String) -> String? {
        var q = query(user); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func status() -> [String: Any] {
        guard let u = user(), password(u) != nil else { return ["configured": false] }
        return ["configured": true, "user": u]
    }

    /// 로그인 시험(안 읽은 메일 검색)에 성공하면 키체인에 저장
    func save(user: String, password: String) async throws -> [String: Any] {
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard u.contains("@"), !password.isEmpty else { throw GErr.bad("Daum 메일 주소와 앱 비밀번호를 입력해 주세요") }
        let n = try await search("UNSEEN", user: u, pass: password).count
        SecItemDelete(query(u) as CFDictionary)
        var add = query(u); add[kSecValueData as String] = Data(password.utf8)
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw GErr.bad("키체인에 저장하지 못했습니다") }
        try FileManager.default.createDirectory(at: SUPPORT, withIntermediateDirectories: true)
        try u.write(to: userFile, atomically: true, encoding: .utf8)
        return ["configured": true, "user": u, "unread": n]
    }

    func clear() {
        if let u = user() { SecItemDelete(query(u) as CFDictionary) }
        try? FileManager.default.removeItem(at: userFile)
    }

    /// unread: 안 읽은 메일만 / 아니면 받은편지함 전체. 최신 순으로 offset부터 limit개
    func list(unread: Bool, limit: Int, offset: Int) async throws -> [String: Any] {
        guard let u = user(), let p = password(u) else { throw GErr.bad("Daum 메일이 연결되어 있지 않습니다") }
        let unseen = try await search("UNSEEN", user: u, pass: p)
        let all = unread ? unseen : try await search("ALL", user: u, pass: p)
        let sorted = all.sorted(by: >)
        let page = Array(sorted.dropFirst(max(offset, 0)).prefix(max(1, min(limit, 50))))
        var items: [[String: Any]] = []
        if !page.isEmpty {
            let d = try await fetchHeaders(page, user: u, pass: p)
            let byUid = Dictionary(DaumParse.fetches(d).map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
            for uid in page {
                guard let m = byUid[uid] else { continue }
                let h = DaumParse.headers(m.header)
                var it: [String: Any] = ["uid": uid, "unread": !m.seen, "from": DaumParse.senderName(h["from"] ?? ""),
                                         "subject": h["subject"] ?? ""]
                if let t = h["date"].flatMap(DaumParse.date) { it["t"] = t }
                items.append(it)
            }
        }
        return ["items": items, "total": sorted.count, "unreadTotal": unseen.count]
    }

    /// 메일 한 통의 본문(글자만, 최대 4000자). BODY.PEEK라 읽음 표시는 그대로.
    func body(uid: Int) async throws -> String {
        guard let u = user(), let p = password(u) else { throw GErr.bad("Daum 메일이 연결되어 있지 않습니다") }
        let c = try await IMAPConn.open(base: base, user: u, pass: p)
        defer { c.close() }
        let d = try await c.command("UID FETCH \(uid) (UID BODY.PEEK[]<0.60000>)")
        guard let m = DaumParse.fetches(d).first else { return "" }
        return String(DaumParse.bodyText(m.header).prefix(4000))
    }

    /// 받은편지함의 안 읽은 메일을 모두 읽음으로 (dryRun이면 개수만). undoFile을 주면 그 백업의 UID를 다시 안 읽음으로.
    /// 메일은 지우지 않고 \Seen 표시만 바꾼다. 실제로 바꾸기 전에 data/Daum-읽음처리-백업-<시각>.json에 UID를 남긴다.
    func markRead(dryRun: Bool, undoFile: String? = nil) async throws -> [String: Any] {
        guard let u = user(), let p = password(u) else { throw GErr.bad("Daum 메일이 연결되어 있지 않습니다") }
        var uids: [Int]
        if let f = undoFile {
            uids = (try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: f))) as? [String: Any])?["uids"] as? [Int] ?? []
        } else {
            uids = try await search("UNSEEN", user: u, pass: p)
        }
        if dryRun { return ["messages": uids.count] }
        var backup = ""
        if undoFile == nil, !uids.isEmpty {
            let f = DATA_DIR.appendingPathComponent("Daum-읽음처리-백업-\(Int(Date().timeIntervalSince1970)).json")
            try FileManager.default.createDirectory(at: DATA_DIR, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["at": ISO8601DateFormatter().string(from: Date()), "user": u, "uids": uids]).write(to: f)
            backup = f.path
        }
        if !uids.isEmpty {
            let c = try await IMAPConn.open(base: base, user: u, pass: p, readOnly: false)
            defer { c.close() }
            let op = undoFile == nil ? "+FLAGS.SILENT" : "-FLAGS.SILENT"
            for i in stride(from: 0, to: uids.count, by: 300) {     // 명령 한 줄이 너무 길어지지 않게 300개씩
                let chunk = uids[i..<min(i + 300, uids.count)].map(String.init).joined(separator: ",")
                _ = try await c.command("UID STORE \(chunk) \(op) (\\Seen)")
            }
        }
        return ["messages": uids.count, "backup": backup, "undo": undoFile != nil]
    }

    private func search(_ what: String, user: String, pass: String) async throws -> [Int] {
        let c = try await IMAPConn.open(base: base, user: user, pass: pass)
        defer { c.close() }
        return DaumParse.uids(String(decoding: try await c.command("UID SEARCH \(what)"), as: UTF8.self))
    }

    private func fetchHeaders(_ uids: [Int], user: String, pass: String) async throws -> Data {
        let c = try await IMAPConn.open(base: base, user: user, pass: pass)
        defer { c.close() }
        return try await c.command("UID FETCH \(uids.map(String.init).joined(separator: ",")) (UID FLAGS BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])")
    }
}

/// 최소 IMAP 클라이언트 (기본은 읽기 전용: EXAMINE + PEEK → 읽음 상태가 바뀌지 않는다. readOnly: false면 SELECT)
final class IMAPConn: @unchecked Sendable {
    private let conn: NWConnection
    private var buf = Data()
    private var n = 0
    private init(_ c: NWConnection) { conn = c }

    static func open(base: String, user: String, pass: String, readOnly: Bool = true) async throws -> IMAPConn {
        guard let u = URLComponents(string: base), let host = u.host else { throw GErr.bad("Daum 서버 주소가 올바르지 않습니다") }
        let tls = u.scheme == "imaps"
        let c = IMAPConn(NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(u.port ?? (tls ? 993 : 143)))!, using: tls ? .tls : .tcp))
        do {
            try await withTimeout(30) {
                try await c.start()
                _ = try await c.readLine()     // 인사말
                let ok = try await c.run("LOGIN \(quote(user)) \(quote(pass))")
                guard ok.ok else { throw GErr.bad("Daum 로그인에 실패했습니다. 메일 주소와 앱 비밀번호, Daum 메일의 IMAP 사용 설정을 확인해 주세요") }
                let ex = try await c.run(readOnly ? "EXAMINE INBOX" : "SELECT INBOX")
                guard ex.ok else { throw GErr.bad("받은편지함을 열지 못했습니다") }
            }
        } catch { c.close(); throw error is GErr ? error : GErr.bad("Daum 메일 서버에 연결하지 못했습니다. 네트워크를 확인해 주세요") }
        return c
    }

    func close() { conn.cancel() }

    func command(_ cmd: String) async throws -> Data {
        try await withTimeout(40) {
            let r = try await self.run(cmd)
            guard r.ok else { throw GErr.bad("Daum 메일 요청이 거부되었습니다") }
            return r.data
        }
    }

    // ---- 아래는 내부 ----
    private static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    private func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var done = false
            conn.stateUpdateHandler = { st in
                if done { return }
                switch st {
                case .ready: done = true; c.resume()
                case .failed(let e): done = true; c.resume(throwing: e)
                case .cancelled: done = true; c.resume(throwing: GErr.bad("연결이 닫혔습니다"))
                default: break
                }
            }
            conn.start(queue: .global())
        }
    }

    private func fill() async throws {
        let d: Data = try await withCheckedThrowingContinuation { c in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, _, err in
                if let err { c.resume(throwing: err) }
                else if let d, !d.isEmpty { c.resume(returning: d) }
                else { c.resume(throwing: GErr.bad("연결이 닫혔습니다")) }
            }
        }
        buf.append(d)
    }
    private func readLine() async throws -> Data {       // CRLF 제외
        while true {
            if let i = buf.firstIndex(of: 10) {
                var line = buf[buf.startIndex..<i]; if line.last == 13 { line = line.dropLast() }
                let out = Data(line); buf = Data(buf[(i + 1)...]); return out
            }
            try await fill()
        }
    }
    private func readBytes(_ k: Int) async throws -> Data {
        while buf.count < k { try await fill() }
        let out = Data(buf.prefix(k)); buf = Data(buf.dropFirst(k)); return out
    }

    /// 명령을 보내고 태그 응답까지 읽는다. 리터럴({n}) 포함 응답은 원본 바이트 그대로 모아 돌려준다.
    private func run(_ cmd: String) async throws -> (ok: Bool, data: Data) {
        n += 1; let tag = "J\(n)"
        conn.send(content: Data("\(tag) \(cmd)\r\n".utf8), completion: .contentProcessed { _ in })
        var all = Data()
        while true {
            var line = try await readLine()
            if String(decoding: line, as: UTF8.self).hasPrefix(tag + " ") {
                return (String(decoding: line, as: UTF8.self).dropFirst(tag.count + 1).uppercased().hasPrefix("OK"), all)
            }
            all.append(line)
            while let lit = Self.literalLen(line) {           // "...{123}" 뒤 123바이트 + 이어지는 줄
                all.append(Data("\r\n".utf8)); all.append(try await readBytes(lit))
                line = try await readLine(); all.append(line)
            }
            all.append(Data("\r\n".utf8))
        }
    }
    private static func literalLen(_ line: Data) -> Int? {
        guard line.last == UInt8(ascii: "}"), let o = line.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        return Int(String(decoding: line[(o + 1)..<(line.endIndex - 1)], as: UTF8.self))
    }
}

func withTimeout<T: Sendable>(_ sec: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await op() }
        g.addTask { try await Task.sleep(nanoseconds: UInt64(sec * 1e9)); throw GErr.bad("Daum 메일 서버 응답이 없습니다") }
        let r = try await g.next()!; g.cancelAll(); return r
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
