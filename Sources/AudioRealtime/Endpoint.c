#include "AudioRealtime.h"
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreServices/CoreServices.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define MAX_FRAMES 8192u
struct SBEndpoint {
    AudioUnit unit;
    SBQueue *queue;
    double rate;
    float *scratch;
    _Atomic uint64_t underruns;
    _Atomic int32_t error;
    _Atomic uint64_t heartbeat;
};
static OSStatus capture(void *ref, AudioUnitRenderActionFlags *flags,
                        const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *unused) {
    (void)bus; (void)unused;
    SBEndpoint *e = ref;
    atomic_store_explicit(&e->heartbeat, sb_host_time(), memory_order_relaxed);
    if (frames > MAX_FRAMES) { atomic_store(&e->error, kAudio_ParamError); return noErr; }
    AudioBufferList buffer = { .mNumberBuffers = 1,
        .mBuffers = {{ .mNumberChannels = 2, .mDataByteSize = frames * 2 * sizeof(float), .mData = e->scratch }} };
    OSStatus status = AudioUnitRender(e->unit, flags, time, 1, frames, &buffer);
    if (status) { atomic_store(&e->error, status); return noErr; }
    uint64_t host = (time->mFlags & kAudioTimeStampHostTimeValid) ? time->mHostTime : sb_host_time();
    sb_queue_write(e->queue, e->scratch, frames, host);
    return noErr;
}
static OSStatus render(void *ref, AudioUnitRenderActionFlags *flags,
                       const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *buffers) {
    (void)flags; (void)time; (void)bus;
    SBEndpoint *e = ref;
    atomic_store_explicit(&e->heartbeat, sb_host_time(), memory_order_relaxed);
    for (UInt32 b = 0; b < buffers->mNumberBuffers; ++b)
        if (buffers->mBuffers[b].mData) memset(buffers->mBuffers[b].mData, 0, buffers->mBuffers[b].mDataByteSize);
    if (frames > MAX_FRAMES) return noErr;
    if (sb_queue_available(e->queue) > (uint32_t)(e->rate * 0.15)) sb_queue_clear(e->queue);
    uint32_t count = sb_queue_read(e->queue, e->scratch, frames, NULL);
    if (count < frames) atomic_fetch_add_explicit(&e->underruns, frames - count, memory_order_relaxed);
    if (buffers->mNumberBuffers == 1 && buffers->mBuffers[0].mNumberChannels == 2) {
        size_t bytes = count * 2 * sizeof(float);
        if (bytes <= buffers->mBuffers[0].mDataByteSize && buffers->mBuffers[0].mData) memcpy(buffers->mBuffers[0].mData, e->scratch, bytes);
    } else {
        for (UInt32 b = 0; b < buffers->mNumberBuffers && b < 2; ++b) {
            float *out = buffers->mBuffers[b].mData;
            UInt32 safe = buffers->mBuffers[b].mDataByteSize / sizeof(float);
            if (out) for (UInt32 f = 0; f < count && f < safe; ++f) out[f] = e->scratch[f * 2 + b];
        }
    }
    return noErr;
}
static SBEndpoint *create(uint32_t device, SBQueue *queue, bool input, int32_t *error) {
    if (error) *error = 0;
    if (!queue || !device) { if (error) *error = kAudio_ParamError; return NULL; }
    SBEndpoint *e = calloc(1, sizeof(*e));
    if (!e) { if (error) *error = memFullErr; return NULL; }
    e->queue = queue;
    e->scratch = calloc(MAX_FRAMES * 2, sizeof(float));
    if (!e->scratch) { if (error) *error = memFullErr; free(e); return NULL; }
    atomic_init(&e->underruns, 0); atomic_init(&e->error, 0);
    atomic_init(&e->heartbeat, sb_host_time());
    AudioComponentDescription desc = { kAudioUnitType_Output, kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple, 0, 0 };
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    OSStatus status = comp ? AudioComponentInstanceNew(comp, &e->unit) : kAudio_ParamError;
    UInt32 on = 1, off = 0;
    if (!status) status = AudioUnitSetProperty(e->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, input ? &on : &off, sizeof(on));
    if (!status) status = AudioUnitSetProperty(e->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, input ? &off : &on, sizeof(on));
    if (!status) status = AudioUnitSetProperty(e->unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, sizeof(device));
    AudioObjectPropertyAddress address = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 size = sizeof(e->rate);
    if (!status) status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &e->rate);
    AudioStreamBasicDescription format = { .mSampleRate = e->rate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, .mBytesPerPacket = 8,
        .mFramesPerPacket = 1, .mBytesPerFrame = 8, .mChannelsPerFrame = 2, .mBitsPerChannel = 32 };
    if (!status) status = AudioUnitSetProperty(e->unit, kAudioUnitProperty_StreamFormat,
        input ? kAudioUnitScope_Output : kAudioUnitScope_Input, input ? 1 : 0, &format, sizeof(format));
    UInt32 max = MAX_FRAMES;
    if (!status) status = AudioUnitSetProperty(e->unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &max, sizeof(max));
    AURenderCallbackStruct callback = { input ? capture : render, e };
    if (!status) status = AudioUnitSetProperty(e->unit, input ? kAudioOutputUnitProperty_SetInputCallback : kAudioUnitProperty_SetRenderCallback,
        input ? kAudioUnitScope_Global : kAudioUnitScope_Input, 0, &callback, sizeof(callback));
    if (!status) status = AudioUnitInitialize(e->unit);
    if (status) { if (error) *error = status; sb_endpoint_destroy(e); return NULL; }
    return e;
}
SBEndpoint *sb_capture_create(uint32_t d, SBQueue *q, int32_t *err) { return create(d, q, true, err); }
SBEndpoint *sb_output_create(uint32_t d, SBQueue *q, int32_t *err) { return create(d, q, false, err); }
double sb_endpoint_rate(const SBEndpoint *e) { return e ? e->rate : 0; }
int32_t sb_endpoint_start(SBEndpoint *e) { return e ? AudioOutputUnitStart(e->unit) : kAudio_ParamError; }
uint64_t sb_endpoint_underruns(const SBEndpoint *e) { return e ? atomic_load(&e->underruns) : 0; }
int32_t sb_endpoint_error(const SBEndpoint *e) { return e ? atomic_load(&e->error) : 0; }
uint64_t sb_endpoint_heartbeat(const SBEndpoint *e) { return e ? atomic_load_explicit(&e->heartbeat, memory_order_relaxed) : 0; }
void sb_endpoint_destroy(SBEndpoint *e) {
    if (!e) return;
    if (e->unit) { AudioOutputUnitStop(e->unit); AudioUnitUninitialize(e->unit); AudioComponentInstanceDispose(e->unit); }
    free(e->scratch); free(e);
}
