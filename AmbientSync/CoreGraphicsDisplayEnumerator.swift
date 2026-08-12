// The enumeration shape follows the minimal CoreGraphics portion of
// MonitorControl/Support/DisplayManager.swift at upstream commit
// f16d90f29cefbd9fff47e26fc8f99fe7a5280deb.
// Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES/MonitorControl-MIT.txt for the complete notice.

import CoreGraphics
import Foundation

/// Enumerates active displays using public CoreGraphics APIs. All calls occur
/// on this actor's executor, never from the CoreGraphics reconfiguration
/// callback or the main actor.
public actor CoreGraphicsDisplayEnumerator: DisplayEnumerator {
    public init() {}

    public func enumerate() async -> [DisplayRecord] {
        var displayCapacity: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCapacity) == .success,
              displayCapacity > 0
        else {
            return []
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCapacity))
        var displayCount: UInt32 = 0

        let result = displayIDs.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(displayCapacity, buffer.baseAddress, &displayCount)
        }
        guard result == .success, displayCount <= displayCapacity else {
            return []
        }

        return displayIDs.prefix(Int(displayCount)).compactMap { displayID in
            guard displayID != 0 else { return nil }

            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
            let descriptor = DisplayDescriptor(
                serialNumber: serialNumber(for: displayID),
                vendorID: nonZero(CGDisplayVendorNumber(displayID)),
                productID: nonZero(CGDisplayModelNumber(displayID)),
                displayID: displayID
            )
            let name = isBuiltIn ? "Built-in display" : "External display"
            return DisplayRecord(
                displayID: displayID,
                name: name,
                descriptor: descriptor,
                isBuiltIn: isBuiltIn
            )
        }
    }

    private func nonZero(_ value: UInt32) -> UInt32? {
        value == 0 ? nil : value
    }

    private func serialNumber(for displayID: CGDirectDisplayID) -> String? {
        let serial = CGDisplaySerialNumber(displayID)
        return serial == 0 ? nil : String(serial)
    }

}
