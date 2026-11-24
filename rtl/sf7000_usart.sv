//-----------------------------------------------------------------------------
// 8251 USART (uPD8251) for the SF-7000 RS-232 port, asynchronous mode.
//
// After reset (or command bit 6, internal reset) the first write to the
// control port is the mode byte; in synchronous mode (bits 1:0 = 00) one or
// two sync characters follow, then commands. Disk BASIC (COMSET / COMSAVE /
// COMLOAD) writes 00 00 00 40 first: sync mode, two sync characters, internal
// reset, which puts any 8251 into a known state. The synchronous transfer
// itself isn't implemented (nothing on the SF-7000 uses it); the bytes are
// taken and the transmitter stays at mark.
//
// Mode (async): 1:0 baud factor (01 x1, 10 x16, 11 x64), 3:2 length 5-8,
//   4 parity enable, 5 even parity, 7:6 stop bits (01 1, 10 1.5, 11 2).
// Command: 0 TxEN, 1 DTR, 2 RxE, 3 send break, 4 error reset, 5 RTS,
//   6 internal reset, 7 hunt (sync only).
// Status: 0 TxRDY (holding register empty; not gated by CTS / TxEN, as the
//   8251A status bit), 1 RxRDY, 2 TxEMPTY, 3 PE, 4 OE, 5 FE, 6 SYNDET, 7 DSR.
//
// TxC = RxC = 4.9152 MHz / (32 << baud): MAME sf7000.cpp, jumpers 1-6 give
// 9600 ... 300 baud with the x16 factor BASIC uses.
//-----------------------------------------------------------------------------

module sf7000_usart #(
  parameter CLK_HZ = 42954545
) (
  input            clk,
  input            reset,
  input      [2:0] baud,          // 0 = 9600 (jumper 1) ... 5 = 300 (jumper 6)

  input            cs,            // E8 / E9
  input            a0,            // 0 = data, 1 = control / status
  input            rd,            // levels, qualified by cs
  input            wr,
  input      [7:0] din,
  output     [7:0] dout,

  output reg       txd = 1'b1,
  input            rxd,
  input            cts_n,         // 0 = clear to send
  input            dsr_n,
  output           rts_n,
  output           dtr_n
);

  // ---------------------------------------------------------------- TxC / RxC
  // phase accumulator: one tick at 4.9152 MHz / (32 << baud) (153.6 kHz at 9600)
  wire [31:0] step = 32'd153600 >> baud;
  reg  [31:0] acc = 0;
  reg         tick = 1'b0;
  always @(posedge clk) begin
    tick <= 1'b0;
    if (acc + step >= CLK_HZ) begin acc <= acc + step - CLK_HZ; tick <= 1'b1; end
    else acc <= acc + step;
  end

  // ---------------------------------------------------------------- CPU port
  reg rd_q = 1'b0, wr_q = 1'b0;
  always @(posedge clk) begin rd_q <= cs & rd; wr_q <= cs & wr; end
  wire rd_end   = rd_q & ~(cs & rd);
  wire wr_start = (cs & wr) & ~wr_q;

  localparam S_MODE = 2'd0, S_SYNC1 = 2'd1, S_SYNC2 = 2'd2, S_CMD = 2'd3;
  reg [1:0] st = S_MODE;
  reg [7:0] mode = 8'h00, cmd = 8'h00;

  wire       async  = mode[1:0] != 2'b00;
  wire [6:0] factor = (mode[1:0] == 2'b01) ? 7'd1 : (mode[1:0] == 2'b10) ? 7'd16 : 7'd64;
  wire [3:0] nbits  = 4'd5 + mode[3:2];
  wire       par_en = mode[4];
  wire       par_ev = mode[5];
  // stop length in half bits: 1 -> 2, 1.5 -> 3, 2 -> 4
  wire [2:0] stop_h = (mode[7:6] == 2'b10) ? 3'd3 : (mode[7:6] == 2'b11) ? 3'd4 : 3'd2;

  wire tx_en = cmd[0];
  wire rx_en = cmd[2];
  assign dtr_n = ~cmd[1];
  assign rts_n = ~cmd[5];

  reg [7:0] thr;              // transmit holding register
  reg       thr_full = 1'b0;
  reg       tx_busy  = 1'b0;
  reg [7:0] rbr = 8'hFF;      // receive buffer
  reg       rx_rdy = 1'b0;
  reg       pe = 1'b0, oe = 1'b0, fe = 1'b0;

  wire [7:0] status = {~dsr_n, 1'b0, fe, oe, pe, ~thr_full & ~tx_busy, rx_rdy, ~thr_full};
  assign dout = a0 ? status : rbr;

  // ---------------------------------------------------------------- transmitter
  reg  [10:0] tsr;            // start, data, parity, then stop bits shift out from bit 0
  reg  [3:0]  tleft;          // whole bits left (data + parity + start)
  reg  [2:0]  thalf;          // stop half bits left
  reg  [6:0]  tcnt;           // TxC ticks into the current (half) bit
  reg         tstop;
  wire [6:0]  tlen  = tstop ? ((factor >> 1) == 0 ? 7'd1 : factor >> 1) : factor;
  wire [7:0]  tmask = 8'hFF >> (4'd8 - nbits);
  wire [7:0]  tdat  = thr & tmask;
  wire        tpar  = ^tdat ^ ~par_ev;                   // even: ^data, odd: its inverse
  // the frame from bit 0: start, data, parity if enabled, then ones
  wire [10:0] tframe = ({2'b11, 9'h1FF} << (nbits + 4'd1 + (par_en ? 4'd1 : 4'd0)))
                     | (par_en ? ({10'd0, tpar} << (nbits + 4'd1)) : 11'd0)
                     | {2'b00, tdat, 1'b0};

  reg         rx_take;        // CPU read the data register
  always @(posedge clk) begin
    if (reset || (st == S_CMD && wr_start && a0 && din[6])) begin
      thr_full <= 1'b0; tx_busy <= 1'b0; txd <= 1'b1;
    end else begin
      if (wr_start && !a0 && st == S_CMD) begin thr <= din; thr_full <= 1'b1; end
      if (!tx_busy) begin
        txd <= ~(cmd[3] & st == S_CMD);                   // mark, or break
        if (thr_full && tx_en && !cts_n && async && st == S_CMD && tick) begin
          // load: start bit, data LSB first, parity
          tsr   <= tframe;
          tleft <= 4'd1 + nbits + (par_en ? 4'd1 : 4'd0);
          thalf <= stop_h;
          tstop <= 1'b0;
          tcnt  <= 7'd0;
          thr_full <= 1'b0;
          tx_busy  <= 1'b1;
          txd      <= 1'b0;
        end
      end else if (tick) begin
        if (tcnt == tlen - 7'd1) begin
          tcnt <= 7'd0;
          if (!tstop) begin
            tsr <= {1'b1, tsr[10:1]};
            if (tleft == 4'd1) begin tstop <= 1'b1; txd <= 1'b1; end
            else txd <= tsr[1];
            tleft <= tleft - 4'd1;
          end else begin
            if (thalf == 3'd1) tx_busy <= 1'b0;
            thalf <= thalf - 3'd1;
          end
        end else tcnt <= tcnt + 7'd1;
      end
    end
  end

  // ---------------------------------------------------------------- receiver
  reg  [1:0] rx_s = 2'b11;
  always @(posedge clk) rx_s <= {rx_s[0], rxd};
  wire rx = rx_s[1];

  localparam R_IDLE = 2'd0, R_START = 2'd1, R_BITS = 2'd2, R_STOP = 2'd3;
  reg [1:0] rs = R_IDLE;
  reg [6:0] rcnt;
  reg [3:0] ri;               // bits received (data + parity)
  reg [8:0] rsr;
  wire [6:0] rhalf = (factor >> 1) == 0 ? 7'd0 : (factor >> 1) - 7'd1;
  wire [3:0] rlast = par_en ? nbits : nbits - 4'd1;   // index of the last data / parity bit
  wire [7:0] rdat  = rsr[7:0] & (8'hFF >> (4'd8 - nbits));

  always @(posedge clk) begin
    if (reset || (st == S_CMD && wr_start && a0 && din[6])) begin
      rs <= R_IDLE; rx_rdy <= 1'b0; pe <= 1'b0; oe <= 1'b0; fe <= 1'b0;
    end else begin
      if (rd_end && !a0) rx_rdy <= 1'b0;
      if (st == S_CMD && wr_start && a0 && din[4]) begin pe <= 1'b0; oe <= 1'b0; fe <= 1'b0; end
      if (!(rx_en && async && st == S_CMD)) rs <= R_IDLE;
      else if (tick) case (rs)
        R_IDLE:  if (!rx) begin rcnt <= 7'd0; rs <= R_START; end
        R_START: if (rcnt == rhalf) begin      // middle of the start bit
                   if (rx) rs <= R_IDLE;          // a glitch
                   else begin rcnt <= 7'd0; ri <= 4'd0; rsr <= 9'd0; rs <= R_BITS; end
                 end else rcnt <= rcnt + 7'd1;
        R_BITS:  if (rcnt == factor - 7'd1) begin
                   rcnt <= 7'd0;
                   rsr[ri] <= rx;
                   if (ri == rlast) rs <= R_STOP;
                   else ri <= ri + 4'd1;
                 end else rcnt <= rcnt + 7'd1;
        R_STOP:  if (rcnt == factor - 7'd1) begin
                   rbr <= rdat;
                   if (rx_rdy) oe <= 1'b1;
                   rx_rdy <= 1'b1;
                   if (!rx) fe <= 1'b1;
                   if (par_en && (^rdat ^ rsr[nbits] ^ ~par_ev)) pe <= 1'b1;
                   rs <= R_IDLE;
                 end else rcnt <= rcnt + 7'd1;
      endcase
    end
  end

  // ---------------------------------------------------------------- control writes
  reg sync2;
  always @(posedge clk) begin
    if (reset) begin st <= S_MODE; cmd <= 8'h00; end
    else if (wr_start && a0) case (st)
      S_MODE:  begin
                 mode <= din;
                 sync2 <= ~din[7];
                 st <= (din[1:0] == 2'b00) ? S_SYNC1 : S_CMD;
               end
      S_SYNC1: st <= sync2 ? S_SYNC2 : S_CMD;
      S_SYNC2: st <= S_CMD;
      S_CMD:   if (din[6]) begin st <= S_MODE; cmd <= 8'h00; end
               else cmd <= din;
    endcase
  end

endmodule
