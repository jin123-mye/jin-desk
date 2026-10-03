// 메일 → 캘린더 자동 추가 (규칙 기반, 무료·메일 내용이 밖으로 나가지 않음)
// 10분마다 새 메일(광고·프로모션·소셜 제외)을 읽어 아래 규칙에 맞으면 기본 캘린더에 일정을 넣고 알림을 띄운다.
//  1) 구글 캘린더 "일정 추가" 링크(action=TEMPLATE) — 행사·예매 확인 메일에 흔함 → 제목·시간·장소 그대로
//  2) 캘린더 초대 파일(.ics / text/calendar) → DTSTART·DTEND·SUMMARY·LOCATION
//  3) "다음 결제일 : 2026년 10월 03일" → 종일 "<보낸 곳> 결제일"
//  4) "평가판 종료: 10월 6일", "무료 체험 … 종료 … 10월 6일" → 종일 "<보낸 곳> 무료 체험 종료"
//  5) "2026. 9. 20.에 자동으로 갱신" → 종일 "<보낸 곳> 자동 갱신"
//  6) "일시/일정/날짜/마감/기한/예약일/행사일/시험일 : <날짜> [시각]" 줄 → 메일 제목으로
// 결제 규칙(Gmail·Daum 공통): 다음 결제일/청구일, 갱신일·갱신 날짜, 무료 체험 종료, 자동 갱신, 영수증의 이용 기간 끝(Anthropic식 "Sep 15–Oct 15, 2026"),
//   결제 실패 안내(보낸 곳마다 14일에 한 번만 "결제수단 확인" 일정).
// Daum 메일은 6시간에 한 번, 제목·보낸 곳에 결제 관련 낱말이 있는 새 메일만 본문(BODY.PEEK)을 읽어 같은 결제 규칙으로 훑는다(느슨한 6번 규칙은 안 씀).
// 같은 메일은 한 번만(처리 기록 data/mail-calendar.json), 같은 날 같은 제목 일정이 있으면 건너뛴다.
// 넣은 일정: 설명에 "진의 데스크 자동 추가" + 원본 메일 링크, extendedProperties.private.jindeskMsg = 메일 ID.
import Foundation

let MAILCAL_STATE = DATA_DIR.appendingPathComponent("mail-calendar.json")
let MAILCAL_LOG = DATA_DIR.appendingPathComponent("mail-calendar.log")

struct CalCandidate {
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String?
    var rule: String
}

final class MailCalendar {
    static let shared = MailCalendar()
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "mailCalendar") as? Bool ?? false }   // 캘린더에 쓰는 기능이라 처음엔 꺼 두고 메뉴에서 켠다
        set { UserDefaults.standard.set(newValue, forKey: "mailCalendar") }
    }
    var notify: (String, String) -> Void = { _, _ in }
    private var timer: Timer?
    private var running = false
    private let kst = TimeZone.current

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.runOnce() }
        RunLoop.main.add(timer!, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.runOnce() }
    }

    // ---- 처리 기록 ----
    private func loadState() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: MAILCAL_STATE))) as? [String: Any] ?? [:]
    }
    private func saveState(_ s: [String: Any]) {
        try? FileManager.default.createDirectory(at: DATA_DIR, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: s).write(to: MAILCAL_STATE, options: .atomic)
    }
    func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines = ((try? String(contentsOf: MAILCAL_LOG, encoding: .utf8)) ?? "").split(separator: "\n").suffix(500).map(String.init)
        lines.append("\(stamp) \(line)")
        try? (lines.joined(separator: "\n") + "\n").write(to: MAILCAL_LOG, atomically: true, encoding: .utf8)
    }

    // ---- 한 번 훑기: 마지막 확인 이후 새 메일 ----
    func runOnce(dryRun: Bool = false, onlyMessage: String? = nil, done: (([String]) -> Void)? = nil) {
        guard (enabled || dryRun), !running else { done?([]); return }
        if !dryRun && !Google.shared.canWriteCalendar() {   // 예전 토큰(캘린더 읽기 전용)이면 건너뛴다
            log("캘린더 쓰기 권한 없음 — 메뉴에서 Google 연결 해제 후 다시 연결 필요"); done?(["캘린더 쓰기 권한 없음"]); return
        }
        running = true
        Task {
            var report: [String] = []
            defer { running = false; DispatchQueue.main.async { done?(report) } }
            var state = loadState()
            let now = Date()
            // 처음 켤 때는 지금부터 온 메일만 (이미 손으로 넣은 일정과 겹치지 않게)
            let since = (state["since"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? now
            if state["since"] == nil && onlyMessage == nil { state["since"] = now.timeIntervalSince1970; saveState(state); report.append("처음 켜짐: 지금부터 오는 메일을 봅니다"); return }
            var processed = Set(state["processed"] as? [String] ?? [])
            do {
                var ids: [String] = []
                if let m = onlyMessage { ids = [m] } else {
                    let q = "after:\(Int(since.timeIntervalSince1970) - 3600) -category:promotions -category:social -in:sent -in:chats"
                    var u = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
                    u.queryItems = [.init(name: "q", value: q), .init(name: "maxResults", value: "50")]
                    let list = try await Google.shared.request(u.url!) as? [String: Any] ?? [:]
                    ids = (list["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.filter { !processed.contains($0) }
                }
                for id in ids.reversed() {   // 오래된 것부터
                    let msg = try await Google.shared.request(URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full")!) as? [String: Any] ?? [:]
                    let cands = extract(msg)
                    for c in cands {
                        if !dryRun && !failCooldown(c, &state) { continue }
                        let line = "\(c.rule) | \(c.title) | \(c.allDay ? day(c.start) : "\(day(c.start)) \(hm(c.start))–\(hm(c.end))")\(c.location.map { " | \($0)" } ?? "") | 메일 \(id)"
                        if dryRun { report.append("[미리보기] " + line); continue }
                        if try await exists(c) { report.append("[이미 있음] " + line); log("이미 있음 " + line); continue }
                        try await create(c, messageId: id)
                        report.append("[추가] " + line); log("추가 " + line)
                        let when = c.allDay ? day(c.start) : "\(day(c.start)) \(hm(c.start))"
                        await MainActor.run { self.notify("캘린더에 추가했습니다", "\(c.title) · \(when)") }
                    }
                    if !dryRun { processed.insert(id) }
                }
                if onlyMessage == nil { await scanDaum(dryRun: dryRun, force: dryRun, state: &state, report: &report) }
                if !dryRun && onlyMessage == nil {
                    state["processed"] = Array(processed.suffix(2000))
                    state["lastRun"] = now.timeIntervalSince1970
                    saveState(state)
                }
            } catch {
                let m = (error as? GErr)?.message ?? error.localizedDescription
                report.append("오류: \(m)"); log("오류 \(m)")
            }
        }
    }

    // ---- Daum 메일 훑기 (6시간마다, 결제 관련 새 메일만 본문을 읽음) ----
    private let daumHint = try! NSRegularExpression(pattern: "결제|청구|갱신|구독|영수증|이용대금|만료|체험|승인|receipt|invoice|payment|subscription|renew|billing|trial|declined", options: [.caseInsensitive])
    private func scanDaum(dryRun: Bool, force: Bool, state: inout [String: Any], report: inout [String]) async {
        guard (await DaumMail.shared.status())["configured"] as? Bool == true else { return }
        let now = Date()
        if !force, let last = state["daumLast"] as? Double, now.timeIntervalSince1970 - last < 6 * 3600 { return }
        if !dryRun && state["daumSince"] == nil {
            state["daumSince"] = now.timeIntervalSince1970; state["daumLast"] = now.timeIntervalSince1970
            report.append("Daum: 처음 켜짐 — 지금부터 오는 메일을 봅니다"); log("Daum 처음 켜짐"); return
        }
        let since = (state["daumSince"] as? Double) ?? 0
        var processed = Set(state["daumProcessed"] as? [String] ?? [])
        do {
            var all: [[String: Any]] = []
            for off in stride(from: 0, to: dryRun ? 400 : 50, by: 50) {     // 점검(dryRun)은 400통까지 훑는다
                let r = try await DaumMail.shared.list(unread: false, limit: 50, offset: off)
                let page = r["items"] as? [[String: Any]] ?? []
                all += page; if page.count < 50 { break }
            }
            let items = all.sorted { ($0["uid"] as? Int ?? 0) < ($1["uid"] as? Int ?? 0) }
            for m in items {
                guard let uid = m["uid"] as? Int else { continue }
                let key = "d\(uid)"
                let t = (m["t"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? now
                if !dryRun && (processed.contains(key) || t.timeIntervalSince1970 < since - 3600) { continue }
                let subject = m["subject"] as? String ?? "", from = m["from"] as? String ?? ""
                if !dryRun { processed.insert(key) }
                if subject.range(of: "[\\(\\[]\\s*광고\\s*[\\)\\]]", options: .regularExpression) != nil { continue }
                let hay = subject + " " + from
                if daumHint.firstMatch(in: hay, range: NSRange(hay.startIndex..., in: hay)) == nil { continue }
                let body = (try? await DaumMail.shared.body(uid: uid)) ?? ""
                for c in paymentRules(subject: subject, sender: from, text: body, mailDate: t) {
                    if !dryRun && !failCooldown(c, &state) { continue }
                    let line = "\(c.rule) | \(c.title) | \(day(c.start)) | Daum 메일 \(uid) 「\(subject)」"
                    if dryRun { report.append("[Daum 미리보기] " + line); continue }
                    if try await exists(c) { report.append("[이미 있음] " + line); log("이미 있음 " + line); continue }
                    try await create(c, messageId: "daum:\(uid)", note: "Daum 메일 「\(subject)」 (\(from), \(day(t)))")
                    report.append("[추가] " + line); log("추가 " + line)
                    await MainActor.run { self.notify("캘린더에 추가했습니다", "\(c.title) · \(self.day(c.start))") }
                }
            }
            if !dryRun { state["daumProcessed"] = Array(processed.suffix(2000)); state["daumLast"] = now.timeIntervalSince1970 }
        } catch {
            let m = (error as? GErr)?.message ?? error.localizedDescription
            report.append("Daum 오류: \(m)"); log("Daum 오류 \(m)")
        }
    }
    /// 점검용: 처리 기록과 무관하게 최근 Daum 메일 50통을 훑어 무엇을 넣을지만 보여 준다(캘린더는 안 건드림)
    func daumTest(done: @escaping ([String]) -> Void) {
        Task { var r: [String] = []; var st: [String: Any] = [:]; await scanDaum(dryRun: true, force: true, state: &st, report: &r); DispatchQueue.main.async { done(r) } }
    }

    // ---- 규칙 ----
    func extract(_ msg: [String: Any]) -> [CalCandidate] {
        let labels = msg["labelIds"] as? [String] ?? []
        if labels.contains("CATEGORY_PROMOTIONS") || labels.contains("CATEGORY_SOCIAL") || labels.contains("SPAM") { return [] }
        let payload = msg["payload"] as? [String: Any] ?? [:]
        let headers = payload["headers"] as? [[String: Any]] ?? []
        func h(_ n: String) -> String { headers.first { ($0["name"] as? String)?.lowercased() == n }?["value"] as? String ?? "" }
        let subject = h("subject"), from = h("from")
        if subject.range(of: "[\\(\\[]\\s*광고\\s*[\\)\\]]", options: .regularExpression) != nil { return [] }
        let mailDate = Date(timeIntervalSince1970: (Double(msg["internalDate"] as? String ?? "") ?? Date().timeIntervalSince1970 * 1000) / 1000)
        var html = "", plain = "", ics = ""
        collectParts(payload, &html, &plain, &ics)
        let text = plain.isEmpty ? htmlToText(html) : plain
        let raw = html + "\n" + plain
        let sender = senderLabel(from)
        let newsletter = !h("list-unsubscribe").isEmpty   // 수신거부 링크가 있으면 뉴스레터 → 느슨한 규칙(6)은 쓰지 않는다

        // 1) 구글 캘린더 일정 추가 링크
        var out: [CalCandidate] = []
        for link in matches(raw, "https?://(?:www\\.)?google\\.com/calendar/(?:render|event)\\?[^\"'<>\\s)]+") {
            let s = link.replacingOccurrences(of: "&amp;", with: "&")
            guard let c = URLComponents(string: s), (c.queryItems?.first { $0.name == "action" }?.value ?? "") == "TEMPLATE",
                  let dates = c.queryItems?.first(where: { $0.name == "dates" })?.value else { continue }
            let parts = dates.split(separator: "/").map(String.init)
            guard parts.count == 2, let (st, allDay) = parseCalDate(parts[0]), let (en, _) = parseCalDate(parts[1]) else { continue }
            let title = c.queryItems?.first { $0.name == "text" }?.value ?? subject
            let loc = c.queryItems?.first { $0.name == "location" }?.value
            out.append(CalCandidate(title: title, start: st, end: en, allDay: allDay, location: loc?.isEmpty == false ? loc : nil, rule: "캘린더링크"))
        }
        if !out.isEmpty { return dedup(out) }

        // 2) .ics
        if !ics.isEmpty, let c = parseICS(ics, fallback: subject) { return dedup([c]) }

        out += paymentRules(subject: subject, sender: sender, text: text, mailDate: mailDate)
        if !out.isEmpty { return dedup(out) }

        // 6) "일시/일정/마감…: 날짜 [시각]" 줄 → 메일 제목으로 (뉴스레터 제외)
        if newsletter { return [] }
        let label = "(?:일시|일정|날짜|예약\\s*일시|예약일|행사\\s*일시|행사일|시험\\s*일시|시험일|면접\\s*일시|마감|마감일|기한|제출\\s*기한|접수\\s*마감)"
        if let r = text.range(of: "(?m)^\\s*[•·\\-\\*■□▶]?\\s*\(label)\\s*[:：]\\s*[^\\n]{4,60}", options: .regularExpression) {
            let line = String(text[r])
            if let d = findDate(line, after: "[:：]\\s*", ref: mailDate) {
                let isDeadline = line.range(of: "마감|기한", options: .regularExpression) != nil
                let title = cleanSubject(subject) + (isDeadline ? " (마감)" : "")
                if let t = findTime(line, on: d) {
                    out.append(CalCandidate(title: title, start: t, end: t.addingTimeInterval(3600), allDay: false, location: nil, rule: "일시줄"))
                } else {
                    out.append(allDayCand(title, d, "일시줄"))
                }
            }
        }
        return dedup(out)
    }

    // 결제 관련 규칙 (Gmail·Daum 공통). text는 글자만 남긴 본문
    func paymentRules(subject: String, sender: String, text: String, mailDate: Date) -> [CalCandidate] {
        var out: [CalCandidate] = []
        // 3) 다음 결제일·청구일 / 갱신일·갱신 날짜
        if let d = findDate(text, after: "다음\\s*(?:결제|청구)\\s*(?:예정\\s*)?(?:일|날짜)\\s*[:：]?\\s*", ref: mailDate) {
            out.append(allDayCand("\(sender) 결제일", d, "결제일"))
        } else if let d = findDate(text, after: "(?:다음\\s*)?갱신\\s*(?:예정\\s*)?(?:일|날짜)\\s*[:：]?\\s*", ref: mailDate) {
            out.append(allDayCand("\(sender) 갱신일", d, "갱신일"))
        }
        // 4) 무료 체험·평가판 종료
        if let d = findDate(text, after: "(?:평가판|무료\\s*체험|체험\\s*기간|트라이얼|trial)[^\\n]{0,20}?(?:종료|만료|끝)[^\\n0-9]{0,10}", ref: mailDate) {
            out.append(allDayCand("\(sender) 무료 체험 종료", d, "체험종료"))
        }
        // 5) 자동 갱신
        if let d = findDate(text, before: "\\.?\\s*(?:에|부터)?\\s*자동(?:으로)?\\s*갱신", ref: mailDate) {
            out.append(allDayCand("\(sender) 자동 갱신", d, "자동갱신"))
        }
        // 영수증의 이용 기간 "Sep 15–Oct 15, 2026" → 끝나는 날이 다음 결제일 (추정)
        let lower = text.lowercased()
        if out.isEmpty, lower.contains("receipt") || lower.contains("paid") || lower.contains("invoice"),
           let re = try? NSRegularExpression(pattern: "[A-Z][a-z]{2,8}\\s+\\d{1,2}\\s*[–\\-]\\s*([A-Z][a-z]{2,8})\\s+(\\d{1,2}),\\s*(20\\d{2})"),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges == 4,
           let mr = Range(m.range(at: 1), in: text), let dr = Range(m.range(at: 2), in: text), let yr = Range(m.range(at: 3), in: text),
           let mo = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex(of: String(text[mr].lowercased().prefix(3))),
           let day = Int(text[dr]), let year = Int(text[yr]), let d = Calendar.current.date(from: DateComponents(year: year, month: mo + 1, day: day)) {
            out.append(allDayCand("\(sender) 다음 결제 예정", d, "영수증기간"))
        }
        // 결제 실패 안내 → 결제수단 확인 (보낸 곳마다 14일에 한 번만: runOnce·scanDaum이 걸러 준다)
        let head = subject + " " + String(text.prefix(300))
        if head.range(of: "(결제|청구|이체).{0,10}(실패|거절|오류)|정기\\s*결제가\\s*실패|payment.{0,30}(declined|unsuccessful|failed)|(was|were)\\s+unsuccessful", options: [.regularExpression, .caseInsensitive]) != nil,
           head.range(of: "광고", options: .literal) == nil {
            let tomorrow = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400))
            out.append(allDayCand("\(sender) 결제 실패 — 결제수단 확인", tomorrow, "결제실패"))
        }
        return out
    }
    /// 같은 보낸 곳의 결제 실패 일정은 14일에 한 번만
    private func failCooldown(_ c: CalCandidate, _ state: inout [String: Any]) -> Bool {
        guard c.rule == "결제실패" else { return true }
        var seen = state["failSeen"] as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        if let t = seen[c.title], now - t < 14 * 86400 { return false }
        seen[c.title] = now; state["failSeen"] = seen
        return true
    }

    private func allDayCand(_ title: String, _ d: Date, _ rule: String) -> CalCandidate {
        let s = Calendar.current.startOfDay(for: d)
        return CalCandidate(title: title, start: s, end: s.addingTimeInterval(86400), allDay: true, location: nil, rule: rule)
    }
    // 같은 일정 한 번만, 이미 지난 일정은 뺀다
    private func dedup(_ c: [CalCandidate]) -> [CalCandidate] {
        var seen = Set<String>(); let now = Date()
        return c.filter { $0.end > now && seen.insert("\($0.title)|\($0.start)").inserted }
    }

    // 점검용: 내일 날짜로 시험 일정을 실제로 넣고(같은 코드 경로), 중복 확인까지 한 뒤 결과를 돌려준다. 지우는 건 호출한 쪽에서
    func selfTest() async -> String {
        let t = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400))
        let c = CalCandidate(title: "진의 데스크 자동 추가 시험", start: t, end: t.addingTimeInterval(86400), allDay: true, location: nil, rule: "시험")
        do {
            let before = try await exists(c)
            try await create(c, messageId: "selftest")
            let after = try await exists(c)
            return "넣기 전 있음=\(before) → 넣은 뒤 있음=\(after) (날짜 \(day(t)))"
        } catch { return "오류: \((error as? GErr)?.message ?? error.localizedDescription)" }
    }

    // ---- 캘린더 쓰기 ----
    private func exists(_ c: CalCandidate) async throws -> Bool {
        var u = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        let s = Calendar.current.startOfDay(for: c.start)
        u.queryItems = [.init(name: "timeMin", value: iso(s)), .init(name: "timeMax", value: iso(s.addingTimeInterval(86400 * (c.allDay ? 1 : 1)))),
                        .init(name: "singleEvents", value: "true"), .init(name: "maxResults", value: "50")]
        u.percentEncodedQuery = u.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let j = try await Google.shared.request(u.url!) as? [String: Any] ?? [:]
        let norm = { (s: String) in s.lowercased().replacingOccurrences(of: "\\s+", with: "", options: .regularExpression) }
        let items = j["items"] as? [[String: Any]] ?? []
        if items.contains(where: { norm($0["summary"] as? String ?? "") == norm(c.title) }) { return true }
        // 결제·갱신 알림은 같은 날 결제/갱신 종일 일정이 이미 있으면 중복으로 본다 (제목이 달라도: "Claude Pro 결제 $22.00" vs "Anthropic 다음 결제 예정")
        if c.allDay, ["결제일", "갱신일", "자동갱신", "영수증기간"].contains(c.rule) {
            return items.contains { ($0["start"] as? [String: Any])?["date"] != nil && ($0["summary"] as? String ?? "").range(of: "결제|갱신|구독|renew|payment", options: [.regularExpression, .caseInsensitive]) != nil }
        }
        return false
    }
    private func create(_ c: CalCandidate, messageId: String, note: String? = nil) async throws {
        let link = note ?? "https://mail.google.com/mail/#all/\(messageId)"
        var body: [String: Any] = [
            "summary": c.title,
            "description": "진의 데스크 자동 추가 (규칙: \(c.rule))\n원본 메일: \(link)",
            "extendedProperties": ["private": ["jindeskMsg": messageId]],
            "reminders": ["useDefault": false, "overrides": [["method": "popup", "minutes": c.allDay ? 900 : 60]]],
        ]
        if c.allDay {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = kst
            body["start"] = ["date": f.string(from: c.start)]; body["end"] = ["date": f.string(from: c.end)]
            body["transparency"] = "transparent"
        } else {
            body["start"] = ["dateTime": iso(c.start), "timeZone": kst.identifier]; body["end"] = ["dateTime": iso(c.end), "timeZone": kst.identifier]
        }
        if let l = c.location { body["location"] = l }
        _ = try await Google.shared.request(URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!, method: "POST", body: body)
    }

    // ---- 도우미 ----
    private func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.timeZone = kst; f.formatOptions = [.withInternetDateTime]; return f.string(from: d) }
    private func day(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd(E)"; f.locale = Locale(identifier: "ko_KR"); return f.string(from: d) }
    private func hm(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }

    private func collectParts(_ p: [String: Any], _ html: inout String, _ plain: inout String, _ ics: inout String) {
        let mime = (p["mimeType"] as? String ?? "").lowercased()
        if let data = (p["body"] as? [String: Any])?["data"] as? String, let d = b64url(data) {
            let s = String(decoding: d, as: UTF8.self)
            if mime == "text/html" { html += s } else if mime == "text/plain" { plain += s } else if mime == "text/calendar" { ics += s }
        }
        for c in p["parts"] as? [[String: Any]] ?? [] { collectParts(c, &html, &plain, &ics) }
    }
    private func b64url(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
    private func htmlToText(_ h: String) -> String {
        var s = h.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)<br\\s*/?>|</(p|div|tr|li|h\\d)>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</t[dh]>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (a, b) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] { s = s.replacingOccurrences(of: a, with: b) }
        return s.replacingOccurrences(of: "[ \\t\\u00a0]+", with: " ", options: .regularExpression)
    }
    private func matches(_ s: String, _ p: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: p) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }
    private func senderLabel(_ from: String) -> String {
        if let r = from.range(of: "^\\s*\"?([^\"<]+?)\"?\\s*<", options: .regularExpression) {
            let n = String(from[r]).replacingOccurrences(of: "[\"<]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { return n }
        }
        let dom = from.range(of: "@([A-Za-z0-9.-]+)", options: .regularExpression).map { String(from[$0].dropFirst()) } ?? from
        return dom.split(separator: ".").dropLast().last.map(String.init) ?? dom
    }
    private func cleanSubject(_ s: String) -> String {
        s.replacingOccurrences(of: "^(\\s*(re|fw|fwd)\\s*:\\s*)+", with: "", options: [.regularExpression, .caseInsensitive])
         .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
    // 20261003T060000Z / 20261003T150000 / 20261003
    private func parseCalDate(_ s: String) -> (Date, Bool)? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        if s.count == 8 { f.dateFormat = "yyyyMMdd"; f.timeZone = kst; return f.date(from: s).map { ($0, true) } }
        if s.hasSuffix("Z") { f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; f.timeZone = TimeZone(identifier: "UTC"); return f.date(from: s).map { ($0, false) } }
        f.dateFormat = "yyyyMMdd'T'HHmmss"; f.timeZone = kst; return f.date(from: s).map { ($0, false) }
    }
    private func parseICS(_ ics: String, fallback: String) -> CalCandidate? {
        let t = ics.replacingOccurrences(of: "\r\n[ \t]", with: "", options: .regularExpression)
        func field(_ k: String) -> String? {
            guard let r = t.range(of: "(?m)^\(k)(;[^:\\n]*)?:([^\\r\\n]*)", options: .regularExpression) else { return nil }
            return String(t[r]).components(separatedBy: ":").dropFirst().joined(separator: ":")
        }
        guard let ds = field("DTSTART"), let (st, allDay) = parseCalDate(ds.trimmingCharacters(in: .whitespaces)) else { return nil }
        let en = field("DTEND").flatMap { parseCalDate($0.trimmingCharacters(in: .whitespaces))?.0 } ?? st.addingTimeInterval(allDay ? 86400 : 3600)
        let title = field("SUMMARY")?.replacingOccurrences(of: "\\,", with: ",") ?? fallback
        return CalCandidate(title: title, start: st, end: en, allDay: allDay, location: field("LOCATION")?.replacingOccurrences(of: "\\,", with: ","), rule: "초대파일")
    }

    // 날짜 찾기: 2026년 10월 3일 / 2026. 10. 3. / 2026-10-03 / 2026.10.03 / 10월 3일 / 10.03(토) / 10/3
    private let datePats = [
        "(20\\d{2})\\s*년\\s*(\\d{1,2})\\s*월\\s*(\\d{1,2})\\s*일",
        "(20\\d{2})\\s*[.\\-/]\\s*(\\d{1,2})\\s*[.\\-/]\\s*(\\d{1,2})",
        "()(\\d{1,2})\\s*월\\s*(\\d{1,2})\\s*일",
        "()(\\d{1,2})[./](\\d{1,2})\\s*\\(",
    ]
    private func findDate(_ text: String, after prefix: String = "", before suffix: String = "", ref: Date) -> Date? {
        for p in datePats {
            let pat = prefix + p + suffix
            guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges >= 4 else { continue }
            func g(_ i: Int) -> Int? { Range(m.range(at: i), in: text).flatMap { Int(text[$0]) } }
            guard let mo = g(2), let d = g(3), (1...12).contains(mo), (1...31).contains(d) else { continue }
            var y = g(1) ?? Calendar.current.component(.year, from: ref)
            var dc = DateComponents(year: y, month: mo, day: d)
            if g(1) == nil, let cand = Calendar.current.date(from: dc), cand < ref.addingTimeInterval(-30 * 86400) { y += 1; dc.year = y }
            return Calendar.current.date(from: dc)
        }
        return nil
    }
    // 시각: 15:00 / 오후 3시 / 오후 3시 30분
    private func findTime(_ line: String, on day: Date) -> Date? {
        var h: Int?, mi = 0
        if let r = line.range(of: "(오전|오후)?\\s*(\\d{1,2}):(\\d{2})", options: .regularExpression) {
            let s = String(line[r]); let nums = s.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.compactMap(Int.init)
            if nums.count >= 2 { h = nums[0]; mi = nums[1]; if s.contains("오후") && h! < 12 { h! += 12 } }
        } else if let r = line.range(of: "(오전|오후)\\s*(\\d{1,2})\\s*시(\\s*(\\d{1,2})\\s*분)?", options: .regularExpression) {
            let s = String(line[r]); let nums = s.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.compactMap(Int.init)
            if let first = nums.first { h = first; mi = nums.count > 1 ? nums[1] : 0; if s.contains("오후") && h! < 12 { h! += 12 } }
        }
        guard let hh = h, hh < 24 else { return nil }
        return Calendar.current.date(bySettingHour: hh, minute: mi, second: 0, of: day)
    }
}
