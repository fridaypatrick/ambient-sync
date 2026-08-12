// Portions of this header adapt the minimum private display declarations from
// MonitorControl/Support/Bridging-Header.h and the Apple-silicon transport
// boundary from MonitorControl/Support/Arm64DDC.swift at upstream commit
// f16d90f29cefbd9fff47e26fc8f99fe7a5280deb.
// Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES/MonitorControl-MIT.txt for the complete notice.

#pragma once

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Private IOAVService handles never cross the Swift actor boundary. Swift
/// receives an opaque integer token and passes it back only on the serialized
/// AppleSiliconDDCTransportProvider actor.
typedef uint64_t ASDDCServiceToken;

/// Returns zero on success and a negative value when DisplayServices is
/// unavailable or returns an invalid brightness value.
int ASDisplayServicesGetBrightness(CGDirectDisplayID display, float *brightness);

/// Matches external CoreGraphics displays to external IOAVService handles.
/// `tokens` is indexed like `displayIDs`; zero means no usable match.
size_t ASDDCServiceCreateForDisplays(
    const CGDirectDisplayID *displayIDs,
    size_t displayCount,
    ASDDCServiceToken *tokens,
    size_t tokenCapacity
);

void ASDDCServiceDestroy(ASDDCServiceToken token);

bool ASDDCServiceReadVCP(
    ASDDCServiceToken token,
    uint8_t feature,
    uint16_t *currentValue,
    uint16_t *maximumValue
);

bool ASDDCServiceWriteVCP(
    ASDDCServiceToken token,
    uint8_t feature,
    uint16_t value
);

#ifdef __cplusplus
}
#endif
