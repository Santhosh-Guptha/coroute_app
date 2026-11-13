/*
 * CoRoute voice cleanup (Round 8): RNNoise noise suppression for the intercom, with a 120 Hz high-pass,
 * a 16 <-> 48 kHz polyphase resampler and a fast wind-burst ducker.
 *
 * Plain C99, no allocation after cv_create, no globals of our own (RNNoise keeps one lazily initialised
 * FFT table). One CvState per talk pipeline; not thread-safe per state.
 *
 * The app binds this API with dart:ffi (lib/data/services/voice/voice_native.dart): the caller writes
 * 16 kHz PCM16 into cv_io(st), calls cv_process(st, n) and reads the cleaned samples back from the same
 * buffer. No JNI hop and no platform-channel round trip on the audio path.
 *
 * Licence: this file is part of CoRoute. RNNoise (rnnoise/) is BSD-3-Clause, see rnnoise/COPYING.
 */
#ifndef COROUTE_VOICE_H
#define COROUTE_VOICE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__GNUC__)
#define CV_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#else
#define CV_EXPORT
#endif

/** Modes. OFF passes audio through untouched (no latency). */
#define CV_MODE_OFF 0
/** RNNoise output mixed with the (time-aligned) input at -12 dB: suppression is capped near 12 dB. */
#define CV_MODE_NORMAL 1
/** Full RNNoise suppression (default). */
#define CV_MODE_STRONG 2

/** Samples per call must be a multiple of this (10 ms at 16 kHz). */
#define CV_BLOCK_16K 160
/** Largest n accepted by cv_process (60 ms at 16 kHz). */
#define CV_MAX_16K 960

typedef struct CvState CvState;

CV_EXPORT CvState *cv_create(void);
CV_EXPORT void cv_destroy(CvState *st);
/** New talk session: clears filters and delay lines (the RNNoise state is kept: the road did not change). */
CV_EXPORT void cv_reset(CvState *st);
CV_EXPORT void cv_set_mode(CvState *st, int mode);
/** Wind-noise mode: 1 = duck wind bursts (default), 0 = off. */
CV_EXPORT void cv_set_wind_duck(CvState *st, int on);
/** The in/out buffer: CV_MAX_16K int16 samples. */
CV_EXPORT int16_t *cv_io(CvState *st);
/** Cleans n samples (multiple of CV_BLOCK_16K, at most CV_MAX_16K) of cv_io in place. Returns n, or -1. */
CV_EXPORT int cv_process(CvState *st, int n);
/** Highest RNNoise voice probability seen in the last cv_process call (0..1). */
CV_EXPORT float cv_last_vad(CvState *st);
/** Current wind-duck gain in dB (0 = no ducking, negative while a burst is ducked). */
CV_EXPORT float cv_wind_gain_db(CvState *st);
/** Fraction of 10 ms blocks flagged as wind since cv_create / cv_reset (0..1), for diagnostics. */
CV_EXPORT float cv_wind_share(CvState *st);
/** Added latency of NORMAL / STRONG in 16 kHz samples (the output lags the input by this much). */
CV_EXPORT int cv_latency_16k(void);
/** ABI version of this API (bumped on any change of the functions above). */
CV_EXPORT int cv_version(void);

/* Internal helpers, exported for the host test harness (tool/voice_lab). */
CV_EXPORT int cv_resampler_taps(void);

#ifdef __cplusplus
}
#endif

#endif
