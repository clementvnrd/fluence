import FluenceCore
import FluenceDictionary
import AVFoundation
import Foundation
import Speech

/// Live dictation with macOS 26's `SpeechAnalyzer` and a single `SpeechTranscriber`, entirely on
/// the Mac. The app carries no model: macOS downloads and manages the assets of each locale, so
/// the first dictation in a new language can wait a moment for them.
actor AppleSpeechEngine: TranscriptionEngine {
    /// The locale asked for. Nil until first needed: then it comes from the language setting
    /// (FLU-5), read on the main actor where the setting lives.
    private var locale: Locale?

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var audioInput: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    /// The finalized part of the transcript. Volatile text is shown after it but never kept
    /// here: its final version arrives later and is appended instead.
    private var committed = ""

    /// - Parameter locale: a fixed locale; nil (the default) follows Settings ▸ Language,
    ///   whose Auto is the system locale — what this engine always used before.
    init(locale: Locale? = nil) {
        self.locale = locale
    }

    // MARK: FLU-5 text
    private func requestedLocale() async -> Locale {
        if let locale { return locale }
        let identifier = await MainActor.run {
            Settings.shared.dictationLanguage.appleLocaleIdentifier(current: .current)
        }
        let resolved = Locale(identifier: identifier)
        locale = resolved
        return resolved
    }

    func preferredInputFormat() async -> AVAudioFormat? {
        let module = if let transcriber { transcriber } else { Self.makeTranscriber(locale: await requestedLocale()) }
        return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        let locale = await requestedLocale()
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.localeUnsupported(locale)
        }

        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        if supported == nil {
            // Said once in the log rather than silently: the user picked a language this
            // Mac's transcriber doesn't have, and gets English instead.
            Log.speech.info("SpeechTranscriber has no locale for \(locale.identifier, privacy: .public) — using en-US")
        }
        let resolvedLocale = supported ?? Locale(identifier: "en-US")

        let transcriber = Self.makeTranscriber(locale: resolvedLocale)
        self.transcriber = transcriber

        try await Self.ensureModelInstalled(for: transcriber)

        let (inputSequence, audioInput) = AsyncStream<AnalyzerInput>.makeStream()
        self.audioInput = audioInput

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        // Leaning the recognizer toward the user's dictionary catches mishearings that no text
        // correction can undo ("Supabase" heard as "super base"). The pull is soft: spelling
        // stays `DictionaryCorrector`'s job. `biasLimit` keeps the list short, because a long
        // one makes the model hallucinate its terms over silence or unclear audio, which is
        // worse than a misspelling. A context only counts when it is in place before the first
        // audio, and the analyzer initializers that accept one also want the input sequence,
        // which this analyzer only gets in `start(inputSequence:)`; hence `setContext`.
        if let context = await Self.dictionaryContext() {
            try? await analyzer.setContext(context)
        }

        committed = ""

        let (output, outputContinuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { break }
                    let snapshot = await self.fold(result)
                    outputContinuation.yield(TranscriptionChunk(text: snapshot, isFinal: false))
                }
                let transcript = await self?.committed ?? ""
                outputContinuation.yield(TranscriptionChunk(text: transcript, isFinal: true))
                outputContinuation.finish()
            } catch {
                Log.speech.error("SpeechAnalyzer: results stream failed — \(error.localizedDescription)")
                outputContinuation.finish(throwing: error)
            }
        }

        try await analyzer.start(inputSequence: inputSequence)
        Log.speech.info("SpeechAnalyzer: started for \(resolvedLocale.identifier, privacy: .public)")

        return output
    }

    func feed(_ chunk: AudioChunk) async {
        audioInput?.yield(AnalyzerInput(buffer: chunk.buffer))
    }

    func finish() async {
        audioInput?.finish()
        audioInput = nil

        // Cancelling would throw away the volatile tail; finalizing turns it into final results
        // before the results end, so the last words make it into the final chunk.
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.speech.error("SpeechAnalyzer: finalize failed — \(error.localizedDescription)")
            await analyzer?.cancelAndFinishNow()
        }

        // The results task is not cancelled: it still owes the final chunk, which the
        // controller waits for, and it ends by itself once the results do.
        analyzer = nil
        transcriber = nil
        resultsTask = nil
    }

    func cancel() async {
        audioInput?.finish()
        audioInput = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        transcriber = nil
        resultsTask = nil
    }

    // MARK: Results

    /// The transcript once `result` is taken into account. Only a final result is kept; a
    /// volatile one is shown after the committed text until its final version replaces it.
    private func fold(_ result: SpeechTranscriber.Result) -> String {
        let text = String(result.text.characters)
        guard result.isFinal else {
            return (committed + text).trimmingCharacters(in: .whitespaces)
        }
        committed += text
        return committed.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Setup

    /// The user's dictionary phrases as recognition context; nil when there are none, so an
    /// empty context is never set.
    ///
    /// The store belongs to the main actor and this runs on the engine's, so the read hops over
    /// with `MainActor.run`. `assumeIsolated` would not check that claim and would kill the
    /// process here. What comes back is a plain array of strings, safe to carry across.
    private static func dictionaryContext() async -> AnalysisContext? {
        let phrases = await MainActor.run { DictionaryStore.shared.biasPhrases }
        guard !phrases.isEmpty else { return nil }

        let context = AnalysisContext()
        context.contextualStrings[.general] = phrases
        Log.speech.info("SpeechAnalyzer: biased toward \(phrases.count) dictionary phrase(s)")
        return context
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // Partial text while the user is still speaking: the HUD's live line.
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    private static func ensureModelInstalled(for transcriber: SpeechTranscriber) async throws {
        // Locales are compared by their BCP 47 strings: two `Locale` values for the same
        // language can differ in ways that don't matter here.
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        let isInstalled = transcriber.selectedLocales.allSatisfy { locale in
            installed.contains(locale.identifier(.bcp47))
        }
        if isInstalled { return }

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Log.speech.info("SpeechAnalyzer: downloading the speech model")
                try await request.downloadAndInstall()
                Log.speech.info("SpeechAnalyzer: speech model installed")
            }
        } catch {
            throw TranscriptionError.modelInstallFailed(error.localizedDescription)
        }
    }

    /// Checks and installs the speech model for a locale in the background, so the first
    /// hold after choosing a language doesn't wait on the asset download.
    static func prewarm(locale: Locale) async {
        guard SpeechTranscriber.isAvailable else { return }
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return }
        let transcriber = makeTranscriber(locale: resolved)
        do {
            try await ensureModelInstalled(for: transcriber)
            Log.speech.info("prewarm: speech model ready for \(resolved.identifier, privacy: .public)")
        } catch {
            Log.speech.error("prewarm failed for \(resolved.identifier, privacy: .public): \(error.localizedDescription)")
        }
    }
}
