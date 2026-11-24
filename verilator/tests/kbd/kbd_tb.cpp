// Unit test for rtl/sc3000_keyboard.sv (PC layout): PS/2 events in, matrix out.
#include "Vsc3000_keyboard.h"
#include "verilated.h"
#include <cstdio>
static Vsc3000_keyboard* k; static int fails = 0, toggle = 0;
// the machine: scans rows 0-6 one per clock, unless busy (scanning = false)
static bool scanning = true; static int scan_row = 0, scan_div = 1, scan_cnt = 0;
static void tick(int n = 1) { while (n--) { if (scanning && ++scan_cnt >= scan_div) { scan_cnt = 0; k->row_sel = scan_row; scan_row = (scan_row + 1) % 7; }
  k->clk_sys = 0; k->eval(); k->clk_sys = 1; k->eval(); } }
static void ps2(int code, bool down) { toggle ^= 1; k->ps2_key = (code & 0x1FF) | (down << 9) | (toggle << 10); tick(4); }
// pressed? (active low row_data) and SC shift state
static bool at(int row, int col) { k->row_sel = row; k->eval(); return !((k->row_data >> col) & 1); }
static void expect(const char* what, int row, int col, int shift) {
  tick(400);   // let the queue apply (GAP = 100 clocks in this test: CLK_HZ 2500)
  bool p = at(row, col), sh = at(6, 11);
  bool ok = p && (shift < 0 || sh == (bool)shift);
  printf("%-28s row %d col %2d pressed=%d shift=%d  %s\n", what, row, col, p, sh, ok ? "ok" : "FAIL");
  if (!ok) fails++;
}
// Long paste: every character down/up at PS/2 speed, far faster than the queue
// drains. Watch the matrix and record each new press (pos + SC shift).
#include <vector>
#include <string>
struct Ev { int pos; bool sh; };
static std::vector<Ev> watch(int ticks) {
  std::vector<Ev> out; static int prev = -1;
  for (int i = 0; i < ticks; i++) {
    int now = -1; bool sh = false;
    tick();
    for (int r = 0; r < 7; r++) { k->row_sel = r; k->eval();   // row_data is combinational
      int d = ~k->row_data & 0x7FF; if (r == 6) d &= 0x7FF;   // col 11 = shift, ignored
      for (int c = 0; c < 11; c++) if (d >> c & 1) now = r * 12 + c; }
    k->row_sel = 6; k->eval(); sh = !((k->row_data >> 11) & 1);
    if (now != prev && now >= 0) out.push_back({now, sh});
    prev = now;
  }
  return out;
}
static int code_of(char ch, bool& shift) {
  const char* lo = "1234567890 ,:"; const int lc[] = {0x16,0x1E,0x26,0x25,0x2E,0x36,0x3D,0x3E,0x46,0x45,0x29,0x41,0x4C};
  shift = false;
  for (int i = 0; lo[i]; i++) if (lo[i] == ch && ch != ':') return lc[i];
  if (ch == ':') { shift = true; return 0x4C; }
  if (ch == '\n') return 0x5A;
  const char* up = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"; const int uc[] = {0x1C,0x32,0x21,0x23,0x24,0x2B,0x34,0x33,0x43,0x3B,0x42,0x4B,0x3A,0x31,0x44,0x4D,0x15,0x2D,0x1B,0x2C,0x3C,0x2A,0x1D,0x22,0x35,0x1A};
  for (int i = 0; up[i]; i++) if (up[i] == ch) { shift = true; return uc[i]; }
  return -1;
}
static std::vector<Ev> type(const std::string& t, int per_key) {
  for (char ch : t) { bool sh; int c = code_of(ch, sh); if (c < 0) continue;
    if (sh) ps2(0x12, 1); ps2(c, 1); tick(per_key); ps2(c, 0); if (sh) ps2(0x12, 0); }
  return {};
}

int main() {
  k = new Vsc3000_keyboard; k->pc_layout = 1; k->reset = 1; tick(10); k->reset = 0; tick(10);
  ps2(0x1C, 1); expect("a -> a (SC shift on)", 0, 2, 1); ps2(0x1C, 0); tick(200);
  ps2(0x12, 1); ps2(0x1C, 1); expect("Shift+a -> A (SC shift off)", 0, 2, 0); ps2(0x1C, 0); ps2(0x12, 0); tick(200);
  ps2(0x55, 1); expect("= -> Shift + '-'", 3, 8, 1); ps2(0x55, 0); tick(200);
  ps2(0x12, 1); ps2(0x4C, 1); expect("Shift+; (:) -> ':' key", 3, 6, 0); ps2(0x4C, 0); ps2(0x12, 0); tick(200);
  ps2(0x12, 1); ps2(0x3E, 1); expect("Shift+8 (*) -> Shift + ':'", 3, 6, 1); ps2(0x3E, 0); ps2(0x12, 0); tick(200);
  ps2(0x12, 1); ps2(0x1E, 1); expect("Shift+2 (@) -> '@' key", 3, 7, 0); ps2(0x1E, 0); ps2(0x12, 0); tick(200);
  ps2(0x29, 1); expect("space", 1, 4, -1); ps2(0x29, 0); tick(200);
  bool stuck = false; for (int r = 0; r < 7; r++) { k->row_sel = r; tick(); if ((k->row_data & 0x7FF) != 0x7FF) stuck = true; }
  printf("all released: %s\n", stuck ? "FAIL" : "ok"); if (stuck) fails++;
  {
    std::string line = "10 OUT 127,159:OUT 127,191:GOSUB 90\n";
    // reference: one line typed slowly
    std::vector<Ev> ref;
    for (char ch : line) { std::string one(1, ch); type(one, 0); auto e = watch(1000); ref.insert(ref.end(), e.begin(), e.end()); }
    // paste: 14 lines (504 characters) as fast as PS/2 sends them
    std::string paste; for (int i = 0; i < 14; i++) paste += line;
    std::vector<Ev> got;
    for (char ch : paste) { std::string one(1, ch); type(one, 0); auto e = watch(1); got.insert(got.end(), e.begin(), e.end()); }
    ps2(0x12, 1);   // hold Shift while the queue drains: queued keys keep the Shift they were typed with
    auto rest = watch(150000);
    ps2(0x12, 0); got.insert(got.end(), rest.begin(), rest.end());
    bool ok = got.size() == ref.size() * 14;
    for (size_t i = 0; ok && i < got.size(); i++) { const Ev& a = got[i]; const Ev& b = ref[i % ref.size()];
      if (a.pos != b.pos || a.sh != b.sh) { ok = false; printf("paste: key %zu pos %d sh %d, want %d %d\n", i, a.pos, a.sh, b.pos, b.sh); } }
    printf("paste of %zu chars: %zu presses (want %zu)  %s\n", paste.size(), got.size(), ref.size() * 14, ok ? "ok" : "FAIL");
    if (!ok) fails++;
  }
  {
    // the machine stops scanning (BASIC storing a line): queued keys wait, none is lost
    tick(2000);
    scanning = false; k->row_sel = 5;                     // the machine gets busy
    ps2(0x1C, 1); ps2(0x1C, 0); ps2(0x32, 1); ps2(0x32, 0);   // a, b: 'a' goes down (it was idle long)
    tick(3000);                      // busy 3000 clocks (30 x GAP, less than the 2 s fallback)
    bool a_held = at(0, 2), b_wait = !at(2, 3) && !at(4, 3);
    scanning = true;
    auto e = watch(2000);
    bool ok = a_held && b_wait && e.size() >= 1 && e.back().pos == 4 * 12 + 3;   // then 'b' (row 4 col 3)
    printf("busy machine: 'a' held %d, 'b' waits %d, then 'b' %d  %s\n", a_held, b_wait, e.size() >= 1 && e.back().pos == 51, ok ? "ok" : "FAIL");
    if (!ok) fails++;
  }
  {
    // realistic paste: GAP = 100 clocks = 40 ms, so a frame is 42 clocks; BASIC scans the
    // 7 rows every 2 frames (a row every 12 clocks); KVMS sends a key every 80 ms
    // (held 30 ms): the queue backs up by hundreds of changes
    scan_div = 12;
    std::string line = "10 OUT 191,144:OUT 191,129\n20 OUT 191,0:OUT 191,64:FOR I=0 TO 255:NEXT\n";
    std::string paste; for (int i = 0; i < 4; i++) paste += line;
    std::vector<Ev> got;
    for (char ch : paste) { bool sh; int c = code_of(ch, sh); if (c < 0) continue;
      if (sh) ps2(0x12, 1); ps2(c, 1); auto e1 = watch(75 / 8); got.insert(got.end(), e1.begin(), e1.end());
      ps2(c, 0); if (sh) ps2(0x12, 0); auto e2 = watch(125 / 8); got.insert(got.end(), e2.begin(), e2.end()); }
    auto rest = watch(250000); got.insert(got.end(), rest.begin(), rest.end());
    size_t want = 0; for (char ch : paste) { bool sh; if (code_of(ch, sh) >= 0) want++; }
    bool ok = got.size() == want;
    printf("slow-scan paste of %zu keys: %zu presses  %s\n", want, got.size(), ok ? "ok" : "FAIL");
    if (!ok) fails++;
    scan_div = 1;
  }
  k->pc_layout = 0; ps2(0x12, 1); ps2(0x1C, 1); expect("SC layout: Shift+a", 0, 2, 1); ps2(0x1C, 0); ps2(0x12, 0);
  printf("%s\n", fails ? "FAILED" : "PASSED"); k->final(); delete k; return fails != 0;
}
