import Foundation

enum RiskLevel: String, Codable {
    case safe       // read-only, git-tracked small edits
    case action     // write/edit that's recoverable
    case danger     // unrecoverable: overwrite, rm -rf, force push, sudo, outside root
}

enum BubbleForm: String, Codable {
    case collapsed
    case expanded
    case danger
}

struct ToolContext: Codable {
    let name: String        // "Bash" | "Edit" | "Write" | ...
    let cwd: String?
    let command: String?    // Bash
    let filePath: String?   // Edit / Write
    let oldString: String?  // Edit
    let newString: String?  // Edit
    let content: String?    // Write
    let description: String?
}

struct DiffStat: Codable {
    let added: Int
    let removed: Int
    let hunks: Int
}

struct NotchEvent: Codable, Identifiable, Equatable {
    let id: UUID
    let requestId: String?          // only for permission requests (needs response)
    let kind: String                // "notification" | "stop" | "request"
    let title: String
    let body: String
    let source: String
    let sourceApp: String?
    let timestamp: TimeInterval

    // permission request specifics
    let tool: ToolContext?
    let risk: RiskLevel?
    let form: BubbleForm?
    let diff: DiffStat?
    let riskNotes: [String]?
    let suggestedGlob: String?

    init(id: UUID = UUID(),
         requestId: String? = nil,
         kind: String,
         title: String,
         body: String,
         source: String,
         sourceApp: String?,
         timestamp: TimeInterval,
         tool: ToolContext? = nil,
         risk: RiskLevel? = nil,
         form: BubbleForm? = nil,
         diff: DiffStat? = nil,
         riskNotes: [String]? = nil,
         suggestedGlob: String? = nil) {
        self.id = id
        self.requestId = requestId
        self.kind = kind
        self.title = title
        self.body = body
        self.source = source
        self.sourceApp = sourceApp
        self.timestamp = timestamp
        self.tool = tool
        self.risk = risk
        self.form = form
        self.diff = diff
        self.riskNotes = riskNotes
        self.suggestedGlob = suggestedGlob
    }

    static func == (lhs: NotchEvent, rhs: NotchEvent) -> Bool { lhs.id == rhs.id }
}

final class NotificationStore: ObservableObject {
    @Published var current: NotchEvent?
    @Published var history: [NotchEvent] = []
    private let maxHistory = 30

    func push(_ evt: NotchEvent) {
        DispatchQueue.main.async {
            self.current = evt
            self.history.insert(evt, at: 0)
            if self.history.count > self.maxHistory {
                self.history.removeLast(self.history.count - self.maxHistory)
            }
        }
    }

    func clearCurrent() {
        DispatchQueue.main.async { self.current = nil }
    }
}
