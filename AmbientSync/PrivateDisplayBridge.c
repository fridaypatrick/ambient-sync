// Portions of this file adapt the minimum private display declarations from
// MonitorControl/Support/Bridging-Header.h and the Apple-silicon transport
// implementation from MonitorControl/Support/Arm64DDC.swift at upstream
// commit f16d90f29cefbd9fff47e26fc8f99fe7a5280deb.
// Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES/MonitorControl-MIT.txt for the complete notice.

#include "PrivateDisplayBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/graphics/IOGraphicsLib.h>
#include <IOKit/i2c/IOI2CInterface.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

typedef CFTypeRef ASIOAVService;

extern ASIOAVService IOAVServiceCreateWithService(
    CFAllocatorRef allocator,
    io_service_t service
) __attribute__((weak_import));
extern IOReturn IOAVServiceReadI2C(
    ASIOAVService service,
    uint32_t chipAddress,
    uint32_t offset,
    void *outputBuffer,
    uint32_t outputBufferSize
) __attribute__((weak_import));
extern IOReturn IOAVServiceWriteI2C(
    ASIOAVService service,
    uint32_t chipAddress,
    uint32_t dataAddress,
    void *inputBuffer,
    uint32_t inputBufferSize
) __attribute__((weak_import));
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(
    CGDirectDisplayID display
) __attribute__((weak_import));
extern int DisplayServicesGetBrightness(
    CGDirectDisplayID display,
    float *brightness
) __attribute__((weak_import));

enum {
    AS_ARM64_DDC_7BIT_ADDRESS = 0x37,
    AS_ARM64_DDC_DATA_ADDRESS = 0x51,
    AS_DDC_VCP_REPLY_LENGTH = 11,
    AS_DDC_VCP_REPLY_SOURCE_ADDRESS = 0x6E,
    AS_DDC_VCP_REPLY_PAYLOAD_LENGTH = 0x88,
    AS_DDC_VCP_REPLY_OPCODE_INDEX = 2,
    AS_DDC_VCP_REPLY_RESULT_INDEX = 3,
    AS_DDC_VCP_REPLY_FEATURE_INDEX = 4,
    AS_DDC_VCP_REPLY_TYPE_INDEX = 5,
    AS_DDC_VCP_REPLY_CONTINUOUS_TYPE = 0x00,
    AS_DDC_VCP_REPLY_MAXIMUM_HIGH_INDEX = 6,
    AS_DDC_VCP_REPLY_MAXIMUM_LOW_INDEX = 7,
    AS_DDC_VCP_REPLY_CURRENT_HIGH_INDEX = 8,
    AS_DDC_VCP_REPLY_CURRENT_LOW_INDEX = 9,
    AS_DDC_WRITE_CYCLES = 2,
    AS_DDC_ATTEMPTS = 4,
    AS_DDC_WRITE_DELAY_US = 10000,
    AS_DDC_READ_DELAY_US = 50000,
    AS_DDC_RETRY_DELAY_US = 20000,
    AS_MAX_SERVICE_COUNT = 64,
    AS_TEXT_CAPACITY = 512
};

struct ASDDCServiceHandle {
    ASIOAVService service;
};

typedef struct {
    char edidUUID[AS_TEXT_CAPACITY];
    char productName[AS_TEXT_CAPACITY];
    char ioDisplayLocation[AS_TEXT_CAPACITY];
    int64_t serialNumber;
    uint32_t serviceLocation;
    ASIOAVService service;
} ASServiceInfo;

static struct ASDDCServiceHandle *handleForToken(ASDDCServiceToken token) {
    return (struct ASDDCServiceHandle *)(uintptr_t)token;
}

static void copyCFString(CFTypeRef value, char *destination, size_t capacity) {
    if (destination == NULL || capacity == 0) {
        return;
    }
    destination[0] = '\0';
    if (value == NULL || CFGetTypeID(value) != CFStringGetTypeID()) {
        return;
    }
    CFStringGetCString((CFStringRef)value, destination, capacity, kCFStringEncodingUTF8);
}

static bool readCFNumber(CFTypeRef value, int64_t *result) {
    if (value == NULL || result == NULL || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return false;
    }
    return CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, result);
}

static void readRegistryString(
    io_registry_entry_t entry,
    CFStringRef key,
    char *destination,
    size_t capacity
) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(
        entry,
        key,
        kCFAllocatorDefault,
        kIORegistryIterateRecursively
    );
    copyCFString(value, destination, capacity);
    if (value != NULL) {
        CFRelease(value);
    }
}

static void readRegistryNumber(
    io_registry_entry_t entry,
    CFStringRef key,
    int64_t *destination
) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(
        entry,
        key,
        kCFAllocatorDefault,
        kIORegistryIterateRecursively
    );
    (void)readCFNumber(value, destination);
    if (value != NULL) {
        CFRelease(value);
    }
}

static void readDisplayAttributes(io_registry_entry_t entry, ASServiceInfo *info) {
    CFTypeRef attributes = IORegistryEntryCreateCFProperty(
        entry,
        CFSTR("DisplayAttributes"),
        kCFAllocatorDefault,
        kIORegistryIterateRecursively
    );
    if (attributes == NULL || CFGetTypeID(attributes) != CFDictionaryGetTypeID()) {
        if (attributes != NULL) {
            CFRelease(attributes);
        }
        return;
    }

    CFTypeRef productAttributes = CFDictionaryGetValue(
        (CFDictionaryRef)attributes,
        CFSTR("ProductAttributes")
    );
    if (productAttributes != NULL && CFGetTypeID(productAttributes) == CFDictionaryGetTypeID()) {
        CFDictionaryRef productDictionary = (CFDictionaryRef)productAttributes;
        copyCFString(
            CFDictionaryGetValue(productDictionary, CFSTR("ProductName")),
            info->productName,
            sizeof(info->productName)
        );
        readCFNumber(
            CFDictionaryGetValue(productDictionary, CFSTR("SerialNumber")),
            &info->serialNumber
        );
    }

    CFRelease(attributes);
}

static void readFramebufferInfo(io_service_t entry, ASServiceInfo *info, uint32_t location) {
    memset(info, 0, sizeof(*info));
    info->serviceLocation = location;
    readRegistryString(entry, CFSTR("EDID UUID"), info->edidUUID, sizeof(info->edidUUID));
    readDisplayAttributes(entry, info);

    io_string_t path = {0};
    if (IORegistryEntryGetPath(entry, kIOServicePlane, path) == KERN_SUCCESS) {
        strncpy(info->ioDisplayLocation, path, sizeof(info->ioDisplayLocation) - 1);
        info->ioDisplayLocation[sizeof(info->ioDisplayLocation) - 1] = '\0';
    }
}

static bool isExternalLocation(io_service_t entry) {
    char location[64] = {0};
    readRegistryString(entry, CFSTR("Location"), location, sizeof(location));
    return strcmp(location, "External") == 0;
}

static size_t discoverServices(ASServiceInfo *services, size_t capacity) {
    if (services == NULL || capacity == 0 || IOAVServiceCreateWithService == NULL) {
        return 0;
    }

    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (root == IO_OBJECT_NULL) {
        return 0;
    }

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t iteratorResult = IORegistryEntryCreateIterator(
        root,
        kIOServicePlane,
        kIORegistryIterateRecursively,
        &iterator
    );
    if (iteratorResult != KERN_SUCCESS) {
        IOObjectRelease(root);
        return 0;
    }

    ASServiceInfo current = {0};
    uint32_t serviceLocation = 0;
    size_t serviceCount = 0;

    io_registry_entry_t entry = IO_OBJECT_NULL;
    while ((entry = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        io_name_t name = {0};
        if (IORegistryEntryGetName(entry, name) != KERN_SUCCESS) {
            IOObjectRelease(entry);
            continue;
        }

        if (strstr(name, "AppleCLCD2") != NULL || strstr(name, "IOMobileFramebufferShim") != NULL) {
            serviceLocation += 1;
            readFramebufferInfo(entry, &current, serviceLocation);
        } else if (strcmp(name, "DCPAVServiceProxy") == 0 && isExternalLocation(entry)) {
            ASIOAVService service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry);
            if (service != NULL && serviceCount < capacity) {
                current.service = service;
                services[serviceCount] = current;
                serviceCount += 1;
                memset(&current, 0, sizeof(current));
            } else if (service != NULL) {
                CFRelease(service);
            }
        }

        IOObjectRelease(entry);
    }

    IOObjectRelease(iterator);
    IOObjectRelease(root);
    return serviceCount;
}

static void releaseServiceInfos(ASServiceInfo *services, size_t count) {
    if (services == NULL) {
        return;
    }
    for (size_t index = 0; index < count; index += 1) {
        if (services[index].service != NULL) {
            CFRelease(services[index].service);
            services[index].service = NULL;
        }
    }
}

static bool valueFromDictionary(
    CFDictionaryRef dictionary,
    CFStringRef key,
    int64_t *value
) {
    if (dictionary == NULL) {
        return false;
    }
    return readCFNumber(CFDictionaryGetValue(dictionary, key), value);
}

static bool stringFromDictionary(
    CFDictionaryRef dictionary,
    CFStringRef key,
    char *destination,
    size_t capacity
) {
    if (dictionary == NULL) {
        return false;
    }
    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    copyCFString(value, destination, capacity);
    return destination != NULL && destination[0] != '\0';
}

typedef struct {
    char *destination;
    size_t capacity;
    bool copied;
} FirstDictionaryStringContext;

static void copyFirstDictionaryString(const void *key, const void *value, void *context) {
    (void)key;
    FirstDictionaryStringContext *stringContext = (FirstDictionaryStringContext *)context;
    if (stringContext == NULL || stringContext->copied) {
        return;
    }
    copyCFString(value, stringContext->destination, stringContext->capacity);
    stringContext->copied = true;
}

static bool uuidSliceEquals(
    const char *uuid,
    size_t offset,
    const char *expected
) {
    if (uuid == NULL || expected == NULL) {
        return false;
    }
    size_t uuidLength = strlen(uuid);
    if (uuidLength < offset + 4 || strlen(expected) != 4) {
        return false;
    }
    char actual[5] = {0};
    memcpy(actual, uuid + offset, 4);
    return strcasecmp(actual, expected) == 0;
}

static int64_t clampInt64(int64_t value, int64_t minimum, int64_t maximum) {
    if (value < minimum) {
        return minimum;
    }
    if (value > maximum) {
        return maximum;
    }
    return value;
}

static void uppercaseHex(char *destination, size_t capacity, uint64_t value, int width) {
    if (destination == NULL || capacity == 0) {
        return;
    }
    (void)snprintf(destination, capacity, "%0*llX", width, (unsigned long long)value);
}

static int matchScore(CGDirectDisplayID displayID, const ASServiceInfo *service) {
    if (service == NULL || CoreDisplay_DisplayCreateInfoDictionary == NULL) {
        return 0;
    }

    CFDictionaryRef dictionary = CoreDisplay_DisplayCreateInfoDictionary(displayID);
    if (dictionary == NULL) {
        return 0;
    }

    int score = 0;
    int64_t manufactureYear = 0;
    int64_t manufactureWeek = 0;
    int64_t vendorID = 0;
    int64_t productID = 0;
    int64_t verticalSize = 0;
    int64_t horizontalSize = 0;

    if (valueFromDictionary(dictionary, CFSTR("DisplayYearOfManufacture"), &manufactureYear) &&
        valueFromDictionary(dictionary, CFSTR("DisplayWeekOfManufacture"), &manufactureWeek) &&
        valueFromDictionary(dictionary, CFSTR("DisplayVendorID"), &vendorID) &&
        valueFromDictionary(dictionary, CFSTR("DisplayProductID"), &productID) &&
        valueFromDictionary(dictionary, CFSTR("DisplayVerticalImageSize"), &verticalSize) &&
        valueFromDictionary(dictionary, CFSTR("DisplayHorizontalImageSize"), &horizontalSize)) {
        char expected[8] = {0};

        uppercaseHex(expected, sizeof(expected), (uint64_t)clampInt64(vendorID, 0, 0xFFFF), 4);
        if (uuidSliceEquals(service->edidUUID, 0, expected)) {
            score += 1;
        }

        uint16_t product = (uint16_t)clampInt64(productID, 0, 0xFFFF);
        (void)snprintf(
            expected,
            sizeof(expected),
            "%02X%02X",
            (unsigned int)(product & 0xFF),
            (unsigned int)((product >> 8) & 0xFF)
        );
        if (uuidSliceEquals(service->edidUUID, 4, expected)) {
            score += 1;
        }

        (void)snprintf(
            expected,
            sizeof(expected),
            "%02X%02X",
            (unsigned int)clampInt64(manufactureWeek, 0, 0xFF),
            (unsigned int)clampInt64(manufactureYear - 1990, 0, 0xFF)
        );
        if (uuidSliceEquals(service->edidUUID, 19, expected)) {
            score += 1;
        }

        (void)snprintf(
            expected,
            sizeof(expected),
            "%02X%02X",
            (unsigned int)clampInt64(horizontalSize / 10, 0, 0xFF),
            (unsigned int)clampInt64(verticalSize / 10, 0, 0xFF)
        );
        if (uuidSliceEquals(service->edidUUID, 30, expected)) {
            score += 1;
        }
    }

    char displayLocation[AS_TEXT_CAPACITY] = {0};
    if (stringFromDictionary(
            dictionary,
            CFSTR("IODisplayLocation"),
            displayLocation,
            sizeof(displayLocation)) &&
        displayLocation[0] != '\0' &&
        strcmp(displayLocation, service->ioDisplayLocation) == 0) {
        score += 10;
    }

    CFTypeRef nameList = CFDictionaryGetValue(dictionary, CFSTR("DisplayProductName"));
    if (nameList != NULL && CFGetTypeID(nameList) == CFDictionaryGetTypeID()) {
        char displayName[AS_TEXT_CAPACITY] = {0};
        if (!stringFromDictionary(
                (CFDictionaryRef)nameList,
                CFSTR("en_US"),
                displayName,
                sizeof(displayName))) {
            FirstDictionaryStringContext context = {
                .destination = displayName,
                .capacity = sizeof(displayName),
                .copied = false
            };
            CFDictionaryApplyFunction(
                (CFDictionaryRef)nameList,
                copyFirstDictionaryString,
                &context
            );
        }
        if (displayName[0] != '\0' && strcasecmp(displayName, service->productName) == 0) {
            score += 1;
        }
    }

    int64_t displaySerial = 0;
    if (valueFromDictionary(dictionary, CFSTR("DisplaySerialNumber"), &displaySerial) &&
        displaySerial != 0 &&
        service->serialNumber != 0 &&
        displaySerial == service->serialNumber) {
        score += 1;
    }

    CFRelease(dictionary);
    return score;
}

bool ASDisplayCopyProductName(
    CGDirectDisplayID display,
    char *buffer,
    size_t capacity
) {
    if (buffer == NULL || capacity == 0 || CoreDisplay_DisplayCreateInfoDictionary == NULL) {
        return false;
    }

    buffer[0] = '\0';
    CFDictionaryRef dictionary = CoreDisplay_DisplayCreateInfoDictionary(display);
    if (dictionary == NULL) {
        return false;
    }

    CFTypeRef nameList = CFDictionaryGetValue(dictionary, CFSTR("DisplayProductName"));
    if (nameList != NULL && CFGetTypeID(nameList) == CFDictionaryGetTypeID()) {
        CFTypeRef localizedName = CFDictionaryGetValue(
            (CFDictionaryRef)nameList,
            CFSTR("en_US")
        );
        copyCFString(localizedName, buffer, capacity);
        if (buffer[0] == '\0') {
            FirstDictionaryStringContext context = {
                .destination = buffer,
                .capacity = capacity,
                .copied = false
            };
            CFDictionaryApplyFunction(
                (CFDictionaryRef)nameList,
                copyFirstDictionaryString,
                &context
            );
        }
    }

    CFRelease(dictionary);
    return buffer[0] != '\0';
}

static uint8_t ddcChecksum(uint8_t seed, const uint8_t *data, size_t length) {
    uint8_t checksum = seed;
    for (size_t index = 0; index < length; index += 1) {
        checksum ^= data[index];
    }
    return checksum;
}

static bool performDDCCommunication(
    ASIOAVService service,
    const uint8_t *send,
    size_t sendLength,
    uint8_t *reply,
    size_t replyLength
) {
    if (service == NULL || send == NULL || sendLength == 0 || sendLength > 8 ||
        IOAVServiceReadI2C == NULL || IOAVServiceWriteI2C == NULL) {
        return false;
    }

    uint8_t packet[16] = {0};
    packet[0] = (uint8_t)(0x80 | (sendLength + 1));
    packet[1] = (uint8_t)sendLength;
    memcpy(packet + 2, send, sendLength);
    uint8_t address = (uint8_t)(AS_ARM64_DDC_7BIT_ADDRESS << 1);
    if (sendLength != 1) {
        address ^= AS_ARM64_DDC_DATA_ADDRESS;
    }
    packet[sendLength + 2] = ddcChecksum(address, packet, sendLength + 2);

    for (int attempt = 0; attempt < AS_DDC_ATTEMPTS; attempt += 1) {
        bool success = false;
        for (int cycle = 0; cycle < AS_DDC_WRITE_CYCLES; cycle += 1) {
            usleep(AS_DDC_WRITE_DELAY_US);
            success = IOAVServiceWriteI2C(
                service,
                AS_ARM64_DDC_7BIT_ADDRESS,
                AS_ARM64_DDC_DATA_ADDRESS,
                packet,
                (uint32_t)(sendLength + 3)
            ) == kIOReturnSuccess;
        }

        if (reply != NULL && replyLength > 0) {
            usleep(AS_DDC_READ_DELAY_US);
            if (IOAVServiceReadI2C(
                    service,
                    AS_ARM64_DDC_7BIT_ADDRESS,
                    0,
                    reply,
                    (uint32_t)replyLength
                ) == kIOReturnSuccess &&
                replyLength >= 2) {
                success = ddcChecksum(0x50, reply, replyLength - 1) == reply[replyLength - 1];
            } else {
                success = false;
            }
        }

        if (success) {
            return true;
        }
        if (attempt + 1 < AS_DDC_ATTEMPTS) {
            usleep(AS_DDC_RETRY_DELAY_US);
        }
    }

    return false;
}

int ASDisplayServicesGetBrightness(CGDirectDisplayID display, float *brightness) {
    if (brightness == NULL || DisplayServicesGetBrightness == NULL) {
        return -1;
    }

    float value = 0;
    int result = DisplayServicesGetBrightness(display, &value);
    if (result != 0 || !isfinite(value) || value < 0 || value > 1) {
        return -1;
    }
    *brightness = value;
    return 0;
}

bool ASDDCParseVCPReply(
    const uint8_t *reply,
    size_t replyLength,
    uint8_t requestedFeature,
    uint16_t *currentValue,
    uint16_t *maximumValue
) {
    if (reply == NULL || replyLength != AS_DDC_VCP_REPLY_LENGTH ||
        currentValue == NULL || maximumValue == NULL ||
        reply[0] != AS_DDC_VCP_REPLY_SOURCE_ADDRESS ||
        reply[1] != AS_DDC_VCP_REPLY_PAYLOAD_LENGTH ||
        reply[AS_DDC_VCP_REPLY_OPCODE_INDEX] != 0x02 ||
        reply[AS_DDC_VCP_REPLY_RESULT_INDEX] != 0x00 ||
        reply[AS_DDC_VCP_REPLY_FEATURE_INDEX] != requestedFeature ||
        reply[AS_DDC_VCP_REPLY_TYPE_INDEX] != AS_DDC_VCP_REPLY_CONTINUOUS_TYPE) {
        return false;
    }

    uint16_t maximum = (uint16_t)(
        ((uint16_t)reply[AS_DDC_VCP_REPLY_MAXIMUM_HIGH_INDEX] << 8) |
        reply[AS_DDC_VCP_REPLY_MAXIMUM_LOW_INDEX]
    );
    uint16_t current = (uint16_t)(
        ((uint16_t)reply[AS_DDC_VCP_REPLY_CURRENT_HIGH_INDEX] << 8) |
        reply[AS_DDC_VCP_REPLY_CURRENT_LOW_INDEX]
    );
    if (maximum == 0 || current > maximum) {
        return false;
    }

    *maximumValue = maximum;
    *currentValue = current;
    return true;
}

size_t ASDDCServiceCreateForDisplays(
    const CGDirectDisplayID *displayIDs,
    size_t displayCount,
    ASDDCServiceToken *tokens,
    size_t tokenCapacity
) {
    if (displayIDs == NULL || tokens == NULL || displayCount == 0 || tokenCapacity < displayCount ||
        IOAVServiceCreateWithService == NULL || IOAVServiceReadI2C == NULL ||
        IOAVServiceWriteI2C == NULL || CoreDisplay_DisplayCreateInfoDictionary == NULL) {
        return 0;
    }

    for (size_t index = 0; index < tokenCapacity; index += 1) {
        tokens[index] = 0;
    }

    ASServiceInfo *services = calloc(AS_MAX_SERVICE_COUNT, sizeof(ASServiceInfo));
    bool *usedDisplays = calloc(displayCount, sizeof(bool));
    bool *usedServices = calloc(AS_MAX_SERVICE_COUNT, sizeof(bool));
    if (services == NULL || usedDisplays == NULL || usedServices == NULL) {
        free(services);
        free(usedDisplays);
        free(usedServices);
        return 0;
    }

    size_t serviceCount = discoverServices(services, AS_MAX_SERVICE_COUNT);
    size_t matchedCount = 0;

    while (matchedCount < displayCount) {
        int bestScore = 0;
        size_t bestDisplay = 0;
        size_t bestService = 0;
        bool found = false;

        for (size_t displayIndex = 0; displayIndex < displayCount; displayIndex += 1) {
            if (usedDisplays[displayIndex]) {
                continue;
            }
            for (size_t serviceIndex = 0; serviceIndex < serviceCount; serviceIndex += 1) {
                if (usedServices[serviceIndex]) {
                    continue;
                }
                int score = matchScore(displayIDs[displayIndex], &services[serviceIndex]);
                if (score > bestScore) {
                    bestScore = score;
                    bestDisplay = displayIndex;
                    bestService = serviceIndex;
                    found = true;
                }
            }
        }

        if (!found || bestScore <= 0) {
            break;
        }

        struct ASDDCServiceHandle *handle = calloc(1, sizeof(*handle));
        if (handle == NULL) {
            break;
        }
        handle->service = services[bestService].service;
        services[bestService].service = NULL;
        tokens[bestDisplay] = (ASDDCServiceToken)(uintptr_t)handle;
        usedDisplays[bestDisplay] = true;
        usedServices[bestService] = true;
        matchedCount += 1;
    }

    releaseServiceInfos(services, serviceCount);
    free(services);
    free(usedDisplays);
    free(usedServices);
    return matchedCount;
}

void ASDDCServiceDestroy(ASDDCServiceToken token) {
    struct ASDDCServiceHandle *handle = handleForToken(token);
    if (handle == NULL) {
        return;
    }
    if (handle->service != NULL) {
        CFRelease(handle->service);
    }
    free(handle);
}

bool ASDDCServiceReadVCP(
    ASDDCServiceToken token,
    uint8_t feature,
    uint16_t *currentValue,
    uint16_t *maximumValue
) {
    struct ASDDCServiceHandle *handle = handleForToken(token);
    if (handle == NULL || currentValue == NULL || maximumValue == NULL) {
        return false;
    }

    uint8_t send[1] = {feature};
    uint8_t reply[AS_DDC_VCP_REPLY_LENGTH] = {0};
    if (!performDDCCommunication(handle->service, send, sizeof(send), reply, sizeof(reply))) {
        return false;
    }

    return ASDDCParseVCPReply(
        reply,
        sizeof(reply),
        feature,
        currentValue,
        maximumValue
    );
}

bool ASDDCServiceWriteVCP(
    ASDDCServiceToken token,
    uint8_t feature,
    uint16_t value
) {
    struct ASDDCServiceHandle *handle = handleForToken(token);
    if (handle == NULL) {
        return false;
    }

    uint8_t send[3] = {
        feature,
        (uint8_t)(value >> 8),
        (uint8_t)(value & 0xFF)
    };
    return performDDCCommunication(handle->service, send, sizeof(send), NULL, 0);
}
