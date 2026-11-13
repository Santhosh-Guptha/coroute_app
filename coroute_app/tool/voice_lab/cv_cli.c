/*
 * Host harness for android/app/src/main/cpp/coroute_voice.c (Round 8 voice lab).
 * Usage: cv_cli <mode 0|1|2> <wind 0|1> in.wav out.wav
 * Reads 16 kHz mono PCM16 WAV, processes it in 20 ms blocks exactly as the app does (cv_io / cv_process),
 * writes the output WAV and prints one JSON line: latency, CPU time per 10 ms block, VAD / wind stats.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "coroute_voice.h"

static int16_t *read_wav(const char *path, long *n) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  unsigned char hdr[12];
  if (fread(hdr, 1, 12, f) != 12 || memcmp(hdr, "RIFF", 4) || memcmp(hdr + 8, "WAVE", 4)) { fclose(f); return NULL; }
  int16_t *data = NULL;
  for (;;) {
    unsigned char ch[8];
    if (fread(ch, 1, 8, f) != 8) break;
    uint32_t len = ch[4] | ch[5] << 8 | ch[6] << 16 | (uint32_t)ch[7] << 24;
    if (!memcmp(ch, "data", 4)) {
      data = (int16_t *)malloc(len);
      *n = (long)(fread(data, 1, len, f) / 2);
      break;
    }
    fseek(f, len + (len & 1), SEEK_CUR);
  }
  fclose(f);
  return data;
}

static void put32(FILE *f, uint32_t v) { unsigned char b[4] = {v, v >> 8, v >> 16, v >> 24}; fwrite(b, 1, 4, f); }
static void put16(FILE *f, uint16_t v) { unsigned char b[2] = {v, v >> 8}; fwrite(b, 1, 2, f); }

static void write_wav(const char *path, const int16_t *x, long n) {
  FILE *f = fopen(path, "wb");
  fwrite("RIFF", 1, 4, f); put32(f, 36 + n * 2); fwrite("WAVEfmt ", 1, 8, f);
  put32(f, 16); put16(f, 1); put16(f, 1); put32(f, 16000); put32(f, 32000); put16(f, 2); put16(f, 16);
  fwrite("data", 1, 4, f); put32(f, n * 2); fwrite(x, 2, n, f); fclose(f);
}

int main(int argc, char **argv) {
  if (argc < 5) { fprintf(stderr, "usage: cv_cli mode wind in.wav out.wav\n"); return 2; }
  long n = 0;
  int16_t *x = read_wav(argv[3], &n);
  if (!x) { fprintf(stderr, "cannot read %s\n", argv[3]); return 1; }
  CvState *st = cv_create();
  cv_set_mode(st, atoi(argv[1]));
  cv_set_wind_duck(st, atoi(argv[2]));
  int16_t *io = cv_io(st);
  const int blk = 320; /* the ride mic hub delivers 20 ms frames */
  long nb = n / blk;
  double vad_sum = 0, worst = 0;
  struct timespec t0, t1, a, b;
  clock_gettime(CLOCK_MONOTONIC, &t0);
  for (long i = 0; i < nb; i++) {
    memcpy(io, x + i * blk, blk * 2);
    clock_gettime(CLOCK_MONOTONIC, &a);
    cv_process(st, blk);
    clock_gettime(CLOCK_MONOTONIC, &b);
    double us = (b.tv_sec - a.tv_sec) * 1e6 + (b.tv_nsec - a.tv_nsec) / 1e3;
    if (us > worst) worst = us;
    memcpy(x + i * blk, io, blk * 2);
    vad_sum += cv_last_vad(st);
  }
  clock_gettime(CLOCK_MONOTONIC, &t1);
  double total_us = (t1.tv_sec - t0.tv_sec) * 1e6 + (t1.tv_nsec - t0.tv_nsec) / 1e3;
  write_wav(argv[4], x, nb * blk);
  printf("{\"latency16k\":%d,\"usPer10ms\":%.1f,\"worstUsPer20ms\":%.1f,\"meanVad\":%.3f,\"windShare\":%.3f,\"taps\":%d}\n",
         atoi(argv[1]) == 0 ? 0 : cv_latency_16k(), total_us / (nb * 2.0), worst, nb ? vad_sum / nb : 0, cv_wind_share(st), cv_resampler_taps());
  cv_destroy(st);
  free(x);
  return 0;
}
