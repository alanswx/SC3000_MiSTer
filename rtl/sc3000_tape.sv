//-----------------------------------------------------------------------------
// SC-3000 cassette player: plays a tape image from memory into PPI PB7.
//
// Formats (detected from the first bytes):
//   .wav  RIFF/WAVE PCM, 8-bit unsigned or 16-bit signed, mono or stereo (the
//         first channel is used), any sample rate. Chunks are walked, so an
//         18-byte fmt chunk or extra chunks before "data" are fine.
//   .bit  MAME's sc3000_bit format: one character per bit cell at 1200 baud,
//         '1' = two cycles of 2400 Hz, '0' = one cycle of 1200 Hz, anything
//         else (space) = silence (refs/mame/src/lib/formats/sc3000_bit.cpp).
//
// Time base: ce = the Z80 clock enable (3.579545 MHz), so the tape runs at the
// CPU's speed, and a faster CPU (turbo) plays the tape faster with it.
//
// The image is read through a byte port with a ready handshake (SDRAM on the
// MiSTer, an array in the sim): mem_rd is a level, the byte for mem_addr is
// valid on mem_data when mem_ready is high and mem_rd has been seen.
//-----------------------------------------------------------------------------

module sc3000_tape #(
  parameter CPU_HZ = 3579545
) (
  input               clk,
  input               reset,       // rewind
  input               ce,          // CPU clock enable
  input               play,        // deck running (virtual motor)
  input        [24:0] size,        // image size, 0 = no tape

  output logic [24:0] mem_addr,
  output logic        mem_rd,
  input        [7:0]  mem_data,
  input               mem_ready,

  output logic        level,       // to PB7
  output logic        ended,
  output       [24:0] position,    // bytes played (for a status bar)
  output       [24:0] data_end,
  output reg   [24:0] data_start,  // first sample byte
  output reg          sec_tick,    // one second of tape played
  output reg   [15:0] total_sec,   // length of the tape in seconds (valid when total_ok)
  output reg          total_ok
);

  // ----------------------------------------------------------------- reader
  // one-byte fetch: start a read at addr, wait for ready on a later clock
  logic        fetch_go, fetch_busy, fetch_done;
  logic [24:0] fetch_addr;
  logic [7:0]  fetch_q;
  logic [1:0]  fetch_wait;

  always_ff @(posedge clk) begin
    fetch_done <= 1'b0;
    if (reset) begin
      fetch_busy <= 1'b0;
      mem_rd     <= 1'b0;
    end else if (fetch_go & ~fetch_busy) begin
      mem_addr   <= fetch_addr;
      mem_rd     <= 1'b1;
      fetch_busy <= 1'b1;
      fetch_wait <= 2'd3;
    end else if (fetch_busy) begin
      if (fetch_wait != 0) fetch_wait <= fetch_wait - 2'd1;
      else if (mem_ready) begin
        fetch_q    <= mem_data;
        mem_rd     <= 1'b0;
        fetch_busy <= 1'b0;
        fetch_done <= 1'b1;
      end
    end
  end

  // ----------------------------------------------------------------- parser + player
  typedef enum logic [3:0] {
    S_IDLE, S_HDR, S_CHUNK, S_FMT, S_SKIP, S_PLAY_WAV, S_PLAY_BIT, S_END
  } state_t;
  state_t st;

  logic [24:0] p;            // next byte to read
  logic [5:0]  hi;           // header byte index
  logic [31:0] w;            // shift register for little-endian fields
  logic [31:0] chunk_id;
  logic [24:0] chunk_end;
  logic [31:0] rate;
  logic [15:0] bits;
  logic [15:0] chans;
  logic [24:0] dend;
  logic [2:0]  frame_bytes;
  logic        is_bit;

  // sample clock: acc += rate per CPU clock, a new sample each CPU_HZ
  logic [31:0] acc;
  logic        want;         // a sample is due
  logic signed [8:0] sample; // centred, 8-bit resolution

  // .bit: phase within the bit cell, in CPU clocks
  localparam int CELL = CPU_HZ / 1200;         // 2983
  logic [12:0] cell_t;
  logic [7:0]  cell_c;

  // seconds: WAV counts samples against the sample rate, .bit counts 1200 cells
  logic [31:0] sec_cnt;
  // total seconds = data bytes / bytes per second, by repeated subtraction after the header
  logic [31:0] tot_rem, tot_step;
  logic        tot_run;

  assign position = p;
  assign data_end = dend;

  wire [7:0]  b = fetch_q;
  // chunk size as it completes (byte 7 of the chunk header), clipped to 25 bits
  wire [31:0] csize32 = {b, w[31:8]};
  wire [24:0] csize = |csize32[31:25] ? 25'h1FFFFFF : csize32[24:0];

  always_ff @(posedge clk) begin
    fetch_go <= 1'b0;
    sec_tick <= 1'b0;
    if (tot_run) begin
      if (tot_rem >= tot_step) begin tot_rem <= tot_rem - tot_step; if (total_sec != 16'hFFFF) total_sec <= total_sec + 16'd1; end
      else begin tot_run <= 1'b0; total_ok <= 1'b1; end
    end
    if (reset || size == 25'd0) begin
      sec_cnt <= 32'd0; tot_run <= 1'b0; total_ok <= 1'b0; total_sec <= 16'd0; data_start <= 25'd0;
      st <= S_IDLE; p <= 25'd0; hi <= 6'd0; level <= 1'b0; ended <= 1'b0;
      acc <= 32'd0; want <= 1'b0; dend <= size; is_bit <= 1'b0; cell_t <= 13'd0;
      rate <= 32'd44100; bits <= 16'd8; chans <= 16'd1;
    end else begin
      case (st)
        S_IDLE: begin
          // first byte decides the format
          if (~fetch_busy & ~fetch_done) begin fetch_addr <= 25'd0; fetch_go <= 1'b1; end
          if (fetch_done) begin
            if (b == "R") begin st <= S_HDR; p <= 25'd1; hi <= 6'd1; end
            else begin
              st <= S_PLAY_BIT; is_bit <= 1'b1; p <= 25'd0; dend <= size; cell_c <= b; cell_t <= 13'd0;
              data_start <= 25'd0; tot_rem <= {7'd0, size}; tot_step <= 32'd1200; total_sec <= 16'd0; tot_run <= 1'b1;
            end
          end
        end

        // "RIFF" size "WAVE": just skip the 12 bytes
        S_HDR: begin
          p <= 25'd12; st <= S_CHUNK; hi <= 6'd0;
        end

        // chunk header: id (4) + size (4)
        S_CHUNK: begin
          if (p >= size) st <= S_END;
          else if (~fetch_busy & ~fetch_done & ~fetch_go) begin fetch_addr <= p; fetch_go <= 1'b1; end
          if (fetch_done) begin
            w <= {b, w[31:8]};
            p <= p + 25'd1;
            hi <= hi + 6'd1;
            if (hi == 6'd3) chunk_id <= {b, w[31:8]};
            if (hi == 6'd7) begin
              hi <= 6'd0;
              chunk_end <= p + 25'd1 + csize;
              if (chunk_id == "atad") begin            // "data" little-endian
                dend <= (p + 25'd1 + csize > size) ? size : p + 25'd1 + csize;
                frame_bytes <= (bits == 16'd16 ? 3'd2 : 3'd1) * ((chans == 16'd2) ? 3'd2 : 3'd1);
                data_start  <= p + 25'd1;
                tot_rem     <= {7'd0, ((p + 25'd1 + csize > size) ? size : p + 25'd1 + csize) - (p + 25'd1)};
                tot_step    <= rate * ((bits == 16'd16 ? 32'd2 : 32'd1) * ((chans == 16'd2) ? 32'd2 : 32'd1));
                total_sec   <= 16'd0;
                tot_run     <= 1'b1;
                st <= S_PLAY_WAV;
              end else if (chunk_id == " tmf") st <= S_FMT;   // "fmt "
              else st <= S_SKIP;
            end
          end
        end

        // fmt: format(2) channels(2) rate(4) byterate(4) align(2) bits(2)
        S_FMT: begin
          if (~fetch_busy & ~fetch_done & ~fetch_go) begin fetch_addr <= p; fetch_go <= 1'b1; end
          if (fetch_done) begin
            w <= {b, w[31:8]};
            p <= p + 25'd1;
            hi <= hi + 6'd1;
            if (hi == 6'd3)  chans <= {b, w[31:24]};
            if (hi == 6'd7)  rate  <= {b, w[31:8]};
            if (hi == 6'd15) begin bits <= {b, w[31:24]}; st <= S_SKIP; end
          end
        end

        S_SKIP: begin
          p  <= chunk_end + {24'd0, chunk_end[0]};   // chunks are word aligned
          hi <= 6'd0;
          st <= S_CHUNK;
        end

        S_PLAY_WAV: begin
          if (p >= dend) begin st <= S_END; end
          else begin
            if (play & ce) begin
              if (acc + rate >= CPU_HZ) begin acc <= acc + rate - CPU_HZ; want <= 1'b1; end
              else acc <= acc + rate;
            end
            if (want & ~fetch_busy & ~fetch_done & ~fetch_go) begin
              // 16-bit: the high byte of the first channel; 8-bit: the byte
              fetch_addr <= p + ((bits == 16'd16) ? 25'd1 : 25'd0);
              fetch_go <= 1'b1;
            end
            if (fetch_done) begin
              want <= 1'b0;
              p <= p + {22'd0, frame_bytes};
              if (sec_cnt + 32'd1 >= rate) begin sec_cnt <= 32'd0; sec_tick <= 1'b1; end
              else sec_cnt <= sec_cnt + 32'd1;
              // Schmitt trigger around the centre
              if ((bits == 16'd16 ? $signed({b[7], b}) : $signed({1'b0, b}) - 9'sd128) > 9'sd6) level <= 1'b1;
              else if ((bits == 16'd16 ? $signed({b[7], b}) : $signed({1'b0, b}) - 9'sd128) < -9'sd6) level <= 1'b0;
            end
          end
        end

        S_PLAY_BIT: begin
          if (p >= dend) st <= S_END;
          else if (play & ce) begin
            // '1': 2400 Hz (toggle every CELL/4), '0': 1200 Hz (toggle every CELL/2)
            if (cell_c == "1")      level <= (cell_t < CELL/4) || (cell_t >= CELL/2 && cell_t < 3*CELL/4);
            else if (cell_c == "0") level <= (cell_t < CELL/2);
            else                    level <= 1'b0;
            if (cell_t == CELL - 1) begin
              cell_t <= 13'd0;
              if (sec_cnt == 32'd1199) begin sec_cnt <= 32'd0; sec_tick <= 1'b1; end
              else sec_cnt <= sec_cnt + 32'd1;
              p <= p + 25'd1;
              fetch_addr <= p + 25'd1;
              fetch_go <= 1'b1;
            end else cell_t <= cell_t + 13'd1;
          end
          if (fetch_done) cell_c <= b;
        end

        S_END: begin level <= 1'b0; ended <= 1'b1; end
        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
