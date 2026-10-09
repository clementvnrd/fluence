import Foundation

/// Whether the next meeting can start with no macOS prompt and no download, and what
/// « Préparer les réunions » still has to do (FLU-45). Pure: the app reads the grants and
/// the model folders and passes them in.
public enum MeetingReadiness {
    public enum Grant: Equatable, Sendable {
        case granted, undecided, refused
    }

    /// System Audio Recording has no public status query: all Fluence can know is whether it
    /// has already asked. A refusal only shows later, as a silent call.
    public enum SoundAccess: Equatable, Sendable {
        case asked, notAsked
    }

    public struct Model: Equatable, Sendable {
        public let name: String
        public let megabytes: Int
        public let isPresent: Bool

        public init(name: String, megabytes: Int, isPresent: Bool) {
            self.name = name
            self.megabytes = megabytes
            self.isPresent = isPresent
        }
    }

    public struct State: Equatable, Sendable {
        public var microphone: Grant
        public var systemAudio: SoundAccess
        /// `nil` while « Utiliser mon calendrier » is off: nothing to ask then.
        public var calendar: Grant?
        public var models: [Model]

        public init(microphone: Grant, systemAudio: SoundAccess, calendar: Grant?, models: [Model]) {
            self.microphone = microphone
            self.systemAudio = systemAudio
            self.calendar = calendar
            self.models = models
        }

        public var missingModels: [Model] { models.filter { !$0.isPresent } }
        public var missingMegabytes: Int { missingModels.reduce(0) { $0 + $1.megabytes } }

        /// Nothing left for a click to do. A refused calendar counts as done (it is
        /// optional); a refused microphone does not, and only System Settings can undo it.
        public var isReady: Bool {
            microphone == .granted && systemAudio == .asked && calendar != .undecided && missingModels.isEmpty
        }
    }

    public enum Step: Equatable, Sendable {
        case microphone, systemAudio, calendar, download
    }

    /// What one click runs, in order: each macOS prompt first, one at a time, while the user
    /// is looking; then the downloads, which go on by themselves.
    public static func steps(for state: State) -> [Step] {
        var steps: [Step] = []
        if state.microphone == .undecided { steps.append(.microphone) }
        if state.systemAudio == .notAsked { steps.append(.systemAudio) }
        if state.calendar == .undecided { steps.append(.calendar) }
        if !state.missingModels.isEmpty { steps.append(.download) }
        return steps
    }

    // MARK: - Words on screen

    public static func label(_ grant: Grant) -> String {
        switch grant {
        case .granted: "Autorisé"
        case .undecided: "À autoriser"
        case .refused: "Refusé"
        }
    }

    public static func label(_ access: SoundAccess) -> String {
        switch access {
        case .asked: "Demandé"
        case .notAsked: "À demander"
        }
    }

    /// "Prêts", "651 Mo à télécharger", or "Téléchargement… 42 %" while `progress` runs.
    public static func modelsLabel(_ state: State, progress: Double?) -> String {
        if let progress {
            let percent = Int((min(max(progress, 0), 1) * 100).rounded(.down))
            return "Téléchargement…" + FrenchFormat.space + "\(percent)" + FrenchFormat.space + "%"
        }
        let megabytes = state.missingMegabytes
        return megabytes == 0 ? "Prêts" : "\(megabytes)" + FrenchFormat.space + "Mo à télécharger"
    }

    /// The button's title: what the click will do.
    public static func actionTitle(_ state: State) -> String {
        let steps = steps(for: state)
        if steps.isEmpty { return "Tout est prêt" }
        return steps == [.download] ? "Télécharger" : "Préparer"
    }
}
