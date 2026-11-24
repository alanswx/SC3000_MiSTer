// Headless Verilator harness for the SC-3000 core (sc3000_sim.sv).
//
//   ./obj_dir/Vsc3000_sim --cart game.sg --frames 300 --png out.png
//   ./obj_dir/Vsc3000_sim --cart basic3.sc --mapper level3 --type 'PRINT 1+1\n@200' --frames 300 --text-end
//
// Run with --help for every option.

#include "Vsc3000_sim.h"
#include "Vsc3000_sim___024root.h"
#include "Vsc3000_sim_sc3000_sim.h"
#include "verilated.h"

#include <zlib.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <map>
#include <set>
#include <algorithm>
#include <sys/stat.h>
#include <functional>

#ifdef SIM_FULL
static const uint64_t CLK_HZ = 42954545;   // sim clock = clk_sys
#else
static const uint64_t CLK_HZ = 10738635;   // sim clock = VDP master clock rate
#endif

static Vsc3000_sim* top;
static uint64_t cycles = 0;

// ---------------------------------------------------------------- options
static std::string omv_path;
static std::string cart_path, tape_path, ipl_path, disk_path, disk_out, rec_path;
static size_t rec_size = 262144;
static std::string prn_path, ser_out_path;
static size_t prn_size = 65536;
static int baud_sel = 0;                 // 0 = 9600 (jumper 1) ... 5 = 300
static std::string ser_fmt = "8E2";      // bits, parity N/E/O, stop bits of the harness UART
struct SerIn { int frame; std::string data; };
struct DiskSwap { int frame; std::string path; };   // path "" = eject
static std::vector<DiskSwap> swaps;
static std::vector<SerIn> ser_in;
static std::string outdir = "out", png_path, wav_path, trace_path, stop_text, vdp_dump_path;
static int run_frames = 0, every = 0, mapper = -1, trace_from = 0, trace_to = 1 << 30;
static std::set<int> shots, text_frames;
static bool tape_log = false, tape_turbo = false;
static bool model_sg1000 = false, pal = false, border = false, text_at_end = false, io_log = false;
static uint64_t profile_every = 0;
struct Peek { int frame; unsigned addr, n; };
static std::vector<Peek> peeks;

// ---------------------------------------------------------------- PNG
static void put32(std::vector<uint8_t>& v, uint32_t x) {
  v.push_back(x >> 24); v.push_back(x >> 16); v.push_back(x >> 8); v.push_back(x);
}
static void chunk(FILE* f, const char* type, const std::vector<uint8_t>& data) {
  std::vector<uint8_t> b; put32(b, data.size());
  b.insert(b.end(), type, type + 4); b.insert(b.end(), data.begin(), data.end());
  uint32_t crc = crc32(0, b.data() + 4, b.size() - 4);
  put32(b, crc); fwrite(b.data(), 1, b.size(), f);
}
static bool write_png(const std::string& path, int w, int h, const std::vector<uint8_t>& rgb) {
  FILE* f = fopen(path.c_str(), "wb"); if (!f) return false;
  static const uint8_t sig[8] = {137, 80, 78, 71, 13, 10, 26, 10}; fwrite(sig, 1, 8, f);
  std::vector<uint8_t> ihdr; put32(ihdr, w); put32(ihdr, h);
  ihdr.push_back(8); ihdr.push_back(2); ihdr.push_back(0); ihdr.push_back(0); ihdr.push_back(0);
  chunk(f, "IHDR", ihdr);
  std::vector<uint8_t> raw; raw.reserve((w * 3 + 1) * h);
  for (int y = 0; y < h; y++) { raw.push_back(0); raw.insert(raw.end(), &rgb[y * w * 3], &rgb[y * w * 3] + w * 3); }
  uLongf zl = compressBound(raw.size()); std::vector<uint8_t> z(zl);
  compress2(z.data(), &zl, raw.data(), raw.size(), 6); z.resize(zl);
  chunk(f, "IDAT", z); chunk(f, "IEND", {}); fclose(f); return true;
}

// ---------------------------------------------------------------- video capture
static const int FB_W = 400, FB_H = 320;
static std::vector<uint8_t> fb(FB_W * FB_H * 3);
static int vx = 0, vy = 0, max_x = 0, last_w = 0, last_h = 0;
static bool prev_hb = true, prev_vs = false, line_had_pixels = false;
static int frame = 0;

static void save_frame(const std::string& path) {
  std::vector<uint8_t> out(last_w * last_h * 3);
  for (int y = 0; y < last_h; y++) memcpy(&out[y * last_w * 3], &fb[y * FB_W * 3], last_w * 3);
  if (!write_png(path, last_w, last_h, out)) fprintf(stderr, "cannot write %s\n", path.c_str());
  uint32_t c = crc32(0, out.data(), out.size());
  printf("f%d shot %s %dx%d crc %08X\n", frame, path.c_str(), last_w, last_h, c);
}

// ---------------------------------------------------------------- keyboard matrix
// MAME bus/sg1000_exp/sk1100.cpp: key (row, col), col 0-7 = PA0-7, 8-11 = PB0-3
struct RC { int row, col; };
static const std::map<std::string, RC> named_keys = {
  {"eng", {0, 4}}, {"kana", {0, 4}}, {"space", {1, 4}}, {"home", {2, 4}}, {"clr", {2, 4}},
  {"del", {3, 4}}, {"ins", {3, 4}}, {"pi", {3, 5}}, {"down", {4, 5}}, {"left", {5, 5}},
  {"enter", {5, 6}}, {"cr", {5, 6}}, {"right", {6, 5}}, {"up", {6, 6}}, {"yen", {5, 8}},
  {"func", {5, 11}}, {"break", {6, 8}}, {"graph", {6, 9}}, {"ctrl", {6, 10}}, {"shift", {6, 11}},
};
static bool char_key(char c, RC& rc, bool& shift) {
  static const char* pa[7] = {"1QAZ\x01,KI", "2WSX .LO", "3EDC\x01/;P", "4RFV\x01\x01:@",
                              "5TGB\x01\x01][", "6YHN\x01\x01\n\x01", "7UJM\x01\x01\x01\x01"};
  static const char* pa_sh[7] = {"!\x01\x01\x01\x01<\x01\x01", "\"\x01\x01\x01\x01>\x01\x01",
                                 "#\x01\x01\x01\x01?+\x01", "$\x01\x01\x01\x01\x01*`",
                                 "%\x01\x01\x01\x01\x01}{", "&\x01\x01\x01\x01\x01\x01\x01",
                                 "'\x01\x01\x01\x01\x01\x01\x01"};
  static const char pb0[7] = {'8', '9', '0', '-', '^', '\\', 0};   // '\\' types the yen key
  static const char pb0_sh[7] = {'(', ')', 0, '=', '~', '|', 0};
  shift = false;
  if (c >= 'a' && c <= 'z') c = c - 'a' + 'A';   // BASIC wants capitals; Shift gives lower case
  for (int r = 0; r < 7; r++) {
    for (int k = 0; k < 8; k++) {
      if (pa[r][k] == c) { rc = {r, k}; return true; }
      if (pa_sh[r][k] == c) { rc = {r, k}; shift = true; return true; }
    }
    if (pb0[r] && pb0[r] == c) { rc = {r, 8}; return true; }
    if (pb0_sh[r] && pb0_sh[r] == c) { rc = {r, 8}; shift = true; return true; }
  }
  return false;
}

struct KeyEv { int frame; RC rc; bool down; };
static std::vector<KeyEv> key_evs;
static std::map<int, int> key_count;   // row*12+col -> times held (for overlapping events)
static void schedule_text(int f, const std::string& t) {
  for (size_t i = 0; i < t.size(); i++) {
    char c = t[i];
    if (c == '\\' && i + 1 < t.size() && t[i + 1] == 'n') { c = '\n'; i++; }
    RC rc; bool shift;
    if (!char_key(c, rc, shift)) { fprintf(stderr, "cannot type '%c'\n", c); continue; }
    RC sh = named_keys.at("shift");
    if (shift) key_evs.push_back({f, sh, true});
    key_evs.push_back({f, rc, true});
    key_evs.push_back({f + 3, rc, false});
    if (shift) key_evs.push_back({f + 3, sh, false});
    f += (c == '\n') ? 30 : 6;   // BASIC needs time to take in a line
  }
}

struct JoyEv { int frame, len, port; uint8_t bits; };
static std::vector<JoyEv> joy_evs;
struct PadEv { int frame, len; uint32_t bits; };   // Othello Multivision keypad
static std::vector<PadEv> pad_evs;
struct PenEv { int frame, len, x, y; };
static std::vector<PenEv> pen_evs;
struct NmiEv { int frame, len; };
static std::vector<NmiEv> nmi_evs;

// ---------------------------------------------------------------- loading
static std::vector<uint8_t> read_file(const std::string& p) {
  std::vector<uint8_t> d; FILE* f = fopen(p.c_str(), "rb");
  if (!f) { fprintf(stderr, "cannot open %s\n", p.c_str()); exit(3); }
  fseek(f, 0, SEEK_END); d.resize(ftell(f)); fseek(f, 0, SEEK_SET);
  if (fread(d.data(), 1, d.size(), f) != d.size()) { fprintf(stderr, "short read %s\n", p.c_str()); exit(3); }
  fclose(f); return d;
}

// --paste: PS/2 key events into rtl/sc3000_keyboard.sv (PC layout), timed like
// a USB keyboard / KVMS paste: each key held HOLD ms, GAP ms between keys
struct Ps2Ev { uint64_t cycle; int code; bool down; };
static std::vector<Ps2Ev> ps2_evs; static size_t ps2_i = 0; static int ps2_toggle = 0;
struct PasteReq { int frame; std::string text; int hold_ms, gap_ms; };
static std::vector<PasteReq> paste_reqs;
static int ps2_code(char ch, bool& shift) {
  static const char* up = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
  static const int uc[] = {0x1C,0x32,0x21,0x23,0x24,0x2B,0x34,0x33,0x43,0x3B,0x42,0x4B,0x3A,0x31,0x44,0x4D,0x15,0x2D,0x1B,0x2C,0x3C,0x2A,0x1D,0x22,0x35,0x1A};
  shift = false;
  for (int i = 0; up[i]; i++) { if (up[i] == ch) { shift = true; return uc[i]; } if (up[i] + 32 == ch) return uc[i]; }
  switch (ch) {
    case '1': return 0x16; case '2': return 0x1E; case '3': return 0x26; case '4': return 0x25; case '5': return 0x2E;
    case '6': return 0x36; case '7': return 0x3D; case '8': return 0x3E; case '9': return 0x46; case '0': return 0x45;
    case ' ': return 0x29; case ',': return 0x41; case '.': return 0x49; case ';': return 0x4C; case '=': return 0x55;
    case '-': return 0x4E; case '/': return 0x4A; case '\n': return 0x5A; case '\'': return 0x52;
    case ':': shift = true; return 0x4C; case '*': shift = true; return 0x3E; case '(': shift = true; return 0x46;
    case ')': shift = true; return 0x45; case '"': shift = true; return 0x52; case '+': shift = true; return 0x55;
    case '$': shift = true; return 0x25; case '<': shift = true; return 0x41; case '>': shift = true; return 0x49;
  }
  return -1;
}
static void expand_paste(const PasteReq& p, uint64_t base) {
  const uint64_t ms = CLK_HZ / 1000; uint64_t t = base;
  std::string txt; for (size_t i = 0; i < p.text.size(); i++) {
    if (p.text[i] == '\\' && i + 1 < p.text.size() && p.text[i + 1] == 'n') { txt += '\n'; i++; } else txt += p.text[i]; }
  for (char ch : txt) { bool sh; int c = ps2_code(ch, sh); if (c < 0) continue;
    if (sh) { ps2_evs.push_back({t, 0x12, true}); t += 5 * ms; }
    ps2_evs.push_back({t, c, true}); t += p.hold_ms * ms;
    ps2_evs.push_back({t, c, false}); t += 2 * ms;
    if (sh) { ps2_evs.push_back({t, 0x12, false}); }
    t += p.gap_ms * ms; }
}

static void tick() {
  while (ps2_i < ps2_evs.size() && ps2_evs[ps2_i].cycle <= cycles) {
    const Ps2Ev& e = ps2_evs[ps2_i++]; ps2_toggle ^= 1;
    top->ps2_key = (e.code & 0x1FF) | (e.down << 9) | (ps2_toggle << 10); }
  top->clk = 0; top->eval();
  top->clk = 1; top->eval();
  cycles++;
}

static void download(int index, const std::vector<uint8_t>& d) {
  top->dl_busy = 1; top->dl_index = index; tick(); tick();
  for (size_t i = 0; i < d.size(); i++) {
    top->dl_wr = 1; top->dl_index = index; top->dl_addr = i; top->dl_data = d[i];
    tick();
  }
  top->dl_wr = 0; tick();
  top->dl_busy = 0; tick(); tick();
}


// ---------------------------------------------------------------- SD card (hps_io shape)
// One emulated hps_io virtual disk: polls the core's rd/wr, then streams a
// 512-byte block through sd_buff_* with ack held, one byte every 4 clocks.
struct SdDev {
  std::vector<uint8_t> img;
  int state = 0, cnt = 0, addr = 0; uint32_t lba = 0; bool is_wr = false;
  uint64_t reads = 0, writes = 0;
  // accessors bound to the core's port names
  std::function<bool()> rd, wr; std::function<uint32_t()> lba_in; std::function<uint8_t()> din;
  std::function<void(int)> ack; std::function<void(int)> baddr; std::function<void(int)> bdout; std::function<void(int)> bwr;
  void step() {
    bwr(0);
    switch (state) {
      case 0: if (rd() || wr()) { is_wr = wr(); lba = lba_in(); cnt = 40; state = 1; (is_wr ? writes : reads)++; } break;
      case 1: if (--cnt == 0) { ack(1); addr = 0; cnt = 0; state = 2; } break;
      case 2: {
        if (++cnt < 4) { if (is_wr && cnt == 1) baddr(addr); break; }
        cnt = 0; size_t off = (size_t)lba * 512 + addr;
        if (is_wr) { if (off < img.size()) img[off] = din(); }
        else { baddr(addr); bdout(off < img.size() ? img[off] : 0); bwr(1); }
        if (++addr == 512) { state = 3; cnt = 8; }
        break;
      }
      case 3: if (--cnt == 0) { ack(0); state = 4; cnt = 8; } break;
      case 4: if (--cnt == 0) state = 0; break;
    }
  }
};
static SdDev disk, recdev, prndev;
static std::vector<uint8_t>& disk_img = disk.img;
static void sd_bind() {
  disk.rd = [] { return (bool)top->sd_rd; };  disk.wr = [] { return (bool)top->sd_wr; };
  disk.lba_in = [] { return (uint32_t)top->sd_lba; }; disk.din = [] { return (uint8_t)top->sd_buff_din; };
  disk.ack = [](int v) { top->sd_ack = v; }; disk.baddr = [](int v) { top->sd_buff_addr = v; };
  disk.bdout = [](int v) { top->sd_buff_dout = v; }; disk.bwr = [](int v) { top->sd_buff_wr = v; };
  recdev.rd = [] { return false; }; recdev.wr = [] { return (bool)top->rec_sd_wr; };
  recdev.lba_in = [] { return (uint32_t)top->rec_sd_lba; }; recdev.din = [] { return (uint8_t)top->rec_sd_buff_din; };
  recdev.ack = [](int v) { top->rec_sd_ack = v; }; recdev.baddr = [](int v) { top->rec_sd_buff_addr = v; };
  recdev.bdout = [](int) {}; recdev.bwr = [](int) {};
  prndev.rd = [] { return false; }; prndev.wr = [] { return (bool)top->prn_sd_wr; };
  prndev.lba_in = [] { return (uint32_t)top->prn_sd_lba; }; prndev.din = [] { return (uint8_t)top->prn_sd_buff_din; };
  prndev.ack = [](int v) { top->prn_sd_ack = v; }; prndev.baddr = [](int v) { top->prn_sd_buff_addr = v; };
  prndev.bdout = [](int) {}; prndev.bwr = [](int) {};
}

// ---------------------------------------------------------------- RS-232 (the other end of the 8251)
// A software UART at the SF-7000 baud rate in the --serial-fmt format: decodes
// uart_txd into ser_rx (what the SF-7000 sent), drives uart_rxd from ser_tx.
struct SimUart {
  int bits = 8, stop = 2; char par = 'E';
  uint64_t period = 0;                   // sim clocks per bit
  // receive (core -> harness)
  int rstate = 0; uint64_t rnext = 0; int ri = 0; unsigned rsr = 0;
  std::string rx; int rx_errors = 0; bool prev = true;
  // transmit (harness -> core)
  std::string tx; size_t ti = 0; int tstate = 0; uint64_t tnext = 0; int tb = 0; unsigned tframe = 0; int tlen = 0;
  bool line = true;
  void setup() {
    bits = ser_fmt[0] - '0'; par = ser_fmt.size() > 1 ? ser_fmt[1] : 'N'; stop = ser_fmt.size() > 2 ? ser_fmt[2] - '0' : 1;
    period = CLK_HZ / (9600 >> baud_sel);
  }
  int parity(unsigned d) { int p = __builtin_popcount(d & ((1u << bits) - 1)) & 1; return par == 'E' ? p : !p; }
  void step(uint64_t now, bool txd) {
    // decode
    if (rstate == 0) { if (prev && !txd) { rstate = 1; rnext = now + period * 3 / 2; ri = 0; rsr = 0; } }
    else if (now >= rnext) {
      int nb = bits + (par != 'N');
      if (ri < nb) { rsr |= (unsigned)txd << ri; ri++; rnext += period; }
      else {
        if (!txd) rx_errors++;                                       // framing
        if (par != 'N' && ((rsr >> bits) & 1) != (unsigned)parity(rsr)) rx_errors++;
        rx += char(rsr & ((1u << bits) - 1)); rstate = 0;
      }
    }
    prev = txd;
    // send
    if (tstate == 0) {
      if (ti < tx.size()) {
        unsigned d = (uint8_t)tx[ti++]; tframe = 0; int n = 0;
        tframe |= 0u << n++;                                         // start
        for (int i = 0; i < bits; i++) tframe |= ((d >> i) & 1u) << n++;
        if (par != 'N') tframe |= (unsigned)parity(d) << n++;
        for (int i = 0; i < stop; i++) tframe |= 1u << n++;
        tlen = n; tb = 0; tstate = 1; tnext = now;
      }
    } else if (now >= tnext) {
      if (tb == tlen) { tstate = 0; line = true; }
      else { line = (tframe >> tb) & 1; tb++; tnext = now + period; }
    }
  }
};
static SimUart uart;

// ---------------------------------------------------------------- VDP state
static int vdp_reg(int n) {
  return top->rootp->sc3000_sim->machine__DOT__vdp__DOT__cpu_io_b__DOT__ctrl_reg_q[n];
}
static uint8_t vram(int a) { return top->rootp->sc3000_sim->vram[a & 0x3FFF]; }

static std::string screen_text() {
  int r1 = vdp_reg(1), r2 = vdp_reg(2);
  int cols = (r1 & 0x10) ? 40 : 32, base = (r2 & 0x0F) * 0x400;
  std::string all;
  for (int y = 0; y < 24; y++) {
    std::string line;
    for (int x = 0; x < cols; x++) {
      uint8_t c = vram(base + y * cols + x);
      line += (c >= 0x20 && c < 0x7F) ? char(c) : '.';
    }
    while (!line.empty() && (line.back() == ' ' || line.back() == '.')) line.pop_back();
    all += line + "\n";
  }
  return all;
}
static void print_text(int f) {
  printf("--- screen at frame %d (R1=%02X R2=%02X) ---\n", f, vdp_reg(1), vdp_reg(2));
  std::string t = screen_text(); size_t p = 0;
  while (p < t.size()) { size_t q = t.find('\n', p); printf("|%s\n", t.substr(p, q - p).c_str()); p = q + 1; }
  fflush(stdout);
}
static void dump_vdp(const std::string& path) {
  // ColecoAdam .vdp layout: 8 registers + 16 KB VRAM (vdpref.py reads it)
  FILE* f = fopen(path.c_str(), "wb"); if (!f) return;
  for (int i = 0; i < 8; i++) fputc(vdp_reg(i), f);
  for (int i = 0; i < 16384; i++) fputc(vram(i), f);
  fclose(f);
}

// ---------------------------------------------------------------- CPU trace (MAME debugger format)
// mame sc3000 -cart X -debug -debugscript trace.cmd, with
//   trace sim.tr,maincpu,noloop,{tracelog "AF=%04X BC=%04X DE=%04X HL=%04X IX=%04X IY=%04X SP=%04X ",af,bc,de,hl,ix,iy,sp}
static FILE* trace_f = nullptr;
static uint32_t reg_bits(int lo, int n) {
  uint32_t v = 0;
  for (int i = 0; i < n; i++) { int b = lo + i; if ((top->cpu_reg[b >> 5] >> (b & 31)) & 1) v |= 1u << i; }
  return v;
}
static bool prefix_pending = false;
static uint64_t trace_lines = 0;
static uint8_t last_fetch = 0;
static void trace_fetch(uint16_t pc, uint8_t op) {
  bool cont = prefix_pending;
  prefix_pending = !cont && (op == 0xCB || op == 0xDD || op == 0xED || op == 0xFD);
  if (op == 0xCB && cont) prefix_pending = false;
  if ((last_fetch == 0xDD || last_fetch == 0xFD) && op == 0xCB) prefix_pending = false;
  last_fetch = op;
  if (cont || !trace_f || frame < trace_from || frame > trace_to) return;
#ifndef SIM_TV80
  uint32_t A = reg_bits(0, 8), F = reg_bits(8, 8), SP = reg_bits(48, 16);
  uint32_t BC = reg_bits(80, 16), DE = reg_bits(96, 16), HL = reg_bits(112, 16), IX = reg_bits(128, 16), IY = reg_bits(192, 16);
  fprintf(trace_f, "AF=%04X BC=%04X DE=%04X HL=%04X IX=%04X IY=%04X SP=%04X %04X: ; %02X\n",
          (A << 8) | F, BC, DE, HL, IX, IY, SP, pc, op);
#else
  fprintf(trace_f, "%04X: ; %02X\n", pc, op);
#endif
  trace_lines++;
}

// ---------------------------------------------------------------- WAV
static FILE* wav = nullptr; static uint32_t wav_samples = 0;
static void wav_close() {
  if (!wav) return;
  uint32_t rate = 44100, bytes = wav_samples * 2;
  fseek(wav, 0, SEEK_SET);
  auto w32 = [](uint32_t v) { fwrite(&v, 4, 1, wav); };
  auto w16 = [](uint16_t v) { fwrite(&v, 2, 1, wav); };
  fwrite("RIFF", 1, 4, wav); w32(36 + bytes); fwrite("WAVEfmt ", 1, 8, wav);
  w32(16); w16(1); w16(1); w32(rate); w32(rate * 2); w16(2); w16(16);
  fwrite("data", 1, 4, wav); w32(bytes); fclose(wav);
}

// ---------------------------------------------------------------- usage
static void usage() {
  puts("Vsc3000_sim options:\n"
       "  --cart FILE             cartridge image (.sg .sc .bin .rom)\n"
       "  --mapper NAME           auto (default), rom, level3, castle, othello\n"
       "                          terebi, dahjee_a, dahjee_b, music, multicart, megacart\n"
       "  --sf7000 IPL            attach the SF-7000 with this IPL ROM (ipl.rom, 8 KB)\n"
       "  --disk FILE             .sf7 disk image in the SF-7000 drive (writes stay in memory)\n"
       "  --disk-out FILE         write the disk image back to FILE at the end\n"
       "  --swap FILE@F           put another .sf7 in the drive at frame F (with --disk-out, the one\n"
       "                          taken out is written to OUT.fF); 'blank' = 160 KB of E5,\n"
       "                          '-' = eject\n"
       "  --rec FILE[:SIZE]       Tape save: record into a blank SIZE-byte .bit (spaces), written to FILE at the end\n"
       "  --printer FILE[:SIZE]   SF-7000 printer: a blank SIZE-byte file (spaces) mounted, the printed bytes to FILE\n"
       "  --baud N                SF-7000 baud jumper - 1: 0 = 9600 (default) ... 5 = 300\n"
       "  --serial-fmt 8E2        format of the harness end of the RS-232 line (default 8E2, BASIC's default)\n"
       "  --serial-in 'TEXT@F'    send TEXT (\\n = CR LF, \\r = CR, \\x1a = EOF) to the SF-7000 RS-232 from frame F\n"
       "  --serial-in-file FILE@F send the bytes of FILE from frame F\n"
       "  --serial-out FILE       what the SF-7000 sent on RS-232 (also printed at the end)\n"
       "  --tape FILE             tape image (.wav, MAME .bit); plays while the program polls PB7\n"
       "  --turbo                 OSD Tape speed = 4x (full-rate build only: make full)\n"
       "  --tape-log              log the virtual motor (play/stop) with the tape position\n"
       "  --sg1000                SG-1000 model (1 KB RAM, SG-1000 I/O map, no keyboard)\n"
       "  --omv BIOS              Othello Multivision FG-2000 with this BIOS (omvbios.bin, 16 KB)\n"
       "  --pad KEYS@FRAME[:N]    OMV keypad: KEYS from 1-9 0 A-H (# = 9, * = 0), held N frames (3)\n"
       "  --paste 'TEXT@F[:HOLD:GAP]' type TEXT through rtl/sc3000_keyboard.sv (PS/2 events, PC layout),\n"
       "                          each key held HOLD ms, GAP ms between keys (default 30:50, KVMS paste)\n"
       "  --pal / --border        TMS9929A timing / VDP border on\n"
       "  --frames N              stop after N frames (required)\n"
       "  --png FILE              write the last frame to FILE\n"
       "  --shots F1,F2,..        write OUTDIR/frame_NNNNN.png at these frames\n"
       "  --every K               a shot every K frames\n"
       "  --outdir DIR            (default ./out)\n"
       "  --type 'TEXT@FRAME'     type TEXT from FRAME (\\n = CR), 6 frames per key, 30 after CR\n"
       "  --key NAME@FRAME[:N]    hold a key N frames (enter space home del ins up down left right\n"
       "                          func break graph ctrl shift eng pi yen)\n"
       "  --joy BITS@FRAME[:N][/2] joystick: BITS from 'udlrab' (a = TL, b = TR)\n"
       "  --pen X,Y@FRAME[:N]     Terebi Oekaki: pen to X,Y (0-255, 0-191), down for N frames\n"
       "  --nmi FRAME[:N]         press RESET (SC-3000) / PAUSE (SG-1000): Z80 NMI\n"
       "  --text F1,F2,..         print the name table as text at these frames\n"
       "  --text-end              print it at the end\n"
       "  --until 'TEXT'          stop when TEXT is on screen (checked every 10 frames)\n"
       "  --trace FILE[:F1[:F2]]  Z80 trace in MAME tracelog format, frames F1..F2\n"
       "  --peek ADDR:N@FRAME     print N bytes of SF-7000 RAM (hex ADDR) at FRAME\n"
       "  --vdp FILE              dump 8 VDP registers + 16 KB VRAM at the end (.vdp)\n"
       "  --io-log                log I/O writes (frame, port, data)\n"
       "  --profile N             sample the PC every N cycles, print the busiest at exit\n"
       "  --wav FILE              audio as 44.1 kHz mono WAV\n");
}

static std::pair<std::string, int> split_at(const std::string& s) {
  size_t p = s.rfind('@');
  if (p == std::string::npos) { fprintf(stderr, "missing @FRAME in '%s'\n", s.c_str()); exit(3); }
  return {s.substr(0, p), atoi(s.c_str() + p + 1)};
}
static void parse_list(const char* s, std::set<int>& out) {
  std::string t(s); size_t p = 0;
  while (p < t.size()) { size_t q = t.find(',', p); if (q == std::string::npos) q = t.size();
    out.insert(atoi(t.substr(p, q - p).c_str())); p = q + 1; }
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto next = [&]() -> const char* { if (i + 1 >= argc) { fprintf(stderr, "%s needs a value\n", a.c_str()); exit(3); } return argv[++i]; };
    if (a == "--help" || a == "-h") { usage(); return 0; }
    else if (a == "--cart") cart_path = next();
    else if (a == "--mapper") {
      std::string m = next();
      mapper = m == "auto" ? 15 : m == "rom" ? 0 : m == "level3" ? 1 : m == "castle" ? 2 : m == "othello" ? 3 :
               m == "terebi" ? 4 : m == "dahjee_a" ? 5 : m == "dahjee_b" ? 6 : m == "music" ? 7 :
               m == "multicart" ? 8 : m == "megacart" ? 9 : -2;
      if (mapper == -2) { fprintf(stderr, "unknown mapper %s\n", m.c_str()); return 3; }
    }
    else if (a == "--tape") tape_path = next();
    else if (a == "--sf7000") ipl_path = next();
    else if (a == "--disk") disk_path = next();
    else if (a == "--disk-out") disk_out = next();
    else if (a == "--rec") { std::string v = next(); size_t c = v.rfind(':');
      if (c != std::string::npos) { rec_size = strtoul(v.c_str() + c + 1, 0, 0); v = v.substr(0, c); } rec_path = v; }
    else if (a == "--tape-log") tape_log = true;
    else if (a == "--turbo") {
#ifndef SIM_FULL
      fprintf(stderr, "--turbo needs the full-rate build (make full, obj_full/Vsc3000_sim)\n"); return 3;
#endif
      tape_turbo = true;
    }
    else if (a == "--printer") { std::string v = next(); size_t c = v.rfind(':');
      if (c != std::string::npos) { prn_size = strtoul(v.c_str() + c + 1, 0, 0); v = v.substr(0, c); } prn_path = v; }
    else if (a == "--baud") baud_sel = atoi(next());
    else if (a == "--swap") { std::string v = next(); size_t at = v.rfind('@');
      if (at == std::string::npos) { fprintf(stderr, "missing @FRAME in '%s'\n", v.c_str()); return 3; }
      swaps.push_back({atoi(v.c_str() + at + 1), v.substr(0, at)}); }
    else if (a == "--serial-fmt") ser_fmt = next();
    else if (a == "--serial-out") ser_out_path = next();
    else if (a == "--serial-in" || a == "--serial-in-file") {
      std::string v = next(); size_t at = v.rfind('@');
      if (at == std::string::npos) { fprintf(stderr, "missing @FRAME in '%s'\n", v.c_str()); return 3; }
      std::string t = v.substr(0, at), d;
      if (a == "--serial-in-file") { auto b = read_file(t); d.assign(b.begin(), b.end()); }
      else for (size_t i = 0; i < t.size(); i++) {
        if (t[i] == '\\' && i + 1 < t.size()) {
          char n = t[++i];
          if (n == 'n') d += "\r\n"; else if (n == 'r') d += '\r';
          else if (n == 'x' && i + 2 < t.size()) { d += char(strtoul(t.substr(i + 1, 2).c_str(), 0, 16)); i += 2; }
          else d += n;
        } else d += t[i];
      }
      ser_in.push_back({atoi(v.c_str() + at + 1), d}); }
    else if (a == "--sg1000") model_sg1000 = true;
    else if (a == "--pal") pal = true;
    else if (a == "--border") border = true;
    else if (a == "--frames") run_frames = atoi(next());
    else if (a == "--png") png_path = next();
    else if (a == "--shots") parse_list(next(), shots);
    else if (a == "--every") every = atoi(next());
    else if (a == "--outdir") outdir = next();
    else if (a == "--type") { auto p = split_at(next()); schedule_text(p.second, p.first); }
    else if (a == "--key") {
      std::string s = next(); int len = 3; size_t c = s.find(':');
      if (c != std::string::npos) { len = atoi(s.c_str() + c + 1); s = s.substr(0, c); }
      auto p = split_at(s); auto it = named_keys.find(p.first);
      if (it == named_keys.end()) { fprintf(stderr, "unknown key %s\n", p.first.c_str()); return 3; }
      key_evs.push_back({p.second, it->second, true});
      key_evs.push_back({p.second + len, it->second, false});
    }
    else if (a == "--joy") {
      std::string s = next(); int port = 0, len = 3;
      if (s.size() > 2 && s.substr(s.size() - 2) == "/2") { port = 1; s = s.substr(0, s.size() - 2); }
      size_t c = s.find(':'); if (c != std::string::npos) { len = atoi(s.c_str() + c + 1); s = s.substr(0, c); }
      auto p = split_at(s); uint8_t bits = 0;
      for (char ch : p.first) bits |= ch == 'u' ? 1 : ch == 'd' ? 2 : ch == 'l' ? 4 : ch == 'r' ? 8 : ch == 'a' ? 16 : ch == 'b' ? 32 : 0;
      joy_evs.push_back({p.second, len, port, bits});
    }
    else if (a == "--pen") {   // X,Y@FRAME[:N]  Terebi Oekaki pen at X,Y, down for N frames
      std::string v = next(); int len = 1; size_t c = v.find(':');
      if (c != std::string::npos) { len = atoi(v.c_str() + c + 1); v = v.substr(0, c); }
      auto p = split_at(v); int x = 0, y = 0; sscanf(p.first.c_str(), "%d,%d", &x, &y);
      pen_evs.push_back({p.second, len, x, y});
    }
    else if (a == "--omv") omv_path = next();
    else if (a == "--paste") {   // 'TEXT@FRAME[:HOLD:GAP]' ms, default 30:50 (KVMS)
      std::string v = next(); int hold = 30, gap = 50; size_t at = v.rfind('@');
      std::string tail = v.substr(at + 1); int f = atoi(tail.c_str());
      size_t c1 = tail.find(':'); if (c1 != std::string::npos) { hold = atoi(tail.c_str() + c1 + 1);
        size_t c2 = tail.find(':', c1 + 1); if (c2 != std::string::npos) gap = atoi(tail.c_str() + c2 + 1); }
      paste_reqs.push_back({f, v.substr(0, at), hold, gap}); }
    else if (a == "--pad") {
      std::string v = next(); int len = 3; size_t c = v.rfind(':');
      if (c != std::string::npos && c > v.rfind('@')) { len = atoi(v.c_str() + c + 1); v = v.substr(0, c); }
      auto p = split_at(v); uint32_t bits = 0;
      for (char ch : p.first) {
        if (ch >= '1' && ch <= '9') bits |= 1u << (ch - '1');
        else if (ch == '0' || ch == '*') bits |= 1u << 9;
        else if (ch == '#') bits |= 1u << 8;
        else if (ch >= 'A' && ch <= 'H') bits |= 1u << (10 + ch - 'A');
      }
      pad_evs.push_back({p.second, len, bits});
    }
    else if (a == "--nmi") {
      std::string s = next(); int len = 3; size_t c = s.find(':');
      if (c != std::string::npos) { len = atoi(s.c_str() + c + 1); s = s.substr(0, c); }
      nmi_evs.push_back({atoi(s.c_str()), len});
    }
    else if (a == "--text") parse_list(next(), text_frames);
    else if (a == "--text-end") text_at_end = true;
    else if (a == "--until") stop_text = next();
    else if (a == "--trace") {
      std::string s = next(); size_t c = s.find(':');
      if (c != std::string::npos) {
        std::string r = s.substr(c + 1); s = s.substr(0, c);
        size_t d = r.find(':'); trace_from = atoi(r.c_str());
        if (d != std::string::npos) trace_to = atoi(r.c_str() + d + 1);
      }
      trace_path = s;
    }
    else if (a == "--peek") {   // ADDR:N@FRAME, SF-7000 RAM
      auto p = split_at(next()); unsigned ad = 0, n = 16; sscanf(p.first.c_str(), "%x:%u", &ad, &n);
      peeks.push_back({p.second, ad, n});
    }
    else if (a == "--vdp") vdp_dump_path = next();
    else if (a == "--io-log") io_log = true;
    else if (a == "--profile") profile_every = atoll(next());
    else if (a == "--wav") wav_path = next();
    else { fprintf(stderr, "unknown option %s\n", a.c_str()); usage(); return 3; }
  }
  if (run_frames <= 0) { fprintf(stderr, "--frames N is required\n"); return 3; }
  for (size_t p = 1; p <= outdir.size(); p++)   // mkdir -p
    if (p == outdir.size() || outdir[p] == '/') mkdir(outdir.substr(0, p).c_str(), 0755);
  std::stable_sort(key_evs.begin(), key_evs.end(), [](const KeyEv& x, const KeyEv& y) { return x.frame < y.frame; });

  top = new Vsc3000_sim;
  sd_bind();
  top->rec_img_mounted = 0; top->rec_sd_ack = 0;
  top->prn_img_mounted = 0; top->prn_sd_ack = 0; top->baud = baud_sel; top->uart_rxd = 1;
  uart.setup();
  top->use_ps2 = !paste_reqs.empty(); top->ps2_key = 0;
  top->model_sg1000 = model_sg1000; top->model_omv = !omv_path.empty(); top->omv_keys = 0; top->pal = pal; top->border = border;
  top->tab_x = 128; top->tab_y = 96; top->tab_pen = 0;
  top->reset = 1; top->nmi_key = 0; top->joy1 = 0; top->joy2 = 0; top->tape_rewind = 0; top->tape_turbo = 0; top->sf7000_on = 0; top->sd_ack = 0; top->sd_buff_wr = 0; top->img_mounted = 0;
  for (int w = 0; w < 3; w++) top->key_matrix[w] = 0;
  top->mapper_osd = mapper < 0 ? 15 : mapper;
  for (int i = 0; i < 16; i++) tick();

  if (!cart_path.empty()) {
    std::vector<uint8_t> c = read_file(cart_path);
    if (c.size() > (1u << 22)) { fprintf(stderr, "cartridge larger than 4 MB\n"); return 3; }
    download(1, c);
    printf("cart: %s, %zu bytes, crc32 %08X, mapper %d%s\n", cart_path.c_str(), c.size(), (unsigned)top->cart_crc,
           (int)top->mapper, mapper < 0 ? " (detected)" : "");
  }
  if (!omv_path.empty()) {
    download(4, read_file(omv_path));
    printf("omv: BIOS %s\n", omv_path.c_str());
  }
  if (!ipl_path.empty()) {
    top->sf7000_on = 1;
    download(3, read_file(ipl_path));
    printf("sf7000: IPL %s\n", ipl_path.c_str());
  }
  top->tape_turbo = tape_turbo;
  if (!tape_path.empty()) {
    std::vector<uint8_t> t = read_file(tape_path);
    if (t.size() > (1u << 24)) { fprintf(stderr, "tape larger than 16 MB\n"); return 3; }
    download(2, t);
    printf("tape: %s, %zu bytes\n", tape_path.c_str(), t.size());
  }
  top->tape_rewind = 1; for (int i = 0; i < 8; i++) tick(); top->tape_rewind = 0;
  if (!rec_path.empty()) {
    recdev.img.assign(rec_size, ' ');
    top->rec_img_size = rec_size; top->rec_img_mounted = 1;
    for (int i = 0; i < 4; i++) tick();
    top->rec_img_mounted = 0;
    printf("tape save: blank %zu-byte .bit\n", rec_size);
  }
  if (!prn_path.empty()) {
    prndev.img.assign(prn_size, ' ');
    top->prn_img_size = prn_size; top->prn_img_mounted = 1;
    for (int i = 0; i < 4; i++) tick();
    top->prn_img_mounted = 0;
    printf("printer: blank %zu-byte file\n", prn_size);
  }
  if (!disk_path.empty()) {
    disk_img = read_file(disk_path);
    top->img_size = disk_img.size(); top->img_readonly = 0; top->img_mounted = 1;
    for (int i = 0; i < 16; i++) tick();
    top->img_mounted = 0;
    printf("disk: %s, %zu bytes\n", disk_path.c_str(), disk_img.size());
  }
  for (int i = 0; i < 64; i++) tick();
  top->reset = 0;

  if (!trace_path.empty()) { trace_f = fopen(trace_path.c_str(), "w"); if (!trace_f) { perror("trace"); return 3; } }
  if (!wav_path.empty()) { wav = fopen(wav_path.c_str(), "wb"); uint8_t h[44] = {0}; fwrite(h, 1, 44, wav); }

  size_t ki = 0;
  std::map<uint16_t, uint64_t> pc_hist;
  uint64_t wav_acc = 0;
  bool prev_io = false, prev_fetch = false;
  uint16_t fetch_pc = 0;
  int exit_code = 0;

  while (frame < run_frames) {
    tick();
    if (top->sf7000_on) disk.step();
    if (!rec_path.empty()) recdev.step();
    if (!prn_path.empty()) prndev.step();
    if (top->sf7000_on) { uart.step(cycles, top->uart_txd); top->uart_rxd = uart.line; }

    // opcode fetches: the byte is on DI when MREQ goes up at the end of T2
    bool fetch = !top->cpu_m1_n && !top->cpu_mreq_n && top->cpu_iorq_n && !top->cpu_rd_n;
    if (fetch && !prev_fetch) fetch_pc = top->cpu_a;
    static uint8_t fetch_byte = 0;
    if (fetch) fetch_byte = top->cpu_di;
    // registers are settled once the refresh half (T3/T4) of the fetch is over
    static bool fetch_done = false, prev_rfsh = false;
    if (!fetch && prev_fetch) fetch_done = true;
    bool rfsh = !top->cpu_rfsh_n;
    if (fetch_done && prev_rfsh && !rfsh) { trace_fetch(fetch_pc, fetch_byte); fetch_done = false; }
    prev_rfsh = rfsh;
    prev_fetch = fetch;

    if (top->ce_pix) {
      bool hb = top->HBlank, vb = top->VBlank;
      if (!hb && !vb) {
        if (vx < FB_W && vy < FB_H) {
          uint8_t* p = &fb[(vy * FB_W + vx) * 3]; p[0] = top->R; p[1] = top->G; p[2] = top->B;
        }
        vx++; line_had_pixels = true;
      }
      if (hb && !prev_hb) {
        if (line_had_pixels) { max_x = std::max(max_x, vx); vy++; }
        vx = 0; line_had_pixels = false;
      }
      prev_hb = hb;
    }

    bool io = !top->cpu_iorq_n && top->cpu_m1_n && !top->cpu_wr_n;
    if (io_log && io && !prev_io) printf("f%d io W %02X <- %02X\n", frame, top->cpu_a & 0xFF, top->cpu_do);
    prev_io = io;

    if (profile_every && cycles % profile_every == 0) pc_hist[fetch_pc]++;

    if (wav) { wav_acc += 44100; if (wav_acc >= CLK_HZ) { wav_acc -= CLK_HZ;
      int16_t s = int16_t(top->audio * 16); fwrite(&s, 2, 1, wav); wav_samples++; } }

    static int prev_motor = 0;
    if (tape_log && top->tape_motor != prev_motor) {
      printf("f%d tape %s%s at byte %u%s\n", frame, top->tape_motor ? "PLAY" : "STOP", top->turbo_active ? " (4x)" : "", (unsigned)top->tape_pos,
             top->tape_ended ? " (ended)" : "");
      fflush(stdout);
    }
    prev_motor = top->tape_motor;

    bool vs = top->VSync;
    if (vs && !prev_vs) {
      if (vy > 0) { last_w = std::min(max_x, FB_W); last_h = std::min(vy, FB_H); }
      vy = 0; vx = 0; max_x = 0;
      frame++;
      if (shots.count(frame) || (every && frame % every == 0)) {
        char name[64]; snprintf(name, sizeof name, "/frame_%05d.png", frame);
        save_frame(outdir + name);
      }
      if (text_frames.count(frame)) print_text(frame);
      for (auto& pk : peeks) if (pk.frame == frame) {
        printf("f%d sf7000 RAM %04X:", frame, pk.addr);
        for (unsigned i = 0; i < pk.n; i++) printf(" %02X", top->rootp->sc3000_sim->sf7000__DOT__ram[(pk.addr + i) & 0xFFFF]);
        printf("\n");
      }

      // input for the new frame
      for (auto& si : ser_in) if (si.frame == frame) uart.tx += si.data;
      for (auto& sw : swaps) if (sw.frame == frame) {
        if (!disk_out.empty()) { std::string o = disk_out + ".f" + std::to_string(frame);
          FILE* f = fopen(o.c_str(), "wb"); if (f) { fwrite(disk_img.data(), 1, disk_img.size(), f); fclose(f); } }
        if (sw.path == "-") disk_img.clear();
        else if (sw.path == "blank") disk_img.assign(40 * 16 * 256, 0xE5);
        else disk_img = read_file(sw.path);
        top->img_size = disk_img.size(); top->img_mounted = 1; tick(); tick(); top->img_mounted = 0;
        printf("f%d disk swap: %s (%zu bytes)\n", frame, sw.path.c_str(), disk_img.size());
      }
      for (auto& p : paste_reqs) if (p.frame == frame) {
        expand_paste(p, cycles);
        std::sort(ps2_evs.begin() + ps2_i, ps2_evs.end(), [](const Ps2Ev& a, const Ps2Ev& b) { return a.cycle < b.cycle; }); }
      while (ki < key_evs.size() && key_evs[ki].frame <= frame) {
        KeyEv& e = key_evs[ki++]; int bit = e.rc.row * 12 + e.rc.col;
        key_count[bit] += e.down ? 1 : -1;
        bool on = key_count[bit] > 0;
        if (on) top->key_matrix[bit >> 5] |= 1u << (bit & 31); else top->key_matrix[bit >> 5] &= ~(1u << (bit & 31));
      }
      uint8_t j1 = 0, j2 = 0;
      for (auto& e : joy_evs) if (frame >= e.frame && frame < e.frame + e.len) (e.port ? j2 : j1) |= e.bits;
      top->joy1 = j1; top->joy2 = j2;
      uint32_t pad = 0;
      for (auto& e : pad_evs) if (frame >= e.frame && frame < e.frame + e.len) pad |= e.bits;
      top->omv_keys = pad;
      bool pen = false;
      for (auto& e : pen_evs) if (frame >= e.frame) { top->tab_x = e.x; top->tab_y = e.y; if (frame < e.frame + e.len) pen = true; }
      top->tab_pen = pen;
      bool nmi = false;
      for (auto& e : nmi_evs) if (frame >= e.frame && frame < e.frame + e.len) nmi = true;
      top->nmi_key = nmi;

      if (!stop_text.empty() && frame % 10 == 0 && screen_text().find(stop_text) != std::string::npos) {
        printf("f%d found \"%s\" on screen\n", frame, stop_text.c_str()); stop_text.clear(); break;
      }
      if (frame % 500 == 0) fprintf(stderr, "frame %d\n", frame);
    }
    prev_vs = vs;
  }
  if (!stop_text.empty()) { printf("\"%s\" not found\n", stop_text.c_str()); exit_code = 2; }

  if (!png_path.empty()) save_frame(png_path);
  if (text_at_end) print_text(frame);
  if (!vdp_dump_path.empty()) dump_vdp(vdp_dump_path);
  if (!pc_hist.empty()) {
    std::vector<std::pair<uint64_t, uint16_t>> v;
    for (auto& p : pc_hist) v.push_back({p.second, p.first});
    std::sort(v.rbegin(), v.rend());
    printf("PC profile:\n");
    for (size_t i = 0; i < v.size() && i < 20; i++) printf("  %04X %llu\n", v[i].second, (unsigned long long)v[i].first);
  }
  if (top->sf7000_on) printf("sd: %llu reads, %llu writes\n", (unsigned long long)disk.reads, (unsigned long long)disk.writes);
  if (!rec_path.empty()) {
    size_t n = std::min((size_t)top->rec_length, recdev.img.size());
    FILE* f = fopen(rec_path.c_str(), "wb"); if (f) { fwrite(recdev.img.data(), 1, n, f); fclose(f); }
    printf("tape save: %zu characters, %llu sector writes -> %s\n", n, (unsigned long long)recdev.writes, rec_path.c_str());
  }
  if (!prn_path.empty()) {
    // the file as the SD card has it, cut at the bytes printed
    size_t n = std::min((size_t)top->prn_length, prndev.img.size());
    FILE* f = fopen(prn_path.c_str(), "wb"); if (f) { fwrite(prndev.img.data(), 1, n, f); fclose(f); }
    printf("printer: %zu bytes, %llu sector writes -> %s\n", n, (unsigned long long)prndev.writes, prn_path.c_str());
  }
  if (top->sf7000_on && (!uart.rx.empty() || !ser_out_path.empty() || !ser_in.empty())) {
    std::string vis;
    for (char c : uart.rx) { if (c == '\r') vis += "\\r"; else if (c == '\n') vis += "\\n"; else if ((uint8_t)c < 32 || (uint8_t)c > 126) { char b[8]; snprintf(b, 8, "\\x%02X", (uint8_t)c); vis += b; } else vis += c; }
    printf("serial out: %zu bytes, %d errors: %s\n", uart.rx.size(), uart.rx_errors, vis.c_str());
    printf("serial in: %zu of %zu bytes sent\n", uart.ti, uart.tx.size());
    if (!ser_out_path.empty()) { FILE* f = fopen(ser_out_path.c_str(), "wb"); if (f) { fwrite(uart.rx.data(), 1, uart.rx.size(), f); fclose(f); } }
  }
  if (!disk_out.empty()) { FILE* f = fopen(disk_out.c_str(), "wb"); if (f) { fwrite(disk_img.data(), 1, disk_img.size(), f); fclose(f); } }
  if (trace_f) { fclose(trace_f); printf("trace: %llu instructions -> %s\n", (unsigned long long)trace_lines, trace_path.c_str()); }
  printf("done: %d frames, %llu cycles, last frame %dx%d\n", frame, (unsigned long long)cycles, last_w, last_h);
  wav_close();
  delete top;
  return exit_code;
}
