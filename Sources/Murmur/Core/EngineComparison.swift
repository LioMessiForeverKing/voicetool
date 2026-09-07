import AVFoundation
import Foundation

/// One engine's result from a comparison run.
struct ComparisonResult: Sendable {
    let engine: String
    let text: String
    let seconds: Double
}

/// Runs the *same* captured audio through every engine, so a single hold produces a
/// directly comparable set of outputs.
///
/// Both engines are driven in batch from the identical buffer. Apple's engine can stream,
/// and does during normal dictation — but replaying a fixed buffer into both is the only
/// way to get numbers that mean the same thing on both sides.
enum EngineComparison {
    /// - Parameter onResult: called as each engine finishes, so the UI can show results
    ///   incrementally instead of waiting for the whole set.
    static func run(
        chunks: [AudioChunk],
        onResult: @MainActor (ComparisonResult) -> Void = { _ in }
    ) async -> [ComparisonResult] {
        var results: [ComparisonResult] = []
        // Sequential: two engines racing for the ANE would contaminate each other's timings.
        for (name, engine) in [
            ("Apple", AppleSpeechEngine() as any TranscriptionEngine),
            ("Parakeet", ParakeetEngine() as any TranscriptionEngine),
        ] {
            let result = await measure(name: name, engine: engine, chunks: chunks)
            results.append(result)
            await onResult(result)
        }
        return results
    }

    private static func measure(
        name: String,
        engine: any TranscriptionEngine,
        chunks: [AudioChunk]
    ) async -> ComparisonResult {
        do {
            let stream = try await engine.start()

            // Timed after start(), so model load is not read as an engine difference.
            let started = Date()

            let collector = Task { () -> String in
                var latest = ""
                for try await chunk in stream { latest = chunk.text }
                return latest
            }

            for chunk in chunks {
                await engine.feed(chunk)
            }
            await engine.finish()

            // A thrown stream surfaces as an error; failed and silent otherwise look identical.
            let text: String
            do {
                text = try await collector.value
            } catch {
                Log.speech.error("\(name, privacy: .public) stream failed: \(error.localizedDescription)")
                text = "⚠️ \(error.localizedDescription)"
            }

            return ComparisonResult(
                engine: name,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                seconds: Date().timeIntervalSince(started)
            )
        } catch {
            Log.speech.error("\(name, privacy: .public) comparison failed: \(error.localizedDescription)")
            await engine.finish()
            return ComparisonResult(engine: name, text: "⚠️ \(error.localizedDescription)", seconds: 0)
        }
    }
}
