#ifndef SWITCHBOARD_AUDIO_REALTIME_H
#define SWITCHBOARD_AUDIO_REALTIME_H
#include <stdint.h>
#include <stdbool.h>
typedef struct SBQueue SBQueue;
typedef struct SBEndpoint SBEndpoint;
typedef struct SBDiscardCapture SBDiscardCapture;
SBDiscardCapture *sb_discard_capture_start(uint32_t device, int32_t *error);
void sb_discard_capture_destroy(SBDiscardCapture *capture);
SBQueue *sb_queue_create(uint32_t capacity);
void sb_queue_destroy(SBQueue *queue);
bool sb_queue_write(SBQueue *queue, const float *stereo, uint32_t frames, uint64_t host_time);
uint32_t sb_queue_read(SBQueue *queue, float *stereo, uint32_t maximum, uint64_t *host_time);
uint32_t sb_queue_read_packet(SBQueue *queue, float *stereo, uint32_t maximum, uint64_t *host_time);
uint32_t sb_queue_available(const SBQueue *queue);
uint64_t sb_queue_dropped(const SBQueue *queue);
void sb_queue_clear(SBQueue *queue);
uint64_t sb_host_time(void);
double sb_host_seconds(uint64_t ticks);
SBEndpoint *sb_capture_create(uint32_t device, SBQueue *queue, int32_t *error);
SBEndpoint *sb_output_create(uint32_t device, SBQueue *queue, int32_t *error);
double sb_endpoint_rate(const SBEndpoint *endpoint);
int32_t sb_endpoint_start(SBEndpoint *endpoint);
void sb_endpoint_destroy(SBEndpoint *endpoint);
uint64_t sb_endpoint_underruns(const SBEndpoint *endpoint);
int32_t sb_endpoint_error(const SBEndpoint *endpoint);
uint64_t sb_endpoint_heartbeat(const SBEndpoint *endpoint);
#endif
