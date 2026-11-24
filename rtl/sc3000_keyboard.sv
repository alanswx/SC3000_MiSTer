//-----------------------------------------------------------------------------
// SC-3000 / SK-1100 keyboard: PS/2 (hps_io ps2_key) -> 7 x 12 matrix, active low.
//
// Matrix = MAME sk1100.cpp: row = PPI PC2:0, bits 0-7 = PA0-7, 8-11 = PB0-3.
// Key positions after SMS_MiSTer rtl/keyboard.sv (commit bb77fbd, GPL-2+).
//
// Two layouts (P3 Input "Keyboard"):
//   PC (pc_layout = 1, default): keys type what is printed on a US PC keyboard.
//     Symbols that sit elsewhere on the SC-3000 are moved there with the SC
//     Shift set as that character needs ('=' = Shift + '-', ':' = the ':' key,
//     '*' = Shift + ':' ...). Letters swap Shift: on the SC-3000 a plain letter
//     is a capital and Shift gives lower case, so PC 'A' (Shift+a) types 'A'.
//   SC-3000 (pc_layout = 0): by position, as the real keyboard.
//
// Changes to the matrix go through a queue (1024 changes = 512 characters, a
// pasted program; block RAM; when it is full a key is dropped whole, press and
// release). Each change stays until the machine has read it: at least GAP
// (40 ms) and two full scans of rows 0-6 on the PPI (row_sel), so a key is never
// missed however long BASIC is busy (storing a long line after RETURN it scans
// nothing for 400 ms and more). A program that reads only some rows gets the
// next change after 4 x GAP of row activity; one that reads none, after 2 s.
//-----------------------------------------------------------------------------

module sc3000_keyboard #(
  parameter CLK_HZ = 42954545
) (
  input         clk_sys,
  input         reset,
  input         pc_layout,
  input  [2:0]  row_sel,
  input  [10:0] ps2_key,
  output [11:0] row_data
);

  localparam int GAP = CLK_HZ / 25;   // 40 ms

  // ---------------------------------------------------------------- PS/2 -> SC position
  // pos = {row[2:0], col[3:0]}, 7'h7F = no key. sh: 0 = use the PC Shift, 2 = SC Shift off, 3 = on
  wire       key_event_raw = ps2_key[10];
  reg        stb_q = 1'b0;
  wire       ev    = stb_q ^ key_event_raw;
  wire [8:0] code  = ps2_key[8:0];
  wire       down  = ps2_key[9];

  reg lshift = 1'b0, rshift = 1'b0;
  wire pc_shift = lshift | rshift;

  function automatic [6:0] base_pos(input [8:0] c);
    case (c)
      9'h016: base_pos = {3'd0, 4'd0};   9'h015: base_pos = {3'd0, 4'd1};   9'h01C: base_pos = {3'd0, 4'd2};
      9'h01A: base_pos = {3'd0, 4'd3};   9'h058: base_pos = {3'd0, 4'd4};   9'h041: base_pos = {3'd0, 4'd5};
      9'h042: base_pos = {3'd0, 4'd6};   9'h043: base_pos = {3'd0, 4'd7};   9'h03E: base_pos = {3'd0, 4'd8};
      9'h01E: base_pos = {3'd1, 4'd0};   9'h01D: base_pos = {3'd1, 4'd1};   9'h01B: base_pos = {3'd1, 4'd2};
      9'h022: base_pos = {3'd1, 4'd3};   9'h029: base_pos = {3'd1, 4'd4};   9'h049: base_pos = {3'd1, 4'd5};
      9'h04B: base_pos = {3'd1, 4'd6};   9'h044: base_pos = {3'd1, 4'd7};   9'h046: base_pos = {3'd1, 4'd8};
      9'h026: base_pos = {3'd2, 4'd0};   9'h024: base_pos = {3'd2, 4'd1};   9'h023: base_pos = {3'd2, 4'd2};
      9'h021: base_pos = {3'd2, 4'd3};   9'h066: base_pos = {3'd2, 4'd4};   9'h16C: base_pos = {3'd2, 4'd4};
      9'h04A: base_pos = {3'd2, 4'd5};   9'h04C: base_pos = {3'd2, 4'd6};   9'h04D: base_pos = {3'd2, 4'd7};
      9'h045: base_pos = {3'd2, 4'd8};
      9'h025: base_pos = {3'd3, 4'd0};   9'h02D: base_pos = {3'd3, 4'd1};   9'h02B: base_pos = {3'd3, 4'd2};
      9'h02A: base_pos = {3'd3, 4'd3};   9'h170: base_pos = {3'd3, 4'd4};   9'h171: base_pos = {3'd3, 4'd4};
      9'h061: base_pos = {3'd3, 4'd5};   9'h00B: base_pos = {3'd3, 4'd5};   9'h052: base_pos = {3'd3, 4'd6};
      9'h054: base_pos = {3'd3, 4'd7};   9'h04E: base_pos = {3'd3, 4'd8};
      9'h02E: base_pos = {3'd4, 4'd0};   9'h02C: base_pos = {3'd4, 4'd1};   9'h034: base_pos = {3'd4, 4'd2};
      9'h032: base_pos = {3'd4, 4'd3};   9'h172: base_pos = {3'd4, 4'd5};   9'h05D: base_pos = {3'd4, 4'd6};
      9'h05B: base_pos = {3'd4, 4'd7};   9'h055: base_pos = {3'd4, 4'd8};
      9'h036: base_pos = {3'd5, 4'd0};   9'h035: base_pos = {3'd5, 4'd1};   9'h033: base_pos = {3'd5, 4'd2};
      9'h031: base_pos = {3'd5, 4'd3};   9'h16B: base_pos = {3'd5, 4'd5};   9'h05A: base_pos = {3'd5, 4'd6};
      9'h15A: base_pos = {3'd5, 4'd6};   9'h00E: base_pos = {3'd5, 4'd8};   9'h00D: base_pos = {3'd5, 4'd11};
      9'h005: base_pos = {3'd5, 4'd11};
      9'h03D: base_pos = {3'd6, 4'd0};   9'h03C: base_pos = {3'd6, 4'd1};   9'h03B: base_pos = {3'd6, 4'd2};
      9'h03A: base_pos = {3'd6, 4'd3};   9'h174: base_pos = {3'd6, 4'd5};   9'h175: base_pos = {3'd6, 4'd6};
      9'h076: base_pos = {3'd6, 4'd8};   9'h177: base_pos = {3'd6, 4'd8};   9'h011: base_pos = {3'd6, 4'd9};
      9'h111: base_pos = {3'd6, 4'd9};   9'h014: base_pos = {3'd6, 4'd10};  9'h114: base_pos = {3'd6, 4'd10};
      default: base_pos = 7'h7F;
    endcase
  endfunction

  function automatic is_letter(input [8:0] c);
    case (c)
      9'h015, 9'h01C, 9'h01A, 9'h042, 9'h043, 9'h01D, 9'h01B, 9'h022, 9'h04B, 9'h044,
      9'h024, 9'h023, 9'h021, 9'h04D, 9'h02D, 9'h02B, 9'h02A, 9'h02C, 9'h034, 9'h032,
      9'h035, 9'h033, 9'h031, 9'h03C, 9'h03B, 9'h03A: is_letter = 1'b1;
      default: is_letter = 1'b0;
    endcase
  endfunction

  // PC layout: {pos, sh} for a key with the PC Shift state s
  function automatic [8:0] pc_map(input [8:0] c, input s);
    reg [6:0] p;
    begin
      p = base_pos(c);
      pc_map = {p, 2'd0};
      if (is_letter(c)) pc_map = {p, 1'b1, ~s};
      else case (c)
        9'h04E: pc_map = s ? {7'h7F, 2'd0}        : {3'd3, 4'd8, 2'd2};  // - (_ has no key)
        9'h055: pc_map = s ? {3'd2, 4'd6, 2'd3}   : {3'd3, 4'd8, 2'd3};  // + = Sh ;   = = Sh -
        9'h054: pc_map = {3'd4, 4'd7, 1'b1, s};                          // [ {
        9'h05B: pc_map = {3'd4, 4'd6, 1'b1, s};                          // ] }
        9'h05D: pc_map = {3'd5, 4'd8, 1'b1, s};                          // \ = yen, | = Sh yen
        9'h04C: pc_map = s ? {3'd3, 4'd6, 2'd2}   : {3'd2, 4'd6, 2'd2};  // : ;
        9'h052: pc_map = s ? {3'd1, 4'd0, 2'd3}   : {3'd6, 4'd0, 2'd3};  // " = Sh 2   ' = Sh 7
        9'h00E: pc_map = s ? {3'd4, 4'd8, 2'd3}   : {3'd3, 4'd7, 2'd3};  // ~ = Sh ^   ` = Sh @
        9'h01E: if (s) pc_map = {3'd3, 4'd7, 2'd2};                      // @
        9'h036: if (s) pc_map = {3'd4, 4'd8, 2'd2};                      // ^
        9'h03D: if (s) pc_map = {3'd5, 4'd0, 2'd3};                      // & = Sh 6
        9'h03E: if (s) pc_map = {3'd3, 4'd6, 2'd3};                      // * = Sh :
        9'h046: if (s) pc_map = {3'd0, 4'd8, 2'd3};                      // ( = Sh 8
        9'h045: if (s) pc_map = {3'd1, 4'd8, 2'd3};                      // ) = Sh 9
        default: ;
      endcase
    end
  endfunction

  // ---------------------------------------------------------------- queue of matrix changes
  // entry = {press, pos[6:0], sh[1:0]}
  reg [9:0] q [0:1023];
  reg [9:0] wp = 0, rp = 0;
  wire      q_empty = wp == rp;
  wire      q_full  = (wp + 10'd1) == rp;
  wire      q_room2 = (wp + 10'd2) != rp && !q_full;   // a press and its release fit

  // position each key was pressed at (so its release clears the same one)
  reg [6:0] held_pos [0:511];
  reg [6:0] rel_pos;
  reg       rel_pending = 1'b0;
  wire [8:0] map_now = pc_layout ? pc_map(code, pc_shift) : {base_pos(code), 2'd0};
  wire       push_press = ev && !reset && code != 9'h012 && code != 9'h059 && down &&
                          map_now[8:2] != 7'h7F && q_room2;
  wire       push_rel   = rel_pending && !reset && !q_full && rel_pos != 7'h7F;
  wire       q_we = push_press | push_rel;          // never both: PS/2 events are far apart
  // a key that follows the PC Shift takes it as it is now, not when the queue
  // gets to it (KVMS / paste: Shift goes down for the next capital meanwhile)
  wire [1:0] sh_now = (map_now[1:0] == 2'd0) ? {1'b1, pc_shift} : map_now[1:0];
  wire [9:0] q_wd = push_rel ? {1'b0, rel_pos, 2'd0} : {1'b1, map_now[8:2], sh_now};

  always @(posedge clk_sys) begin
    rel_pending <= 1'b0;
    if (reset) begin
      stb_q <= key_event_raw; lshift <= 1'b0; rshift <= 1'b0; wp <= 0;
    end else begin
      stb_q <= key_event_raw;
      if (ev) begin
        if (code == 9'h012) lshift <= down;
        else if (code == 9'h059) rshift <= down;
        else if (down) begin
          if (push_press)
            held_pos[code] <= map_now[8:2];
          else
            held_pos[code] <= 7'h7F;          // dropped: drop its release too
        end else begin
          rel_pos <= held_pos[code];
          rel_pending <= 1'b1;
        end
      end
      if (q_we) wp <= wp + 10'd1;
    end
  end

  // the queue's one write port (block RAM)
  always @(posedge clk_sys) if (q_we) q[wp] <= q_wd;

  // ---------------------------------------------------------------- apply, one change per GAP
  reg [11:0] mat [0:6];          // 1 = pressed
  reg [31:0] t = 0;
  reg [1:0]  shf = 2'd0;       // SC Shift forced by the last printable key: 2 = off, 3 = on
  reg [6:0]  shf_pos = 7'h7F;
  // registered read (block RAM): e is q[rp] one clock later; an entry is taken
  // only once it has been in the queue for a clock (q_ne) and t has run out
  reg  [9:0] e;
  reg        q_ne = 1'b0;
  always @(posedge clk_sys) e <= q[rp];

  // has the machine read the matrix since the last change?
  localparam int PART = GAP * 4;      // some rows scanned, never all: 160 ms
  localparam int IDLE = GAP * 50;     // no scanning at all: 2 s
  reg  [2:0] row_q = 3'd0;
  reg  [6:0] seen = 7'd0;
  reg  [1:0] full = 2'd0;            // full scans since the last change (saturates at 2)
  reg        act = 1'b0;             // any row change since the last change
  reg [31:0] since = 0;              // clocks since the last change
  wire       applied;
  wire [6:0] seen_now = seen | ((row_sel < 3'd7) ? (7'd1 << row_sel) : 7'd0);
  always @(posedge clk_sys) begin
    row_q <= row_sel;
    if (reset || applied) begin
      seen <= 7'd0; full <= 2'd0; act <= 1'b0; since <= 0;
    end else begin
      if (since != 32'hFFFFFFFF) since <= since + 1;
      if (row_sel != row_q) begin
        act <= 1'b1;
        if (seen_now == 7'h7F) begin
          seen <= 7'd0;
          if (full != 2'd2) full <= full + 2'd1;
        end else seen <= seen_now;
      end
    end
  end
  wire read_out = (full == 2'd2) || (act && since >= PART) || (since >= IDLE);
  assign applied = !reset && t == 0 && !q_empty && q_ne && read_out;

  always @(posedge clk_sys) begin
    q_ne <= !q_empty;
    if (reset) begin
      for (int i = 0; i < 7; i++) mat[i] <= 12'd0;
      rp <= 0; t <= 0; shf <= 2'd0; shf_pos <= 7'h7F; q_ne <= 1'b0;
    end else begin
      if (t != 0) t <= t - 1;
      else if (applied) begin
        rp <= rp + 10'd1;
        t  <= GAP;
        if (e[8:6] < 3'd7) mat[e[8:6]][e[5:2]] <= e[9];
        if (e[9]) begin
          shf <= e[1:0];
          shf_pos <= e[8:2];
        end else if (e[8:2] == shf_pos) begin
          shf <= 2'd0;
          shf_pos <= 7'h7F;
        end
      end
    end
  end

  wire sc_shift = shf[1] ? shf[0] : pc_shift;

  logic [11:0] r;
  always_comb begin
    r = (row_sel < 3'd7) ? mat[row_sel] : 12'd0;
    if (row_sel == 3'd6) r[11] = sc_shift;
  end
  assign row_data = ~r;

endmodule
