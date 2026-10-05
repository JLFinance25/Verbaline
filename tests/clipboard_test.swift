import Cocoa
// Tests TextInserter.paste on a PRIVATE pasteboard with a no-op keystroke — never touches the real clipboard or apps.
@main struct ClipboardTest {
    static func main() {
        var fails = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS  " : "FAIL  ") + name); if !ok { fails += 1 } }
        func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        let pb = NSPasteboard(name: .init("verbaline-test-\(getpid())"))
        func setOriginal() {
            pb.clearContents()
            let item = NSPasteboardItem()
            item.setString("ORIGINAL", forType: .string)
            item.setString("<b>ORIGINAL</b>", forType: .html)
            item.setData(Data("{\\rtf1 ORIGINAL}".utf8), forType: .rtf)
            pb.writeObjects([item])
        }
        // 1. single paste restores original with type order intact
        setOriginal(); let order = pb.pasteboardItems?.first?.types ?? []
        var seen = ""
        TextInserter.paste("dictation-1", into: pb, press: { seen = pb.string(forType: .string) ?? "" }, restoreAfter: 0.1)
        check("text is on clipboard at paste time", seen == "dictation-1")
        spin(0.3)
        check("original restored", pb.string(forType: .string) == "ORIGINAL")
        check("all formats + order restored", pb.pasteboardItems?.first?.types == order)
        // 2. two pastes back-to-back restore the ORIGINAL, not dictation-1
        setOriginal()
        TextInserter.paste("dictation-1", into: pb, press: {}, restoreAfter: 0.2)
        spin(0.05)
        TextInserter.paste("dictation-2", into: pb, press: { seen = pb.string(forType: .string) ?? "" }, restoreAfter: 0.2)
        check("second paste puts its own text", seen == "dictation-2")
        spin(0.5)
        check("back-to-back pastes restore the original", pb.string(forType: .string) == "ORIGINAL")
        // 3. user copies something new between pastes -> that new copy is what gets restored
        setOriginal()
        TextInserter.paste("dictation-1", into: pb, press: {}, restoreAfter: 0.2)
        spin(0.05)
        pb.clearContents(); pb.setString("USER-NEW-COPY", forType: .string)
        TextInserter.paste("dictation-2", into: pb, press: {}, restoreAfter: 0.2)
        spin(0.5)
        check("user's newer copy is preserved", pb.string(forType: .string) == "USER-NEW-COPY")
        // 4. user copies during the restore window -> we must not overwrite it
        setOriginal()
        TextInserter.paste("dictation-1", into: pb, press: {}, restoreAfter: 0.2)
        spin(0.05)
        pb.clearContents(); pb.setString("USER-COPIED-MEANWHILE", forType: .string)
        spin(0.4)
        check("copy made during restore window is left alone", pb.string(forType: .string) == "USER-COPIED-MEANWHILE")
        // 5. empty clipboard stays empty
        pb.clearContents()
        TextInserter.paste("dictation-1", into: pb, press: {}, restoreAfter: 0.1)
        spin(0.3)
        check("empty clipboard restored to empty", (pb.pasteboardItems ?? []).isEmpty)
        pb.releaseGlobally()
        print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(fails == 0 ? 0 : 1)
    }
}
