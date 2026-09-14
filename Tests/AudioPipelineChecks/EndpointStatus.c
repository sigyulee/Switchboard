#include "AudioRealtime.h"

// DeviceDoubles never passes a real endpoint or calls Core Audio.
int32_t sb_endpoint_error(const SBEndpoint *endpoint) {
    (void)endpoint;
    return 0;
}

uint64_t sb_endpoint_underruns(const SBEndpoint *endpoint) {
    (void)endpoint;
    return 0;
}
