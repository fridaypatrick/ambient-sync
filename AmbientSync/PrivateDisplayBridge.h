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

typedef enum ASDDCMatchConfidence {
    ASDDCMatchConfidenceNone = 0,
    ASDDCMatchConfidenceLow = 1,
    ASDDCMatchConfidenceHigh = 2
} ASDDCMatchConfidence;

typedef struct ASDDCMatchEvidence {
    int score;
    bool locationMatch;
    uint8_t independentSignalCount;
} ASDDCMatchEvidence;

/// Returns zero on success and a negative value when DisplayServices is
/// unavailable or returns an invalid brightness value.
int ASDisplayServicesGetBrightness(CGDirectDisplayID display, float *brightness);

/// Copies a localized product name from existing CoreDisplay metadata.
/// Returns false when metadata is unavailable.
bool ASDisplayCopyProductName(
    CGDirectDisplayID display,
    char *buffer,
    size_t capacity
);

/// Matches external CoreGraphics displays to external IOAVService handles.
/// `tokens` is indexed like `displayIDs`; zero means no usable match.
size_t ASDDCServiceCreateForDisplays(
    const CGDirectDisplayID *displayIDs,
    size_t displayCount,
    ASDDCServiceToken *tokens,
    size_t tokenCapacity
);

/// Matches displays and returns an explicit confidence classification for each
/// token. Confidence is high only for an unambiguous IODisplayLocation match
/// or at least three independent metadata dimensions. Matching remains bounded
/// and does not perform DDC writes.
size_t ASDDCServiceCreateForDisplaysWithConfidence(
    const CGDirectDisplayID *displayIDs,
    size_t displayCount,
    ASDDCServiceToken *tokens,
    ASDDCMatchConfidence *confidences,
    size_t tokenCapacity
);

/// Scores display/service metadata without accessing CoreDisplay or IOKit.
/// Vendor+product EDID identity is one dimension; manufacture metadata,
/// physical dimensions, product name, and serial are separate dimensions.
ASDDCMatchEvidence ASDDCScoreMatchEvidence(
    const char *displayLocation,
    const char *serviceLocation,
    const char *displayProductName,
    const char *serviceProductName,
    int64_t displaySerial,
    int64_t serviceSerial,
    int64_t manufactureYear,
    int64_t manufactureWeek,
    int64_t vendorID,
    int64_t productID,
    int64_t horizontalSize,
    int64_t verticalSize,
    const char *serviceEDIDUUID
);

/// Pure confidence rule used by service matching and deterministic tests.
ASDDCMatchConfidence ASDDCClassifyMatchConfidence(
    bool locationMatch,
    uint8_t independentSignalCount
);

/// Classifies an assigned pair only when it is the unique best-scoring pair
/// for both its display and service. Alternative arrays exclude selected pair.
ASDDCMatchConfidence ASDDCClassifyAssignedMatch(
    ASDDCMatchEvidence selected,
    const ASDDCMatchEvidence *displayAlternatives,
    size_t displayAlternativeCount,
    const ASDDCMatchEvidence *serviceAlternatives,
    size_t serviceAlternativeCount
);

void ASDDCServiceDestroy(ASDDCServiceToken token);

bool ASDDCServiceReadVCP(
    ASDDCServiceToken token,
    uint8_t feature,
    uint16_t *currentValue,
    uint16_t *maximumValue
);

/// Validates and parses one fixed-size DDC Get VCP reply. This checks the
/// protocol fields that identify a successful reply for `requestedFeature`;
/// it does not prove physical display or DDC/CI hardware compatibility.
bool ASDDCParseVCPReply(
    const uint8_t *reply,
    size_t replyLength,
    uint8_t requestedFeature,
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
