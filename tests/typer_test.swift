import Foundation
// TextTyper's keystroke plan and its typing loop, with a fake keyboard (nothing is ever typed into a real app).
@main struct TyperTest {
    static func main() {
        var fails = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS  " : "FAIL  ") + name); if !ok { fails += 1 } }
        let s = TextTyper.strokes(for: "Hi 👋🏽 café\r\nok\n")
        check("one stroke per character, emoji kept whole", s.count == 13 && s[3] == .text("👋🏽"))
        check("accented letter is one stroke", s[8] == .text("é"))
        check("CRLF becomes one line break", s[9] == .lineBreak && s[10] == .text("o"))
        check("trailing newline is a line break", s.last == .lineBreak)
        check("empty text → no strokes", TextTyper.strokes(for: "").isEmpty)

        func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        // full run
        let typer = TextTyper()
        var typed: [TextTyper.Stroke] = []
        var result: Bool?
        typer.type("abc\nd", speed: .fast, post: { typed.append($0) }) { result = $0 }
        check("is typing while running", typer.isTyping)
        let t0 = Date(); while result == nil, Date().timeIntervalSince(t0) < 3 { spin(0.01) }
        check("finished = true", result == true)
        check("all strokes sent in order", typed == [.text("a"), .text("b"), .text("c"), .lineBreak, .text("d")])
        check("not typing after finishing", !typer.isTyping)
        // cancel mid-way (Esc)
        var count = 0
        result = nil
        typer.type(String(repeating: "x", count: 200), speed: .steady, post: { _ in count += 1 }) { result = $0 }
        spin(0.2); typer.cancel()
        let t1 = Date(); while result == nil, Date().timeIntervalSince(t1) < 3 { spin(0.01) }
        check("cancel stops early (finished = false)", result == false)
        check("cancel stopped well before the end (\(count) of 200)", count > 0 && count < 50)
        // a new run after a cancel starts clean
        typed = []; result = nil
        typer.type("ok", speed: .fast, post: { typed.append($0) }) { result = $0 }
        let t2 = Date(); while result == nil, Date().timeIntervalSince(t2) < 3 { spin(0.01) }
        check("next run after cancel types everything", result == true && typed == [.text("o"), .text("k")])
        print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(fails == 0 ? 0 : 1)
    }
}
