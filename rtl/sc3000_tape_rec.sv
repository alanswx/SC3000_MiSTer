//-----------------------------------------------------------------------------
// SC-3000 tape recorder: what BASIC's SAVE writes on PPI PC4 becomes a MAME
// .bit file (one character per 1200-baud bit cell: '1', '0', ' ' = silence;
// refs/mame/src/lib/formats/sc3000_bit.cpp), written through an hps_io
// virtual disk (OSD "Tape save"). sc3000_tape.sv plays .bit files back.
//
// PC4 carries a square wave: a 1 is two cycles of 2400 Hz (four half-cycles of
// ~746 Z80 clocks), a 0 one cycle of 1200 Hz (two of ~1491). Half-cycles are
// timed in Z80 clocks, so tape turbo changes nothing, and called short or long
// at 1118. Four shorts make a 1, two longs a 0; a run of shorts between longs
// is always a multiple of four, so the count realigns at every 0.
// While nothing is written for two cells (5966 clocks), silence goes to the
// file as spaces, up to one second (1200 cells); then the block is closed
// and the sector in use is written out. Recording resumes with the next edge.
//
// The file: the characters from offset 0 in 512-byte sectors. Main can't grow
// a mounted image, so the file must be big enough already: a blank tape is a
// file of spaces (releases/ has one), which also plays back as silence.
// Mounting rewinds to the start. Sectors go out from two 512-byte banks; the
// rest of a partly filled sector is written as spaces.
//-----------------------------------------------------------------------------

module sc3000_tape_rec #(
  parameter CPU_HZ = 3579545
) (
  input             clk,
  input             ce_cpu,        // one per Z80 clock (turbo included)
  input             tape_out,      // PPI PC4

  input             img_mounted,   // hps_io VD for "Tape save"
  input             img_readonly,
  input      [63:0] img_size,
  output reg [31:0] sd_lba = 0,
  output reg        sd_wr = 0,
  input             sd_ack,
  input       [8:0] sd_buff_addr,
  output      [7:0] sd_buff_din,

  output reg        active = 0,    // a writable file is mounted
  output reg        recording = 0, // inside a block
  output reg        full = 0,
  output reg [24:0] length = 0     // characters recorded since the mount
);

  localparam int CELL  = CPU_HZ / 1200;      // 2983
  localparam int SHORT = (CELL * 3) / 8;     // 1118: between 746 and 1491
  localparam int LONGM = CELL;               // longer than this is not a bit

  reg  [24:0] limit = 0;

  // ---------------------------------------------------------------- two-bank sector buffer
  reg  [7:0] buffer [0:1023];
  reg  [9:0] wa;
  reg  [7:0] wd;
  reg        we = 0;
  reg        out_bank;          // bank being written to the SD card
  reg  [7:0] buf_q;
  reg        pad = 1'b0;
  reg  [8:0] out_fill;          // characters valid in it (0 = all 512)
  always @(posedge clk) begin
    if (we) buffer[wa] <= wd;
    buf_q <= buffer[{out_bank, sd_buff_addr}];         // plain registered read: block RAM
    pad   <= out_fill != 0 && sd_buff_addr >= out_fill;   // past the bytes of a part sector: spaces
  end
  assign sd_buff_din = pad ? 8'h20 : buf_q;

  // ---------------------------------------------------------------- decoder
  reg        lvl_q = 0;
  reg [15:0] t = 0;             // Z80 clocks since the last edge
  reg [2:0]  nshort = 0;
  reg        nlong = 0;
  reg [10:0] spaces = 0;        // silence cells written in this gap
  reg [11:0] cell_t = 0;        // clocks into the current silence cell
  reg        emit;
  reg [7:0]  emit_c;

  always @(posedge clk) begin
    emit <= 1'b0;
    if (img_mounted) begin
      nshort <= 0; nlong <= 0; t <= 0; spaces <= 0;
    end else if (ce_cpu) begin
      lvl_q <= tape_out;
      if (tape_out != lvl_q) begin
        // an edge: classify the half-cycle that just ended
        t <= 0;
        spaces <= 0;
        cell_t <= 0;
        if (t < SHORT) begin
          nlong <= 0;
          if (nshort == 3'd3) begin nshort <= 0; emit <= 1'b1; emit_c <= "1"; end
          else nshort <= nshort + 3'd1;
        end else if (t < LONGM) begin
          nshort <= 0;
          if (nlong) begin nlong <= 0; emit <= 1'b1; emit_c <= "0"; end
          else nlong <= 1'b1;
        end else begin
          nshort <= 0; nlong <= 0;     // the first edge after silence
        end
      end else begin
        if (t != 16'hFFFF) t <= t + 16'd1;
        // silence: a space per cell once two cells have passed without an edge
        if (t >= 2 * CELL) begin
          if (cell_t == CELL - 1) begin
            cell_t <= 0;
            if (recording && spaces != 11'd1200) begin spaces <= spaces + 11'd1; emit <= 1'b1; emit_c <= " "; end
          end else cell_t <= cell_t + 12'd1;
        end
      end
    end
  end

  // ---------------------------------------------------------------- file writer
  reg        flush_req = 0;     // close the block: write the current sector as it stands
  reg [1:0]  pend = 0;          // banks waiting to go out
  reg [31:0] pend_lba [0:1];
  reg [8:0]  pend_fill [0:1];
  reg        ack_q = 0;
  reg        busy = 0;

  always @(posedge clk) begin
    we <= 1'b0;
    ack_q <= sd_ack;
    if (img_mounted) begin
      active    <= ~img_readonly & |img_size;
      limit     <= (|img_size[63:25]) ? 25'h1FFFFFF : img_size[24:0];
      length    <= 0;
      full      <= 0;
      recording <= 0;
      pend      <= 0;
    end else begin
      if (emit && active && !full && (emit_c != " " || recording)) begin
        if (emit_c != " ") recording <= 1'b1;
        wa <= length[9:0]; wd <= emit_c; we <= 1'b1;
        length <= length + 25'd1;
        if (length + 25'd1 >= limit) full <= 1'b1;
        if (length[8:0] == 9'd511) begin                         // a sector is complete
          pend[length[9]]      <= 1'b1;
          pend_lba[length[9]]  <= {16'd0, length[24:9]};
          pend_fill[length[9]] <= 9'd0;
        end
        if (emit_c == " " && spaces == 11'd1200) flush_req <= 1'b1;   // one second of silence: close
      end
      if (flush_req && !we) begin
        flush_req <= 1'b0;
        recording <= 1'b0;
        if (length[8:0] != 0) begin
          pend[length[9]]      <= 1'b1;
          pend_lba[length[9]]  <= {16'd0, length[24:9]};
          pend_fill[length[9]] <= length[8:0];
        end
      end
      // one sector at a time to the SD card
      if (!busy && !sd_wr) begin
        if (pend[0] || pend[1]) begin
          out_bank <= pend[0] ? 1'b0 : 1'b1;
          out_fill <= pend[0] ? pend_fill[0] : pend_fill[1];
          sd_lba   <= pend[0] ? pend_lba[0] : pend_lba[1];
          sd_wr    <= 1'b1;
          busy     <= 1'b1;
        end
      end
      if (sd_wr && sd_ack) sd_wr <= 1'b0;
      if (busy && ack_q && !sd_ack) begin
        busy <= 1'b0;
        pend[out_bank] <= 1'b0;
      end
    end
  end

endmodule
