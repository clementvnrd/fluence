// Vendored from mlx-audio-swift v0.1.9 (github.com/Neywa-Labs/mlx-audio-swift, MIT, Copyright (c) 2025 Prince Canuma; LICENSE beside it),
// FLU-149. Trimmed to the batch transcription path Fluence uses.
import Foundation
import MLX
import MLXNN

private struct CoherePrefillContext {
    let adapterOut: MLXArray
    let promptLength: Int
    var logits: MLXArray
    var cache: CohereTranscribeDecoderKVCache?
    let startTime: Date
}

private let cohereWeightPrefixAliases: [(source: String, target: String)] = [
    ("encoder.pre_encode.", "encoder.subsampling."),
    ("encoder_decoder_proj.", "bridge_proj."),
    ("log_softmax.mlp.layer0.", "lm_head."),
    ("transf_decoder.embedding.", "decoder.embedding."),
    ("transf_decoder._embedding.", "decoder.embedding."),
    ("transf_decoder.decoder.", "decoder.core."),
    ("transf_decoder._decoder.", "decoder.core."),
]

private struct CohereCheckpointLoadError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private func cohereAcceptedAliases(for expectedKey: String) -> [String] {
    cohereWeightPrefixAliases.compactMap { alias in
        guard expectedKey.hasPrefix(alias.target) else { return nil }
        return expectedKey.replacingOccurrences(of: alias.target, with: alias.source)
    }
}

private func isOptionalCohereParameter(_ key: String, config: CohereTranscribeConfig) -> Bool {
    if key.hasPrefix("bridge_proj.") {
        return config.encoder.dModel == config.decoder.hiddenSize
    }
    return false
}

private func cohereQuantizationSummary(_ config: CohereTranscribeConfig) -> String {
    let globalBits = config.quantization.map { String($0.bits) } ?? "none"
    let globalGroupSize = config.quantization.map { String($0.groupSize) } ?? "none"
    return "model_type=\(config.modelType), bits=\(globalBits), group_size=\(globalGroupSize)"
}

private func cohereInventoryContext(for key: String, config: CohereTranscribeConfig) -> String {
    let acceptedAliases = cohereAcceptedAliases(for: key).sorted()
    let aliasSummary = acceptedAliases.isEmpty
        ? "accepted_aliases=none"
        : "accepted_aliases=\(acceptedAliases.joined(separator: ", "))"
    return "\(aliasSummary); optional_by_config=\(isOptionalCohereParameter(key, config: config)); \(cohereQuantizationSummary(config))"
}

private func cohereIsFloatingDType(_ dtype: DType) -> Bool {
    switch dtype {
    case .float16, .bfloat16, .float32:
        return true
    default:
        return false
    }
}

private func cohereCompanionBaseKey(for key: String) -> String? {
    for suffix in [".scales", ".biases"] {
        guard key.hasSuffix(suffix) else { continue }
        return String(key.dropLast(suffix.count)) + ".weight"
    }
    return nil
}

private func cohereCompanionKey(for baseKey: String, suffix: String) -> String {
    if baseKey.hasSuffix(".weight") {
        return String(baseKey.dropLast(".weight".count)) + suffix
    }
    return baseKey + suffix
}

private func cohereQKVSpec(for key: String) -> (prefix: String, part: String, suffix: String)? {
    for (needle, part) in [
        (".linear_q.", "q"),
        (".linear_k.", "k"),
        (".linear_v.", "v"),
        (".query_net.", "q"),
        (".key_net.", "k"),
        (".value_net.", "v"),
    ] {
        guard let range = key.range(of: needle) else { continue }
        let prefix = String(key[..<range.lowerBound])
        let suffix = String(key[range.upperBound...])
        if ["weight", "bias", "scales", "biases"].contains(suffix) {
            return (prefix, part, suffix)
        }
    }

    return nil
}

private func cohereMapWeightKeyName(_ key: String) -> String {
    let prefixMapped = cohereWeightPrefixAliases.first { key.hasPrefix($0.source) }.map {
        key.replacingOccurrences(of: $0.source, with: $0.target)
    } ?? key

    return prefixMapped
        .replacingOccurrences(of: "self_attn.linear_out.", with: "self_attn.out_proj.")
        .replacingOccurrences(of: "self_attn.linear_pos.", with: "self_attn.pos_proj.")
        .replacingOccurrences(of: "first_sub_layer.out_projection.", with: "first_sub_layer.out_proj.")
        .replacingOccurrences(of: "second_sub_layer.out_projection.", with: "second_sub_layer.out_proj.")
}

private func cohereValidateWeightInventory(
    model: CohereTranscribeModel,
    weights: [String: MLXArray],
    config: CohereTranscribeConfig
) throws {
    let expectedParameters = Dictionary(uniqueKeysWithValues: model.parameters().flattened().map { ($0.0, $0.1) })
    let quantizationActive = config.quantization != nil

    let providedBaseKeys = Set(weights.keys.filter { cohereCompanionBaseKey(for: $0) == nil })
    let providedCompanionKeys = Set(weights.keys.filter { cohereCompanionBaseKey(for: $0) != nil })

    for companionKey in providedCompanionKeys {
        guard let baseKey = cohereCompanionBaseKey(for: companionKey) else { continue }
        guard expectedParameters[baseKey] != nil else {
            throw CohereCheckpointLoadError(
                message: "Quantized companion tensor \(companionKey) resolves to no Swift module parameter. \(cohereInventoryContext(for: companionKey, config: config))"
            )
        }
    }

    for baseKey in expectedParameters.keys
    where !baseKey.hasSuffix(".scales")
        && !baseKey.hasSuffix(".biases")
        && !providedBaseKeys.contains(baseKey)
        && !isOptionalCohereParameter(baseKey, config: config)
    {
        throw CohereCheckpointLoadError(
            message: "Missing required tensor \(baseKey). \(cohereInventoryContext(for: baseKey, config: config))"
        )
    }

    for (key, value) in weights where cohereCompanionBaseKey(for: key) == nil {
        guard let expected = expectedParameters[key] else {
            throw CohereCheckpointLoadError(
                message: "Unexpected tensor \(key) does not match any Swift module parameter. \(cohereInventoryContext(for: key, config: config))"
            )
        }

        let scalesKey = cohereCompanionKey(for: key, suffix: ".scales")
        let biasesKey = cohereCompanionKey(for: key, suffix: ".biases")
        let hasQuantizedCompanion = providedCompanionKeys.contains(scalesKey)
        let isPackedQuantized = quantizationActive && !cohereIsFloatingDType(value.dtype)

        if hasQuantizedCompanion || isPackedQuantized {
            if !hasQuantizedCompanion {
                let siblingPrefix = String(key.dropLast(".weight".count))
                let siblingKeys = weights.keys.filter { $0.hasPrefix(siblingPrefix) }.sorted()
                throw CohereCheckpointLoadError(
                    message: "Packed quantized tensor \(key) is missing matching .scales companion. sibling_keys=\(siblingKeys). \(cohereInventoryContext(for: key, config: config))"
                )
            }

            guard let scales = weights[scalesKey] else {
                throw CohereCheckpointLoadError(
                    message: "Quantized tensor \(key) is missing required \(scalesKey) companion. \(cohereInventoryContext(for: key, config: config))"
                )
            }
            if let biases = weights[biasesKey], biases.shape != scales.shape {
                throw CohereCheckpointLoadError(
                    message: "Quantized tensor \(key) has incompatible companion shapes: scales=\(scales.shape), biases=\(biases.shape). \(cohereInventoryContext(for: key, config: config))"
                )
            }
            continue
        }

        guard value.shape == expected.shape else {
            throw CohereCheckpointLoadError(
                message: "Shape mismatch for \(key): expected \(expected.shape), got \(value.shape). \(cohereInventoryContext(for: key, config: config))"
            )
        }
    }
}

private func extractMissingCohereKey(from errorDescription: String) -> String? {
    let marker = "Key "
    let suffix = " not found"

    guard let markerRange = errorDescription.range(of: marker) else { return nil }
    let afterMarker = errorDescription[markerRange.upperBound...]
    guard let suffixRange = afterMarker.range(of: suffix) else { return nil }
    return String(afterMarker[..<suffixRange.lowerBound])
}

func normalizeCohereWeightKeys(_ weights: [String: MLXArray]) -> [String: MLXArray] {
    var normalized = [String: MLXArray](minimumCapacity: weights.count)
    var pendingQKV: [String: [String: MLXArray]] = [:]
    let replacements = [
        "encoder.subsampling.conv.0.": "encoder.subsampling.conv0.",
        "encoder.subsampling.conv.2.": "encoder.subsampling.conv2.",
        "encoder.subsampling.conv.3.": "encoder.subsampling.conv3.",
        "encoder.subsampling.conv.5.": "encoder.subsampling.conv5.",
        "encoder.subsampling.conv.6.": "encoder.subsampling.conv6.",
    ]
    let subsamplingKernelShapes = [
        "encoder.subsampling.conv0.weight": [3, 3],
        "encoder.subsampling.conv2.weight": [3, 3],
        "encoder.subsampling.conv3.weight": [1, 1],
        "encoder.subsampling.conv5.weight": [3, 3],
        "encoder.subsampling.conv6.weight": [1, 1],
    ]

    for (key, value) in weights {
        if key.hasSuffix(".num_batches_tracked") || key.hasPrefix("preprocessor.") {
            continue
        }

        if let (prefix, part, suffix) = cohereQKVSpec(for: key) {
            let mergedPrefix = cohereMapWeightKeyName(prefix)
            let mergedKey = "\(mergedPrefix).qkv_proj.\(suffix)"
            pendingQKV[mergedKey, default: [:]][part] = value
            continue
        }

        let initiallyMappedKey = cohereMapWeightKeyName(key)
        let mappedKey = replacements.first { initiallyMappedKey.hasPrefix($0.key) }.map {
            initiallyMappedKey.replacingOccurrences(of: $0.key, with: $0.value)
        } ?? initiallyMappedKey

        if mappedKey.hasPrefix("decoder.embedding.position_embedding") {
            continue
        }

        if mappedKey.hasSuffix(".weight"), value.ndim == 4, let kernelShape = subsamplingKernelShapes[mappedKey] {
            if value.shape[1] == kernelShape[0], value.shape[2] == kernelShape[1] {
                normalized[mappedKey] = value
            } else if value.shape[2] == kernelShape[0], value.shape[3] == kernelShape[1] {
                normalized[mappedKey] = value.transposed(0, 2, 3, 1)
            } else {
                normalized[mappedKey] = value
            }
        } else if mappedKey.hasSuffix(".weight"), value.ndim == 3, mappedKey.contains(".conv.") {
            let likelyPyTorchLayout: Bool
            if mappedKey.contains("depthwise_conv") {
                likelyPyTorchLayout = value.shape[1] == 1 && value.shape[2] > 1
            } else {
                likelyPyTorchLayout = value.shape[2] == 1 && value.shape[1] > 1
            }
            normalized[mappedKey] = likelyPyTorchLayout ? value.transposed(0, 2, 1) : value
        } else {
            normalized[mappedKey] = value
        }
    }

    for (mergedKey, parts) in pendingQKV {
        guard let q = parts["q"], let k = parts["k"], let v = parts["v"] else {
            continue
        }
        normalized[mergedKey] = MLX.concatenated([q, k, v], axis: 0)
    }

    return normalized
}

public final class CohereTranscribeModel: Module {
    public let config: CohereTranscribeConfig

    @ModuleInfo(key: "encoder") var encoder: ConformerEncoder
    @ModuleInfo(key: "decoder") var decoder: TransformerDecoderWrapper
    @ModuleInfo(key: "bridge_proj") var bridgeProj: Linear?
    @ModuleInfo(key: "lm_head") var lmHead: Linear

    private var tokenizer: CohereTranscribeTokenizer?

    public init(_ config: CohereTranscribeConfig) {
        self.config = config
        self._encoder.wrappedValue = ConformerEncoder(config.encoder)
        self._decoder.wrappedValue = TransformerDecoderWrapper(config: config)

        if config.encoder.dModel != config.decoder.hiddenSize {
            self._bridgeProj.wrappedValue = Linear(config.encoder.dModel, config.decoder.hiddenSize)
        }
        self._lmHead.wrappedValue = Linear(config.decoder.hiddenSize, config.vocabSize)
    }

    /// Greedy transcription of 16 kHz mono samples (Fluence, FLU-149). Audio longer than
    /// `chunkSeconds` is cut at a quiet point — the model was trained on clips up to 35 s — and
    /// each chunk's output stops after `maxTokens(chunk seconds)` tokens, so a decoder loop
    /// cannot run on to the context limit.
    public func transcribe(
        _ samples: [Float],
        language: String,
        chunkSeconds: Float = 30,
        maxTokens: (Double) -> Int
    ) -> String {
        let chunks = splitAudioIntoChunks(MLXArray(samples), sampleRate: config.sampleRate, chunkDuration: chunkSeconds)
        return chunks
            .map { chunk, _ in
                generateSingleChunk(
                    audio: chunk,
                    language: language,
                    maxTokens: maxTokens(Double(chunk.dim(0)) / Double(config.sampleRate))
                )
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func generateSingleChunk(audio: MLXArray, language: String, maxTokens: Int) -> String {
        var context = encodeAndPrefill(audio: audio, language: language)
        var generated: [Int] = []
        let eosTokenId = tokenizer?.encode(text: "<|endoftext|>").first ?? 0
        let maxGenerationTokens = min(max(0, maxTokens), max(0, config.decoder.maxSequenceLength - context.promptLength))

        for pos in context.promptLength..<(context.promptLength + maxGenerationTokens) {
            let token = context.logits.squeezed().argMax(axis: -1).item(Int.self)
            generated.append(token)
            if token == eosTokenId { break }

            let inputIds = MLXArray([Int32(token)]).expandedDimensions(axis: 0)
            let positions = MLXArray([Int32(pos)]).expandedDimensions(axis: 0)
            let next = decoder(
                inputIds: inputIds,
                positions: positions,
                encoderHiddenStates: context.adapterOut,
                selfAttentionMask: nil,
                crossAttentionMask: nil,
                cache: context.cache
            )
            context.cache = next.1
            context.logits = lmHead(next.0[0, -1])
            eval(context.logits)
            if generated.count % 256 == 0 {
                Memory.clearCache()
            }
        }

        if generated.last == eosTokenId {
            _ = generated.popLast()
        }
        Memory.clearCache()
        return tokenizer?.decode(tokens: generated).trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private extension CohereTranscribeModel {
    func encodeAndPrefill(
        audio: MLXArray,
        language: String
    ) -> CoherePrefillContext {
        let start = Date()
        guard let tokenizer else {
            fatalError("CohereTranscribeTokenizer must be loaded before generation")
        }

        let melFilters = CohereTranscribeAudio.computeMelFilters(
            sampleRate: config.sampleRate,
            nFft: 512,
            numMels: config.encoder.featIn
        )
        
        let features = CohereTranscribeAudio.computeFeatures(
            audio: audio,
            melFilters: melFilters,
            nFft: 512,
            winLength: 400,
            hopLength: 160
        )

        let (encOut, _) = encoder(features)
        
        let adapterOut: MLXArray
        if let bridgeProj = bridgeProj {
            adapterOut = bridgeProj(encOut)
        } else {
            adapterOut = encOut
        }

        let promptIds = tokenizer.buildPromptTokens(
            language: language,
            usePunctuation: true,
            useTimestamps: false
        )
        
        let promptLength = promptIds.count
        let promptIdsMX = MLXArray(promptIds.map(Int32.init)).expandedDimensions(axis: 0)
        let positions = MLXArray((0..<promptLength).map(Int32.init)).expandedDimensions(axis: 0)
        let selfMask = MultiHeadAttention.createAdditiveCausalMask(promptLength).asType(adapterOut.dtype)

        let prefill = decoder(
            inputIds: promptIdsMX,
            positions: positions,
            encoderHiddenStates: adapterOut,
            selfAttentionMask: selfMask,
            crossAttentionMask: nil,
            cache: nil
        )
        
        let h = prefill.0
        let cache = prefill.1

        let logits = lmHead(h[0, -1])
        
        var cacheArrays: [MLXArray] = [logits]
        for layerCache in cache.layers {
            if let selfKeys = layerCache.selfKeys, let selfValues = layerCache.selfValues {
                cacheArrays.append(selfKeys)
                cacheArrays.append(selfValues)
            }
            if let crossKeys = layerCache.crossKeys, let crossValues = layerCache.crossValues {
                cacheArrays.append(crossKeys)
                cacheArrays.append(crossValues)
            }
        }
        eval(cacheArrays)

        return CoherePrefillContext(
            adapterOut: adapterOut,
            promptLength: promptLength,
            logits: logits,
            cache: cache,
            startTime: start
        )
    }
}

public extension CohereTranscribeModel {
    static func fromDirectory(_ modelDir: URL) throws -> CohereTranscribeModel {
        let configURL = modelDir.appendingPathComponent("config.json")
        let configData = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(CohereTranscribeConfig.self, from: configData)

        let model = CohereTranscribeModel(config)
        model.tokenizer = try CohereTranscribeTokenizer(modelDir: modelDir, config: config)

        let files = try FileManager.default.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil)
        let safetensors = files.filter { $0.pathExtension == "safetensors" }

        guard !safetensors.isEmpty else {
            throw CohereCheckpointLoadError(
                message: "Failed to load Cohere checkpoint from \(modelDir.path): no .safetensors files found. \(cohereQuantizationSummary(config))"
            )
        }

        var weights: [String: MLXArray] = [:]
        for file in safetensors {
            let shard = try MLX.loadArrays(url: file)
            weights.merge(shard) { _, new in new }
        }

        let sanitizedWeights = normalizeCohereWeightKeys(weights)

        if config.quantization != nil {
            quantize(model: model) { path, _ in
                guard sanitizedWeights["\(path).scales"] != nil else {
                    return nil
                }

                return config.quantization?.asTuple
            }
        }

        try cohereValidateWeightInventory(model: model, weights: sanitizedWeights, config: config)

        do {
            try model.update(parameters: ModuleParameters.unflattened(sanitizedWeights), verify: .all)
        } catch {
            let expectedKeys = Set(model.parameters().flattened().map(\.0))
            let providedKeys = Set(sanitizedWeights.keys)
            let missingRequiredKeys = expectedKeys
                .filter { !providedKeys.contains($0) && !isOptionalCohereParameter($0, config: config) }
                .sorted()
            let highlightedKey = extractMissingCohereKey(from: error.localizedDescription)
                ?? missingRequiredKeys.first
                ?? expectedKeys.subtracting(providedKeys).sorted().first

            let aliasSummary: String
            if let highlightedKey {
                let aliases = cohereAcceptedAliases(for: highlightedKey).sorted()
                aliasSummary = aliases.isEmpty ? "accepted_aliases=none" : "accepted_aliases=\(aliases.joined(separator: ", "))"
            } else {
                aliasSummary = "accepted_aliases=unknown"
            }

            let optionalSummary: String
            if let highlightedKey {
                optionalSummary = "optional_by_config=\(isOptionalCohereParameter(highlightedKey, config: config))"
            } else {
                optionalSummary = "optional_by_config=unknown"
            }

            let missingSummary = highlightedKey.map { "missing_key=\($0)" } ?? "missing_key=unknown"

            throw CohereCheckpointLoadError(
                message: "Failed to load Cohere checkpoint from \(modelDir.path): \(error.localizedDescription). \(missingSummary); \(aliasSummary); \(optionalSummary); \(cohereQuantizationSummary(config))"
            )
        }
        model.train(false)
        eval(model)

        return model
    }
}

// From mlx-audio-swift's Qwen3ASR.swift, same licence.
/// Split long audio into chunks at low-energy boundaries.
///
/// - Parameters:
///   - audio: 1D audio waveform as MLXArray
///   - sampleRate: Sample rate of the audio
///   - chunkDuration: Maximum chunk duration in seconds (default: 1200 = 20 min)
///   - minChunkDuration: Minimum chunk duration in seconds (default: 1.0)
///   - searchExpandSec: Window to search for silence around cut point (default: 5.0)
///   - minWindowMs: Minimum window size for energy calculation in ms (default: 100.0)
/// - Returns: Array of (chunk waveform, offset in seconds) tuples
func splitAudioIntoChunks(
    _ audio: MLXArray,
    sampleRate: Int,
    chunkDuration: Float = 1200.0,
    minChunkDuration: Float = 1.0,
    searchExpandSec: Float = 5.0,
    minWindowMs: Float = 100.0
) -> [(MLXArray, Float)] {
    // Ensure 1D
    let wav: MLXArray
    if audio.ndim > 1 {
        wav = audio.mean(axis: -1)
    } else {
        wav = audio
    }

    let totalSamples = wav.dim(0)
    let totalSec = Float(totalSamples) / Float(sampleRate)

    if totalSec <= chunkDuration {
        if totalSec < minChunkDuration {
            let minSamples = Int(minChunkDuration * Float(sampleRate))
            let padWidth = minSamples - totalSamples
            if padWidth > 0 {
                let padded = MLX.padded(wav, widths: [IntOrPair((0, padWidth))])
                return [(padded, 0.0)]
            }
        }
        return [(wav, 0.0)]
    }

    var chunks: [(MLXArray, Float)] = []
    var startSample = 0
    let maxChunkSamples = Int(chunkDuration * Float(sampleRate))
    let searchSamples = Int(searchExpandSec * Float(sampleRate))
    let minWindowSamples = Int(minWindowMs * Float(sampleRate) / 1000.0)
    let minSamples = Int(minChunkDuration * Float(sampleRate))

    while startSample < totalSamples {
        let endSample = min(startSample + maxChunkSamples, totalSamples)

        if endSample >= totalSamples {
            let chunkLen = totalSamples - startSample
            var chunk = wav[startSample..<totalSamples]
            let offsetSec = Float(startSample) / Float(sampleRate)
            if chunkLen < minSamples {
                let padWidth = minSamples - chunkLen
                chunk = MLX.padded(chunk, widths: [IntOrPair((0, padWidth))])
            }
            chunks.append((chunk, offsetSec))
            break
        }

        // Search for low-energy point around the cut
        let searchStart = max(startSample, endSample - searchSamples)
        let searchEnd = min(totalSamples, endSample + searchSamples)

        var cutSample: Int
        let searchLen = searchEnd - searchStart
        if searchLen > minWindowSamples {
            // Only pull the search region to CPU for energy calculation
            let searchRegion = wav[searchStart..<searchEnd].asArray(Float.self)

            let energyLen = searchRegion.count - minWindowSamples + 1
            var energy = [Float](repeating: 0, count: energyLen)
            let invWindow = 1.0 / Float(minWindowSamples)

            var windowSum: Float = 0
            for i in 0..<minWindowSamples {
                windowSum += searchRegion[i] * searchRegion[i]
            }
            energy[0] = windowSum * invWindow

            for i in 1..<energyLen {
                let oldVal = searchRegion[i - 1]
                let newVal = searchRegion[i + minWindowSamples - 1]
                windowSum += newVal * newVal - oldVal * oldVal
                energy[i] = windowSum * invWindow
            }

            // Find minimum energy point
            var minIdx = 0
            var minEnergy = energy[0]
            for i in 1..<energyLen {
                if energy[i] < minEnergy {
                    minEnergy = energy[i]
                    minIdx = i
                }
            }
            minIdx += minWindowSamples / 2
            cutSample = searchStart + minIdx
        } else {
            cutSample = endSample
        }

        cutSample = max(cutSample, startSample + sampleRate)

        let actualEnd = min(cutSample, totalSamples)
        let chunkLen = actualEnd - startSample
        var chunk = wav[startSample..<actualEnd]
        let offsetSec = Float(startSample) / Float(sampleRate)

        if chunkLen < minSamples {
            let padWidth = minSamples - chunkLen
            chunk = MLX.padded(chunk, widths: [IntOrPair((0, padWidth))])
        }

        chunks.append((chunk, offsetSec))
        startSample = cutSample
    }

    return chunks
}
