import Foundation

// MeetingTypes
// ------------
// The shared shapes the meeting notetaker's pieces pass to each other. Kept in one small file so the pieces
// (MeetingAudio, MeetingTranscriber, MeetingSummarizer, NotesWindow) can be built and tested separately.
//
//     MeetingApp       which app is in the meeting ("FaceTime", "zoom.us", "Google Chrome") and its processes
//     Speaker          .you (your mic) or .them (the meeting app's sound)
//     TranscriptLine   one line of the transcript: who, when (seconds from the start), what
//     MeetingNote      the finished note: title, overview, to-dos, loan details, transcript

struct MeetingApp: Equatable {
    let name: String          // shown to the user: "FaceTime"
    let bundleID: String?     // "com.apple.FaceTime"; nil for hidden system helpers
    let pids: [pid_t]         // every process whose sound belongs to this meeting
}

enum Speaker: String, Codable { case you, them }

struct TranscriptLine: Codable, Equatable {
    let speaker: Speaker
    let start: TimeInterval   // seconds from the start of the meeting
    let text: String
}

struct MeetingTodo: Codable, Equatable {
    let owner: Speaker
    let task: String
}

struct MeetingNote: Codable, Equatable {
    var title: String
    var date: Date
    var duration: TimeInterval
    var appName: String
    var overview: String                 // a 2–3 minute read
    var todos: [MeetingTodo]
    var loanDetails: [LoanDetail]        // only what was actually said; empty when nothing was, or it's turned off
    var transcript: [TranscriptLine]

    struct LoanDetail: Codable, Equatable {
        let label: String                // "Purchase price"
        let value: String                // "$450,000"
    }
}
