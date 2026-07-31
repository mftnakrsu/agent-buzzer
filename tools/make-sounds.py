#!/usr/bin/env python3
"""Generate sounds/bird.wav — the flagship agent-buzzer sound.

Two short rising chirps, roughly 190ms in total. Somebody is going to hear
this fifty times a day, so the design goals in order are: recognisable at low
volume, over before you can get annoyed by it, and no clicks at any edge.

Stdlib only (wave + math). No numpy, no downloads. The generated .wav is
committed to the repo, so you only need to run this if you want to change the
sound:

    python3 tools/make-sounds.py

The output is deterministic: same input constants, byte-identical file.
"""

from __future__ import annotations

import argparse
import math
import os
import struct
import wave

SAMPLE_RATE = 44100
BIT_DEPTH = 16
FULL_SCALE = 2 ** (BIT_DEPTH - 1) - 1

# Peak amplitude after normalisation. Deliberately not 1.0: a notification that
# runs into the ceiling sounds harsh on laptop speakers.
PEAK = 0.72

# A chirp is a fast rising sweep. Birds do this with harmonics, so a little
# second harmonic keeps it from sounding like a test tone.
HARMONIC_LEVEL = 0.14

# (duration_s, start_hz, end_hz, gain)
# The second chirp is a touch higher and quieter, the way a real two-note call
# tends to land.
CHIRPS = (
    (0.080, 2200.0, 3600.0, 1.00),
    (0.078, 2450.0, 3750.0, 0.82),
)
GAP = 0.030


def envelope(position: float) -> float:
    """Amplitude envelope over a chirp, from 0.0 to 1.0 of its length.

    Raised-cosine attack so the onset cannot click, then a smooth decay that
    reaches exactly zero at the end so the release cannot click either.
    """
    attack = 0.18
    if position < attack:
        # 0 -> 1 with zero slope at both ends.
        return 0.5 - 0.5 * math.cos(math.pi * position / attack)
    decay = (position - attack) / (1.0 - attack)
    # cos^2 shaped tail: fast enough to feel crisp, smooth enough to be quiet.
    return math.cos(0.5 * math.pi * decay) ** 2


def chirp(duration: float, f_start: float, f_end: float, gain: float) -> list[float]:
    """One exponentially rising sweep.

    Phase is integrated rather than computed per-sample from the instantaneous
    frequency, which is what keeps the sweep free of discontinuities.
    """
    total = int(duration * SAMPLE_RATE)
    ratio = f_end / f_start
    samples: list[float] = []
    phase = 0.0
    for i in range(total):
        position = i / total
        frequency = f_start * (ratio ** position)
        phase += 2.0 * math.pi * frequency / SAMPLE_RATE
        value = math.sin(phase) + HARMONIC_LEVEL * math.sin(2.0 * phase)
        samples.append(value * envelope(position) * gain)
    return samples


def silence(duration: float) -> list[float]:
    return [0.0] * int(duration * SAMPLE_RATE)


def build_bird() -> list[float]:
    samples: list[float] = []
    for index, (duration, f_start, f_end, gain) in enumerate(CHIRPS):
        if index:
            samples.extend(silence(GAP))
        samples.extend(chirp(duration, f_start, f_end, gain))
    return samples


def normalise(samples: list[float], peak: float = PEAK) -> list[float]:
    loudest = max(abs(s) for s in samples) or 1.0
    scale = peak / loudest
    return [s * scale for s in samples]


def write_wav(path: str, samples: list[float]) -> None:
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    frames = b"".join(
        struct.pack("<h", max(-FULL_SCALE, min(FULL_SCALE, int(round(s * FULL_SCALE)))))
        for s in samples
    )
    with wave.open(path, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(BIT_DEPTH // 8)
        out.setframerate(SAMPLE_RATE)
        out.writeframes(frames)


def read_wav(path: str) -> tuple[list[int], int, int, int]:
    with wave.open(path, "rb") as src:
        frames = src.readframes(src.getnframes())
        values = list(struct.unpack("<%dh" % (len(frames) // 2), frames))
        return values, src.getframerate(), src.getnchannels(), src.getsampwidth()


def check(path: str, samples: list[float]) -> int:
    """Verify a committed .wav still matches what this script generates.

    Compared with a tolerance rather than byte-for-byte: `math.sin` is allowed
    to differ in the last bit between platforms' libm, so a strict comparison
    would fail depending on which machine ran it.
    """
    if not os.path.exists(path):
        print(f"FAIL {path} does not exist")
        return 1

    expected = [max(-FULL_SCALE, min(FULL_SCALE, int(round(s * FULL_SCALE)))) for s in samples]
    actual, rate, channels, width = read_wav(path)

    problems = []
    if rate != SAMPLE_RATE:
        problems.append(f"sample rate is {rate}, expected {SAMPLE_RATE}")
    if channels != 1:
        problems.append(f"{channels} channels, expected mono")
    if width * 8 != BIT_DEPTH:
        problems.append(f"{width * 8}-bit, expected {BIT_DEPTH}-bit")
    if len(actual) != len(expected):
        problems.append(f"{len(actual)} frames, expected {len(expected)}")
    else:
        worst = max(abs(a - b) for a, b in zip(actual, expected))
        # 2 LSB out of 32767 is inaudible; anything more means the generator
        # and the committed file have genuinely diverged.
        if worst > 2:
            problems.append(f"samples differ by up to {worst} (tolerance 2)")

    if problems:
        print(f"FAIL {path} no longer matches tools/make-sounds.py:")
        for p in problems:
            print(f"  - {p}")
        print("  Regenerate it with: python3 tools/make-sounds.py")
        return 1

    print(f"ok   {path} matches tools/make-sounds.py")
    return 0


def main() -> int:
    default_out = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "sounds", "bird.wav"
    )
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=default_out, help="output .wav path")
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the existing file matches, without writing anything",
    )
    args = parser.parse_args()

    samples = normalise(build_bird())

    if args.check:
        return check(args.out, samples)

    write_wav(args.out, samples)

    duration_ms = len(samples) / SAMPLE_RATE * 1000
    print(f"wrote {args.out}")
    print(f"  {duration_ms:.0f}ms, {SAMPLE_RATE}Hz, mono, {BIT_DEPTH}-bit")
    print(f"  peak {max(abs(s) for s in samples):.2f} of full scale")
    print(f"  first/last sample {samples[0]:.5f}/{samples[-1]:.5f} (both must be ~0)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
