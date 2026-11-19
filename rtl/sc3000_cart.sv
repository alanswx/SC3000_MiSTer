//-----------------------------------------------------------------------------
// SC-3000 / SG-1000 cartridge slot: mappers after MAME src/devices/bus/sega8/rom.cpp
// (read_cart / write_cart / read_ram / write_ram / write_io of each device) and
// sg1000.cpp (which slot types take C000-FFFF: cartridge pin B3 /RAMDIS).
//
//   0 ROM         plain ROM up to 48 KB at 0000-BFFF: rom[offset % size]
//   1 LEVEL3      BASIC Level III: ROM 0000-7FFF, 32 KB RAM at 8000-BFFF + C000-FFFF
//   2 CASTLE      The Castle: + 8 KB RAM at 8000-9FFF
//   3 OTHELLO     Othello / BASIC Level II: + 2 KB RAM at 8000-9FFF (mirrored)
//   4 TEREBI      Terebi Oekaki tablet: read 8000 = pen (bit 0, active low),
//                 read A000 = data, write 6000 bit 0: 1 = latch X (4-251),
//                 0 = latch Y + 20h
//   5 DAHJEE_A    + 8 KB RAM at 2000-3FFF, 1 KB at C000-FFFF (mirrored)
//   6 DAHJEE_B    8 KB RAM at C000-FFFF (mirrored)
//   7 MUSIC       Music Editor: 8 KB RAM at 8000-9FFF, 2 KB at C000-FFFF
//   8 MULTICART   SC-3000 Survivors Multicart (2 MB): 32 KB ROM window at
//                 0000-7FFF, block from an OUT to E0-FF: bit 7 ? {bit6, bit4:0} : 3Fh;
//                 32 KB RAM at 8000-BFFF + C000-FFFF
//   9 MEGACART    Survivors Megacart (4 MB): block = {bit7:6, bit4:0}
//
// ROM storage is outside (BRAM in the sim, SDRAM on hardware): rom_addr is the
// byte offset in the image, rom_data comes back one clock later.
//-----------------------------------------------------------------------------

module sc3000_cart (
  input               clk,
  input               reset,
  input        [3:0]  mapper,
  input        [23:0] rom_size,     // image size in bytes (0 = no cartridge)

  input        [15:0] a,
  input               rd,
  input               wr,
  input        [7:0]  d_i,
  output logic [7:0]  d_o,
  output              ram_sel,      // to sc3000 cart_ram_sel_i
  input               io_wr,        // I/O write (multicart bank register)

  // Terebi Oekaki tablet
  input        [7:0]  tab_x,
  input        [7:0]  tab_y,        // 0-191
  input               tab_pen,      // 1 = pen down

  output logic [23:0] rom_addr,
  output              rom_rd,       // a read of the ROM image (SDRAM read request)
  input        [7:0]  rom_data
);

  localparam M_ROM = 4'd0, M_LEVEL3 = 4'd1, M_CASTLE = 4'd2, M_OTHELLO = 4'd3, M_TEREBI = 4'd4,
             M_DAHJEE_A = 4'd5, M_DAHJEE_B = 4'd6, M_MUSIC = 4'd7, M_MULTI = 4'd8, M_MEGA = 4'd9;

  // rom[offset % size] for offset < C000 without a divider: images of 24 KB
  // and more are at least half of the window, so one subtraction does it;
  // smaller ones are powers of two in practice.
  wire [23:0] off = {8'd0, a};
  logic [23:0] pow2_mask;
  always_comb begin
    pow2_mask = 24'hFFFFFF;
    for (int i = 23; i >= 0; i--) if (rom_size <= (24'd1 << i)) pow2_mask = (24'd1 << i) - 24'd1;
  end
  wire [23:0] rom_off = (rom_size >= 24'h006000) ? ((off < rom_size) ? off : off - rom_size)
                                                 : (off & pow2_mask);

  // Multicart / megacart block (32 KB pages)
  reg [6:0] block = 7'h7F;
  always @(posedge clk) begin
    if (reset) block <= 7'h7F;
    else if (io_wr && a[7:5] == 3'b111) begin
      if (mapper == M_MULTI) block <= d_i[7] ? {1'b0, d_i[6], d_i[4:0]} : 7'h3F;
      if (mapper == M_MEGA)  block <= {d_i[7:6], d_i[4:0]};
    end
  end
  wire is_multi = mapper == M_MULTI || mapper == M_MEGA;
  wire [23:0] multi_off = {2'b00, block, a[14:0]} & pow2_mask;

  // Cartridge RAM (32 KB, BRAM)
  reg  [7:0]  cram [0:32767];
  reg  [7:0]  cram_q;
  logic [14:0] cram_a;
  logic        cram_hit;
  wire         hi = a[15:14] == 2'b11;
  always_comb begin
    cram_hit = 1'b0;
    cram_a   = 15'd0;
    case (mapper)
      M_LEVEL3, M_MULTI, M_MEGA: begin cram_hit = a[15]; cram_a = {a[14], a[13:0]}; end
      M_CASTLE:   begin cram_hit = a[15:13] == 3'b100; cram_a = {2'b00, a[12:0]}; end
      M_OTHELLO:  begin cram_hit = a[15:13] == 3'b100; cram_a = {4'b0000, a[10:0]}; end
      M_DAHJEE_A: begin
        if (a[15:13] == 3'b001) begin cram_hit = 1'b1; cram_a = {2'b00, a[12:0]}; end
        if (hi)                 begin cram_hit = 1'b1; cram_a = {5'b00100, a[9:0]}; end
      end
      M_DAHJEE_B: begin cram_hit = hi; cram_a = {2'b00, a[12:0]}; end
      M_MUSIC: begin
        if (a[15:13] == 3'b100) begin cram_hit = 1'b1; cram_a = {2'b00, a[12:0]}; end
        if (hi)                 begin cram_hit = 1'b1; cram_a = {4'b0100, a[10:0]}; end
      end
      default: ;
    endcase
  end
  always @(posedge clk) begin
    if (cram_hit & wr) cram[cram_a] <= d_i;
    cram_q <= cram[cram_a];
  end

  assign ram_sel = (mapper == M_LEVEL3) || (mapper == M_DAHJEE_A) || (mapper == M_DAHJEE_B) ||
                   (mapper == M_MUSIC) || is_multi;
  assign rom_rd  = rd & ~cram_hit & ~hi & (rom_size != 24'd0) &
                   ~(mapper == M_TEREBI && (a == 16'h8000 || a == 16'hA000));

  // Terebi Oekaki
  reg [7:0] tv_data = 8'd0;
  always @(posedge clk) begin
    if (mapper == M_TEREBI && wr && a == 16'h6000)
      tv_data <= d_i[0] ? ((tab_x < 8'd4) ? 8'd4 : (tab_x > 8'd251) ? 8'd251 : tab_x) : tab_y + 8'h20;
  end

  reg cram_hit_q;
  reg [1:0] tv_rd_q;
  always @(posedge clk) begin
    cram_hit_q <= cram_hit;
    tv_rd_q    <= {mapper == M_TEREBI && a == 16'hA000, mapper == M_TEREBI && a == 16'h8000};
  end

  always_comb begin
    rom_addr = is_multi ? multi_off : rom_off;
    if (rom_size == 24'd0)       d_o = 8'hFF;
    else if (cram_hit_q)         d_o = cram_q;
    else if (tv_rd_q[0])         d_o = {7'd0, ~tab_pen};
    else if (tv_rd_q[1])         d_o = tv_data;
    else if (hi)                 d_o = 8'hFF;
    else                         d_o = rom_data;
  end

endmodule
