# loudness envelope (RMS per 100 ms) of a WAV, first channel; '#' bar
import sys, wave, numpy as np
w = wave.open(sys.argv[1]); r = w.getframerate(); ch = w.getnchannels(); sw = w.getsampwidth()
a = np.frombuffer(w.readframes(w.getnframes()), dtype={1:np.uint8,2:np.int16,4:np.int32}[sw]).astype(float)
a = a[::ch]
if sw == 1: a -= 128
step = r // 10
rms = [np.std(a[i:i+step]) for i in range(0, len(a) - step, step)]
mx = max(rms) or 1
start = float(sys.argv[2]) if len(sys.argv) > 2 else 0
for i, v in enumerate(rms):
    if i / 10 >= start: print('%5.1f %6d %s' % (i / 10, v, '#' * int(40 * v / mx)))
