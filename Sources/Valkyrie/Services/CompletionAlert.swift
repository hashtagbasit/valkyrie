import AppKit

/// Signals that a long operation has finished.
///
/// A full flash or a 20GB download runs long enough that nobody watches it, so the app
/// has to reach out when it's done. This deliberately avoids UserNotifications: that
/// framework needs a registered, signed bundle to behave, and an ad-hoc build would fail
/// silently. A sound plus a bouncing Dock icon works everywhere with no permissions.
enum CompletionAlert {
    static func signal(success: Bool) {
        NSSound(named: success ? "Glass" : "Basso")?.play()
        NSApp.requestUserAttention(success ? .informationalRequest : .criticalRequest)
    }
}
