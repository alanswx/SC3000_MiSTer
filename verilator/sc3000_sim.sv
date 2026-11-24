// Simulation top for the SC-3000 core: rtl/sc3000.sv + rtl/sc3000_cart.sv with
// the memories as plain arrays. No sys/, hps_io, SDRAM or video_mixer.
//
// Clocking (fast build): the sim clock is the 10.738635 MHz rate, ce_10m7 = 1,
// the Z80/PSG enables are /3 (cv_clock), pixel enable = /2 (5.37 MHz).

module sc3000_sim #(
  parameter CART_AW = 22,              // 4 MB cartridge image (megacart)
  parameter TAPE_AW = 24,              // 16 MB tape image (hardware: SDRAM)
  parameter FULL    = 0                // 1: clk = clk_sys (42.95 MHz) with SC3000.sv's enables and tape turbo
) (
  input               clk,
  input               reset,

  // preload (ioctl-like): index 1 = cartridge
  input               dl_busy,
  input               dl_wr,
  input        [7:0]  dl_index,
  input        [24:0] dl_addr,
  input        [7:0]  dl_data,
  input        [3:0]  mapper_osd,     // 15 = auto (sc3000_detect), else the mapper number
  output       [3:0]  mapper,
  output       [31:0] cart_crc,

  input               sf7000_on,
  // SD block device (hps_io shape) for the SF-7000 disk
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
  output              fdd_motor,
  // SF-7000 RS-232 (8251) and printer file (third SD device)
  input        [2:0]  baud,
  output              uart_txd,
  input               uart_rxd,
  input               prn_img_mounted,
  input        [31:0] prn_img_size,
  output       [31:0] prn_sd_lba,
  output              prn_sd_wr,
  input               prn_sd_ack,
  input        [8:0]  prn_sd_buff_addr,
  output       [7:0]  prn_sd_buff_din,
  output       [24:0] prn_length,
  output              prn_active,
  // second SD device: Tape save (.bit recorder)
  input               rec_img_mounted,
  input        [31:0] rec_img_size,
  output       [31:0] rec_sd_lba,
  output              rec_sd_wr,
  input               rec_sd_ack,
  input        [8:0]  rec_sd_buff_addr,
  output       [7:0]  rec_sd_buff_din,
  output       [24:0] rec_length,
  output              rec_active,

  input               model_sg1000,
  input               model_omv,       // Othello Multivision (BIOS = dl index 4)
  input        [17:0] omv_keys,
  input               pal,
  input               border,

  // keyboard matrix from the harness: bit (row*12 + col), 1 = pressed;
  // col 0-7 = PA0-7, 8-11 = PB0-3 (MAME sk1100.cpp PAn / PBn ports)
  input        [95:0] key_matrix,
  input               use_ps2,         // 1: the keyboard is rtl/sc3000_keyboard.sv fed with ps2_key
  input        [10:0] ps2_key,
  input        [5:0]  joy1,            // 1 = pressed {TR, TL, right, left, down, up}
  input        [5:0]  joy2,
  input               nmi_key,
  input        [7:0]  tab_x,           // Terebi Oekaki tablet
  input        [7:0]  tab_y,
  input               tab_pen,
  input               tape_rewind,
  input               tape_turbo,      // OSD Tape speed = 4x (FULL build)
  output              turbo_active,
  output              tape_out,
  output              tape_level,
  output              tape_motor,
  output              tape_ended,
  output       [24:0] tape_pos,

  output       [7:0]  R, G, B,
  output              HSync, VSync, HBlank, VBlank,
  output              ce_pix,
  output signed [10:0] audio,

  output       [15:0] cpu_a,
  output       [7:0]  cpu_di,
  output       [7:0]  cpu_do,
  output              cpu_m1_n,
  output              cpu_mreq_n,
  output              cpu_iorq_n,
  output              cpu_rd_n,
  output              cpu_wr_n,
  output              cpu_rfsh_n,
  output              cpu_halt_n,
  output              cpu_int_n,
  output              cpu_cen_p,
  output       [211:0] cpu_reg,
  output       [7:0]  ppi_pc
);

  // Clock enables -----------------------------------------------------------
  wire ce_cpu_p, ce_cpu_n, ce_psg, ce_10m7, ce_5m37;
  wire turbo_req;
  generate if (FULL) begin : g_full
    sc3000_clocks clocks (.clk(clk), .turbo_req(turbo_req), .ce_10m7(ce_10m7), .ce_5m37(ce_5m37),
                          .ce_psg(ce_psg), .ce_cpu_p(ce_cpu_p), .ce_cpu_n(ce_cpu_n), .turbo(turbo_active));
  end else begin : g_fast
    // clk = the 10.7 MHz rate: VDP every clock, Z80/PSG /3, pixels /2. No turbo.
    cv_clock clock_b (.clk_i(clk), .clk_en_10m7_i(1'b1), .reset_n_i(1'b1),
                      .clk_en_3m58_p_o(ce_cpu_p), .clk_en_3m58_n_o(ce_cpu_n));
    reg c2 = 1'b0;
    always @(posedge clk) c2 <= ~c2;
    assign ce_10m7 = 1'b1;
    assign ce_5m37 = c2;
    assign ce_psg  = ce_cpu_p;
    assign turbo_active = 1'b0;
  end endgenerate
  assign ce_pix    = ce_5m37;
  assign cpu_cen_p = ce_cpu_p;

  // Cartridge ROM (hardware: SDRAM) -----------------------------------------
  reg  [7:0] cart_rom [0:(1<<CART_AW)-1] /*verilator public*/;
  reg  [7:0] cart_rom_q;
  wire [23:0] rom_addr;
  always @(posedge clk) begin
    if (dl_wr && dl_index == 8'd1) cart_rom[dl_addr[CART_AW-1:0]] <= dl_data;
    cart_rom_q <= cart_rom[rom_addr[CART_AW-1:0]];
  end

  // Tape image (index 2) and player ----------------------------------------
  reg  [7:0]  tape_mem [0:(1<<TAPE_AW)-1] /*verilator public*/;
  reg  [24:0] tape_size = 25'd0;
  reg  [7:0]  tape_q;
  wire [24:0] tape_a;
  wire        tape_rd;
  always @(posedge clk) begin
    if (dl_wr && dl_index == 8'd2) begin
      tape_mem[dl_addr[TAPE_AW-1:0]] <= dl_data;
      tape_size <= dl_addr + 25'd1;
    end
    tape_q <= tape_mem[tape_a[TAPE_AW-1:0]];
  end
  wire tape_poll, ppi_wr;
  wire tape_loaded = tape_size != 0 && !(dl_busy && dl_index == 8'd2);
  sc3000_tape_motor motor (.clk(clk), .reset(reset | tape_rewind), .ce(ce_cpu_p),
                           .poll(tape_poll & tape_loaded & ~tape_ended), .ppi_wr(ppi_wr), .motor(tape_motor));
  reg turbo_sel = 1'b0, motor_r = 1'b0;
  always @(posedge clk) begin
    motor_r <= tape_motor;
    if (tape_motor & ~motor_r) turbo_sel <= tape_turbo;
  end
  assign turbo_req = turbo_sel & tape_motor & tape_loaded & ~tape_ended;
  sc3000_tape tape (.clk(clk), .reset(tape_rewind | (dl_busy && dl_index == 8'd2)), .ce(ce_cpu_p), .play(tape_motor),
                    .size(dl_busy && dl_index == 8'd2 ? 25'd0 : tape_size),
                    .mem_addr(tape_a), .mem_rd(tape_rd), .mem_data(tape_q), .mem_ready(1'b1),
                    .level(tape_level), .ended(tape_ended), .position(tape_pos), .data_end(),
                    .data_start(), .sec_tick(), .total_sec(), .total_ok());

  sc3000_tape_rec tape_rec (.clk(clk), .ce_cpu(ce_cpu_p), .tape_out(tape_out),
    .img_mounted(rec_img_mounted), .img_readonly(1'b0), .img_size({32'd0, rec_img_size}),
    .sd_lba(rec_sd_lba), .sd_wr(rec_sd_wr), .sd_ack(rec_sd_ack), .sd_buff_addr(rec_sd_buff_addr),
    .sd_buff_din(rec_sd_buff_din), .active(rec_active), .recording(), .full(), .length(rec_length));

  // Mapper detection -------------------------------------------------------
  wire [3:0]  det_mapper;
  wire [24:0] det_size;
  sc3000_detect detect (.clk(clk), .dl_busy(dl_busy && dl_index == 8'd1), .dl_wr(dl_wr),
                        .dl_addr(dl_addr), .dl_data(dl_data),
                        .mapper(det_mapper), .size(det_size), .crc_out(cart_crc));
  assign mapper = (mapper_osd == 4'd15) ? det_mapper : mapper_osd;
  wire [23:0] cart_size = det_size[24] ? 24'hFFFFFF : det_size[23:0];

  // VRAM --------------------------------------------------------------------
  reg  [7:0] vram [0:16383] /*verilator public*/;
  reg  [7:0] vram_q;
  wire [13:0] vram_a;
  wire        vram_we;
  wire [7:0]  vram_do;
  always @(posedge clk) begin
    if (vram_we) vram[vram_a] <= vram_do;
    vram_q <= vram[vram_a];
  end

  // Keyboard matrix ---------------------------------------------------------
  wire [2:0]  kbd_row;
  wire [11:0] ps2_row_n;
  sc3000_keyboard #(.CLK_HZ(FULL ? 42954545 : 10738635)) keyboard (
    .clk_sys(clk), .reset(reset), .pc_layout(1'b1), .row_sel(kbd_row), .ps2_key(ps2_key), .row_data(ps2_row_n));
  wire [11:0] row_keys = use_ps2 ? ~ps2_row_n : key_matrix[kbd_row*12 +: 12];

  // Machine -----------------------------------------------------------------
  wire        hs_n, vs_n;
  wire [15:0] cart_a;
  wire        cart_rd, cart_wr, cart_ram_sel;
  wire [7:0]  cart_do, cart_di;

  wire [7:0] rom_cart_di, sf_mem_q, sf_io_q;
  wire       rom_cart_ram_sel, sf_ram_sel, sf_io_en, ext_io_rd, ext_io_wr;
  assign cart_di      = sf7000_on ? sf_mem_q : rom_cart_di;
  assign cart_ram_sel = sf7000_on ? sf_ram_sel : rom_cart_ram_sel;

  sf7000 #(.CLK_HZ(FULL ? 42954545 : 10738635)) sf7000 (
    .clk(clk), .reset(reset), .enable(sf7000_on),
    .rom_wr(dl_wr && dl_index == 8'd3), .rom_addr(dl_addr[12:0]), .rom_data(dl_data),
    .a(cart_a), .mem_rd(cart_rd), .mem_wr(cart_wr), .d_i(cart_do), .mem_d_o(sf_mem_q), .ram_sel(sf_ram_sel),
    .io_rd(ext_io_rd), .io_wr(ext_io_wr), .io_en(sf_io_en), .io_d_o(sf_io_q),
    .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
    .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
    .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
    .baud(baud), .uart_txd(uart_txd), .uart_rxd(uart_rxd), .uart_cts_n(1'b0), .uart_dsr_n(1'b0),
    .uart_rts_n(), .uart_dtr_n(),
    .prn_img_mounted(prn_img_mounted), .prn_img_readonly(1'b0), .prn_img_size({32'd0, prn_img_size}),
    .prn_sd_lba(prn_sd_lba), .prn_sd_wr(prn_sd_wr), .prn_sd_ack(prn_sd_ack), .prn_sd_buff_addr(prn_sd_buff_addr),
    .prn_sd_buff_din(prn_sd_buff_din), .prn_active(prn_active), .prn_length(prn_length),
    .motor_led(fdd_motor));

  sc3000_cart cart (
    .clk(clk), .reset(reset), .mapper(mapper), .rom_size(sf7000_on ? 24'd0 : cart_size),
    .a(cart_a), .rd(cart_rd), .wr(cart_wr & ~sf7000_on), .d_i(cart_do), .d_o(rom_cart_di),
    .ram_sel(rom_cart_ram_sel), .io_wr(ext_io_wr & ~sf7000_on),
    .tab_x(tab_x), .tab_y(tab_y), .tab_pen(tab_pen), .rom_addr(rom_addr), .rom_rd(), .rom_data(cart_rom_q));

  sc3000 machine (
    .clk(clk), .reset(reset), .ce_10m7(ce_10m7), .ce_cpu_p(ce_cpu_p), .ce_cpu_n(ce_cpu_n),
    .ce_psg(ce_psg), .turbo(turbo_active),
    .model_sg1000(model_sg1000), .model_omv(model_omv), .cart_in(cart_size != 24'd0),
    .bios_wr(dl_wr && dl_index == 8'd4), .bios_addr(dl_addr[13:0]), .bios_data(dl_data), .omv_keys(omv_keys),
    .pal(pal), .border(border),
    .cart_a(cart_a), .cart_rd(cart_rd), .cart_wr(cart_wr), .cart_do(cart_do), .cart_di(cart_di),
    .cart_ram_sel_i(cart_ram_sel), .wait_n(1'b1), .cart_m1(),
    .ext_iorq(), .ext_io_rd(ext_io_rd), .ext_io_wr(ext_io_wr), .ext_io_en(sf_io_en), .ext_io_di(sf_io_q),
    .kbd_row(kbd_row), .kbd_pa(~row_keys[7:0]), .kbd_pb(~row_keys[11:8]),
    .joy1_n(~joy1), .joy2_n(~joy2), .nmi_key(nmi_key),
    .tape_in(tape_level), .tape_out(tape_out), .tape_poll(tape_poll), .ppi_wr(ppi_wr), .printer_busy(1'b0), .printer_fault_n(1'b1),
    .vram_a(vram_a), .vram_we(vram_we), .vram_do(vram_do), .vram_di(vram_q),
    .rgb_r(R), .rgb_g(G), .rgb_b(B),
    .hsync_n(hs_n), .vsync_n(vs_n), .hblank(HBlank), .vblank(VBlank),
    .audio(audio),
    .dbg_a(cpu_a), .dbg_di(cpu_di), .dbg_do(cpu_do), .dbg_m1_n(cpu_m1_n), .dbg_mreq_n(cpu_mreq_n),
    .dbg_iorq_n(cpu_iorq_n), .dbg_rd_n(cpu_rd_n), .dbg_wr_n(cpu_wr_n), .dbg_rfsh_n(cpu_rfsh_n),
    .dbg_halt_n(cpu_halt_n), .dbg_int_n(cpu_int_n), .dbg_ppi_pc(ppi_pc), .dbg_reg(cpu_reg));

  // sync outputs active high for the harness
  assign HSync = ~hs_n;
  assign VSync = ~vs_n;

endmodule
