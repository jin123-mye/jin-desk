// Daum 메일(IMAP) 응답 해석 — 네트워크·키체인과 무관한 순수 함수 (tools/daum-parse-test.swift로 시험)
import Foundation

enum DaumParse {
    /// "* SEARCH 1 2 3" → [1, 2, 3]
    static func uids(_ out: String) -> [Int] {
        for line in out.components(separatedBy: .newlines) where line.hasPrefix("* SEARCH") {
            return line.dropFirst(8).split(separator: " ").compactMap { Int($0) }
        }
        return []
    }

    struct Msg { var uid: Int; var seen: Bool; var header: Data }

    /// "* N FETCH (UID 5 FLAGS (\Seen) BODY[HEADER.FIELDS (...)] {123}\r\n<123바이트>)" 묶음을 나눈다
    static func fetches(_ d: Data) -> [Msg] {
        let b = [UInt8](d), marker = Array(" FETCH (".utf8)
        var i = 0, out: [Msg] = []
        while let r = find(b, marker, from: i) {
            var j = r + marker.count, meta = [UInt8]()
            while j < b.count && b[j] != UInt8(ascii: "{") { meta.append(b[j]); j += 1 }
            guard j < b.count else { break }
            j += 1
            var num = ""
            while j < b.count && b[j] != UInt8(ascii: "}") { num.append(Character(UnicodeScalar(b[j]))); j += 1 }
            j += 1
            while j < b.count && (b[j] == 13 || b[j] == 10) { j += 1; if b[j - 1] == 10 { break } }
            let len = Int(num) ?? 0
            guard len >= 0, j + len <= b.count else { break }
            let m = String(decoding: meta, as: UTF8.self)
            let uid = m.range(of: #"UID (\d+)"#, options: .regularExpression).flatMap { Int(m[$0].dropFirst(4)) } ?? 0
            out.append(Msg(uid: uid, seen: m.contains("\\Seen"), header: Data(b[j..<(j + len)])))
            i = j + len
        }
        return out
    }

    private static func find(_ h: [UInt8], _ n: [UInt8], from: Int) -> Int? {
        guard !n.isEmpty, h.count >= n.count, from <= h.count - n.count else { return nil }
        var i = from
        while i <= h.count - n.count { if h[i] == n[0] && Array(h[i..<(i + n.count)]) == n { return i }; i += 1 }
        return nil
    }

    static func korean() -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
    }
    static func encoding(_ name: String) -> String.Encoding {
        let n = name.lowercased()
        if n == "utf-8" || n == "utf8" { return .utf8 }
        if n.contains("euc-kr") || n.contains("ks_c_5601") || n == "cp949" || n == "uhc" { return korean() }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        if cf != kCFStringEncodingInvalidId { return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
        return .utf8
    }

    /// 머리글 → [소문자 이름: 값] (이어진 줄 펴기 + =?charset?B/Q?..?= 해독)
    static func headers(_ raw: Data) -> [String: String] {
        let text = (String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: korean()) ?? String(decoding: raw, as: UTF8.self))
            .replacingOccurrences(of: "\r\n", with: "\n")
        var lines: [String] = []
        for l in text.components(separatedBy: "\n") {
            if (l.hasPrefix(" ") || l.hasPrefix("\t")), !lines.isEmpty { lines[lines.count - 1] += " " + l.trimmingCharacters(in: .whitespaces) }
            else if !l.isEmpty { lines.append(l) }
        }
        var h: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            let k = l[..<c].lowercased()
            if h[k] == nil { h[k] = decodeWords(String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces)) }
        }
        return h
    }

    static func decodeWords(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?\s]*)\?="#) else { return s }
        let ns = s as NSString
        var out = "", last = 0, prevEncoded = false
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if !(prevEncoded && gap.trimmingCharacters(in: .whitespaces).isEmpty) { out += gap }
            let cs = ns.substring(with: m.range(at: 1)), kind = ns.substring(with: m.range(at: 2)).lowercased(), body = ns.substring(with: m.range(at: 3))
            var data = Data()
            if kind == "b" { data = Data(base64Encoded: body + String(repeating: "=", count: (4 - body.count % 4) % 4)) ?? Data() }
            else {
                let u = Array(body.replacingOccurrences(of: "_", with: " ").utf8); var i = 0
                while i < u.count {
                    if u[i] == UInt8(ascii: "="), i + 2 < u.count + 0, let v = UInt8(String(decoding: u[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) { data.append(v); i += 3 }
                    else { data.append(u[i]); i += 1 }
                }
            }
            out += String(data: data, encoding: encoding(cs)) ?? String(data: data, encoding: .utf8) ?? ""
            last = m.range.location + m.range.length; prevEncoded = true
        }
        out += ns.substring(from: last)
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// `"이름" <a@b.c>` → 이름 (없으면 주소 앞부분)
    static func senderName(_ from: String) -> String {
        var name = from
        if let lt = from.lastIndex(of: "<") {
            name = String(from[..<lt]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if name.isEmpty { name = String(from[from.index(after: lt)...]).replacingOccurrences(of: ">", with: "") }
        }
        if name.contains("@"), let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        return name.isEmpty ? from : name
    }

    static func date(_ s: String) -> Double? {
        let cleaned = s.replacingOccurrences(of: #"\s*\(.*\)"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yy HH:mm:ss Z"] {
            f.dateFormat = fmt
            if let d = f.date(from: cleaned) { return d.timeIntervalSince1970 * 1000 }
        }
        return nil
    }

    // ---- 본문 해독 (MIME): 결제 메일 같은 것을 읽어 볼 때 쓴다 ----
    private static func split(_ d: Data) -> (Data, Data) {
        for sep in ["\r\n\r\n", "\n\n"] {
            if let r = d.range(of: Data(sep.utf8)) { return (d.subdata(in: d.startIndex..<r.lowerBound), d.subdata(in: r.upperBound..<d.endIndex)) }
        }
        return (d, Data())
    }
    private static func param(_ v: String, _ name: String) -> String? {
        guard let r = v.range(of: name + "=", options: .caseInsensitive) else { return nil }
        var t = String(v[r.upperBound...])
        if t.hasPrefix("\"") { t.removeFirst(); return String(t.prefix { $0 != "\"" }) }
        return String(t.prefix { $0 != ";" && $0 != " " && $0 != "\r" && $0 != "\n" })
    }
    private static func decodeBody(_ body: Data, cte: String, charset: String) -> String {
        var data = body
        switch cte.lowercased() {
        case "base64":
            data = Data(base64Encoded: String(decoding: body, as: UTF8.self).components(separatedBy: .whitespacesAndNewlines).joined(), options: .ignoreUnknownCharacters) ?? body
        case "quoted-printable":
            var out = Data(); let b = [UInt8](body); var i = 0
            while i < b.count {
                if b[i] == UInt8(ascii: "="), i + 1 < b.count {
                    if b[i + 1] == 13 || b[i + 1] == 10 { i += 2; if i < b.count && b[i - 1] == 13 && b[i] == 10 { i += 1 }; continue }
                    if i + 2 < b.count, let v = UInt8(String(decoding: b[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) { out.append(v); i += 3; continue }
                }
                out.append(b[i]); i += 1
            }
            data = out
        default: break
        }
        return String(data: data, encoding: encoding(charset)) ?? String(data: data, encoding: .utf8) ?? String(data: data, encoding: korean()) ?? ""
    }
    private static func stripHTML(_ h: String) -> String {
        var t = h.replacingOccurrences(of: #"(?is)<(script|style|head)[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)<br\s*/?>|</(p|div|tr|li|h\d|table)>"#, with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (a, b) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] { t = t.replacingOccurrences(of: a, with: b) }
        return t
    }
    /// 메일 원문 전체(머리글+본문) → 읽을 수 있는 글 (text/plain 우선, 없으면 HTML에서 태그 제거)
    static func bodyText(_ raw: Data) -> String {
        func walk(_ d: Data) -> (plain: String?, html: String?) {
            let (hd, body) = split(d)
            var raw = String(decoding: hd, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            raw = raw.replacingOccurrences(of: #"\n[ \t]+"#, with: " ", options: .regularExpression)
            let ct = raw.components(separatedBy: "\n").first { $0.lowercased().hasPrefix("content-type:") } ?? "Content-Type: text/plain"
            let cte = raw.components(separatedBy: "\n").first { $0.lowercased().hasPrefix("content-transfer-encoding:") }.map { String($0.drop { $0 != ":" }.dropFirst()).trimmingCharacters(in: .whitespaces) } ?? ""
            let low = ct.lowercased()
            if low.contains("multipart/"), let bd = param(ct, "boundary") {
                let text = String(decoding: body, as: UTF8.self)
                var plain: String? = nil, html: String? = nil
                for part in text.components(separatedBy: "--" + bd).dropFirst() where !part.hasPrefix("--") {
                    let r = walk(Data(part.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n")).utf8))
                    if plain == nil { plain = r.plain }; if html == nil { html = r.html }
                }
                return (plain, html)
            }
            let cs = param(ct, "charset") ?? "utf-8"
            if low.contains("text/html") { return (nil, stripHTML(decodeBody(body, cte: cte, charset: cs))) }
            if low.contains("text/plain") || !low.contains("/") { return (decodeBody(body, cte: cte, charset: cs), nil) }
            return (nil, nil)
        }
        let r = walk(raw)
        let t = (r.plain?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? r.plain : r.html) ?? ""
        return t.replacingOccurrences(of: #"[ \t\u{00a0}\u{034f}]+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
