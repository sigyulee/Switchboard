// SPDX-License-Identifier: AGPL-3.0-only
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreServices/CoreServices.h>
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

// Only the hardware setup boundary is replaced. Endpoint ownership, validation,
// allocation, callbacks and the queue are the production implementation.
static struct {
    AudioObjectID requested_device;
    AudioObjectID returned_device;
    UInt32 returned_size;
    OSStatus read_status;
    OSStatus initialize_status;
    unsigned initialize_calls;
    unsigned read_calls;
    unsigned start_calls;
    unsigned stop_calls;
    unsigned uninitialize_calls;
    unsigned dispose_calls;
    bool initialized;
    bool disposed;
} hardware;
static int component_storage;
static int unit_storage;

static AudioComponent test_component(void) { return (AudioComponent)&component_storage; }
static AudioUnit test_unit(void) { return (AudioUnit)&unit_storage; }

AudioComponent binding_find_next(AudioComponent previous, const AudioComponentDescription *description) {
    assert(previous == NULL && description != NULL);
    assert(description->componentType == kAudioUnitType_Output);
    assert(description->componentSubType == kAudioUnitSubType_HALOutput);
    return test_component();
}

OSStatus binding_instance_new(AudioComponent component, AudioComponentInstance *instance) {
    assert(component == test_component() && instance != NULL);
    *instance = test_unit();
    return noErr;
}

OSStatus binding_set_property(AudioUnit unit, AudioUnitPropertyID property,
                              AudioUnitScope scope, AudioUnitElement element,
                              const void *data, UInt32 size) {
    assert(unit == test_unit() && !hardware.disposed && data != NULL);
    if (property == kAudioOutputUnitProperty_CurrentDevice) {
        assert(scope == kAudioUnitScope_Global && element == 0);
        assert(size == sizeof(hardware.requested_device));
        memcpy(&hardware.requested_device, data, sizeof(hardware.requested_device));
    }
    return noErr;
}

OSStatus binding_get_property(AudioUnit unit, AudioUnitPropertyID property,
                              AudioUnitScope scope, AudioUnitElement element,
                              void *data, UInt32 *size) {
    assert(unit == test_unit() && hardware.initialized && !hardware.disposed);
    assert(property == kAudioOutputUnitProperty_CurrentDevice);
    assert(scope == kAudioUnitScope_Global && element == 0);
    assert(data != NULL && size != NULL && *size == sizeof(AudioObjectID));
    assert(hardware.start_calls == 0);
    ++hardware.read_calls;
    if (hardware.read_status != noErr) return hardware.read_status;
    // A malformed size can be reported without writing beyond the caller's buffer.
    UInt32 written = hardware.returned_size < sizeof(AudioObjectID)
        ? hardware.returned_size : (UInt32)sizeof(AudioObjectID);
    memcpy(data, &hardware.returned_device, written);
    *size = hardware.returned_size;
    return noErr;
}

OSStatus binding_nominal_rate(AudioObjectID device, const AudioObjectPropertyAddress *address,
                              UInt32 qualifier_size, const void *qualifier,
                              UInt32 *size, void *data) {
    assert(device == hardware.requested_device && device != kAudioObjectUnknown);
    assert(address != NULL && address->mSelector == kAudioDevicePropertyNominalSampleRate);
    assert(address->mScope == kAudioObjectPropertyScopeGlobal);
    assert(address->mElement == kAudioObjectPropertyElementMain);
    assert(qualifier_size == 0 && qualifier == NULL);
    assert(data != NULL && size != NULL && *size == sizeof(Float64));
    const Float64 rate = 48000;
    memcpy(data, &rate, sizeof(rate));
    *size = sizeof(rate);
    return noErr;
}

OSStatus binding_initialize(AudioUnit unit) {
    assert(unit == test_unit() && !hardware.disposed);
    ++hardware.initialize_calls;
    hardware.initialized = hardware.initialize_status == noErr;
    return hardware.initialize_status;
}

OSStatus binding_start(AudioUnit unit) {
    assert(unit == test_unit() && hardware.initialized && !hardware.disposed);
    ++hardware.start_calls;
    return noErr;
}

OSStatus binding_stop(AudioUnit unit) {
    assert(unit == test_unit() && !hardware.disposed);
    ++hardware.stop_calls;
    return noErr;
}

OSStatus binding_uninitialize(AudioUnit unit) {
    assert(unit == test_unit() && !hardware.disposed);
    ++hardware.uninitialize_calls;
    hardware.initialized = false;
    return noErr;
}

OSStatus binding_dispose(AudioComponentInstance instance) {
    assert(instance == test_unit() && !hardware.disposed);
    ++hardware.dispose_calls;
    hardware.disposed = true;
    return noErr;
}

#define AudioComponentFindNext binding_find_next
#define AudioComponentInstanceNew binding_instance_new
#define AudioUnitSetProperty binding_set_property
#define AudioUnitGetProperty binding_get_property
#define AudioObjectGetPropertyData binding_nominal_rate
#define AudioUnitInitialize binding_initialize
#define AudioOutputUnitStart binding_start
#define AudioOutputUnitStop binding_stop
#define AudioUnitUninitialize binding_uninitialize
#define AudioComponentInstanceDispose binding_dispose
#include "../../Sources/AudioRealtime/Endpoint.c"

static unsigned failures;
static const char *case_name;
static const char *direction;
#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s / %s: %s (line %d)\n", \
                direction, case_name, #condition, __LINE__); \
        ++failures; \
    } \
} while (0)

int main(void) {
    // Removing the readback, accepting an unexpected device or malformed result,
    // querying before initialization, or leaking its unit must fail these cases.
    const struct {
        const char *name;
        AudioObjectID returned_device;
        UInt32 returned_size;
        OSStatus read_status;
        OSStatus initialize_status;
        OSStatus expected_error;
    } cases[] = {
        { "matching device", 41, sizeof(AudioObjectID), noErr, noErr, noErr },
        { "different device", 93, sizeof(AudioObjectID), noErr, noErr, kAudio_ParamError },
        { "unknown device", kAudioObjectUnknown, sizeof(AudioObjectID), noErr, noErr, kAudio_ParamError },
        { "read failure", 41, sizeof(AudioObjectID), kAudioUnitErr_InvalidProperty, noErr, kAudioUnitErr_InvalidProperty },
        { "empty result", 41, 0, noErr, noErr, kAudio_ParamError },
        { "short result", 41, sizeof(AudioObjectID) - 1, noErr, noErr, kAudio_ParamError },
        { "oversized result", 41, sizeof(AudioObjectID) + 1, noErr, noErr, kAudio_ParamError },
        { "initialize failure", 41, sizeof(AudioObjectID), noErr, kAudioUnitErr_FailedInitialization, kAudioUnitErr_FailedInitialization },
    };
    for (unsigned input = 0; input < 2; ++input) {
        direction = input ? "capture" : "output";
        for (size_t index = 0; index < sizeof(cases) / sizeof(cases[0]); ++index) {
            case_name = cases[index].name;
            memset(&hardware, 0, sizeof(hardware));
            hardware.returned_device = cases[index].returned_device;
            hardware.returned_size = cases[index].returned_size;
            hardware.read_status = cases[index].read_status;
            hardware.initialize_status = cases[index].initialize_status;
            SBQueue *queue = sb_queue_create(1024);
            assert(queue != NULL);
            int32_t error = 12345;
            SBEndpoint *endpoint = input ? sb_capture_create(41, queue, &error)
                                         : sb_output_create(41, queue, &error);
            CHECK(hardware.requested_device == 41);
            CHECK(hardware.initialize_calls == 1);
            CHECK(hardware.read_calls == (cases[index].initialize_status == noErr ? 1u : 0u));
            CHECK(hardware.start_calls == 0);
            CHECK(error == cases[index].expected_error);
            if (cases[index].expected_error == noErr) {
                CHECK(endpoint != NULL);
                CHECK(hardware.dispose_calls == 0);
                if (endpoint) {
                    CHECK(sb_endpoint_rate(endpoint) == 48000);
                    CHECK(sb_endpoint_start(endpoint) == noErr);
                    CHECK(hardware.start_calls == 1);
                }
            } else {
                CHECK(endpoint == NULL);
                CHECK(hardware.dispose_calls == 1);
                CHECK(sb_endpoint_start(endpoint) == kAudio_ParamError);
                CHECK(hardware.start_calls == 0);
            }
            sb_endpoint_destroy(endpoint);
            CHECK(hardware.stop_calls == 1);
            CHECK(hardware.uninitialize_calls == 1);
            CHECK(hardware.dispose_calls == 1);
            sb_queue_destroy(queue);
        }
    }
    if (failures) return 1;
    puts("Endpoint binding checks passed: capture/output matching IDs, failed reads, malformed sizes, mismatch rejection and cleanup.");
    return 0;
}
