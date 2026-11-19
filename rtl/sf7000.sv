//-----------------------------------------------------------------------------
// Sega SF-7000 Super Control Station (cartridge-slot disk unit), after MAME
// src/devices/bus/sega8/sf7000.cpp and the SF-7000 schematic:
//
//   Memory  64 KB RAM over the whole map (it also takes C000-FFFF from the
//           internal RAM: cart pin B3), 8 KB IPL ROM at 0000-3FFF (mirrored)
//           while PPI PC6 (/ROM SEL) is low. Writes always reach RAM.
//   I/O     E0 FDC status, E1 FDC data (uPD765A, sf7000_fdc.sv)
//           E4-E7 8255: PA0 FDC INT, PA1 printer BUSY, PA2 FDD INDEX;
//                       PB printer data; PC0 /IN USE, PC1 /MOTOR ON, PC2 TC,
//                       PC3 FDC RESET, PC5 FDC READY, PC6 /ROM SEL, PC7 /STROBE
//           E8-E9 8251 USART (stub: transmitter always empty, no receive)
//   Decode: A7:A4 = 1110 (MAME only checks A4 = 0; docs: E0-EF).
//-----------------------------------------------------------------------------

module sf7000 #(
  parameter CLK_HZ = 42954545          // clk rate, for the 300 rpm index pulse
) (
  input               clk,
  input               reset,
  input               enable,      // OSD: SF-7000 attached

  // IPL ROM download (8 KB)
  input               rom_wr,
  input        [12:0] rom_addr,
  input        [7:0]  rom_data,

  // cartridge bus (from sc3000)
  input        [15:0] a,
  input               mem_rd,
  input               mem_wr,
  input        [7:0]  d_i,
  output       [7:0]  mem_d_o,
  output              ram_sel,     // takes C000-FFFF too

  input               io_rd,
  input               io_wr,
  output              io_en,       // this unit answers the I/O read
  output       [7:0]  io_d_o,

  // disk image (hps_io SD)
  input               img_mounted,
  input               img_readonly,
  input        [31:0] img_size,
  output       [31:0] sd_lba,
  output              sd_rd,
  output              sd_wr,
  input               sd_ack,
  input        [8:0]  sd_buff_addr,
  input        [7:0]  sd_buff_dout,
  output       [7:0]  sd_buff_din,
  input               sd_buff_wr,

  output              motor_led
);

  // ---------------------------------------------------------------- memory
  reg [7:0] ipl [0:8191];
  reg [7:0] ipl_q;
  always @(posedge clk) begin
    if (rom_wr) ipl[rom_addr] <= rom_data;
    ipl_q <= ipl[a[12:0]];
  end

  reg [7:0] ram [0:65535];
  reg [7:0] ram_q;
  always @(posedge clk) begin
    if (enable & mem_wr) ram[a] <= d_i;
    ram_q <= ram[a];
  end

  // ---------------------------------------------------------------- PPI
  wire       io_sel = enable & (a[7:4] == 4'hE);
  wire       ppi_cs = io_sel & (a[3:2] == 2'b01);
  wire       fdc_cs = io_sel & (a[3:2] == 2'b00);
  wire       usart_cs = io_sel & (a[3:2] == 2'b10);
  wire [7:0] ppi_q, pc;
  wire       fdc_int;

  jt8255 ppi (
    .rst(reset), .clk(clk),
    .addr(a[1:0]), .din(d_i), .dout(ppi_q),
    .rdn(~io_rd), .wrn(~io_wr), .csn(~ppi_cs),
    .porta_din({5'b00000, index, 1'b0, fdc_int}),
    .portb_din(8'hFF), .portc_din(8'hFF),
    .porta_dout(), .portb_dout(), .portc_dout(pc));

  // Port C upper half is an input after reset (8255 reset state): the pins
  // float and /ROM SEL reads low, so the IPL is mapped (MAME tri_pc = 8Fh).
  reg c_hi_out = 1'b0;
  always @(posedge clk) begin
    if (reset) c_hi_out <= 1'b0;
    else if (ppi_cs & io_wr & (a[1:0] == 2'b11) & d_i[7]) c_hi_out <= ~d_i[3];
  end
  wire romsel   = ~c_hi_out | ~pc[6];

  assign mem_d_o = (romsel && a[15:14] == 2'b00) ? ipl_q : ram_q;
  assign ram_sel = enable;

  // lower half of port C as an output (TC, FDC RESET, /MOTOR ON)
  reg c_lo_out = 1'b0;
  always @(posedge clk) begin
    if (reset) c_lo_out <= 1'b0;
    else if (ppi_cs & io_wr & (a[1:0] == 2'b11) & d_i[7]) c_lo_out <= ~d_i[0];
  end

  // ---------------------------------------------------------------- index pulse
  // 300 rpm: one pulse every 200 ms, 4 ms wide, while the motor runs with a
  // disk in. The IPL times INDEX off -> on and wants 169-207 ms.
  localparam int REV = CLK_HZ / 5;
  localparam int PW  = CLK_HZ / 250;
  wire motor_on = c_lo_out & ~pc[1];
  wire disk_in;
  reg [31:0] rot = 0;
  always @(posedge clk) rot <= (rot >= REV - 1) ? 0 : rot + 1;
  wire index = motor_on & disk_in & (rot < PW);

  // ---------------------------------------------------------------- FDC
  wire [7:0] fdc_q;
  sf7000_fdc fdc (
    .clk(clk), .reset(reset | (c_lo_out & pc[3])),
    .cs(fdc_cs), .a0(a[0]), .rd(io_rd), .wr(io_wr), .din(d_i), .dout(fdc_q),
    .int_o(fdc_int), .tc(pc[2] & c_lo_out), .motor(motor_on), .disk_in(disk_in),
    .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
    .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
    .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
    .sd_buff_wr(sd_buff_wr));

  assign motor_led = enable & motor_on;

  // ---------------------------------------------------------------- USART stub
  // status: TxRDY (0), TxE (2), DSR (7) off; data reads FF
  wire [7:0] usart_q = a[0] ? 8'h05 : 8'hFF;

  assign io_en  = io_sel & (ppi_cs | fdc_cs | usart_cs);
  assign io_d_o = ppi_cs ? ppi_q : fdc_cs ? fdc_q : usart_q;

endmodule
