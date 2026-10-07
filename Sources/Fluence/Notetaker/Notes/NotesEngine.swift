import FluenceNotesCore
import Foundation
import FoundationModels

/// Why a meeting has no (new) notes. Every case is shown to the user as is: the notes are
/// either written from the transcript or not written at all — never approximated.
enum NotesFailure: Error, Equatable, Sendable {
    /// Apple Intelligence is off, not supported, or still downloading.
    case unavailable(String)
    /// Too little was said to summarise.
    case tooShort
    /// The model took longer than the per-call limit.
    case timedOut
    /// The model's guardrails declined part of the transcript.
    case declined
    case unsupportedLanguage
    /// The model returned nothing usable.
    case empty
    case cancelled
    case failed(String)

    var message: String {
        switch self {
        case .unavailable(let reason): "No notes: \(reason)"
        case .tooShort: "No notes: too little was said to summarise."
        case .timedOut: "No notes: the on-device model took too long. Try Regenerate."
        case .declined: "No notes: the on-device model declined part of this transcript."
        case .unsupportedLanguage: "No notes: the on-device model doesn't support this meeting's language."
        case .empty: "No notes: the on-device model returned nothing usable."
        case .cancelled: "Note writing was cancelled."
        case .failed(let detail): "No notes: \(detail)"
        }
    }
}

/// Where a generation is, for the UI.
enum NotesProgress: Equatable, Sendable {
    case preparing
    /// Reading part `index` (1-based) of `count`.
    case reading(index: Int, count: Int)
    case merging
    case writing
}

/// Everything one generation needs, as plain values.
struct NotesRequest: Sendable {
    var lines: [TranscriptLine]
    var context: NotesContext
}

/// Meeting notes with Apple's on-device model, map-reduce style.
///
/// The system model has one 4,096-token window for instructions, schema, prompt and answer,
/// which a meeting transcript blows through in minutes. So:
///
/// 1. The transcript is cut on speaker turns into chunks that fit (`TranscriptChunker`).
///    On macOS 26.4+, every call is measured with `tokenCount(for:)` before it is made and
///    re-cut if it would not fit; earlier systems rely on the conservative estimate, and a
///    context overflow still triggers a re-cut.
/// 2. A meeting that fits one chunk is written in a single call.
/// 3. Otherwise each chunk is mapped to a `ChunkExtraction`, the extractions are cleaned
///    and merged in code (`NotesMerger`), consolidated by the model in groups if a very long
///    meeting's list is still too big, and reduced to the final notes.
///
/// Every call has its own session (a session holds one request at a time and accumulates a
/// transcript we do not want), a low temperature, a bounded answer and a timeout. Any
/// failure fails the whole generation: partial notes would silently omit part of the
/// meeting.
struct NotesEngine: Sendable {
    /// Model label stored in `MeetingNotes.model`.
    static let modelName = "Apple Foundation Models (on-device)"

    /// Per call. A full chunk prefills ~2,500 tokens and writes up to ~800; on Apple
    /// silicon that is well under a minute, so this only trips on a stalled model.
    var callTimeout: Duration = .seconds(90)
    /// Formatting work, not creative work.
    var temperature = 0.2
    /// Fewer words than this and there is nothing to summarise.
    var minimumWords = 25

    @concurrent
    func generate(
        _ request: NotesRequest,
        progress: @escaping @MainActor @Sendable (NotesProgress) -> Void
    ) async throws(NotesFailure) -> FinalNotesDraft {
        do {
            return try await run(request, progress: progress)
        } catch let failure as NotesFailure {
            throw failure
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw Self.classify(error)
        }
    }

    // MARK: - Pipeline

    private func run(
        _ request: NotesRequest,
        progress: @escaping @MainActor @Sendable (NotesProgress) -> Void
    ) async throws -> FinalNotesDraft {
        let model = SystemLanguageModel.default
        if let reason = FoundationModelFormatter.unavailableReason {
            throw NotesFailure.unavailable(reason)
        }
        let wordCount = request.lines.reduce(0) { $0 + $1.text.split(separator: " ").count }
        guard wordCount >= minimumWords else { throw NotesFailure.tooShort }

        await progress(.preparing)
        let budget = NotesBudget(contextSize: Self.contextSize(of: model))
        var context = request.context
        context.userNotes = NotesPrompts.trimmedUserNotes(context.userNotes, budget: budget.userNotesTokens)
        let hasUserNotes = !context.userNotes.isEmpty
        let chunks = TranscriptChunker.chunk(request.lines, budget: budget.chunkTokens(hasUserNotes: hasUserNotes))
        guard !chunks.isEmpty else { throw NotesFailure.tooShort }

        // Short meeting: one call, straight to the final notes.
        if chunks.count == 1 {
            let instructions = NotesPrompts.singlePassInstructions(context)
            let prompt = NotesPrompts.singlePassPrompt(chunks[0], context: context)
            if try await fits(instructions, prompt, FinalNotesOutput.self, budget) {
                await progress(.writing)
                do {
                    let output = try await respond(FinalNotesOutput.self, instructions, prompt, budget)
                    return try finish(output.draft, context: context, sourceText: chunks[0].text)
                } catch where Self.isContextOverflow(error) {
                    // Estimate was off for this text: fall through to map-reduce on halves.
                }
            }
        }

        // Map.
        var partials: [PartialNotes] = []
        let parts = try await fittedChunks(chunks, context: context, budget: budget)
        for (index, chunk) in parts.enumerated() {
            try Task.checkCancellation()
            await progress(.reading(index: index + 1, count: parts.count))
            let partial = try await map(chunk, index: index, count: parts.count, context: context, budget: budget, depth: 0)
            partials.append(contentsOf: partial)
        }

        // Reduce.
        await progress(.merging)
        let merged = try await consolidate(partials, context: context, budget: budget)
        await progress(.writing)
        let instructions = NotesPrompts.reduceInstructions(context)
        let prompt = NotesPrompts.reducePrompt(merged, context: context)
        let output = try await respond(FinalNotesOutput.self, instructions, prompt, budget)
        let knownNames = context.participants + merged.actionItems.compactMap { $0.owner }
        return try finish(output.draft, context: context, sourceText: NotesMerger.render(merged), knownNames: knownNames)
    }

    /// Maps one chunk; on a context overflow or a guardrail refusal, retries once on each
    /// half — a shorter excerpt is both smaller and less likely to trip a filter on one line.
    private func map(
        _ chunk: TranscriptChunk,
        index: Int,
        count: Int,
        context: NotesContext,
        budget: NotesBudget,
        depth: Int
    ) async throws -> [PartialNotes] {
        let instructions = NotesPrompts.mapInstructions(context)
        let prompt = NotesPrompts.mapPrompt(chunk, index: index, count: count, context: context)
        do {
            let output = try await respond(ChunkExtraction.self, instructions, prompt, budget)
            return [NotesMerger.clean(output.partial, chunk: chunk, participants: context.participants)]
        } catch where depth == 0 && chunk.lines.count > 1 && Self.isRetryableBySplitting(error) {
            var results: [PartialNotes] = []
            for half in Self.halves(chunk) {
                results += try await map(half, index: index, count: count, context: context, budget: budget, depth: depth + 1)
            }
            return results
        }
    }

    /// Re-cuts chunks whose real token count (macOS 26.4+) is over budget.
    private func fittedChunks(_ chunks: [TranscriptChunk], context: NotesContext, budget: NotesBudget) async throws -> [TranscriptChunk] {
        var result: [TranscriptChunk] = []
        for (index, chunk) in chunks.enumerated() {
            var pending = [chunk]
            var rounds = 0
            while let next = pending.first {
                pending.removeFirst()
                let instructions = NotesPrompts.mapInstructions(context)
                let prompt = NotesPrompts.mapPrompt(next, index: index, count: chunks.count, context: context)
                let fitsWindow = try await fits(instructions, prompt, ChunkExtraction.self, budget)
                if !fitsWindow, rounds < 4, next.lines.count > 1 {
                    pending.insert(contentsOf: Self.halves(next), at: 0)
                    rounds += 1
                } else {
                    result.append(next)
                }
            }
        }
        return result
    }

    /// Merges the extractions in code, then, while the result is too big for the reduce
    /// call, has the model consolidate groups of them. Three rounds at most; past that the
    /// least important items (quotes, then late recap points) are dropped to fit.
    private func consolidate(_ partials: [PartialNotes], context: NotesContext, budget: NotesBudget) async throws -> PartialNotes {
        let limit = budget.reduceInputTokens(hasUserNotes: !context.userNotes.isEmpty)
        var current = partials
        for _ in 0..<3 {
            let merged = NotesMerger.merge(current)
            if TokenEstimate.tokens(in: NotesMerger.render(merged)) <= limit { return merged }
            let groups = NotesMerger.batches(current, budget: limit)
            guard groups.count < current.count else { break }
            var next: [PartialNotes] = []
            for group in groups {
                try Task.checkCancellation()
                if group.count == 1 { next.append(group[0]); continue }
                let source = NotesMerger.merge(group)
                let output = try await respond(
                    ChunkExtraction.self,
                    NotesPrompts.consolidateInstructions(context),
                    NotesPrompts.consolidatePrompt(group, context: context),
                    budget
                )
                next.append(NotesMerger.cleanConsolidated(
                    output.partial,
                    source: source,
                    knownNames: context.participants
                ))
            }
            current = next
        }
        return NotesMerger.trim(NotesMerger.merge(current), toFit: limit)
    }

    private func finish(
        _ draft: FinalNotesDraft,
        context: NotesContext,
        sourceText: String,
        knownNames: [String]? = nil
    ) throws -> FinalNotesDraft {
        let cleaned = NotesMerger.clean(
            draft,
            knownNames: knownNames ?? context.participants,
            sourceText: sourceText + "\n" + context.userNotes
        )
        // A recap is the minimum: lists without one would be notes nobody can read.
        guard !cleaned.recap.isEmpty else { throw NotesFailure.empty }
        return cleaned
    }

    // MARK: - Calls

    private func respond<Output: Generable & Sendable>(
        _ type: Output.Type,
        _ instructions: String,
        _ prompt: String,
        _ budget: NotesBudget
    ) async throws -> Output {
        let options = GenerationOptions(temperature: temperature, maximumResponseTokens: budget.responseTokens)
        let timeout = callTimeout
        return try await withThrowingTaskGroup(of: Output.self) { group in
            group.addTask {
                let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
                let response = try await session.respond(
                    to: prompt,
                    generating: Output.self,
                    includeSchemaInPrompt: true,
                    options: options
                )
                return response.content
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw NotesFailure.timedOut
            }
            // Whichever finishes first wins; the loser is cancelled.
            guard let first = try await group.next() else { throw NotesFailure.timedOut }
            group.cancelAll()
            return first
        }
    }

    /// Whether instructions + prompt + schema + answer fit the window. Measured where the
    /// SDK can (macOS 26.4+); assumed true otherwise, the chunk sizes being estimates with a
    /// margin already.
    private func fits<Output: Generable>(
        _ instructions: String,
        _ prompt: String,
        _ type: Output.Type,
        _ budget: NotesBudget
    ) async throws -> Bool {
        // `tokenCount(for:)` first ships in the macOS 26.4 SDK (Swift 6.3). Older SDKs — CI's
        // Xcode among them — fall back to the estimate.
        #if compiler(>=6.3)
        guard #available(macOS 26.4, *) else { return true }
        let model = SystemLanguageModel.default
        do {
            let used = try await model.tokenCount(for: Instructions(instructions))
                + model.tokenCount(for: Prompt(prompt))
                + model.tokenCount(for: Output.generationSchema)
            return budget.fits(promptTokens: used)
        } catch {
            // Counting is an optimisation; the call itself still reports an overflow.
            return true
        }
        #else
        return true
        #endif
    }

    /// The model's context window. `contextSize` first ships in the macOS 26.4 SDK; before
    /// that the on-device model is documented at 4,096 tokens.
    static func contextSize(of model: SystemLanguageModel) -> Int {
        #if compiler(>=6.3)
        return model.contextSize
        #else
        return 4_096
        #endif
    }

    // MARK: - Errors

    private static func halves(_ chunk: TranscriptChunk) -> [TranscriptChunk] {
        let middle = chunk.lines.count / 2
        return [
            TranscriptChunk(lines: Array(chunk.lines[..<middle])),
            TranscriptChunk(lines: Array(chunk.lines[middle...])),
        ]
    }

    static func isContextOverflow(_ error: Error) -> Bool {
        // `LanguageModelError` is macOS 27 SDK (Swift 6.4) API.
        #if compiler(>=6.4)
        if #available(macOS 27.0, *), let error = error as? LanguageModelError,
           case .contextSizeExceeded = error {
            return true
        }
        #endif
        if let error = error as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = error {
            return true
        }
        return false
    }

    static func isRetryableBySplitting(_ error: Error) -> Bool {
        if isContextOverflow(error) { return true }
        return classify(error) == .declined
    }

    /// Maps SDK errors to what the user is told. Covers both the macOS 26
    /// `GenerationError` and the macOS 27 `LanguageModelError`.
    static func classify(_ error: Error) -> NotesFailure {
        if let failure = error as? NotesFailure { return failure }
        if error is CancellationError { return .cancelled }
        #if compiler(>=6.4)
        if #available(macOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded: return .failed("the transcript did not fit the on-device model.")
            case .guardrailViolation, .refusal: return .declined
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage
            case .timeout: return .timedOut
            case .rateLimited: return .failed("the on-device model is busy. Try Regenerate in a moment.")
            default: return .failed("the on-device model could not write them.")
            }
        }
        #endif
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return .failed("the transcript did not fit the on-device model.")
            case .assetsUnavailable: return .unavailable("the on-device model is unavailable.")
            case .guardrailViolation, .refusal: return .declined
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage
            case .rateLimited, .concurrentRequests:
                return .failed("the on-device model is busy. Try Regenerate in a moment.")
            case .decodingFailure, .unsupportedGuide: return .failed("the on-device model returned malformed notes.")
            @unknown default: return .failed("the on-device model could not write them.")
            }
        }
        return .failed("the on-device model could not write them.")
    }

    /// For the log: the kind of failure only, never content.
    static func logLabel(_ failure: NotesFailure) -> String {
        switch failure {
        case .unavailable: "unavailable"
        case .tooShort: "too short"
        case .timedOut: "timed out"
        case .declined: "declined by guardrails"
        case .unsupportedLanguage: "unsupported language"
        case .empty: "empty"
        case .cancelled: "cancelled"
        case .failed: "failed"
        }
    }
}
