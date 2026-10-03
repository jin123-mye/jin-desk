// WidgetKit 위젯용 데이터: 앱이 Google에서 받아 요약해 JinDesk/widget/data.json에 쓰고, 바뀌면 위젯을 다시 그리게 한다.
// 위젯(샌드박스)은 이 폴더만 읽기 전용으로 읽는다. 메일 2분·일정/드라이브 5분 간격 (대시보드 페이지와 같은 입력).
import Foundation
import WidgetKit

let WIDGET_DIR = SUPPORT.appendingPathComponent("widget")
let WIDGET_FILE = WIDGET_DIR.appendingPathComponent("data.json")
// 광고 표시: 제목의 (광고)·[광고]·(AD) (페이지의 AD_RE와 같다)
let AD_RE = try! NSRegularExpression(pattern: "[\\(\\[【〔<]\\s*(광고|AD)\\s*[\\)\\]】〕>]", options: [.caseInsensitive])

final class WidgetFeed {
    static let shared = WidgetFeed()
    var hideAds: Bool {
        get { UserDefaults.standard.object(forKey: "hideAds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hideAds") }
    }
    private var daum: (unread: Int, items: [[String: Any]])?      // Daum 메일 (연결돼 있을 때만)
    private var mail: [String: Any]?, cal: [[String: Any]]?, driveWeek: Int?
    private var error: String?
    private var lastWritten = Data()
    private var timers: [Timer] = []

    func start() {
        try? FileManager.default.createDirectory(at: WIDGET_DIR, withIntermediateDirectories: true)
        refreshMail(); refreshCalDrive(); refreshDaum()
        timers = [Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.refreshMail(); self?.refreshDaum() },
                  Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refreshCalDrive() }]
        timers.forEach { RunLoop.main.add($0, forMode: .common) }
    }
    func refreshAll() { refreshMail(); refreshCalDrive(); refreshDaum() }

    /// Daum 메일 안 읽은 것 (연결 안 됐거나 실패하면 조용히 건너뜀 → 위젯은 Gmail만)
    func refreshDaum() {
        Task {
            guard (await DaumMail.shared.status())["configured"] as? Bool == true else {
                await MainActor.run { if self.daum != nil { self.daum = nil; self.write() } }; return
            }
            guard let r = try? await DaumMail.shared.list(unread: true, limit: 10, offset: 0) else { return }
            let items = (r["items"] as? [[String: Any]] ?? []).map { m -> [String: Any] in
                var o: [String: Any] = ["from": m["from"] as? String ?? "", "subject": m["subject"] as? String ?? "", "url": "https://mail.daum.net/", "src": "Daum"]
                if let t = m["t"] { o["t"] = t }
                return o
            }
            await MainActor.run { self.daum = (r["unreadTotal"] as? Int ?? items.count, items); self.write() }
        }
    }

    func refreshMail() {
        let q = "in:inbox is:unread" + (hideAds ? " -category:promotions -category:social -subject:광고" : "")
        Task {
            do {
                let p = try await Google.shared.call(server: "Gmail", tool: "search_threads", input: ["query": q, "pageSize": 15])
                await MainActor.run { self.mail = p; self.error = nil; self.write() }
            } catch { await MainActor.run { self.error = (error as? GErr)?.message ?? error.localizedDescription; self.write() } }
        }
    }
    func refreshCalDrive() {
        let start = Calendar.current.startOfDay(for: Date()), end = start.addingTimeInterval(30 * 86400)   // 오늘 일정이 없을 때 "다음 일정"을 보여 주려고 30일치
        let iso = ISO8601DateFormatter()
        Task {
            do {
                let c = try await Google.shared.call(server: "Google Calendar", tool: "list_events",
                                                     input: ["startTime": iso.string(from: start), "endTime": iso.string(from: end), "orderBy": "startTime", "pageSize": 50])
                let d = try await Google.shared.call(server: "Google Drive", tool: "list_recent_files",
                                                     input: ["pageSize": 12, "orderBy": "recency", "excludeContentSnippets": true])
                let weekAgo = Date().addingTimeInterval(-7 * 86400)
                let week = (d["files"] as? [[String: Any]] ?? []).filter { (($0["modifiedTime"] as? String).flatMap(parseISO) ?? .distantPast) >= weekAgo }.count
                await MainActor.run { self.cal = c["events"] as? [[String: Any]] ?? []; self.driveWeek = week; self.write() }
            } catch { await MainActor.run { self.error = (error as? GErr)?.message ?? error.localizedDescription; self.write() } }
        }
    }

    // ---- 요약 → data.json ----
    private func write() {
        // 켜진 직후 메일만 먼저 오면 일정이 빈 채로 그려지니, 둘 다 한 번 받은 뒤(또는 오류)부터 쓴다
        guard (mail != nil && cal != nil) || error != nil else { return }
        let now = Date()
        var mails: [[String: Any]] = [], todayMail: Int? = nil, unread: Int? = nil, exact = false
        var items: [[String: Any]] = []
        if let m = mail {
            let threads = (m["threads"] as? [[String: Any]] ?? []).filter { th in
                !hideAds || !((th["messages"] as? [[String: Any]]) ?? []).contains { isAd($0["subject"] as? String ?? "") }
            }
            items = threads.map { th in
                let last = (th["messages"] as? [[String: Any]])?.last ?? [:]
                let t = Double(last["internalDate"] as? String ?? "")
                var o: [String: Any] = ["from": senderName(last["sender"] as? String ?? ""), "subject": last["subject"] as? String ?? "", "src": "Gmail"]
                if let t { o["t"] = t }
                if let u = th["viewUrl"] ?? last["viewUrl"] { o["url"] = u }
                return o
            }
            unread = Int(m["resultCountEstimate"] as? String ?? "")
            exact = m["resultCountExact"] as? Bool ?? false
        }
        let gmailUnread = unread
        if let d = daum {                        // Daum 안 읽은 메일을 합친다 (수치·목록·오늘 온 메일)
            items += d.items.filter { !hideAds || !isAd($0["subject"] as? String ?? "") }
            items.sort { ($0["t"] as? Double ?? 0) > ($1["t"] as? Double ?? 0) }
            unread = (unread ?? 0) + d.unread
        }
        if mail != nil || daum != nil {
            mails = Array(items.prefix(6))
            todayMail = items.filter { ($0["t"] as? Double).map { Calendar.current.isDate(Date(timeIntervalSince1970: $0 / 1000), inSameDayAs: now) } ?? false }.count
        }
        let events: [[String: Any]] = (cal ?? []).filter { ($0["status"] as? String) != "cancelled" }.compactMap { e in
            guard let s = evTime(e["start"]) else { return nil }
            let allDay = ((e["start"] as? [String: Any])?["dateTime"] == nil)
            var o: [String: Any] = ["title": e["summary"] as? String ?? "", "start": s * 1000, "end": (evTime(e["end"]) ?? s) * 1000, "allDay": allDay]
            if let u = e["htmlLink"] { o["url"] = u }
            return o
        }.sorted { ($0["start"] as! Double) < ($1["start"] as! Double) }
        writeDeskSnapshot(items: items, gmailUnread: gmailUnread, daumUnread: daum?.unread, events: events)
        var j: [String: Any] = ["unreadExact": exact, "hideAds": hideAds, "events": events, "mails": mails]
        if let unread { j["unread"] = unread }
        if let todayMail { j["todayMail"] = todayMail }
        if let driveWeek { j["driveWeek"] = driveWeek }
        if let error { j["error"] = error }
        // 내용이 바뀐 때만 파일을 쓰고 위젯을 다시 그리게 한다 (위젯 새로 그리기는 하루 횟수 제한이 있다)
        guard let body = try? JSONSerialization.data(withJSONObject: j, options: .sortedKeys), body != lastWritten else { return }
        lastWritten = body
        j["updatedAt"] = now.timeIntervalSince1970 * 1000
        guard let out = try? JSONSerialization.data(withJSONObject: j, options: .sortedKeys) else { return }
        try? out.write(to: WIDGET_FILE, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
        if CommandLine.arguments.contains("--feed-test") { print("[feed] 씀 \(out.count)B unread=\(unread.map(String.init) ?? "-") events=\(events.count) mails=\(mails.count) err=\(error ?? "-")") }
    }

    // ---- 자비스용 스냅샷: 옵시디언 볼트의 숨김 폴더(.jarvis-desk)에 요약을 쓴다 → Syncthing이 파이로도 옮김.
    // 숨김 폴더라 노트 색인(.md만·숨김 제외)에 안 섞인다. 메일 본문은 없고 보낸 곳·제목·시각만.
    private var lastSnap = Data()
    private func writeDeskSnapshot(items: [[String: Any]], gmailUnread: Int?, daumUnread: Int?, events: [[String: Any]]) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Obsidian Vault/.jarvis-desk")
        guard FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().path) else { return }
        let subs = (try? JSONSerialization.jsonObject(with: Data(contentsOf: DATA_DIR.appendingPathComponent("subscriptions.json")))) ?? NSNull()
        let mails = items.prefix(20).map { m -> [String: Any] in
            ["src": m["src"] ?? "", "from": m["from"] ?? "", "subject": m["subject"] ?? "", "t": m["t"] ?? NSNull()]
        }
        var snap: [String: Any] = ["mail": ["gmailUnread": (gmailUnread.map { $0 as Any } ?? NSNull()), "daumUnread": (daumUnread.map { $0 as Any } ?? NSNull()), "items": mails] as [String: Any],
                                   "events": events, "subscriptions": subs]
        guard let body = try? JSONSerialization.data(withJSONObject: snap, options: .sortedKeys), body != lastSnap else { return }
        lastSnap = body
        snap["updatedAt"] = Date().timeIntervalSince1970 * 1000
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: snap, options: [.sortedKeys, .prettyPrinted]).write(to: dir.appendingPathComponent("desk.json"), options: .atomic)
        } catch { NSLog("자비스 스냅샷 쓰기 실패: \(error.localizedDescription)") }
    }

    private func isAd(_ s: String) -> Bool { AD_RE.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
    private func senderName(_ s: String) -> String {
        if let r = s.range(of: "^\\s*\"?([^\"<]+?)\"?\\s*<", options: .regularExpression) {
            return String(s[r]).replacingOccurrences(of: "[\"<]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        return s
    }
    // 일정 시각: dateTime은 오프셋 포함 ISO, 종일은 date(앞 10자)를 현지 자정으로
    private func evTime(_ v: Any?) -> Double? {
        guard let o = v as? [String: Any] else { return nil }
        if let s = o["dateTime"] as? String { return parseISO(s)?.timeIntervalSince1970 }
        if let s = o["date"] as? String {
            let p = s.prefix(10).split(separator: "-").compactMap { Int($0) }
            guard p.count == 3 else { return nil }
            return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))?.timeIntervalSince1970
        }
        return nil
    }
}

func parseISO(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s)
}
