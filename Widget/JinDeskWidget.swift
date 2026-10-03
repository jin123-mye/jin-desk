// 진의 데스크 — macOS WidgetKit 위젯 (앱 안 PlugIns/JinDeskWidget.appex)
// 데이터는 진의 데스크 앱이 ~/Library/Application Support/JinDesk/widget/data.json에 써 주고,
// 위젯은 샌드박스 예외(읽기 전용)로 그 파일만 읽는다. 흑백 전환·격자·편집·미션 컨트롤은 macOS가 처리한다.
import WidgetKit
import SwiftUI
import os

// 점검용 기록: 읽었는지·개수만 남긴다(제목 같은 내용은 안 남김). 보기: /usr/bin/log show --predicate 'subsystem == "com.jin.desk.widget"'
let wlog = Logger(subsystem: "com.jin.desk.widget", category: "feed")

// ---- 데이터 (앱의 WidgetFeed와 같은 모양) ----
struct Feed: Codable {
    struct Event: Codable { let title: String; let start: Double; let end: Double; let allDay: Bool; let url: String? }
    struct Mail: Codable { let from: String; let subject: String; let t: Double?; let url: String?; let src: String? }
    let updatedAt: Double
    let error: String?
    let unread: Int?
    let unreadExact: Bool
    let hideAds: Bool
    let todayMail: Int?
    let driveWeek: Int?
    let events: [Event]
    let mails: [Mail]
}

func feedURL() -> URL {
    // 샌드박스 안에서는 홈이 컨테이너로 바뀌므로 실제 홈 경로를 쓴다
    let home = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/JinDesk/widget/data.json")
}
func loadFeed() -> Feed? {
    guard let d = try? Data(contentsOf: feedURL()) else { return nil }
    return try? JSONDecoder().decode(Feed.self, from: d)
}

struct DeskEntry: TimelineEntry { let date: Date; let feed: Feed?; let preview: Bool }

// 위젯 갤러리 미리보기용 예시 (지어낸 값)
let SAMPLE: Feed = {
    let now = Date().timeIntervalSince1970 * 1000, h = 3_600_000.0
    return Feed(updatedAt: now, error: nil, unread: 12, unreadExact: true, hideAds: true, todayMail: 3, driveWeek: 4,
                events: [.init(title: "캡스톤 팀 회의", start: now + h, end: now + 2 * h, allDay: false, url: nil),
                         .init(title: "알고리즘 스터디", start: now + 5 * h, end: now + 6 * h, allDay: false, url: nil)],
                mails: [.init(from: "학과 사무실", subject: "중간고사 일정 안내", t: now - h, url: nil, src: "Gmail"),
                        .init(from: "스터디", subject: "이번 주 문제 공유", t: now - 3 * h, url: nil, src: "Daum")])
}()

struct Provider: TimelineProvider {
    func placeholder(in c: Context) -> DeskEntry { DeskEntry(date: Date(), feed: SAMPLE, preview: true) }
    func getSnapshot(in c: Context, completion: @escaping (DeskEntry) -> Void) {
        completion(DeskEntry(date: Date(), feed: c.isPreview ? (loadFeed() ?? SAMPLE) : loadFeed(), preview: c.isPreview && loadFeed() == nil))
    }
    // 같은 데이터로 5분 간격 항목을 1시간치 만든다(‘N분 후’·‘진행 중’이 저절로 바뀌게). 새 데이터는 앱이 다시 그려 달라고 알린다
    func getTimeline(in c: Context, completion: @escaping (Timeline<DeskEntry>) -> Void) {
        let f = loadFeed(), now = Date()
        wlog.log("timeline \(c.family.description, privacy: .public) 파일=\(f != nil ? "읽음" : "못 읽음", privacy: .public) 안읽은=\(f?.unread ?? -1, privacy: .public) 일정=\(f?.events.count ?? -1, privacy: .public) 메일=\(f?.mails.count ?? -1, privacy: .public) 오류=\(f?.error != nil, privacy: .public)")
        let entries = (0..<12).map { DeskEntry(date: now.addingTimeInterval(Double($0) * 300), feed: f, preview: false) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

// ---- 보기 ----
let CAL = Color(red: 0.42, green: 0.29, blue: 0.77), MAIL = Color(red: 0.18, green: 0.34, blue: 0.78), DRIVE = Color(red: 0.09, green: 0.50, blue: 0.37)
let DOW = ["일", "월", "화", "수", "목", "금", "토"]

func hm(_ ms: Double) -> String { let d = Date(timeIntervalSince1970: ms / 1000); let c = Calendar.current.dateComponents([.hour, .minute], from: d); return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) }
func rel(_ ms: Double?, now: Date) -> String {
    guard let ms else { return "" }
    let m = Int((now.timeIntervalSince1970 * 1000 - ms) / 60000)
    if m < 1 { return "방금" }; if m < 60 { return "\(m)분 전" }
    let d = Date(timeIntervalSince1970: ms / 1000)
    if Calendar.current.isDate(d, inSameDayAs: now) { return "\(m / 60)시간 전" }
    let c = Calendar.current.dateComponents([.month, .day], from: d); return "\(c.month ?? 0)/\(c.day ?? 0)"
}
// 보낸 사람이 길면 앞 n글자만 (긴 제목이 남는 자리에서 말줄임되게)
func short(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }
func goURL(_ s: String?) -> URL? {   // 누르면 앱이 받아서 브라우저로 연다
    guard let s, let e = s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
    return URL(string: "jindesk://go?u=\(e)")
}

struct Stat: View {
    let label: String, value: String, color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 6, height: 6).widgetAccentable(); Text(label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DeskView: View {
    @Environment(\.widgetFamily) var family
    let entry: DeskEntry
    var f: Feed? { entry.feed }
    var now: Date { entry.date }
    var nowMs: Double { now.timeIntervalSince1970 * 1000 }
    var tomorrowMs: Double { (Calendar.current.startOfDay(for: now).addingTimeInterval(86400)).timeIntervalSince1970 * 1000 }
    var todayLeft: [Feed.Event] { (f?.events ?? []).filter { $0.end > nowMs && $0.start < tomorrowMs } }
    func num(_ v: Int?) -> String { v.map { $0.formatted() } ?? "—" }
    var unreadText: String { guard let u = f?.unread else { return "—" }; return (u >= 200 && !(f?.unreadExact ?? false)) ? "200+" : u.formatted() }
    var dateText: String { let c = Calendar.current.dateComponents([.month, .day, .weekday], from: now); return "\(c.month ?? 0)월 \(c.day ?? 0)일 \(DOW[(c.weekday ?? 1) - 1])요일" }

    var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("진의 데스크").font(.system(size: 13, weight: .bold))
            Spacer()
            Text(dateText).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    func eventRow(_ e: Feed.Event) -> some View {
        let live = !e.allDay && e.start <= nowMs && nowMs < e.end
        let later = e.start >= tomorrowMs
        let d = Date(timeIntervalSince1970: e.start / 1000), c = Calendar.current.dateComponents([.month, .day, .weekday], from: d)
        let time = later ? "\(c.month ?? 0)/\(c.day ?? 0)" : (e.allDay ? "종일" : hm(e.start))
        let mins = Int((e.start - nowMs) / 60000)
        let tail = live ? "진행 중" : (mins > 0 && mins < 60 ? "\(mins)분 후" : "")
        return Link(destination: goURL(e.url) ?? URL(string: "jindesk://open")!) {
            HStack(spacing: 6) {
                Text(time).font(.system(size: 11, design: .monospaced)).foregroundStyle(live ? CAL : .secondary).frame(width: 40, alignment: .leading)
                Text(e.title.isEmpty ? "(제목 없음)" : e.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 2)
                if !tail.isEmpty { Text(tail).font(.system(size: 10, weight: live ? .semibold : .regular)).foregroundStyle(live ? CAL : .secondary).widgetAccentable(live).lineLimit(1).fixedSize() }
            }
        }
    }
    func mailRow(_ m: Feed.Mail) -> some View {
        Link(destination: goURL(m.url) ?? URL(string: "jindesk://open")!) {
            HStack(spacing: 6) {
                if let src = m.src {   // 출처: G = Gmail, D = Daum
                    Text(src == "Daum" ? "D" : "G").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 13, height: 13).background(RoundedRectangle(cornerRadius: 3).fill(src == "Daum" ? Color.orange : MAIL)).fixedSize()
                }
                Text(short(m.from.isEmpty ? "알 수 없음" : m.from, 8) + " · ").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Text(m.subject.isEmpty ? "(제목 없음)" : m.subject).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 2)
                Text(rel(m.t, now: now)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
        }
    }

    // 일정: 오늘 남은 것, 없으면 30일 안의 다음 일정 1개
    @ViewBuilder func events(_ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("일정").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            if todayLeft.isEmpty {
                Text("오늘 남은 일정이 없습니다.").font(.system(size: 11)).foregroundStyle(.secondary)
                // 대 크기는 다음 일정 2개, 중 크기는 1개
                ForEach(Array((f?.events ?? []).filter { $0.start >= tomorrowMs }.prefix(n - 1).enumerated()), id: \.offset) { eventRow($0.element) }
            } else {
                ForEach(Array(todayLeft.prefix(n).enumerated()), id: \.offset) { eventRow($0.element) }
            }
        }
    }
    @ViewBuilder func mails(_ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(f?.hideAds ?? true ? "안 읽은 메일 · 광고 제외" : "안 읽은 메일").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            if (f?.mails ?? []).isEmpty { Text("읽지 않은 메일이 없습니다.").font(.system(size: 11)).foregroundStyle(.secondary) }
            ForEach(Array((f?.mails ?? []).prefix(n).enumerated()), id: \.offset) { mailRow($0.element) }
        }
    }

    var body: some View {
        Group {
            if f == nil {
                VStack(alignment: .leading, spacing: 6) {
                    header
                    Spacer()
                    Text("진의 데스크 앱을 기다리는 중").font(.system(size: 12, weight: .medium))
                    Text("앱이 켜져 있고 Google 계정이 연결되어 있으면 곧 나타납니다.").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                }
            } else if let err = f?.error, f?.unread == nil {
                VStack(alignment: .leading, spacing: 6) { header; Spacer(); Text(err).font(.system(size: 11)).foregroundStyle(.secondary); Spacer() }
            } else {
                switch family {
                case .systemSmall:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("진의 데스크").font(.system(size: 12, weight: .bold))
                        Stat(label: "읽지 않은 메일", value: unreadText, color: MAIL)
                        Stat(label: "오늘 남은 일정", value: String(todayLeft.count), color: CAL)
                        if let e = todayLeft.first {
                            Text((e.allDay ? "종일 " : hm(e.start) + " ") + e.title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                case .systemMedium:
                    VStack(alignment: .leading, spacing: 8) {
                        header
                        HStack(spacing: 6) {
                            Stat(label: "남은 일정", value: String(todayLeft.count), color: CAL)
                            Stat(label: "안 읽음", value: unreadText, color: MAIL)
                            Stat(label: "오늘 온", value: num(f?.todayMail), color: MAIL)
                            Stat(label: "드라이브", value: num(f?.driveWeek), color: DRIVE)
                        }
                        events(2)
                    }
                default:
                    VStack(alignment: .leading, spacing: 10) {
                        header
                        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                            GridRow { Stat(label: "오늘 남은 일정", value: String(todayLeft.count), color: CAL); Stat(label: "읽지 않은 메일", value: unreadText, color: MAIL) }
                            GridRow { Stat(label: "오늘 온 안 읽은 메일", value: num(f?.todayMail), color: MAIL); Stat(label: "7일간 드라이브 변경", value: num(f?.driveWeek), color: DRIVE) }
                        }
                        events(3)
                        mails(4)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "jindesk://open"))
        .containerBackground(.background, for: .widget)   // 애플 위젯과 같은 시스템 기본 배경 (흑백 전환 때는 macOS가 알아서 바꾼다)
    }
}

struct JinDeskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JinDesk", provider: Provider()) { DeskView(entry: $0) }
            .configurationDisplayName("진의 데스크")
            .description("오늘 일정, 안 읽은 메일, 드라이브 변경을 한눈에.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct JinDeskWidgets: WidgetBundle {
    var body: some Widget { JinDeskWidget() }
}
