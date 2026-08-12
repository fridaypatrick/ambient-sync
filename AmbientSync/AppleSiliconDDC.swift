// Portions of this file adapt the minimum Apple-silicon DDC transport and
// external-display write boundary from MonitorControl/Support/Arm64DDC.swift
// and MonitorControl/Model/OtherDisplay.swift at upstream commit
// f16d90f29cefbd9fff47e26fc8f99fe7a5280deb.
// Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES/MonitorControl-MIT.txt for the complete notice.

import Foundation

func ddcRawVCPValue(forPercent percent: Int, maximum: UInt16) -> UInt16 {
    guard maximum > 0 else { return 0 }

    let boundedPercent = min(max(percent, 0), 100)
    let scaledValue = (Double(boundedPercent) / 100.0 * Double(maximum)).rounded()
    let boundedValue = min(max(scaledValue, 0.0), Double(maximum))
    return UInt16(boundedValue)
}

public struct DDCBrightnessCapability: Equatable, Sendable {
    public let current: UInt16
    public let maximum: UInt16

    public init(current: UInt16, maximum: UInt16) {
        self.current = current
        self.maximum = maximum
    }
}

/// Single serialized owner for all Apple-silicon IOAVService handles and I2C
/// operations. Opaque C tokens never leave this actor as hardware handles.
public actor AppleSiliconDDCTransportProvider: ExternalDisplayTransportProvider {
    private struct Handle {
        let token: ASDDCServiceToken
        let generation: UInt64
        let capability: DDCBrightnessCapability
    }

    private var generation: UInt64 = 0
    private var handles: [UInt32: Handle] = [:]

    public init() {}

    public func rebuild(for displays: [DisplayRecord]) async -> [ExternalDisplayBinding] {
        invalidateHandles()
        generation &+= 1

        let externalDisplays = displays.filter { !$0.isBuiltIn }
        guard !externalDisplays.isEmpty else {
            return []
        }

        let displayIDs = externalDisplays.map(\.displayID)
        var tokens = [ASDDCServiceToken](repeating: 0, count: displayIDs.count)
        let matchedCount = displayIDs.withUnsafeBufferPointer { displayBuffer in
            tokens.withUnsafeMutableBufferPointer { tokenBuffer in
                ASDDCServiceCreateForDisplays(
                    displayBuffer.baseAddress,
                    displayBuffer.count,
                    tokenBuffer.baseAddress,
                    tokenBuffer.count
                )
            }
        }

        guard matchedCount > 0 else {
            return []
        }

        var bindings: [ExternalDisplayBinding] = []
        for (index, display) in externalDisplays.enumerated() {
            let token = tokens[index]
            guard token != 0 else { continue }

            var current: UInt16 = 0
            var maximum: UInt16 = 0
            guard ASDDCServiceReadVCP(token, DDCTarget.brightness.rawValue, &current, &maximum) else {
                ASDDCServiceDestroy(token)
                continue
            }

            let capability = DDCBrightnessCapability(current: current, maximum: maximum)
            handles[display.displayID] = Handle(
                token: token,
                generation: generation,
                capability: capability
            )
            let sink = AppleSiliconExternalBrightnessSink(
                provider: self,
                displayID: display.displayID,
                generation: generation
            )
            bindings.append(ExternalDisplayBinding(record: display, sink: sink))
        }

        return bindings
    }

    public func invalidate() async {
        invalidateHandles()
    }

    fileprivate func write(
        displayID: UInt32,
        generation requestedGeneration: UInt64,
        percent: Int
    ) -> Bool {
        guard let handle = handles[displayID], handle.generation == requestedGeneration else {
            return false
        }

        let rawValue = ddcRawVCPValue(forPercent: percent, maximum: handle.capability.maximum)
        return ASDDCServiceWriteVCP(handle.token, DDCTarget.brightness.rawValue, rawValue)
    }

    fileprivate func invalidate(
        displayID: UInt32,
        generation requestedGeneration: UInt64
    ) {
        guard let handle = handles[displayID], handle.generation == requestedGeneration else {
            return
        }
        ASDDCServiceDestroy(handle.token)
        handles.removeValue(forKey: displayID)
    }

    private func invalidateHandles() {
        for handle in handles.values {
            ASDDCServiceDestroy(handle.token)
        }
        handles.removeAll(keepingCapacity: true)
    }

    deinit {
        for handle in handles.values {
            ASDDCServiceDestroy(handle.token)
        }
    }
}

private enum DDCTarget: UInt8 {
    case brightness = 0x10
}

public struct AppleSiliconExternalBrightnessSink: ExternalBrightnessSink {
    private let provider: AppleSiliconDDCTransportProvider
    private let displayID: UInt32
    private let generation: UInt64

    fileprivate init(
        provider: AppleSiliconDDCTransportProvider,
        displayID: UInt32,
        generation: UInt64
    ) {
        self.provider = provider
        self.displayID = displayID
        self.generation = generation
    }

    public func writeBrightness(_ percent: Int) async -> Bool {
        await provider.write(
            displayID: displayID,
            generation: generation,
            percent: percent
        )
    }

    public func invalidate() async {
        await provider.invalidate(displayID: displayID, generation: generation)
    }
}
