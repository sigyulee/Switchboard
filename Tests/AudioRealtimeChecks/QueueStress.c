// SPDX-License-Identifier: AGPL-3.0-only
#include "AudioRealtime.h"

#include <inttypes.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

enum { TOTAL_FRAMES = 1048576, CAPACITY = 257, MAX_PACKET = 97, MAX_READ = 131 };

typedef struct {
    SBQueue *queue;
    _Atomic bool failed;
    struct timespec deadline;
    uint64_t rejected_frames; // Producer owns this until pthread_join.
    uint32_t consumed_frames; // Consumer owns this until pthread_join.
} Check;

static void fail(Check *check, const char *message) {
    if (!atomic_exchange_explicit(&check->failed, true, memory_order_relaxed)) {
        fprintf(stderr, "FAIL concurrent queue: %s\n", message);
    }
}

static bool stop(Check *check) {
    if (atomic_load_explicit(&check->failed, memory_order_relaxed)) return true;
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        fail(check, "cannot read the monotonic clock");
        return true;
    }
    if (now.tv_sec > check->deadline.tv_sec ||
        (now.tv_sec == check->deadline.tv_sec && now.tv_nsec >= check->deadline.tv_nsec)) {
        fail(check, "30-second deadline exceeded");
        return true;
    }
    return false;
}

static uint32_t packet_frames(uint32_t packet, uint32_t frame) {
    uint32_t count = 1 + (packet * 37u) % MAX_PACKET;
    return count < TOTAL_FRAMES - frame ? count : TOTAL_FRAMES - frame;
}

static uint64_t packet_time(uint32_t packet) {
    return UINT64_C(0x100000000) + (uint64_t)packet * 1009;
}

static void *produce(void *argument) {
    Check *check = argument;
    float samples[MAX_PACKET * 2];
    uint32_t frame = 0;
    for (uint32_t packet = 0; frame < TOTAL_FRAMES; ++packet) {
        uint32_t count = packet_frames(packet, frame);
        for (uint32_t index = 0; index < count; ++index) {
            samples[index * 2] = (float)(frame + index);
            samples[index * 2 + 1] = -(float)(frame + index) - 0.5f;
        }
        for (;;) {
            if (stop(check)) return NULL;
            if (sb_queue_write(check->queue, samples, count, packet_time(packet))) break;
            check->rejected_frames += count;
            sched_yield();
        }
        frame += count;
    }
    return NULL;
}

static void *consume(void *argument) {
    Check *check = argument;
    float samples[MAX_READ * 2];
    uint32_t frame = 0, packet = 0, offset = 0, reads = 0;
    uint32_t packet_size = packet_frames(packet, frame);
    while (frame < TOTAL_FRAMES) {
        if (stop(check)) return NULL;
        // Smaller and larger reads exercise both split packets and boundaries.
        uint32_t maximum = 1 + (reads++ * 53u) % MAX_READ;
        uint64_t time = 0;
        uint32_t count = sb_queue_read_packet(check->queue, samples, maximum, &time);
        if (!count) {
            sched_yield();
            continue;
        }
        if (count > maximum || count > packet_size - offset) {
            fail(check, "read crossed a packet boundary or exceeded its maximum");
            return NULL;
        }
        if (time != packet_time(packet)) {
            fail(check, "packet timestamp does not match its samples");
            return NULL;
        }
        for (uint32_t index = 0; index < count; ++index) {
            if (samples[index * 2] != (float)(frame + index) ||
                samples[index * 2 + 1] != -(float)(frame + index) - 0.5f) {
                fail(check, "stereo samples are lost, reordered, repeated, or corrupted");
                return NULL;
            }
        }
        frame += count;
        offset += count;
        if (offset == packet_size) {
            offset = 0;
            packet_size = packet_frames(++packet, frame);
        }
    }
    check->consumed_frames = frame;
    return NULL;
}

int main(void) {
    Check check = {0};
    atomic_init(&check.failed, false);
    check.queue = sb_queue_create(CAPACITY);
    if (!check.queue || clock_gettime(CLOCK_MONOTONIC, &check.deadline) != 0) {
        fprintf(stderr, "FAIL concurrent queue: initialization failed\n");
        sb_queue_destroy(check.queue);
        return EXIT_FAILURE;
    }
    check.deadline.tv_sec += 30;
    pthread_t producer, consumer;
    int result = pthread_create(&producer, NULL, produce, &check);
    if (result != 0) {
        fprintf(stderr, "FAIL concurrent queue: pthread_create producer (%d)\n", result);
        sb_queue_destroy(check.queue);
        return EXIT_FAILURE;
    }
    result = pthread_create(&consumer, NULL, consume, &check);
    if (result != 0) {
        fail(&check, "pthread_create consumer");
        // Do not release shared memory unless its owner has finished.
        if (pthread_join(producer, NULL) == 0) sb_queue_destroy(check.queue);
        return EXIT_FAILURE;
    }
    int producer_join = pthread_join(producer, NULL);
    int consumer_join = pthread_join(consumer, NULL);
    if (producer_join != 0 || consumer_join != 0) {
        fprintf(stderr, "FAIL concurrent queue: pthread_join (%d, %d)\n", producer_join, consumer_join);
        return EXIT_FAILURE;
    }
    if (check.consumed_frames != TOTAL_FRAMES || sb_queue_available(check.queue) != 0) {
        fail(&check, "not all accepted frames were consumed exactly once");
    }
    if (sb_queue_dropped(check.queue) != check.rejected_frames) {
        fail(&check, "overflow accounting differs from rejected writes");
    }
    bool passed = !atomic_load_explicit(&check.failed, memory_order_relaxed);
    sb_queue_destroy(check.queue);
    if (!passed) return EXIT_FAILURE;
    printf("PASS concurrent SPSC queue: %u stereo frames, packet timestamps, "
           "overflow accounting (%" PRIu64 " rejected frames retried).\n",
           TOTAL_FRAMES, check.rejected_frames);
    return EXIT_SUCCESS;
}
