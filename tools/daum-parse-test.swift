// 시험: mkdir -p /tmp/dpt && cp tools/daum-parse-test.swift /tmp/dpt/main.swift && swiftc DaumParse.swift /tmp/dpt/main.swift -o /tmp/dp-test && /tmp/dp-test
import Foundation
func expect(_ a: Any, _ b: Any, _ n: String) { if "\(a)" != "\(b)" { print("FAIL \(n): \(a) != \(b)"); exit(1) } else { print("ok \(n)") } }
let subj = "=?UTF-8?B?" + Data("안녕하세요 테스트".utf8).base64EncodedString() + "?="
let euc = Data("한글".data(using: DaumParse.korean())!).map { String(format: "=%02X", $0) }.joined()
let h1 = "From: =?UTF-8?B?" + Data("다글로".utf8).base64EncodedString() + "?= <noreply@daglo.ai>\r\nSubject: \(subj)\r\n =?EUC-KR?Q?\(euc)?=\r\nDate: Mon, 28 Sep 2026 13:03:00 +0900 (KST)\r\n\r\n"
let h2 = "From: \"Kim\" <kim@example.com>\r\nSubject: plain\r\nDate: Tue, 29 Sep 2026 09:00:00 +0000\r\n\r\n"
var raw = Data()
for (i, h) in [(5, h1), (9, h2)].enumerated() {
    let hd = Data(h.1.utf8)
    raw.append(Data("* \(i + 1) FETCH (UID \(h.0) FLAGS (\(h.0 == 5 ? "\\Seen" : "")) BODY[HEADER.FIELDS (FROM SUBJECT DATE)] {\(hd.count)}\r\n".utf8)); raw.append(hd); raw.append(Data(")\r\n".utf8))
}
let ms = DaumParse.fetches(raw)
expect(ms.count, 2, "fetch count"); expect(ms[0].uid, 5, "uid"); expect(ms[0].seen, true, "seen"); expect(ms[1].seen, false, "unseen")
let a = DaumParse.headers(ms[0].header)
expect(DaumParse.senderName(a["from"]!), "다글로", "sender")
expect(a["subject"]!, "안녕하세요 테스트한글", "subject (연속 인코딩 단어는 공백 없이 이어짐)")
expect(DaumParse.date(a["date"]!) ?? 0, 1790568180000.0, "date")
expect(DaumParse.senderName(DaumParse.headers(ms[1].header)["from"]!), "Kim", "plain sender")
expect(DaumParse.uids("* SEARCH 3 7 12\r\nA1 OK done"), [3, 7, 12], "uids"); expect(DaumParse.uids("A1 OK"), [], "empty")
print("ALL OK")
