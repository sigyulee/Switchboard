// SPDX-License-Identifier: AGPL-3.0-only
// Compile the complete prepared driver in this translation unit. Only property
// callbacks run: no HAL registration, Initialize, audio I/O, or installed driver.
#include <BlackHole.c>

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition, message) do { \
    if (!(condition)) { \
        fprintf(stderr, "Driver property check failed at line %d: %s\n", __LINE__, message); \
        exit(1); \
    } \
} while (0)

static const AudioObjectID sentinel = 0xa5a5a5a5;
static atomic_bool concurrentStart;

// These host callbacks absorb only persistence and notifications. The property
// setters/getters, UID construction, ownership, and synchronization remain real.
static OSStatus properties_changed(AudioServerPlugInHostRef host, AudioObjectID object,
                                   UInt32 count, const AudioObjectPropertyAddress addresses[]) {
    (void)host;
    (void)object;
    (void)count;
    (void)addresses;
    return noErr;
}

static OSStatus write_storage(AudioServerPlugInHostRef host, CFStringRef key,
                              CFPropertyListRef value) {
    (void)host;
    (void)key;
    (void)value;
    return noErr;
}

static AudioServerPlugInHostInterface testHost = {
    .PropertiesChanged = properties_changed,
    .WriteToStorage = write_storage,
};

static AudioObjectPropertyAddress address_for(AudioObjectPropertySelector selector) {
    return (AudioObjectPropertyAddress) {
        selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain,
    };
}

static OSStatus get_property(AudioObjectID object, AudioObjectPropertySelector selector,
                             UInt32 qualifierSize, const void *qualifier, UInt32 capacity,
                             UInt32 *written, void *output) {
    AudioObjectPropertyAddress address = address_for(selector);
    return (*gAudioServerPlugInDriverRef)->GetPropertyData(gAudioServerPlugInDriverRef,
        object, 0, &address, qualifierSize, qualifier, capacity, written, output);
}

static UInt32 property_size(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = address_for(selector);
    UInt32 size = UINT32_MAX;
    CHECK((*gAudioServerPlugInDriverRef)->GetPropertyDataSize(gAudioServerPlugInDriverRef,
        object, 0, &address, 0, NULL, &size) == noErr, "property size must succeed");
    return size;
}

static void set_acquired(bool acquired) {
    AudioObjectPropertyAddress address = address_for(kAudioBoxPropertyAcquired);
    UInt32 value = acquired ? 1 : 0;
    CHECK((*gAudioServerPlugInDriverRef)->SetPropertyData(gAudioServerPlugInDriverRef,
        kObjectID_Box, 0, &address, 0, NULL, sizeof(value), &value) == noErr,
        "acquired property setter must succeed");
}

static void check_translation(AudioObjectPropertySelector selector, UInt32 qualifierSize,
                               const void *qualifier, UInt32 capacity, OSStatus expectedStatus,
                               AudioObjectID expectedObject) {
    AudioObjectID output[2] = {sentinel, sentinel};
    UInt32 written = UINT32_MAX;
    OSStatus status = get_property(kObjectID_PlugIn, selector, qualifierSize, qualifier,
                                  capacity, &written, output);
    CHECK(status == expectedStatus, "UID translation status");
    CHECK(written == (status == noErr ? sizeof(AudioObjectID) : 0),
          "UID translation must initialize the byte count");
    CHECK(output[0] == (status == noErr ? expectedObject : sentinel),
          "UID translation object or untouched failure output");
    CHECK(output[1] == sentinel, "UID translation must not overwrite adjacent storage");
}

static void check_uids(void) {
    const struct {
        AudioObjectPropertySelector selector;
        CFStringRef uid;
        AudioObjectID object;
    } cases[] = {
        {kAudioPlugInPropertyTranslateUIDToBox, CFSTR(kDriver_Name "_UID"), kObjectID_Box},
        {kAudioPlugInPropertyTranslateUIDToDevice, CFSTR(kDriver_Name "_UID"), kObjectID_Device},
        {kAudioPlugInPropertyTranslateUIDToDevice, CFSTR(kDriver_Name "_2_UID"), kObjectID_Device2},
        {kAudioPlugInPropertyTranslateUIDToBox, CFSTR("unknown UID"), kAudioObjectUnknown},
        {kAudioPlugInPropertyTranslateUIDToDevice, CFSTR("unknown UID"), kAudioObjectUnknown},
    };
    for (unsigned acquired = 0; acquired < 2; ++acquired) {
        set_acquired(acquired != 0);
        for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
            CHECK(property_size(kObjectID_PlugIn, cases[i].selector) == sizeof(AudioObjectID),
                  "translation advertises one object");
            check_translation(cases[i].selector, sizeof(CFStringRef), &cases[i].uid,
                              sizeof(AudioObjectID), noErr, cases[i].object);
            check_translation(cases[i].selector, sizeof(CFStringRef), &cases[i].uid,
                              2 * sizeof(AudioObjectID), noErr, cases[i].object);
            for (UInt32 capacity = 0; capacity < sizeof(AudioObjectID); ++capacity) {
                check_translation(cases[i].selector, sizeof(CFStringRef), &cases[i].uid,
                                  capacity, kAudioHardwareBadPropertySizeError, 0);
            }
        }
    }
    const AudioObjectPropertySelector selectors[] = {
        kAudioPlugInPropertyTranslateUIDToBox, kAudioPlugInPropertyTranslateUIDToDevice,
    };
    CFStringRef uid = CFSTR(kDriver_Name "_UID");
    CFStringRef missingUID = NULL;
    for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); ++i) {
        check_translation(selectors[i], sizeof(uid), NULL, sizeof(AudioObjectID),
                          kAudioHardwareBadPropertySizeError, 0);
        check_translation(selectors[i], sizeof(uid), &missingUID, sizeof(AudioObjectID),
                          kAudioHardwareBadPropertySizeError, 0);
        for (UInt32 size = 0; size < 2 * sizeof(uid); ++size) {
            if (size == sizeof(uid)) continue;
            // Allocate exactly the advertised storage so ASan detects a read
            // past short qualifiers, even if an erroneous branch returns success.
            void *qualifier = malloc(size ? size : 1);
            CHECK(qualifier != NULL, "qualifier allocation");
            memset(qualifier, 0, size ? size : 1);
            if (size >= sizeof(uid)) memcpy(qualifier, &uid, sizeof(uid));
            check_translation(selectors[i], size, qualifier, sizeof(AudioObjectID),
                              kAudioHardwareBadPropertySizeError, 0);
            free(qualifier);
        }
    }
    puts("UID qualifiers, known/unknown identities, and bounded outputs passed.");
}

static void check_list(AudioObjectID object, AudioObjectPropertySelector selector,
                       const AudioObjectID expected[], UInt32 count) {
    CHECK(property_size(object, selector) == count * sizeof(AudioObjectID),
          "list size must match the owned or published object count");
    for (UInt32 capacity = 0; capacity <= 5 * sizeof(AudioObjectID); ++capacity) {
        AudioObjectID output[6];
        for (size_t i = 0; i < 6; ++i) output[i] = sentinel;
        UInt32 written = UINT32_MAX;
        OSStatus status = get_property(object, selector, 0, NULL, capacity, &written, output);
        UInt32 fetched = capacity / sizeof(AudioObjectID);
        if (fetched > count) fetched = count;
        bool shortBoxList = object == kObjectID_Box && selector == kAudioBoxPropertyDeviceList
                            && count > 0 && capacity < sizeof(AudioObjectID);
        CHECK(status == (shortBoxList ? kAudioHardwareBadPropertySizeError : noErr),
              "list buffer capacity status");
        CHECK(written == fetched * sizeof(AudioObjectID), "list initialized byte count");
        for (UInt32 i = 0; i < 6; ++i) {
            CHECK(output[i] == (i < fetched ? expected[i] : sentinel),
                  "all returned IDs must be initialized; unused output must stay untouched");
        }
    }
}

static void check_lists(void) {
    const AudioObjectID owned[] = {kObjectID_Box, kObjectID_Device, kObjectID_Device2};
    const AudioObjectID devices[] = {kObjectID_Device, kObjectID_Device2};
    for (unsigned acquired = 0; acquired < 2; ++acquired) {
        set_acquired(acquired != 0);
        check_list(kObjectID_PlugIn, kAudioObjectPropertyOwnedObjects, owned, acquired ? 3 : 1);
        check_list(kObjectID_PlugIn, kAudioPlugInPropertyBoxList, owned, 1);
        check_list(kObjectID_PlugIn, kAudioPlugInPropertyDeviceList, devices, acquired ? 2 : 0);
        check_list(kObjectID_Box, kAudioBoxPropertyDeviceList, devices, acquired ? 2 : 0);
        check_list(kObjectID_Box, kAudioObjectPropertyOwnedObjects, NULL, 0);
        for (size_t i = 0; i < sizeof(owned) / sizeof(owned[0]); ++i) {
            AudioObjectID owner = sentinel;
            UInt32 written = UINT32_MAX;
            CHECK(get_property(owned[i], kAudioObjectPropertyOwner, 0, NULL,
                sizeof(owner), &written, &owner) == noErr, "owner query must succeed");
            CHECK(owner == kObjectID_PlugIn && written == sizeof(owner),
                  "box and both devices retain plug-in ownership");
        }
    }
    puts("Acquired/unacquired ownership and partial list buffers passed.");
}

static void check_resource_bundle(void) {
    CHECK(property_size(kObjectID_PlugIn, kAudioPlugInPropertyResourceBundle) == sizeof(CFStringRef),
          "resource bundle advertises a CFStringRef");
    const UInt32 capacities[] = {sizeof(AudioObjectID), 0, 1, 2, 3, 5, 6, 7,
                                sizeof(CFStringRef), 2 * sizeof(CFStringRef)};
    for (size_t i = 0; i < sizeof(capacities) / sizeof(capacities[0]); ++i) {
        UInt32 capacity = capacities[i];
        // A real four-byte allocation catches a pointer-sized write with ASan.
        unsigned char *output = malloc(capacity ? capacity : 1);
        CHECK(output != NULL, "resource bundle output allocation");
        memset(output, 0xa5, capacity ? capacity : 1);
        UInt32 written = UINT32_MAX;
        OSStatus status = get_property(kObjectID_PlugIn, kAudioPlugInPropertyResourceBundle,
                                      0, NULL, capacity, &written, output);
        if (capacity < sizeof(CFStringRef)) {
            CHECK(status == kAudioHardwareBadPropertySizeError && written == 0,
                  "resource bundle must reject output smaller than a pointer");
            for (UInt32 j = 0; j < capacity; ++j)
                CHECK(output[j] == 0xa5, "failed resource output must stay untouched");
        } else {
            CHECK(status == noErr && written == sizeof(CFStringRef), "resource bundle result size");
            CFStringRef resource = NULL;
            memcpy(&resource, output, sizeof(resource));
            CHECK(resource != NULL && CFEqual(resource, CFSTR("")), "resource bundle is plug-in root");
            for (UInt32 j = sizeof(CFStringRef); j < capacity; ++j)
                CHECK(output[j] == 0xa5, "resource bundle must not overwrite trailing storage");
        }
        free(output);
    }
    puts("Resource bundle pointer-sized output bounds passed.");
}

static void *toggle_acquired(void *unused) {
    (void)unused;
    while (!atomic_load_explicit(&concurrentStart, memory_order_acquire)) {}
    for (unsigned i = 0; i < 10000; ++i) set_acquired((i & 1) != 0);
    return NULL;
}

static void *read_lists(void *unused) {
    (void)unused;
    while (!atomic_load_explicit(&concurrentStart, memory_order_acquire)) {}
    for (unsigned i = 0; i < 10000; ++i) {
        UInt32 ownedSize = property_size(kObjectID_PlugIn, kAudioObjectPropertyOwnedObjects);
        UInt32 deviceSize = property_size(kObjectID_PlugIn, kAudioPlugInPropertyDeviceList);
        CHECK(ownedSize == sizeof(AudioObjectID) || ownedSize == 3 * sizeof(AudioObjectID),
              "concurrent owned size must describe a complete state");
        CHECK(deviceSize == 0 || deviceSize == 2 * sizeof(AudioObjectID),
              "concurrent device size must describe a complete state");
        AudioObjectID output[4] = {sentinel, sentinel, sentinel, sentinel};
        UInt32 written = UINT32_MAX;
        CHECK(get_property(kObjectID_PlugIn, kAudioObjectPropertyOwnedObjects, 0, NULL,
                           sizeof(output), &written, output) == noErr, "concurrent owned list");
        CHECK((written == sizeof(AudioObjectID) || written == 3 * sizeof(AudioObjectID))
              && output[0] == kObjectID_Box && output[3] == sentinel,
              "concurrent owned list bounds and state");
        CHECK(written == sizeof(AudioObjectID)
              ? output[1] == sentinel && output[2] == sentinel
              : output[1] == kObjectID_Device && output[2] == kObjectID_Device2,
              "concurrent owned list contents");
        CHECK(get_property(kObjectID_PlugIn, kAudioPlugInPropertyDeviceList, 0, NULL,
                           sizeof(output), &written, output) == noErr, "concurrent device list");
        CHECK(written == 0 || (written == 2 * sizeof(AudioObjectID)
              && output[0] == kObjectID_Device && output[1] == kObjectID_Device2),
              "concurrent device list contents");
    }
    return NULL;
}

static void check_concurrency(void) {
    pthread_t writer, readers[2];
    CHECK(pthread_create(&writer, NULL, toggle_acquired, NULL) == 0, "create property writer");
    for (unsigned i = 0; i < 2; ++i)
        CHECK(pthread_create(&readers[i], NULL, read_lists, NULL) == 0, "create property reader");
    atomic_store_explicit(&concurrentStart, true, memory_order_release);
    CHECK(pthread_join(writer, NULL) == 0, "join property writer");
    for (unsigned i = 0; i < 2; ++i)
        CHECK(pthread_join(readers[i], NULL) == 0, "join property reader");
    puts("Concurrent acquisition changes and property reads passed.");
}

int main(int argc, char *argv[]) {
    gPlugIn_Host = &testHost;
    CHECK(argc <= 2, "usage: PropertyChecks [uids|lists|resources|concurrency]");
    if (argc == 1 || strcmp(argv[1], "uids") == 0) check_uids();
    if (argc == 1 || strcmp(argv[1], "lists") == 0) check_lists();
    if (argc == 1 || strcmp(argv[1], "resources") == 0) check_resource_bundle();
    if (argc == 1 || strcmp(argv[1], "concurrency") == 0) check_concurrency();
    CHECK(argc == 1 || strcmp(argv[1], "uids") == 0 || strcmp(argv[1], "lists") == 0
          || strcmp(argv[1], "resources") == 0 || strcmp(argv[1], "concurrency") == 0,
          "unknown check selection");
    printf("Driver property checks passed for %s.\n", kDriver_Name);
    return 0;
}
