# decode a PSG noise segment into bits from run lengths, then find the recurrence
import sys, wave, numpy as np
w = wave.open(sys.argv[1]); r = w.getframerate(); ch = w.getnchannels()
a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(float)[::ch]
t0, t1, div = float(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
x = a[int(t0*r):int(t1*r)]; x -= x.mean()
s = x > 0; e = np.flatnonzero(s[1:] != s[:-1]); runs = np.diff(e)
u = r / (3579545 / div)
bits = []
lvl = int(s[e[0] + 1])
for n in runs:
    k = max(1, int(round(n / u))); bits += [lvl] * k; lvl ^= 1
b = np.array(bits)
res = sorted(((max(m, 1 - m), p, q) for (m, p, q) in ((np.mean(b[q:] == (b[q-p:len(b)-p] ^ b[:len(b)-q])), p, q) for p in range(1, 18) for q in range(p+1, 19))), reverse=True)
per = max((np.mean(b[L:] == b[:-L]), L) for L in range(2, 40))
print('%s %d bits, ones %.2f, best b[n]=b[n-%d]^b[n-%d] %.3f, best period %d (%.3f)' % (sys.argv[1], len(b), b.mean(), res[0][1], res[0][2], res[0][0], per[1], per[0]))
