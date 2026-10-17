@preconcurrency import AVFoundation
import Synchronization

/// Plays the IEC 61937 passthrough bytes of an mpv- or VLC-style audio output as APAC, through a
/// ``SpatialAudioRenderer`` on the host's synchronizer.
///
/// Every method returns at once and may be called from any thread, such as the player's audio thread:
///
/// ```swift
/// let sink = try SpatialAudioPassthroughSink(codec: .trueHDAtmos, synchronizer: synchronizer)
/// sink.begin(at: seekTime)                    // at the start and after every seek or discontinuity
/// let taken = sink.write(bursts)              // offer the rest again later
/// if sink.isReady { synchronizer.setRate(1, time: seekTime) }
/// sink.end()                                  // at the end of the stream
/// sink.close()
/// ```
///
/// Bytes wait in a bounded buffer while the renderer is full, so `write` takes only what fits. A
/// failure, such as content that is not Atmos or DTS:X, stops the timeline and calls `onFailure`
/// once; fall back to the host's own output. Native Atmos output also needs `AtmosOutputActivator`
/// from SpatialAudioPlayback, attached to the same synchronizer.
@available(macOS 26, iOS 26, tvOS 26, *)
public final class SpatialAudioPassthroughSink: Sendable {
    private struct Timeline {
        let input: AsyncStream<Data>.Continuation
        let feeder: Task<Void, Never>
    }

    private struct State {
        var timeline: Timeline?
        var generation = 0
        var readyGeneration = -1
        var buffered = 0
        var ended = false
        var failure: (any Error)?
        var closed = false
        var volume: Float = 1
        var muted = false
        var output: Task<Void, Never>?
    }

    private let renderer: SpatialAudioRenderer
    private let bufferLimit: Int
    private let onFailure: (@Sendable (any Error) -> Void)?
    private let state = Mutex(State())

    /// `bufferLimit` bounds the passthrough bytes waiting for the renderer; the default holds about
    /// a third of a second of TrueHD in MAT frames.
    public convenience init(codec: SpatialAudioCodec, configuration: APACConfiguration = .init(),
                            synchronizer: AVSampleBufferRenderSynchronizer, bufferLimit: Int = 1 << 20,
                            onFailure: (@Sendable (any Error) -> Void)? = nil) throws {
        self.init(renderer: try SpatialAudioRenderer(codec: codec, configuration: configuration, synchronizer: synchronizer),
                  bufferLimit: bufferLimit, onFailure: onFailure)
    }

    init(renderer: SpatialAudioRenderer, bufferLimit: Int, onFailure: (@Sendable (any Error) -> Void)?) {
        self.renderer = renderer
        self.bufferLimit = max(bufferLimit, 1)
        self.onFailure = onFailure
    }

    deinit { close() }

    /// Whether the current timeline holds enough APAC to start the clock, or has ended.
    public var isReady: Bool { state.withLock { $0.readyGeneration == $0.generation } }

    /// The error that stopped the current timeline, if any.
    public var failure: (any Error)? { state.withLock { $0.failure } }

    /// How much audio is queued ahead of the synchronizer's time, for the host's delay report.
    /// Bytes still waiting in the buffer are not counted.
    public var queuedAhead: CMTime {
        get async { await renderer.queuedAhead }
    }

    /// Starts a new timeline at `time`, dropping what the previous one queued: at the start, after
    /// a seek, and after an IEC 61937 pause burst or another discontinuity.
    public func begin(at time: CMTime) {
        let (bursts, input) = AsyncStream<Data>.makeStream()
        state.withLock { state in
            guard !state.closed else { return }
            state.generation += 1
            state.buffered = 0
            state.ended = false
            state.failure = nil
            let previous = state.timeline
            previous?.input.finish()
            previous?.feeder.cancel()
            let generation = state.generation
            // The feeder reports through weak references, so releasing the sink closes it.
            let report = Report(
                consumed: { [weak self] count in self?.consumed(count, generation: generation) },
                ready: { [weak self] in self?.markReady(generation) },
                failed: { [weak self] error in self?.fail(error, generation: generation) })
            let feeder = Task { [renderer] in
                await Self.feed(bursts, renderer: renderer, at: time, after: previous?.feeder, report: report)
            }
            state.timeline = Timeline(input: input, feeder: feeder)
        }
    }

    /// Queues passthrough bytes for the current timeline and returns how many it took: none before
    /// ``begin(at:)``, after ``end()`` or a failure, or while the buffer is full. Bursts may be split anywhere.
    @discardableResult
    public func write(_ bytes: Data) -> Int {
        state.withLock { state in
            guard let timeline = state.timeline, state.failure == nil, !state.ended else { return 0 }
            let taken = min(bytes.count, bufferLimit - state.buffered)
            guard taken > 0 else { return 0 }
            state.buffered += taken
            timeline.input.yield(bytes.prefix(taken))
            return taken
        }
    }

    /// Ends the current timeline's stream, so its last audio plays and ``isReady`` turns true even
    /// for a stream too short to fill the renderer.
    public func end() {
        state.withLock { state in
            state.ended = true
            return state.timeline
        }?.input.finish()
    }

    /// Sets the APAC output volume, from 0 to 1. A passthrough host's own volume never reaches it.
    public func setVolume(_ volume: Float) { updateOutput { $0.volume = volume } }

    /// Mutes or unmutes the APAC output.
    public func setMuted(_ muted: Bool) { updateOutput { $0.muted = muted } }

    /// Applies the latest volume and mute after any earlier update, so calls land in order.
    private func updateOutput(_ change: (inout State) -> Void) {
        state.withLock { state in
            change(&state)
            let previous = state.output
            state.output = Task { [weak self, renderer] in
                await previous?.value
                guard let latest = self?.state.withLock({ (volume: $0.volume, muted: $0.muted) }) else { return }
                await renderer.setVolume(latest.volume)
                await renderer.setMuted(latest.muted)
            }
        }
    }

    /// Stops playback for good. Releasing the sink does the same.
    public func close() {
        let timeline = state.withLock { state in
            defer {
                state.closed = true
                state.timeline = nil
                state.generation += 1
            }
            return state.closed ? nil : state.timeline
        }
        guard let timeline else { return }
        timeline.input.finish()
        timeline.feeder.cancel()
        // A feeder waiting for capacity on a stopped clock leaves with the new timeline.
        Task { [renderer] in try? await renderer.begin(at: .zero) }
    }

    private struct Report: Sendable {
        let consumed: @Sendable (Int) -> Void
        let ready: @Sendable () -> Void
        let failed: @Sendable (any Error) -> Void
    }

    private static func feed(_ bursts: AsyncStream<Data>, renderer: SpatialAudioRenderer, at time: CMTime,
                             after previous: Task<Void, Never>?, report: Report) async {
        do {
            // The first begin releases a previous feeder waiting for capacity; once it has left,
            // the second starts this timeline cleanly.
            try await renderer.begin(at: time)
            await previous?.value
            try Task.checkCancellation()
            try await renderer.begin(at: time)
            // Readiness is watched alongside, because an enqueue or the final flush can wait for
            // capacity that only the clock the host starts on it frees.
            let watcher = Task {
                while !Task.isCancelled {
                    if await renderer.isReadyToPlay { return report.ready() }
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            defer { watcher.cancel() }
            var unpacker = IEC61937Unpacker()
            var enqueued = false
            for await chunk in bursts {
                defer { report.consumed(chunk.count) }
                let stream = try unpacker.unpack(chunk)
                guard !stream.isEmpty else { continue }
                try await renderer.enqueue(stream, time: time + unpacker.skippedDuration)
                enqueued = true
            }
            guard !Task.isCancelled else { return }
            // A timeline that ended before any audio, such as one begun near the end, has nothing to play.
            guard enqueued else { return report.ready() }
            // A partial final burst does not discard audio already decoded.
            try? unpacker.finish()
            try await renderer.endOfStream()
            report.ready()
        } catch is CancellationError {
        } catch {
            // Drop queued APAC, so it cannot play over the host's fallback.
            try? await renderer.begin(at: time.isNumeric ? time : .zero)
            report.failed(error)
        }
    }

    private func consumed(_ count: Int, generation: Int) {
        state.withLock { if $0.generation == generation { $0.buffered -= count } }
    }

    private func markReady(_ generation: Int) {
        state.withLock { if $0.generation == generation { $0.readyGeneration = generation } }
    }

    private func fail(_ error: any Error, generation: Int) {
        let current = state.withLock { state in
            guard state.generation == generation, state.failure == nil, !state.closed else { return false }
            state.failure = error
            return true
        }
        if current { onFailure?(error) }
    }
}
