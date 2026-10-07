import Foundation

/// A prompt preset: what kind of meeting this was, and therefore what the notes should
/// pay attention to. Chosen per meeting; General is the default.
public enum NotesTemplate: String, Sendable, Codable, CaseIterable, Identifiable, Hashable {
    case general
    case oneOnOne
    case clientCall
    case standUp

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "General"
        case .oneOnOne: "1:1"
        case .clientCall: "Client call"
        case .standUp: "Stand-up"
        }
    }

    /// The part of the instructions that changes with the template.
    public var focus: String {
        switch self {
        case .general:
            return "A general meeting. Capture its purpose, the main topics, what was agreed "
                + "and who does what next."
        case .oneOnOne:
            return "A one-to-one between two people. Focus on feedback given and received, "
                + "blockers, priorities, and what each person committed to. Keep personal "
                + "remarks factual and discreet."
        case .clientCall:
            return "A call with a client. Focus on the client's needs and requirements, "
                + "their concerns and objections, scope, budget or dates discussed, and every "
                + "commitment made to the client."
        case .standUp:
            return "A team stand-up. For each person: what they did, what they do next, and "
                + "what blocks them. Keep it short; the recap gives each person's update in a "
                + "phrase."
        }
    }
}
