/// FLU-128: the line under « Privé / Précis » in Réglages › Transcription, in plain words and
/// from the real state: where the voice goes, where the text is corrected, what takes over.
public enum TranscriptionRoute {
    public enum Step: Equatable, Sendable { case voice, missingKey, correction, fallback }

    public struct Part: Equatable, Sendable {
        public let step: Step
        public let lead: String
        public let target: String
        /// The voice leaves the Mac.
        public let isCloud: Bool
    }

    /// `local` is the engine a dictation runs on now (Apple while Parakeet is not on disk):
    /// with a cloud provider it is the engine `CloudEngine` wraps, so the fallback. Compare
    /// mode never uses the cloud (`engineForCurrentSetting`), and without a key the cloud
    /// answers « Aucune clé » and the local text is typed.
    public static func summary(
        local: ComparedEngine, cloud: CloudProvider?, hasKey: Bool, compareMode: Bool, cleanup: CleanupLevel
    ) -> [Part] {
        let sent = sentTo(cloud: cloud, hasKey: hasKey, compareMode: compareMode)
        let cloud = compareMode ? nil : cloud
        var parts = [Part(
            step: .voice, lead: "Votre voix →",
            target: compareMode ? "Mode comparaison" : sent?.displayName ?? local.displayName + " sur ce Mac",
            isCloud: sent != nil
        )]
        if let cloud, !hasKey {
            parts.append(Part(step: .missingKey, lead: "Aucune clé", target: cloud.displayName, isCloud: false))
        }
        parts.append(cleanup == .none
            ? Part(step: .correction, lead: "Sans correction", target: "", isCloud: false)
            : Part(step: .correction, lead: "Correction", target: "sur ce Mac", isCloud: false))
        if sent != nil {
            parts.append(Part(step: .fallback, lead: "Secours", target: local.displayName, isCloud: false))
        }
        return parts
    }

    /// Where the voice really goes: the cloud only with its key, and never in compare mode.
    /// The Précis card, its amber line and « Secours » all read it (FLU-140).
    public static func sentTo(cloud: CloudProvider?, hasKey: Bool, compareMode: Bool) -> CloudProvider? {
        hasKey && !compareMode ? cloud : nil
    }

    /// What leaves the Mac in Précis, in one line (FLU-134).
    public static func sentNote(_ provider: CloudProvider) -> String {
        "L'audio de vos dictées et de vos appels et les mots du dictionnaire sont envoyés à \(provider.displayName)."
    }
}
