//-----------------------------------------------------------------------------
// SF-7000 Centronics port -> a file on an hps_io virtual disk (OSD "Printer").
//
// The SF-7000 drives the printer from its 8255: PB = data, PC7 = /STROBE,
// PA1 = BUSY (MAME sf7000.cpp). Disk BASIC's LPRINT / LLIST put the byte on
// PB, pulse PC7 low and wait for BUSY low before the next one (and give up
// with an error after a few seconds of BUSY). Each byte latched on the falling
// edge of /STROBE goes to the file as it is: what BASIC sends (CR LF line ends,
// printer control codes included).
//
// The file: bytes from offset 0 in 512-byte sectors. Main can't grow a mounted
// image, so the file must exist with room already (a file of spaces: blank
// tape style; the unused rest stays spaces). Mounting starts again at offset 0.
// A sector goes out when it is full, or after 0.5 s with nothing printed, so
// the file is up to date soon after LPRINT ends; the rest of a partly filled
// sector is written as spaces. BUSY is high while both 512-byte banks are
// waiting for the SD card, which only a very fast sender would see.
// No file mounted (or full): BUSY low and the bytes are dropped, as with an
// online printer, so programs that print don't stop.
// Only a short /STROBE pulse (< 100 us; BASIC's is a few us) is a byte: the
// 8255 mode set at boot pulls PC7 low until the first print, which a real
// printer would take as a NUL; here it is ignored.
//-----------------------------------------------------------------------------

module sf7000_printer #(
  parameter CLK_HZ = 42954545
) (
  input             clk,
  input             reset,
  input             strobe_n,
  input       [7:0] data,
  output            busy,

  input             img_mounted,
  input             img_readonly,
  input      [63:0] img_size,
  output reg [31:0] sd_lba = 0,
  output reg        sd_wr = 0,
  input             sd_ack,
  input       [8:0] sd_buff_addr,
  output      [7:0] sd_buff_din,

  output reg        active = 0,   // a writable file is mounted
  output reg [24:0] length = 0    // bytes printed since the mount
);

  localparam int IDLE = CLK_HZ / 2;
  localparam int PULSE = CLK_HZ / 10000;   // 100 us

  reg  [24:0] limit = 0;
  reg         full = 0;

  // ---------------------------------------------------------------- two-bank sector buffer
  reg  [7:0] buffer [0:1023];
  reg  [9:0] wa;
  reg  [7:0] wd;
  reg        we = 0;
  reg        out_bank;
  reg  [7:0] buf_q;
  reg        pad = 1'b0;
  reg  [8:0] out_fill;           // bytes valid in it (0 = all 512)
  always @(posedge clk) begin
    if (we) buffer[wa] <= wd;
    buf_q <= buffer[{out_bank, sd_buff_addr}];         // plain registered read: block RAM
    pad   <= out_fill != 0 && sd_buff_addr >= out_fill;   // past the bytes of a part sector: spaces
  end
  assign sd_buff_din = pad ? 8'h20 : buf_q;

  reg        stb_q = 1'b1;
  reg [15:0] stb_t = 0;
  reg  [7:0] stb_d;
  always @(posedge clk) begin
    stb_q <= strobe_n;
    if (stb_q & ~strobe_n) begin stb_t <= 0; stb_d <= data; end
    else if (~strobe_n && stb_t != 16'hFFFF) stb_t <= stb_t + 16'd1;
  end
  wire byte_in = ~stb_q & strobe_n & (stb_t < PULSE);
  reg  [1:0] pend = 0;
  reg [31:0] pend_lba [0:1];
  reg  [8:0] pend_fill [0:1];
  reg        busy_sd = 0, ack_q = 0;
  reg [31:0] idle = 0;
  reg        dirty = 0;           // bytes in the current sector not yet written
  reg  [1:0] again = 0;           // queued again while that bank was going out
  wire [1:0] queue;               // banks queued this clock

  assign busy = active & ~full & (&pend);
  wire   fill_sector  = byte_in && active && !full && !(&pend) && length[8:0] == 9'd511;
  wire   flush_sector = !(byte_in && active && !full && !(&pend)) && dirty && idle >= IDLE && !we;
  assign queue = (fill_sector | flush_sector) ? (2'b01 << length[9]) : 2'b00;

  always @(posedge clk) begin
    we <= 1'b0;
    ack_q <= sd_ack;
    if (img_mounted) begin
      active <= ~img_readonly & |img_size;
      limit  <= (|img_size[63:25]) ? 25'h1FFFFFF : img_size[24:0];
      length <= 0; full <= 0; pend <= 0; dirty <= 0; idle <= 0; again <= 0;
    end else begin
      if (idle != 32'hFFFFFFFF) idle <= idle + 1;
      if (byte_in && active && !full && !(&pend)) begin
        wa <= length[9:0]; wd <= stb_d; we <= 1'b1;
        length <= length + 25'd1;
        idle  <= 0;
        dirty <= 1'b1;
        if (length + 25'd1 >= limit) full <= 1'b1;
        if (length[8:0] == 9'd511) begin
          pend[length[9]]      <= 1'b1;
          pend_lba[length[9]]  <= {16'd0, length[24:9]};
          pend_fill[length[9]] <= 9'd0;
          dirty <= 1'b0;
        end
      end else if (dirty && idle >= IDLE && !we) begin
        // a pause: write the partly filled sector (it is rewritten when it fills)
        dirty <= 1'b0;
        pend[length[9]]      <= 1'b1;
        pend_lba[length[9]]  <= {16'd0, length[24:9]};
        pend_fill[length[9]] <= length[8:0];
      end
      if (!busy_sd && !sd_wr && (pend[0] || pend[1])) begin
        out_bank <= pend[0] ? 1'b0 : 1'b1;
        out_fill <= pend[0] ? pend_fill[0] : pend_fill[1];
        sd_lba   <= pend[0] ? pend_lba[0] : pend_lba[1];
        sd_wr    <= 1'b1;
        busy_sd  <= 1'b1;
      end
      if (sd_wr && sd_ack) sd_wr <= 1'b0;
      if (busy_sd && ack_q && !sd_ack) begin
        busy_sd <= 1'b0;
        if (again[out_bank]) again[out_bank] <= 1'b0;   // write it once more, with the new bytes
        else if (!queue[out_bank]) pend[out_bank] <= 1'b0;
      end
      if (busy_sd && queue[out_bank] && !(ack_q && !sd_ack)) again[out_bank] <= 1'b1;
    end
  end

endmodule
