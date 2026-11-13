#!/usr/bin/env python3
"""CoRoute Round 8 voice lab: synthetic riding noise, speech, and before/after measurements.

  python3 voice_lab.py gen  OUTDIR          # speech (flite TTS via ffmpeg, or formant synth) + noises + mixes
  python3 voice_lab.py score OUTDIR RESULTS # scores processed files OUTDIR/proc/<variant>/<mix>.wav

Nothing here ships in the app. numpy + scipy; pystoi (MIT) is used for STOI when installed.

Metrics (all on 16 kHz mono, output aligned by the measured latency):
  * SNR in        10*log10(sum s^2 / sum n^2) of the mix (by construction).
  * SNR out       spectral (phase-blind) signal-to-error, 60-7000 Hz, 32 ms frames: |Y| against |a S| with the
                  best gain a. Speech distortion counts as error too (conservative); filter phase is not counted. SNR in uses the same measure on the unprocessed mix.
  * Noise cut     in speech pauses (clean speech below -50 dBFS): noise power in / output power, dB.
  * Speech loss   level change of the speech-active parts when the CLEAN speech is processed alone, dB.
  * STOI          short-time objective intelligibility (0..1), when pystoi is installed.
"""
import json
import os
import subprocess
import sys
import wave

import numpy as np
from scipy import signal

FS = 16000
RNG = np.random.default_rng(355)

SENTENCES = [
    ("kal", "Fuel stop at the next exit, everyone keep left."),
    ("slt", "Slow down, there is gravel on the road after the bridge."),
    ("awb", "I can see a truck ahead, wait before you overtake."),
    ("rms", "Regroup at the tea stall, the sweeper is two minutes behind."),
    ("slt", "Police checkpoint ahead, keep your documents ready."),
    ("kal", "Nice curve coming up, stay in your lane."),
]


def write_wav(path, x):
    x = np.clip(np.round(x * 32768.0), -32768, 32767).astype('<i2')
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(FS)
        w.writeframes(x.tobytes())


def read_wav(path):
    with wave.open(path, 'rb') as w:
        assert w.getframerate() == FS and w.getnchannels() == 1
        return np.frombuffer(w.readframes(w.getnframes()), dtype='<i2').astype(np.float64) / 32768.0


def rms_db(x):
    return 10 * np.log10(np.mean(x ** 2) + 1e-20)


def colored(n, exponent):
    """1/f^exponent noise (0 white, 1 pink, 2 brown), unit RMS."""
    spec = np.fft.rfft(RNG.standard_normal(n))
    f = np.fft.rfftfreq(n, 1 / FS)
    f[0] = f[1]
    spec /= f ** (exponent / 2)
    x = np.fft.irfft(spec, n)
    return x / np.sqrt(np.mean(x ** 2))


def flite_speech(tmp):
    parts = []
    for i, (voice, text) in enumerate(SENTENCES):
        p = os.path.join(tmp, f'utt{i}.wav')
        cmd = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
               f"flite=text='{text}':voice={voice}", '-ar', str(FS), '-ac', '1', '-y', p]
        if subprocess.run(cmd).returncode != 0:
            return None
        parts.append(read_wav(p))
        parts.append(np.zeros(int(FS * RNG.uniform(0.6, 1.2))))  # pauses between phrases
    return np.concatenate([np.zeros(int(FS * 1.0))] + parts)


def formant_speech(seconds=20.0):
    """Fallback: glottal pulses through vowel formants, 4 syllables/s, fricatives, pauses."""
    n = int(FS * seconds)
    out = np.zeros(n)
    vowels = [(730, 1090, 2440), (270, 2290, 3010), (300, 870, 2240), (530, 1840, 2480), (570, 840, 2410)]
    t = 0
    while t < n - FS:
        dur = int(FS * RNG.uniform(1.0, 2.5))
        f0 = RNG.uniform(95, 190)
        seg = np.zeros(dur)
        pos = 0.0
        while pos < dur:
            seg[int(pos)] = 1.0
            pos += FS / (f0 * (1 + 0.1 * np.sin(2 * np.pi * pos / FS * 1.3)))
        env = np.zeros(dur)
        syl = int(FS / 4)
        for s in range(0, dur - syl, syl):
            env[s:s + syl] = np.hanning(syl)
        voiced = np.zeros(dur)
        for s in range(0, dur, syl):
            f1, f2, f3 = vowels[RNG.integers(len(vowels))]
            chunk = seg[s:s + syl]
            y = chunk
            for f, bw in ((f1, 80), (f2, 100), (f3, 150)):
                b, a = signal.iirpeak(f, f / bw, FS)
                y = signal.lfilter(b, a, y)
            voiced[s:s + len(y)] = y
        fric = signal.lfilter(*signal.butter(4, [3500, 7000], 'bandpass', fs=FS), RNG.standard_normal(dur)) * 0.15
        fmask = (np.arange(dur) % syl) < syl * 0.15
        x = voiced * env + fric * fmask
        out[t:t + dur] = x
        t += dur + int(FS * RNG.uniform(0.5, 1.0))
    return out


def noises(n):
    t = np.arange(n) / FS
    out = {}
    out['pink'] = colored(n, 1.0)
    out['brown'] = colored(n, 2.0)
    # Wind on a helmet / phone mic: brown-ish rumble, low-passed, with gusts (+6..+14 dB, 0.3-1.5 s).
    w = signal.lfilter(*signal.butter(2, 400, fs=FS), colored(n, 1.6))
    env = np.ones(n)
    k = 0
    while k < n:
        k += int(FS * RNG.uniform(0.8, 2.5))
        d = int(FS * RNG.uniform(0.3, 1.5))
        if k + d < n:
            env[k:k + d] += (10 ** (RNG.uniform(6, 14) / 20) - 1) * np.hanning(d)
        k += d
    out['wind_gusts'] = w * env / np.sqrt(np.mean((w * env) ** 2))
    # Engine drone: twin firing frequency 30-60 Hz wandering, harmonics to ~1.5 kHz, amplitude flutter.
    f0 = 45 + 12 * np.sin(2 * np.pi * 0.07 * t) + 3 * np.sin(2 * np.pi * 0.5 * t)
    ph = 2 * np.pi * np.cumsum(f0) / FS
    e = sum((1.0 / k) * np.sin(k * ph + RNG.uniform(0, 6.28)) for k in range(1, 33))
    e *= 1 + 0.2 * np.sin(2 * np.pi * 7 * t)
    e += 0.2 * signal.lfilter(*signal.butter(2, [80, 1200], 'bandpass', fs=FS), RNG.standard_normal(n))
    out['engine'] = e / np.sqrt(np.mean(e ** 2))
    # Road / tyre roar: band-limited brown + pink, steady.
    r = signal.lfilter(*signal.butter(2, [60, 1500], 'bandpass', fs=FS), colored(n, 1.5))
    out['road_roar'] = r / np.sqrt(np.mean(r ** 2))
    # Traffic: pink bed + passing vehicles (swoosh bells) + a horn.
    tr = 0.4 * colored(n, 1.0)
    for c in np.arange(1.5, n / FS - 1, 3.1):
        i = int(c * FS)
        d = int(FS * 1.6)
        if i + d < n:
            tr[i:i + d] += signal.lfilter(*signal.butter(2, [100, 3000], 'bandpass', fs=FS), RNG.standard_normal(d)) * np.hanning(d) * 2
    hi = int(n * 0.55)
    hd = int(FS * 0.8)
    th = np.arange(hd) / FS
    tr[hi:hi + hd] += 0.8 * (np.sign(np.sin(2 * np.pi * 420 * th)) + np.sign(np.sin(2 * np.pi * 520 * th))) * np.hanning(hd) ** 0.3
    out['traffic'] = tr / np.sqrt(np.mean(tr ** 2))
    # Motorway at 80-100 km/h through a helmet: wind + engine + road roar.
    hw = out['wind_gusts'] * 1.0 + out['engine'] * 0.6 + out['road_roar'] * 0.7
    out['highway_mix'] = hw / np.sqrt(np.mean(hw ** 2))
    return out


MIX_SNRS = [5, 0]


def gen(outdir):
    os.makedirs(outdir, exist_ok=True)
    s = flite_speech(outdir)
    kind = 'flite TTS (4 voices)'
    if s is None:
        s = formant_speech()
        kind = 'formant synth'
    s = s / np.max(np.abs(s)) * 10 ** (-6 / 20)
    s *= 10 ** ((-26 - rms_db(s[np.abs(s) > 1e-3])) / 20)  # active speech about -26 dBFS
    n = len(s)
    write_wav(os.path.join(outdir, 'clean.wav'), s)
    meta = {'speech': kind, 'seconds': round(n / FS, 2), 'mixes': {}}
    for name, nz in noises(n).items():
        for snr in MIX_SNRS:
            g = np.sqrt(np.sum(s ** 2) / np.sum(nz ** 2) / 10 ** (snr / 10))
            noise = nz * g
            mix = s + noise
            peak = np.max(np.abs(mix))
            scale = min(1.0, 0.95 / peak)
            tag = f'{name}_{snr}dB'
            write_wav(os.path.join(outdir, f'{tag}.wav'), mix * scale)
            write_wav(os.path.join(outdir, f'{tag}.noise.wav'), noise * scale)
            write_wav(os.path.join(outdir, f'{tag}.speech.wav'), s * scale)
            meta['mixes'][tag] = {'noise': name, 'snr_in': snr, 'scale': scale}
    with open(os.path.join(outdir, 'meta.json'), 'w') as f:
        json.dump(meta, f, indent=1)
    print(json.dumps({'generated': len(meta['mixes']), 'speech': kind, 'seconds': meta['seconds']}))


def _mag(x):
    f, t, z = signal.stft(x, FS, nperseg=512, noverlap=384)
    band = (f >= 60) & (f <= 7000)
    return np.abs(z[band])


def spectral_snr(s, y):
    S, Y = _mag(s), _mag(y)
    m = min(S.shape[1], Y.shape[1])
    S, Y = S[:, :m], Y[:, :m]
    a = np.sum(S * Y) / np.sum(S * S)
    return 10 * np.log10(np.sum((a * S) ** 2) / (np.sum((Y - a * S) ** 2) + 1e-20))


def align(y, lat, n):
    z = np.zeros(n)
    m = min(n, len(y) - lat)
    z[:m] = y[lat:lat + m]
    return z


def measure_latency(clean, out):
    """Lag (samples) of out vs clean by cross-correlation over 0..1000."""
    n = min(len(clean), len(out))
    best, lag = -1, 0
    for L in range(0, 1000):
        c = np.dot(clean[:n - L], out[L:n])
        if c > best:
            best, lag = c, L
    return lag


def score(outdir, results_path):
    meta = json.load(open(os.path.join(outdir, 'meta.json')))
    procdir = os.path.join(outdir, 'proc')
    try:
        from pystoi import stoi
    except Exception:
        stoi = None
    clean_full = read_wav(os.path.join(outdir, 'clean.wav'))
    res = {'speech': meta['speech'], 'seconds': meta['seconds'], 'variants': {}}
    for variant in sorted(os.listdir(procdir)):
        vdir = os.path.join(procdir, variant)
        info = {}
        ip = os.path.join(vdir, 'info.json')
        if os.path.exists(ip):
            info = json.load(open(ip))
        c_out = read_wav(os.path.join(vdir, 'clean.wav'))
        mlat = measure_latency(clean_full, c_out)
        lat = mlat  # align by the measured lag (the nominal one is in info)
        rows = {}
        active = np.convolve(clean_full ** 2, np.ones(320) / 320, 'same') > 10 ** (-50 / 10)
        ca = align(c_out, lat, len(clean_full))
        speech_loss = 10 * np.log10(np.sum(ca[active] ** 2) / np.sum(clean_full[active] ** 2) + 1e-20)
        for tag, m in meta['mixes'].items():
            p = os.path.join(vdir, f'{tag}.wav')
            if not os.path.exists(p):
                continue
            s = read_wav(os.path.join(outdir, f'{tag}.speech.wav'))
            nz = read_wav(os.path.join(outdir, f'{tag}.noise.wav'))
            mix = s + nz
            y = align(read_wav(p), lat, len(s))
            snr_out = spectral_snr(s, y)
            snr_in = spectral_snr(s, mix)
            pause = ~active
            noise_cut = 10 * np.log10(np.sum(nz[pause] ** 2) / (np.sum(y[pause] ** 2) + 1e-20))
            row = {'snr_in': round(snr_in, 1), 'snr_out': round(snr_out, 1), 'gain_db': round(snr_out - snr_in, 1),
                   'noise_cut_db': round(noise_cut, 1)}
            fj = os.path.join(vdir, f'{tag}.json')
            if os.path.exists(fj):
                try:
                    row['wind_share'] = json.load(open(fj)).get('windShare')
                except Exception:
                    pass
            if stoi is not None:
                row['stoi_in'] = round(float(stoi(s, mix, FS)), 3)
                row['stoi_out'] = round(float(stoi(s, y, FS)), 3)
            rows[tag] = row
        res['variants'][variant] = {'info': info, 'latency16k': lat, 'measured_latency16k': mlat,
                                    'speech_loss_db': round(speech_loss, 2), 'mixes': rows}
    for k, fn in (('ffi_check', 'ffi_check.json'), ('cpu_strong_chain', 'cpu.json')):
        fp = os.path.join(outdir, fn)
        if os.path.exists(fp):
            try:
                res[k] = json.loads(open(fp).read().strip().splitlines()[-1])
            except Exception:
                pass
    import platform
    res['host'] = {'machine': platform.machine(), 'processor': platform.processor() or 'unknown', 'python': platform.python_version()}
    with open(results_path, 'w') as f:
        json.dump(res, f, indent=1)
    print_table(res)


def print_table(res):
    variants = list(res['variants'])
    tags = sorted({t for v in res['variants'].values() for t in v['mixes']})
    print(f"speech: {res['speech']}, {res['seconds']} s")
    if 'ffi_check' in res:
        print(f"ffi check: {res['ffi_check']}")
    if 'cpu_strong_chain' in res:
        print(f"cpu (strong chain, best of 3): {res['cpu_strong_chain']}")
    for v in variants:
        d = res['variants'][v]
        print(f"{v}: latency {d['latency16k']} (measured {d['measured_latency16k']}) samples, clean-speech level change {d['speech_loss_db']} dB, info {d['info']}")
    print('cells: SNR gain (spectral, dB) | noise cut in pauses (dB) | STOI in>out')
    head = 'mix'.ljust(20) + ''.join(f'{v[:22]:>24}' for v in variants)
    print(head)
    for t in tags:
        cells = []
        for v in variants:
            r = res['variants'][v]['mixes'].get(t)
            if not r:
                cells.append(' ' * 24)
                continue
            st = f" {r['stoi_in']:.2f}>{r['stoi_out']:.2f}" if 'stoi_out' in r else ''
            cells.append(f"{r['gain_db']:+5.1f}dB cut{r['noise_cut_db']:4.0f}{st}".rjust(24))
        print(t.ljust(20) + ''.join(cells))


if __name__ == '__main__':
    if sys.argv[1] == 'gen':
        gen(sys.argv[2])
    elif sys.argv[1] == 'score':
        score(sys.argv[2], sys.argv[3])
