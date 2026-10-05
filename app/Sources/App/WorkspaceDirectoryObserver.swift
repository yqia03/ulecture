import Foundation
import CoreServices

/// FSEvents is a hint to rescan the catalog, never the source of file identity.
/// Periodic and activation scans remain the recovery path for dropped events,
/// offline disks and platforms that cannot create a stream for a selected root.
@MainActor final class WorkspaceDirectoryObserver {
    private final class Callback {
        let action: @MainActor () -> Void
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    }
    private var stream: FSEventStreamRef?
    private var roots = [String]()
    private let onChange: () -> Void
    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    func observe(_ paths: [String]) {
        let next = Array(Set(paths)).sorted()
        guard next != roots else { return }
        stop(); roots = next
        guard !next.isEmpty else { return }
        let callback = Callback { [weak self] in self?.onChange() }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(callback).toOpaque(), retain: { pointer in
            guard let pointer else { return nil }
            return UnsafeRawPointer(Unmanaged<Callback>.fromOpaque(pointer).retain().toOpaque())
        }, release: { pointer in
            if let pointer { Unmanaged<Callback>.fromOpaque(pointer).release() }
        }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagIgnoreSelf)
        guard let stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            MainActor.assumeIsolated { Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().action() }
        }, &context, next as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); return }
        self.stream = stream
    }

    func stop() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil; roots = []
    }
    deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }
}
