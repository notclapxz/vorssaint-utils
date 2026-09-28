// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// A recording left behind by a quit or a crash comes back in its editor.
///
/// Upstream ties a recording's life to its editor window, which is right for
/// a person closing it and wrong for the app going away: a reinstall once quit
/// the app over an unexported exam recording and the file was gone, with no
/// trash and no backup to bring it back. So a quit keeps the recording, and
/// the next launch opens it again before anything sweeps old folders.
enum RecorderTakeRecovery {
    /// Set once the app has agreed to quit. From then on an editor closing is
    /// the app leaving, not the person throwing the recording away.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var quitting = false

    static var isQuitting: Bool { lock.withLock { quitting } }

    static func appWillQuit() {
        lock.withLock { quitting = true }
    }

    /// The recordings worth an editor again: those with a master that no open
    /// editor or running recording already owns. A folder with no master
    /// never held a finished recording and is left to the sweep.
    static func takesToReopen(_ takes: [(id: UUID, hasMaster: Bool)],
                              owned: Set<UUID>) -> [UUID] {
        takes.filter { $0.hasMaster && !owned.contains($0.id) }.map(\.id)
    }
}
