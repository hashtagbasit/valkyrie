import Foundation
import IOKit.pwr_mgt

/// Holds the Mac awake for the duration of a long operation.
///
/// A flash or a multi-gigabyte download can easily outlast the idle-sleep timer, and
/// a machine that sleeps mid-write to the bootloader is exactly how a phone gets
/// bricked. The assertion allows the display to sleep but not the system.
final class PowerAssertion {
    private var assertionID: IOPMAssertionID = 0
    private var held = false

    private let reason: String

    init(reason: String) {
        self.reason = reason
    }

    func acquire() {
        guard !held else { return }
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        held = (status == kIOReturnSuccess)
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(assertionID)
        held = false
    }

    deinit {
        release()
    }
}
