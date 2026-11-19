//-----------------------------------------------------------------------------
// Tape status bar (~/dev2/tape-standard.md rules 19-24): `TAPE > m:ss/ m:ss x4`
// and a 64-step bar in the bottom-left corner while the deck plays.
// sc3000_tape_overlay (renderer) and tape_font.vh come unchanged (renamed) from
// SVI328_MiSTer rtl/tape_overlay.sv; sc3000_tape_status is new: the elapsed and
// total times come from the WAV/.bit player's own seconds (sc3000_tape.sv).
// The next-step hint is not used (hint fields of the word are 0).
//-----------------------------------------------------------------------------

`define TH_RETURN 8'h01
`define TH_PLAY   8'h03

// Status word for the overlay (tape-standard rules 19-24), from the WAV/.bit
// player's own seconds: one word {hint_show, hint_len, hint_text, loaded,
// playing, fast, fill, elapsed, total} handed to the video clock with a toggle.
module sc3000_tape_status (
  input  logic         clk,
  input  logic         rewind,      // mount or rewind: elapsed back to 0
  input  logic         loaded,      // a tape is mounted
  input  logic         playing,     // deck running
  input  logic         fast,        // turbo active
  input  logic         sec_tick,    // one second of tape played
  input  logic  [15:0] total_sec,
  input  logic         total_ok,
  input  logic  [24:0] position,    // byte pointer
  input  logic  [24:0] data_start,
  input  logic  [24:0] data_end,
  output logic [223:0] status,      // held while req != ack
  output logic         req,
  input  logic         ack          // asynchronous; synchronised here
);
  logic [15:0] elapsed, total;      // BCD m1 m0 s1 s0
  logic [15:0] tot_left;
  logic        tot_conv, tot_done;
  logic [24:0] thresh;
  wire  [24:0] span = data_end - data_start;
  wire  [24:0] step_bytes = span[24:6] == 0 ? 25'd1 : {6'd0, span[24:6]};
  logic [6:0]  fill;
  logic [1:0]  ack_sync;

  function automatic logic [15:0] bcd_tick(input logic [15:0] t);
    logic [15:0] n;
    n = t;
    if (t == 16'h9959) return t;                 // saturate at 99:59
    if (t[3:0] != 4'd9) n[3:0] = t[3:0] + 4'd1;
    else begin
      n[3:0] = 0;
      if (t[7:4] != 4'd5) n[7:4] = t[7:4] + 4'd1;
      else begin
        n[7:4] = 0;
        if (t[11:8] != 4'd9) n[11:8] = t[11:8] + 4'd1;
        else begin n[11:8] = 0; n[15:12] = t[15:12] + 4'd1; end
      end
    end
    return n;
  endfunction

  wire [223:0] pack = {1'b0, 5'd0, 176'd0, loaded, playing, fast, fill, elapsed, total};

  initial begin
    elapsed = 0; total = 0; tot_left = 0; tot_conv = 0; tot_done = 0;
    thresh = 0; fill = 0; req = 0; status = 0; ack_sync = 0;
  end

  always_ff @(posedge clk) begin
    ack_sync <= {ack_sync[0], ack};

    // Total: binary seconds from the player -> BCD m:ss, once per mount
    if (rewind || !total_ok) begin
      tot_done <= 0; tot_conv <= 0;
      if (!total_ok) total <= 0;
    end else if (!tot_done && !tot_conv) begin
      tot_left <= total_sec; total <= 0; tot_conv <= 1;
    end else if (tot_conv) begin
      if (tot_left != 0) begin tot_left <= tot_left - 16'd1; total <= bcd_tick(total); end
      else begin tot_conv <= 0; tot_done <= 1; end
    end

    if (rewind) elapsed <= 0;
    else if (sec_tick) elapsed <= bcd_tick(elapsed);

    // Fill: 64 steps over the sample data
    if (rewind || position <= data_start || thresh == 0) begin
      fill <= 0; thresh <= data_start + step_bytes;
    end else if (position >= thresh && fill != 7'd64) begin
      fill <= fill + 7'd1; thresh <= thresh + step_bytes;
    end

    if (req == ack_sync[1] && pack != status) begin
      status <= pack;
      req <= !req;
    end
  end
endmodule

module sc3000_tape_overlay #(
  parameter logic [3:0] FACTOR = 4'd4      // shown as "x4" while turbo is on
)(
  input  logic         clk,         // video clock
  input  logic         ce_pix,
  input  logic         hblank, vblank,
  input  logic         enable,      // OSD Tape overlay: On
  input  logic [223:0] status,      // from sc3000_tape_status, stable while req != ack
  input  logic         req,
  output logic         ack,
  input  logic  [23:0] rgb_in,
  output logic  [23:0] rgb_out
);
  localparam int CHARS = 22;
  logic [1:0]   req_sync;
  logic [223:0] shown;
  logic [10:0]  x, width;
  logic [9:0]   y, height;
  logic         line_active, old_hblank, old_vblank;

  initial begin
    req_sync = 0; ack = 0; shown = 0; x = 0; y = 0; width = 0; height = 0;
    line_active = 0; old_hblank = 0; old_vblank = 0;
  end

  // Measure the active picture each frame (256x192, or larger with the border).
  always_ff @(posedge clk) begin
    req_sync <= {req_sync[0], req};
    if (req_sync[1] != ack) begin shown <= status; ack <= req_sync[1]; end
    if (ce_pix) begin
      old_hblank <= hblank; old_vblank <= vblank;
      if (!hblank && !vblank) begin x <= x + 11'd1; line_active <= 1; end
      if (hblank && !old_hblank) begin
        if (line_active) begin width <= x; y <= y + 10'd1; end
        x <= 0; line_active <= 0;
      end
      if (vblank && !old_vblank) begin height <= y; y <= 0; end
    end
  end

  wire         hint_show = shown[223];
  wire [4:0]   hint_len  = shown[222:218];
  wire [175:0] hint_text = shown[217:42];
  wire         tape_bar  = enable && shown[41] && shown[40];   // loaded, playing
  wire         hint      = enable && hint_show && !tape_bar;
  wire         visible   = tape_bar || hint;
  wire         fast      = shown[39];
  wire [6:0]   fill      = shown[38:32];
  wire [15:0]  elapsed   = shown[31:16];
  wire [15:0]  total     = shown[15:0];
  // Double the overlay on wide or tall pictures (the SVI's are 256-284 x 192-240).
  wire         sx = width >= 11'd512, sy = height >= 10'd300;
  wire [4:0]   chars = tape_bar ? 5'(CHARS) : hint_len;
  wire [10:0]  box_w = {3'd0, chars, 3'd0} + 11'd4;
  wire [9:0]   box_h = tape_bar ? 10'd18 : 10'd12;
  wire [10:0]  x0 = 11'd4;
  wire [9:0]   y0 = height - (sy ? {box_h[8:0], 1'b0} : box_h) - 10'd4;
  wire [10:0]  dx = x - x0;
  wire [9:0]   dy = y - y0;
  wire [10:0]  lx = sx ? {1'b0, dx[10:1]} : dx;
  wire [9:0]   ly = sy ? {1'b0, dy[9:1]} : dy;
  wire         in_box = x >= x0 && y >= y0 && lx < box_w && ly < box_h;

  wire [10:0]  tx = lx - 11'd2;
  wire [9:0]   ty = ly - 10'd2;

  `include "tape_font.vh"

  function automatic logic [7:0] digit(input logic [3:0] d, input logic blank_zero);
    return blank_zero && d == 0 ? 8'h20 : 8'h30 + {4'd0, d};
  endfunction
  // The character at column col (an always_comb, not a function reading
  // module signals: Quartus 17 reports those signals as never read).
  wire  [4:0] col = tx[7:3];
  logic [7:0] ch;
  always_comb begin
    if (!tape_bar) ch = hint_text[175 - 8 * col -: 8];
    else case (col)
      5'd0: ch = "T";  5'd1: ch = "A";  5'd2: ch = "P";  5'd3: ch = "E";
      5'd5: ch = `TH_PLAY;
      5'd7: ch = digit(elapsed[15:12], 1'b1);  5'd8: ch = digit(elapsed[11:8], 1'b0);
      5'd9: ch = ":";
      5'd10: ch = digit(elapsed[7:4], 1'b0);  5'd11: ch = digit(elapsed[3:0], 1'b0);
      5'd12: ch = "/";
      5'd13: ch = digit(total[15:12], 1'b1);  5'd14: ch = digit(total[11:8], 1'b0);
      5'd15: ch = ":";
      5'd16: ch = digit(total[7:4], 1'b0);  5'd17: ch = digit(total[3:0], 1'b0);
      5'd19: ch = fast ? "x" : " ";
      5'd20: ch = fast ? digit(FACTOR, 1'b0) : " ";
      default: ch = " ";
    endcase
  end
  function automatic logic [7:0] glyph(input logic [7:0] c, input logic [2:0] r);
    logic [63:0] g;
    if (c == `TH_RETURN) begin g = 64'h0002022262FE6020; return g[63 - 8 * r -: 8]; end
    if (c == `TH_PLAY)   begin g = 64'h4060707870604000; return g[63 - 8 * r -: 8]; end
    if (c == "x")        begin g = 64'h0000442810284400; return g[63 - 8 * r -: 8]; end   // the font has no lower case
    if (c >= 8'h40 && c < 8'h60) return tape_font({1'b0, c[4:0]}, r);
    if (c >= 8'h20 && c < 8'h40) return tape_font({1'b1, c[4:0]}, r);
    return 8'h00;
  endfunction

  wire [7:0] glyph_row = glyph(ch, ty[2:0]);
  wire text_on = ty < 10'd8 && tx < {3'd0, chars, 3'd0} && glyph_row[3'd7 - tx[2:0]];
  // Progress bar at ly 12..15, 128 px for 64 steps.
  wire bar_area = tape_bar && ly >= 10'd12 && ly < 10'd16 && lx >= 11'd2 && lx < 11'd130;
  wire bar_on = bar_area && (lx - 11'd2) < {3'd0, fill, 1'b0};

  always_comb begin
    rgb_out = rgb_in;
    if (visible && in_box)
      rgb_out = text_on ? 24'hFFFFFF : bar_on ? 24'h44CC44 : bar_area ? 24'h333333 : 24'h000000;
  end
endmodule
