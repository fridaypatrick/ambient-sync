// Portions of this file adapt the minimal built-in brightness call from
// MonitorControl/Model/AppleDisplay.swift at upstream commit
// f16d90f29cefbd9fff47e26fc8f99fe7a5280deb.
// Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES/MonitorControl-MIT.txt for the complete notice.

import Foundation

/// Private DisplayServices access is actor-confined and degrades to nil when
/// the weak-linked symbol is unavailable or returns an invalid value.
public actor DisplayServicesBrightnessSource: BuiltInBrightnessSource {
    public init() {}

    public func readBrightness(for displayID: UInt32) async -> Double? {
        var brightness: Float = 0
        guard ASDisplayServicesGetBrightness(displayID, &brightness) == 0,
              brightness.isFinite,
              brightness >= 0,
              brightness <= 1
        else {
            return nil
        }

        return Double(brightness)
    }
}
