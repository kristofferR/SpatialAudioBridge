#ifndef SPATIAL_AUDIO_CORE_H
#define SPATIAL_AUDIO_CORE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct SABHandle SABHandle;
/* Source sample frames, not channel samples, including seek pre-roll, excluding encoder padding.
   Events count spans of accepted concealment, not completed recoveries. DTS:X reports zero. */
typedef struct SABRecoveryStatistics {
    uint64_t concealed_frames;
    uint64_t concealment_events;
    uint64_t longest_concealment_frames;
} SABRecoveryStatistics;
typedef int32_t (*SABPCMCallback)(void *context, const float *pcm, uint32_t frames, uint32_t sample_rate, uint32_t channels);
SABHandle *sab_create(uint32_t codec, uint32_t channels);
/* Applies TrueHD dialogue normalisation as an AV receiver does when enabled is nonzero; off by default. */
void sab_set_dialogue_normalisation(SABHandle *handle, int32_t enabled);
/* All calls on a session must be serialized. PCM is borrowed until callback returns.
   Return zero from callback to continue, nonzero to cancel. Input chunks <=65536 bytes.
   end=1 flushes and checks truncation; any error makes the session terminal. */
int32_t sab_push(SABHandle *handle, const uint8_t *data, size_t length, int32_t end, SABPCMCallback callback, void *context);
size_t sab_error(const SABHandle *handle, char *buffer, size_t capacity);
/* Copies a cumulative snapshot, also after end/error; a new session resets it. Returns -1 on
   null pointers, zero on success. Serialize with session calls; do not reenter from callback. */
int32_t sab_recovery_statistics(const SABHandle *handle, SABRecoveryStatistics *output);
void sab_destroy(SABHandle *handle);
#ifdef __cplusplus
}
#endif
#endif
