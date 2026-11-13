/*
 * CoRoute voice cleanup (Round 8). See coroute_voice.h for the API and docs/features_355/voice_clarity.md for
 * the design and the measured results (tool/voice_lab).
 *
 * Per 10 ms block of 16 kHz input:
 *   1. wind-gust features on the raw input (energy below 100 Hz: share, smoothed level over its slow average;
 *      clipping);
 *   2. 2nd-order Butterworth high-pass at 120 Hz (wind rumble, engine drone);
 *   3. x3 polyphase upsampling to 48 kHz (121-tap Kaiser-windowed sinc, cut-off 7.3 kHz);
 *   4. RNNoise (one 480-sample frame);
 *   5. /3 decimation back to 16 kHz with the same filter;
 *   6. NORMAL: + the time-aligned high-passed input at -12 dB (caps the suppression, more natural);
 *   7. wind-duck gain (fast attack, 120 ms release), not while RNNoise hears a voice. The detector runs on input that is 12.5 ms ahead of
 *      the output, so the duck is in place before a gust reaches the output (look-ahead for free).
 * Added latency: 600 samples at 48 kHz = 200 samples at 16 kHz = 12.5 ms (RNNoise 10 ms + filters 2.5 ms).
 */
#include "coroute_voice.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "rnnoise.h"

#define CV_VERSION 1
#define TAPS 121                       /* odd: linear phase, integer group delay of 60 samples at 48 kHz */
#define PHASE_TAPS ((TAPS + 2) / 3)    /* 41 */
#define FRAME48 480
#define LATENCY_48K (FRAME48 + (TAPS - 1)) /* RNNoise 480 + two filters x 60 */
#define LATENCY_16K (LATENCY_48K / 3)      /* 200 */
#define HP_HZ 120.0
#define WIND_LP_HZ 100.0

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

typedef struct {
  float b0, b1, b2, a1, a2;
  float z1, z2;
} Biquad;

struct CvState {
  DenoiseState *rn;
  int mode;
  int wind_duck;
  int16_t io[CV_MAX_16K];
  float h[TAPS];
  /* upsampler history (16 kHz, newest last) */
  float up_hist[PHASE_TAPS];
  /* decimator history: TAPS-1 previous 48 kHz samples followed by the current frame */
  float dn_buf[TAPS - 1 + FRAME48];
  float in48[FRAME48];
  float out48[FRAME48];
  /* dry (high-passed) delay line for NORMAL, LATENCY_16K samples */
  float dry[LATENCY_16K];
  int dry_pos;
  Biquad hp;
  Biquad wind_lp, wind_lp2;
  /* wind detector */
  float floor_db;      /* slow low-band reference, dBFS (diagnostics) */
  double low_fast, low_slow, tot_fast;
  int floor_blocks; /* kept across cv_reset: the road did not change between two presses */
  int wind_hold;
  float wind_gain;     /* linear, smoothed per sample */
  long blocks, wind_blocks;
  float last_vad, prev_vad;
};

static double bessel_i0(double x) {
  double sum = 1.0, term = 1.0, q = x * x / 4.0;
  for (int k = 1; k < 40; k++) {
    term *= q / ((double)k * k);
    sum += term;
    if (term < 1e-12 * sum) break;
  }
  return sum;
}

/* Low-pass FIR for the 48 kHz grid: Kaiser-windowed sinc, unity DC gain. */
static void design_lowpass(float *h, int n, double fc, double fs, double beta) {
  double sum = 0.0, i0b = bessel_i0(beta);
  int mid = (n - 1) / 2;
  double w = 2.0 * fc / fs;
  for (int i = 0; i < n; i++) {
    int k = i - mid;
    double s = k == 0 ? w : sin(M_PI * w * k) / (M_PI * k);
    double r = (double)k / mid;
    double win = bessel_i0(beta * sqrt(1.0 - r * r)) / i0b;
    h[i] = (float)(s * win);
    sum += s * win;
  }
  for (int i = 0; i < n; i++) h[i] = (float)(h[i] / sum);
}

static void biquad_hp(Biquad *b, double f, double fs) {
  double w0 = 2 * M_PI * f / fs, c = cos(w0), al = sin(w0) / (2 * 0.7071067811865476);
  double a0 = 1 + al;
  b->b0 = (float)((1 + c) / 2 / a0); b->b1 = (float)(-(1 + c) / a0); b->b2 = b->b0;
  b->a1 = (float)(-2 * c / a0); b->a2 = (float)((1 - al) / a0);
  b->z1 = b->z2 = 0;
}

static void biquad_lp(Biquad *b, double f, double fs) {
  double w0 = 2 * M_PI * f / fs, c = cos(w0), al = sin(w0) / (2 * 0.7071067811865476);
  double a0 = 1 + al;
  b->b0 = (float)((1 - c) / 2 / a0); b->b1 = (float)((1 - c) / a0); b->b2 = b->b0;
  b->a1 = (float)(-2 * c / a0); b->a2 = (float)((1 - al) / a0);
  b->z1 = b->z2 = 0;
}

static inline float biquad_run(Biquad *b, float x) {
  /* transposed direct form II */
  float y = b->b0 * x + b->z1;
  b->z1 = b->b1 * x - b->a1 * y + b->z2;
  b->z2 = b->b2 * x - b->a2 * y;
  return y;
}

CvState *cv_create(void) {
  CvState *st = (CvState *)calloc(1, sizeof(CvState));
  if (!st) return NULL;
  st->rn = rnnoise_create(NULL);
  if (!st->rn) { free(st); return NULL; }
  st->mode = CV_MODE_STRONG;
  st->wind_duck = 1;
  design_lowpass(st->h, TAPS, 7300.0, 48000.0, 8.0);
  cv_reset(st);
  return st;
}

void cv_destroy(CvState *st) {
  if (!st) return;
  if (st->rn) rnnoise_destroy(st->rn);
  free(st);
}

void cv_reset(CvState *st) {
  if (!st) return;
  memset(st->up_hist, 0, sizeof(st->up_hist));
  memset(st->dn_buf, 0, sizeof(st->dn_buf));
  memset(st->dry, 0, sizeof(st->dry));
  st->dry_pos = 0;
  biquad_hp(&st->hp, HP_HZ, 16000.0);
  biquad_lp(&st->wind_lp, WIND_LP_HZ, 16000.0);
  biquad_lp(&st->wind_lp2, WIND_LP_HZ, 16000.0);
  st->wind_hold = 0;
  st->wind_gain = 1.0f;
  st->blocks = st->wind_blocks = 0;
  st->last_vad = st->prev_vad = 0.0f;
}

void cv_set_mode(CvState *st, int mode) {
  if (!st) return;
  if (mode < CV_MODE_OFF || mode > CV_MODE_STRONG) mode = CV_MODE_STRONG;
  st->mode = mode;
}

void cv_set_wind_duck(CvState *st, int on) { if (st) st->wind_duck = on ? 1 : 0; }
int16_t *cv_io(CvState *st) { return st ? st->io : NULL; }
float cv_last_vad(CvState *st) { return st ? st->last_vad : 0.0f; }
float cv_wind_gain_db(CvState *st) { return st ? (float)(20.0 * log10(st->wind_gain > 1e-6f ? st->wind_gain : 1e-6f)) : 0.0f; }
float cv_wind_share(CvState *st) { return st && st->blocks ? (float)st->wind_blocks / (float)st->blocks : 0.0f; }
int cv_latency_16k(void) { return LATENCY_16K; }
int cv_version(void) { return CV_VERSION; }
int cv_resampler_taps(void) { return TAPS; }

/* Wind features of one raw 10 ms block: a gust is a rise of the energy below 100 Hz well over its slow average
 * (or clipping). Levels are smoothed over ~35 ms first: 10 ms holds about one cycle of the low band, so single
 * blocks of steady noise jump by several dB and would look like gusts. */
static int wind_burst(CvState *st, const float *raw, int n) {
  double e = 0, el = 0;
  int clip = 0;
  for (int i = 0; i < n; i++) {
    float x = raw[i];
    /* 4th-order low-pass at 100 Hz (two biquads): wind on a mic is mostly below 100 Hz, a voice is not. */
    float l = biquad_run(&st->wind_lp2, biquad_run(&st->wind_lp, x));
    e += (double)x * x;
    el += (double)l * l;
    if (x >= 32000.0f || x <= -32000.0f) clip++;
  }
  double pl = el / n / (32768.0 * 32768.0), pt = e / n / (32768.0 * 32768.0);
  if (st->floor_blocks == 0) { st->low_fast = st->low_slow = pl; st->tot_fast = pt; }
  st->low_fast += 0.25 * (pl - st->low_fast);
  st->tot_fast += 0.25 * (pt - st->tot_fast);
  float fast_db = (float)(10.0 * log10(st->low_fast + 1e-12));
  float slow_db = (float)(10.0 * log10(st->low_slow + 1e-12));
  float ratio = (float)(st->tot_fast > 0 ? st->low_fast / st->tot_fast : 0);
  int burst = ratio > 0.5f && fast_db > -50.0f && fast_db > slow_db + 6.0f && st->floor_blocks >= 50;
  /* Slow reference (~2 s; ~0.5 s for the first half second): not pulled up by the gust it has to detect. */
  double k = st->floor_blocks < 50 ? 0.04 : 0.005;
  if (!burst) st->low_slow += k * (pl - st->low_slow);
  if (st->floor_blocks < 50) st->floor_blocks++;
  st->floor_db = slow_db;
  return burst || clip >= 3;
}

/* Wind-duck target (linear gain) from the burst flag and RNNoise's voice probability of the same block. */
static float wind_target(CvState *st, int burst, float vad) {
  if (burst) st->wind_hold = 3; /* 30 ms hold against chatter */
  else if (st->wind_hold > 0) st->wind_hold--;
  int windy = st->wind_hold > 0;
  st->blocks++;
  if (windy) st->wind_blocks++;
  if (!windy || !st->wind_duck || st->mode == CV_MODE_OFF) return 1.0f;
  /* A voice under the gust: RNNoise already keeps the voice and cuts the wind; ducking would cut words. */
  if (vad > 0.6f || st->prev_vad > 0.6f) return 1.0f;
  float duck_db = st->mode == CV_MODE_STRONG ? -20.0f : -12.0f;
  return powf(10.0f, duck_db / 20.0f);
}

int cv_process(CvState *st, int n) {
  if (!st || n <= 0 || n > CV_MAX_16K || n % CV_BLOCK_16K) return -1;
  if (st->mode == CV_MODE_OFF) { st->last_vad = 0; return n; }
  /* Attack ~3 ms, release ~120 ms (per-sample one-pole at 16 kHz). */
  const float att = 1.0f - expf(-1.0f / (0.003f * 16000.0f));
  const float rel = 1.0f - expf(-1.0f / (0.120f * 16000.0f));
  const float *h = st->h;
  float vad_max = 0.0f;
  for (int off = 0; off < n; off += CV_BLOCK_16K) {
    float raw[CV_BLOCK_16K], hp[CV_BLOCK_16K];
    for (int i = 0; i < CV_BLOCK_16K; i++) raw[i] = (float)st->io[off + i];
    int burst = wind_burst(st, raw, CV_BLOCK_16K);
    for (int i = 0; i < CV_BLOCK_16K; i++) hp[i] = biquad_run(&st->hp, raw[i]);

    /* x3 polyphase upsampling: y48[3m+p] = 3 * sum_k h[p+3k] * x16[m-k]. */
    for (int m = 0; m < CV_BLOCK_16K; m++) {
      memmove(st->up_hist + 1, st->up_hist, (PHASE_TAPS - 1) * sizeof(float));
      st->up_hist[0] = hp[m];
      for (int p = 0; p < 3; p++) {
        float acc = 0.0f;
        for (int k = 0; p + 3 * k < TAPS; k++) acc += h[p + 3 * k] * st->up_hist[k];
        st->in48[3 * m + p] = 3.0f * acc;
      }
    }

    float vad = rnnoise_process_frame(st->rn, st->out48, st->in48);
    if (vad > vad_max) vad_max = vad;
    float target = wind_target(st, burst, vad);
    st->prev_vad = vad;

    /* /3 decimation: y16[m] = sum_j h[j] * x48[3m - j] over [history | frame]. */
    memcpy(st->dn_buf + (TAPS - 1), st->out48, FRAME48 * sizeof(float));
    for (int m = 0; m < CV_BLOCK_16K; m++) {
      const float *x = st->dn_buf + (TAPS - 1) + 3 * m;
      float acc = 0.0f;
      for (int j = 0; j < TAPS; j++) acc += h[j] * x[-j];
      float y = acc;
      /* Time-aligned dry signal (the high-passed input LATENCY_16K samples ago). */
      float d = st->dry[st->dry_pos];
      st->dry[st->dry_pos] = hp[m];
      st->dry_pos = (st->dry_pos + 1) % LATENCY_16K;
      if (st->mode == CV_MODE_NORMAL) y += 0.25f * d; /* -12 dB of the original under the cleaned voice */
      float a = target < st->wind_gain ? att : rel;
      st->wind_gain += a * (target - st->wind_gain);
      y *= st->wind_gain;
      if (y > 32767.0f) y = 32767.0f;
      if (y < -32768.0f) y = -32768.0f;
      st->io[off + m] = (int16_t)lrintf(y);
    }
    memmove(st->dn_buf, st->dn_buf + FRAME48, (TAPS - 1) * sizeof(float));
  }
  st->last_vad = vad_max;
  return n;
}
