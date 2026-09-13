#include "AudioRealtime.h"
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdlib.h>

struct SBQueue {
    uint32_t capacity;
    float *samples;
    uint64_t *times;
    _Atomic uint64_t written, read, dropped;
};
SBQueue *sb_queue_create(uint32_t capacity) {
    if (capacity < 2 || capacity > (1u << 22)) return NULL;
    SBQueue *q = calloc(1, sizeof(*q));
    if (!q) return NULL;
    q->samples = calloc((size_t)capacity * 2, sizeof(float));
    q->times = calloc(capacity, sizeof(uint64_t));
    if (!q->samples || !q->times) { sb_queue_destroy(q); return NULL; }
    q->capacity = capacity;
    atomic_init(&q->written, 0); atomic_init(&q->read, 0); atomic_init(&q->dropped, 0);
    return q;
}
void sb_queue_destroy(SBQueue *q) {
    if (!q) return;
    free(q->samples); free(q->times); free(q);
}
bool sb_queue_write(SBQueue *q, const float *samples, uint32_t frames, uint64_t time) {
    if (!q || (!samples && frames)) return false;
    uint64_t w = atomic_load_explicit(&q->written, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&q->read, memory_order_acquire);
    if (frames > q->capacity - (w - r)) {
        atomic_fetch_add_explicit(&q->dropped, frames, memory_order_relaxed);
        return false;
    }
    for (uint32_t i = 0; i < frames; ++i) {
        size_t ix = (size_t)((w + i) % q->capacity);
        q->samples[ix * 2] = samples[i * 2]; q->samples[ix * 2 + 1] = samples[i * 2 + 1];
        q->times[ix] = time;
    }
    atomic_store_explicit(&q->written, w + frames, memory_order_release);
    return true;
}
uint32_t sb_queue_read(SBQueue *q, float *samples, uint32_t maximum, uint64_t *time) {
    if (!q || !samples) return 0;
    uint64_t r = atomic_load_explicit(&q->read, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&q->written, memory_order_acquire);
    uint32_t count = (uint32_t)((w - r) < maximum ? (w - r) : maximum);
    if (time && count) *time = q->times[r % q->capacity];
    for (uint32_t i = 0; i < count; ++i) {
        size_t ix = (size_t)((r + i) % q->capacity);
        samples[i * 2] = q->samples[ix * 2]; samples[i * 2 + 1] = q->samples[ix * 2 + 1];
    }
    atomic_store_explicit(&q->read, r + count, memory_order_release);
    return count;
}
uint32_t sb_queue_available(const SBQueue *q) {
    if (!q) return 0;
    return (uint32_t)(atomic_load_explicit(&q->written, memory_order_acquire) - atomic_load_explicit(&q->read, memory_order_acquire));
}
uint32_t sb_queue_read_packet(SBQueue *q, float *samples, uint32_t maximum, uint64_t *time) {
    if (!q || !samples || !maximum) return 0;
    uint64_t r = atomic_load_explicit(&q->read, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&q->written, memory_order_acquire);
    if (w == r) return 0;
    uint64_t stamp = q->times[r % q->capacity];
    uint32_t count = 0;
    while (count < maximum && r + count < w && q->times[(r + count) % q->capacity] == stamp) ++count;
    return sb_queue_read(q, samples, count, time);
}
uint64_t sb_queue_dropped(const SBQueue *q) { return q ? atomic_load_explicit(&q->dropped, memory_order_relaxed) : 0; }
void sb_queue_clear(SBQueue *q) {
    if (q) atomic_store_explicit(&q->read, atomic_load_explicit(&q->written, memory_order_acquire), memory_order_release);
}
uint64_t sb_host_time(void) { return mach_absolute_time(); }
double sb_host_seconds(uint64_t ticks) {
    mach_timebase_info_data_t info; mach_timebase_info(&info);
    return (double)ticks * info.numer / info.denom / 1e9;
}
