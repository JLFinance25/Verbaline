import Foundation
// EditWatcher's locate/region logic and PersonalDictionary.learn/forget, on temporary files only.
@main struct EditWatcherTest {
    static func main() {
        var fails = 0
        func check(_ name: String, _ got: String?, _ want: String?) {
            let ok = got == want
            print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "\n      got:  \(String(describing: got))\n      want: \(String(describing: want))"))
            if !ok { fails += 1 }
        }
        let W = EditWatcher.self
        let pasted = "We can do a Helllock through Fannie Mae."
        let value = "Hi Sarah. " + pasted + " Talk soon."
        let cursor = ("Hi Sarah. " + pasted as NSString).length
        let loc = W.locatePaste(pasted, in: value, cursor: cursor)
        check("anchors before", loc?.before, "Hi Sarah. ")
        check("anchors after", loc?.after, " Talk soon.")
        // user fixes a word inside the pasted text
        let edited = value.replacingOccurrences(of: "Helllock", with: "HELOC")
        check("region after an in-place fix", W.region(in: edited, before: loc!.before, after: loc!.after, near: loc!.start),
              "We can do a HELOC through Fannie Mae.")
        // user edits text outside the anchors
        let outside = "Hello Sarah, hope you're well. Hi Sarah. " + pasted + " Talk soon. PS see attached."
        check("edits elsewhere leave region alone", W.region(in: outside, before: loc!.before, after: loc!.after, near: loc!.start), pasted)
        // user deletes the text before (anchor gone) → can't tell → nil
        check("anchor gone → nil", W.region(in: pasted + " Talk soon.", before: loc!.before, after: loc!.after, near: loc!.start), nil)
        // pasted at the very end; user keeps typing
        let endLoc = W.locatePaste(pasted, in: "Note: " + pasted, cursor: ("Note: " + pasted as NSString).length)
        check("end paste has empty after-anchor", endLoc?.after, "")
        check("typing after an end paste is included", W.region(in: "Note: We can do a HELOC through Fannie Mae. Thanks!",
              before: endLoc!.before, after: endLoc!.after, near: endLoc!.start), "We can do a HELOC through Fannie Mae. Thanks!")
        // field holds only the pasted text
        let only = W.locatePaste(pasted, in: pasted, cursor: (pasted as NSString).length)
        check("whole-field paste", W.region(in: "We can do a HELOC through Fannie Mae.", before: only!.before, after: only!.after, near: only!.start),
              "We can do a HELOC through Fannie Mae.")
        // same text pasted twice: the one at the cursor is ours
        let twice = "A: ok. B: ok."
        let t = W.locatePaste("ok.", in: twice, cursor: (twice as NSString).length)
        check("duplicate text: picks the one at the cursor", t.map { "\($0.start)" }, "10")
        check("no cursor: last occurrence", W.locatePaste("ok.", in: twice, cursor: nil).map { "\($0.start)" }, "10")
        check("not in field → nil", W.locatePaste("missing text", in: twice, cursor: nil).map { _ in "found" }, nil)

        // learn / forget on a temp dictionary
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verbaline-learn-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dictionary.txt")
        try! "# my words\nescrow\n".write(to: file, atomically: true, encoding: .utf8)
        let dict = PersonalDictionary(fileURL: file)
        check("before learning", dict.apply(to: "We can do a Helllock."), "We can do a Helllock.")
        check("learn returns true", dict.learn(heard: "Helllock", written: "HELOC") ? "yes" : "no", "yes")
        check("applies right away", dict.apply(to: "We can do a Helllock."), "We can do a HELOC.")
        check("learned line under its own heading",
              (try? String(contentsOf: file, encoding: .utf8)).map { $0.contains(PersonalDictionary.learnedHeader + "\nhelllock -> HELOC\n") ? "yes" : "no" }, "yes")
        check("existing words kept", (try? String(contentsOf: file, encoding: .utf8)).map { $0.hasPrefix("# my words\nescrow\n") ? "yes" : "no" }, "yes")
        check("duplicate not added", dict.learn(heard: "helllock", written: "HELOC") ? "added" : "skipped", "skipped")
        check("phrase learn", dict.learn(heard: "Fanny May", written: "Fannie Mae") ? "yes" : "no", "yes")
        check("phrase applies, month untouched", dict.apply(to: "Fanny May is closed in May."), "Fannie Mae is closed in May.")
        check("forget returns true", dict.forget(heard: "Helllock", written: "HELOC") ? "yes" : "no", "yes")
        check("forgotten no longer applies", dict.apply(to: "We can do a Helllock."), "We can do a Helllock.")
        check("other learned line survives", dict.apply(to: "Fanny May"), "Fannie Mae")
        check("forget twice → false", dict.forget(heard: "Helllock", written: "HELOC") ? "yes" : "no", "no")
        try! "{\\rtf1 escrow}".write(to: file, atomically: true, encoding: .utf8)
        check("refuses to write into a rich-text file", dict.learn(heard: "Dee Tee Eye", written: "DTI") ? "wrote" : "refused", "refused")

        print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
        exit(fails == 0 ? 0 : 1)
    }
}
