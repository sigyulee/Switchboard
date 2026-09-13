#include "AudioRealtime.h"
#include <CoreAudio/CoreAudio.h>
#include <stdlib.h>

struct SBDiscardCapture { AudioDeviceID device; AudioDeviceIOProcID proc; };
static OSStatus discard(AudioDeviceID device, const AudioTimeStamp *now, const AudioBufferList *input,
                        const AudioTimeStamp *inputTime, AudioBufferList *output,
                        const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)input; (void)inputTime; (void)output; (void)outputTime; (void)context;
    return noErr;
}
SBDiscardCapture *sb_discard_capture_start(uint32_t device, int32_t *error) {
    if (error) *error = 0;
    SBDiscardCapture *capture = calloc(1, sizeof(*capture));
    if (!capture) { if (error) *error = kAudioHardwareUnspecifiedError; return NULL; }
    capture->device = device;
    OSStatus status = AudioDeviceCreateIOProcID(device, discard, NULL, &capture->proc);
    if (!status) status = AudioDeviceStart(device, capture->proc);
    if (status) { if (error) *error = status; sb_discard_capture_destroy(capture); return NULL; }
    return capture;
}
void sb_discard_capture_destroy(SBDiscardCapture *capture) {
    if (!capture) return;
    if (capture->proc) {
        AudioDeviceStop(capture->device, capture->proc);
        AudioDeviceDestroyIOProcID(capture->device, capture->proc);
    }
    free(capture);
}
