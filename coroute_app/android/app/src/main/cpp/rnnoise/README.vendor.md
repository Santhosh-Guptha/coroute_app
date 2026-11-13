# RNNoise (vendored)

RNNoise, a noise suppression library based on a recurrent neural network, by Jean-Marc Valin
(Xiph.Org Foundation / Mozilla). Licence: BSD-3-Clause, full text in `COPYING` (also in every source
file header). Attribution for the app's licences screen / store listing:
"RNNoise © 2017 Mozilla, © 2007-2017 Jean-Marc Valin, © 2005-2017 Xiph.Org Foundation, © 2003-2004 Mark Borgerding (BSD-3-Clause)".

Provenance (Round 8, 2026-11-13): GitHub and gitlab.xiph.org were not reachable from the build
sandbox, so the sources were taken from the crates.io package `rnnoise-sys` 0.1.3 (a packaging of
the upstream C sources, git `a13e4f91ed3b7d3eee6419053a7a628a61f126f8` of RustAudio/rnnoise-c), whose
archive SHA-256 `f81fc801620fa371b662fd9a60a79db2ac4b247b9433080433321ebd5f5ed902` matches the
crates.io index. This is the classic RNNoise with the built-in model in `rnn_data.c` (no model file
is downloaded or read at run time).

Changes: none to the sources. Left out: `rnn_reader.c` (reads a model from a file; not used),
`rnn_train.py`, `compile.sh`, the training `main()` (compiled out: `TRAINING` is 0).
The upstream `COPYING` file was not part of the package; `COPYING` here is the upstream BSD-3 text
with the copyright lines from the upstream file and the source headers.

Re-sync: replace `src/` and `include/` with the same files from https://github.com/xiph/rnnoise
and run `tool/voice_lab/run_lab.sh` (host build, SNR / latency / CPU checks).
