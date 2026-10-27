import Foundation
import CoreServices

/// A recursive FSEvents subscription owned by the open Review sheet. Git metadata
/// may live outside a linked worktree, so callers include its git/common directories.
final class RepositoryWatcher {
    let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var stream: FSEventStreamRef?

    private final class Sink {
        let continuation: AsyncStream<Void>.Continuation
        init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
    }

    init(directories: [String]) throws {
        let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        changes = channel.stream
        continuation = channel.continuation
        let sink = Sink(continuation)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                return UnsafeRawPointer(Unmanaged<Sink>.fromOpaque(info).retain().toOpaque())
            },
            release: { info in
                if let info { Unmanaged<Sink>.fromOpaque(info).release() }
            }, copyDescription: nil)
        let paths = Array(Set(directories.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })).sorted()
        guard !paths.isEmpty,
            let stream = FSEventStreamCreate(
                nil,
                { _, info, _, _, _, _ in
                    guard let info else { return }
                    Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue().continuation.yield(())
                }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        else {
            continuation.finish()
            throw GitFailure(message: "Unable to watch this repository for changes. Close and reopen Review to retry.")
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "com.spark.review-events", qos: .utility))
        guard FSEventStreamStart(stream) else {
            stop()
            throw GitFailure(message: "Unable to start live updates. Close and reopen Review to retry.")
        }
        // Covers edits between the initial Git read and establishing the stream.
        continuation.yield(())
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        continuation.finish()
    }

    deinit { stop() }
}
