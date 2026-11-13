# CoRoute native voice cleanup (Round 8): libcoroute_voice.so = RNNoise (BSD-3-Clause, Xiph.Org / Mozilla,
# vendored in rnnoise/, see rnnoise/COPYING and rnnoise/README.vendor.md) + the small wrapper coroute_voice.c.
# Loaded by lib/data/services/voice/voice_native.dart through dart:ffi. Built for every ABI the app ships.
cmake_minimum_required(VERSION 3.18)
project(coroute_voice C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
# gnu99: RNNoise uses M_PI from <math.h>.
set(CMAKE_C_EXTENSIONS ON)

add_library(coroute_voice SHARED
  coroute_voice.c
  rnnoise/src/denoise.c
  rnnoise/src/rnn.c
  rnnoise/src/rnn_data.c
  rnnoise/src/pitch.c
  rnnoise/src/kiss_fft.c
  rnnoise/src/celt_lpc.c
)

target_include_directories(coroute_voice PRIVATE rnnoise/include rnnoise/src .)
# Only the cv_* API is exported; RNNoise symbols stay hidden.
target_compile_options(coroute_voice PRIVATE -O2 -fvisibility=hidden -ffunction-sections -fdata-sections
  -Wno-unused-parameter -Wno-unused-variable -Wno-unused-function)
target_compile_definitions(coroute_voice PRIVATE RNNOISE_BUILD)
target_link_options(coroute_voice PRIVATE -Wl,--gc-sections -Wl,-z,max-page-size=16384)
target_link_libraries(coroute_voice m)
