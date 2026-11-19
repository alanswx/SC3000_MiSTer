//============================================================================
//  Sega SC-3000 / SG-1000 for MiSTer
//
//  Machine: rtl/sc3000.sv (shared with the Verilator sim in verilator/).
//  Clocks:  clk_sys 42.954545 MHz (rtl/pll), VDP 10.738635 MHz (/4),
//           Z80 + PSG 3.579545 MHz (/12), pixels 5.369 MHz (/8).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = 0;

assign LED_POWER     = 0;
assign BUTTONS       = 0;
assign VGA_SCALER    = 0;
assign VGA_DISABLE   = 0;
assign HDMI_FREEZE   = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

wire [127:0] status;
reg  [127:0] cfg = 0;          // machine settings, latched at reset (osd-standard rule 1)

`include "build_id.v"
// OSD after ~/dev2/osd-standard.md and video-standard.md.
//   live:  1-2 Aspect ratio, 7-9 Scandoubler Fx, 10-11 Scale, 3 Joysticks swap,
//          19 Tape audio, 22 Keyboard, 24 Tape overlay, 23 Tape speed (taken
//          when the deck starts, tape-standard rule 1), buttons 18 Eject
//          cartridge, 17 Rewind tape
//   reset: 6 Border, 12 Model, 13 Video standard, 16:14 Mapper, 21:20 SF-7000 (cfg)
// Media: F1 cartridge, F2 tape (SDRAM ch1), S1 Tape save (.bit recorder),
// S0 SF-7000 disk (.sf7), F0 Load ROM
// = the SF-7000 IPL (games/SC3000/boot0.rom = MAME sf7000 ipl.rom).
parameter CONF_STR = {
	"SC3000;;",
	"-;",
	"F1,SG SC BINROM,Cartridge;",
	"F2,WAVBIT,Tape;",
	"S1,BIT,Tape save;",
	"S0,SF7,SF-7000 disk;",
	"F0,ROM,Load ROM;",
	"-;",
	"P1,Machine;",
	"P2,Video;",
	"P3,Input;",
	"P4,Audio;",
	"-;",
	"h0-,Changes pending;",
	"R[0],Apply and reset;",

	"P1O[26:25],Model,SC-3000,SG-1000,Othello Multivision;",
	"P1O[16:14],Mapper,Auto,ROM,BASIC Level 3,The Castle,Othello/BASIC 2,Terebi Oekaki,Dahjee A,Dahjee B;",
	"H1P1O[21:20],SF-7000,Auto,On,Off;",
	"h1P1-;",
	"P1-;",
	"P1O[23],Tape speed,4x,Normal;",
	"P1T[17],Rewind tape;",
	"P1T[18],Eject cartridge;",

	"P2O[13],Video standard,NTSC,PAL;",
	"P2O[6],Border,No,Yes;",
	"P2-;",
	"P2O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P2O[11:10],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"P2O[9:7],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P2-;",
	"P2O[24],Tape overlay,On,Off;",

	"P3O[22],Keyboard,PC,SC-3000;",
	"P3O[3],Joysticks swap,No,Yes;",

	"P4O[19],Tape audio,Off,On;",

	"J1,Button 1,Button 2,Pause;",
	"jn,A,B,Start;",
	"v,1;",
	"V,v",`BUILD_DATE
};

/////////////////  CLOCKS  ////////////////////////

wire clk_sys;
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked)
);

wire ce_10m7, ce_5m37, ce_psg, ce_cpu_p, ce_cpu_n, turbo_active;
wire turbo_req;
sc3000_clocks clocks
(
	.clk(clk_sys),
	.turbo_req(turbo_req),
	.ce_10m7(ce_10m7),
	.ce_5m37(ce_5m37),
	.ce_psg(ce_psg),
	.ce_cpu_p(ce_cpu_p),
	.ce_cpu_n(ce_cpu_n),
	.turbo(turbo_active)
);

/////////////////  HPS  ///////////////////////////

wire  [1:0] buttons;
wire [31:0] joy0, joy1;
wire        ioctl_download;
wire  [7:0] ioctl_index;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wait;
wire        forced_scandoubler;
wire [21:0] gamma_bus;
wire [10:0] ps2_key;
wire [24:0] ps2_mouse;

// Virtual disks: 0 = SF-7000 disk, 1 = Tape save
wire  [1:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;
wire [31:0] sd_lba[2];
wire  [1:0] sd_rd, sd_wr, sd_ack;
wire  [8:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire  [7:0] sd_buff_din[2];
wire        sd_buff_wr;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.buttons(buttons),
	.status(status),
	.status_menumask({14'd0, ~ipl_loaded | (status[26:25] != 2'd0), pending}),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_blk_cnt('{6'd0, 6'd0}),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),

	.joystick_0(joy0),
	.joystick_1(joy1)
);

wire ioctl_isCART = ioctl_index[5:0] == 6'd1;
wire cart_dl      = ioctl_download & ioctl_isCART;
wire tape_dl      = ioctl_download & (ioctl_index[5:0] == 6'd2);
// Load ROM (index 0, boot0.rom) is the ROM of the model chosen: the SF-7000 IPL,
// or the Othello Multivision BIOS; boot1.rom (index 40h) is always the OMV BIOS
wire model_omv_sel = status[26:25] == 2'd2;
wire ipl_dl       = ioctl_download & (ioctl_index == 8'd0) & ~model_omv_sel;
wire bios_dl      = ioctl_download & ((ioctl_index == 8'h40) | ((ioctl_index == 8'd0) & model_omv_sel));

reg  ipl_loaded = 0;
always @(posedge clk_sys) if (ipl_dl & ioctl_wr) ipl_loaded <= 1;

// SF-7000 disk mounted (S0)
reg  disk_in = 0;
always @(posedge clk_sys) if (img_mounted[0]) disk_in <= |img_size;

/////////////////  RESET  /////////////////////////

reg  eject_r = 0;
always @(posedge clk_sys) eject_r <= status[18];
wire cart_eject = status[18] & ~eject_r;

// SF-7000 Auto: mounting a disk attaches the unit (a media change: resets at once)
reg  disk_reset = 0;
always @(posedge clk_sys) disk_reset <= img_mounted[0] & |img_size & (status[21:20] == 2'd0) & ~sf7000_on;

wire reset = RESET | status[0] | buttons[1] | cart_dl | ipl_dl | bios_dl | status[18] | disk_reset | ~pll_locked;

always @(posedge clk_sys) if (reset) cfg <= status;
wire pending = {status[26:25], status[21:20], status[16:13], status[6]} != {cfg[26:25], cfg[21:20], cfg[16:13], cfg[6]};

wire       model_sg1000 = cfg[26:25] == 2'd1;
wire       model_omv    = cfg[26:25] == 2'd2;
// SF-7000 (cfg[21:20]: 0 Auto = when a disk is mounted, 1 On, 2 Off); needs the IPL
reg  sf7000_on = 0;
always @(posedge clk_sys) if (reset) sf7000_on <= ipl_loaded & (status[26:25] == 2'd0) &
	((status[21:20] == 2'd1) | ((status[21:20] == 2'd0) & (disk_in | (img_mounted[0] & |img_size))));
wire       pal          = cfg[13];
// OSD Mapper: 0 Auto, 1 ROM, 2 Level 3, 3 Castle, 4 Othello -> sc3000_cart numbering
wire [3:0] mapper_osd   = (cfg[16:14] == 3'd0) ? 4'd15 : {1'b0, cfg[16:14] - 3'd1};

wire fdd_motor;
assign LED_USER = ioctl_download | tape_motor;
assign LED_DISK = {1'b0, fdd_motor};

/////////////////  TABLET  ////////////////////////

// Terebi Oekaki: the PS/2 mouse moves the pen (X 0-255, Y 0-191), left button = pen down
reg  [7:0] tab_x = 8'd128, tab_y = 8'd96;
reg        tab_pen = 0;
always @(posedge clk_sys) begin
	reg old_stb;
	reg signed [9:0] nx, ny;
	old_stb <= ps2_mouse[24];
	if (old_stb != ps2_mouse[24]) begin
		nx = $signed({2'b00, tab_x}) + $signed({{2{ps2_mouse[4]}}, ps2_mouse[15:8]});
		ny = $signed({2'b00, tab_y}) - $signed({{2{ps2_mouse[5]}}, ps2_mouse[23:16]});
		tab_x   <= (nx < 0) ? 8'd0 : (nx > 255) ? 8'd255 : nx[7:0];
		tab_y   <= (ny < 0) ? 8'd0 : (ny > 191) ? 8'd191 : ny[7:0];
		tab_pen <= ps2_mouse[0];
	end
end

/////////////////  CARTRIDGE  /////////////////////

// Mapper detection on the download (CRC32 table from MAME's lists + MAME's
// string rules); the OSD Mapper row overrides it.
wire  [3:0] det_mapper;
wire [24:0] det_size;
sc3000_detect detect
(
	.clk(clk_sys),
	.dl_busy(cart_dl),
	.dl_wr(ioctl_wr),
	.dl_addr(ioctl_addr),
	.dl_data(ioctl_dout),
	.mapper(det_mapper),
	.size(det_size),
	.crc_out()
);

reg cart_in = 0;     // a cartridge is in the slot
always @(posedge clk_sys) begin
	if (cart_dl) cart_in <= 1;
	if (cart_eject) cart_in <= 0;
end

wire  [3:0] mapper    = (mapper_osd == 4'd15) ? det_mapper : mapper_osd;
wire [23:0] cart_size = ~cart_in ? 24'd0 : det_size[24] ? 24'hFFFFFF : det_size[23:0];

wire [15:0] cart_a;
wire        cart_rd, cart_wr, cart_ram_sel;
wire  [7:0] cart_do, cart_di;
wire  [7:0] rom_cart_di, sf_mem_q, sf_io_q;
wire        rom_cart_ram_sel, sf_ram_sel, sf_io_en, ext_io_rd, ext_io_wr;
assign cart_di      = sf7000_on ? sf_mem_q   : rom_cart_di;
assign cart_ram_sel = sf7000_on ? sf_ram_sel : rom_cart_ram_sel;
wire [23:0] rom_addr;
wire        rom_rd;
wire  [7:0] rom_q;
wire        rom_ready;

sc3000_cart cart
(
	.clk(clk_sys),
	.reset(reset),
	.mapper(mapper),
	.rom_size(sf7000_on ? 24'd0 : cart_size),
	.a(cart_a),
	.rd(cart_rd),
	.wr(cart_wr & ~sf7000_on),
	.d_i(cart_do),
	.d_o(rom_cart_di),
	.ram_sel(rom_cart_ram_sel),
	.io_wr(ext_io_wr & ~sf7000_on),
	.tab_x(tab_x),
	.tab_y(tab_y),
	.tab_pen(tab_pen),
	.rom_addr(rom_addr),
	.rom_rd(rom_rd),
	.rom_data(rom_q)
);

/////////////////  SF-7000  ///////////////////////

sf7000 sf7000
(
	.clk(clk_sys),
	.reset(reset),
	.enable(sf7000_on),
	.rom_wr(ipl_dl & ioctl_wr),
	.rom_addr(ioctl_addr[12:0]),
	.rom_data(ioctl_dout),
	.a(cart_a),
	.mem_rd(cart_rd),
	.mem_wr(cart_wr),
	.d_i(cart_do),
	.mem_d_o(sf_mem_q),
	.ram_sel(sf_ram_sel),
	.io_rd(ext_io_rd),
	.io_wr(ext_io_wr),
	.io_en(sf_io_en),
	.io_d_o(sf_io_q),
	.img_mounted(img_mounted[0]),
	.img_readonly(img_readonly),
	.img_size(img_size[31:0]),
	.sd_lba(sd_lba[0]),
	.sd_rd(sd_rd[0]),
	.sd_wr(sd_wr[0]),
	.sd_ack(sd_ack[0]),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din[0]),
	.sd_buff_wr(sd_buff_wr),
	.motor_led(fdd_motor)
);

/////////////////  TAPE  //////////////////////////

// Image in SDRAM from 16 MB up (ch1); the deck runs while the program polls
// PB7 (sc3000_tape_motor.sv: the SC-3000 has no motor line).
reg  [24:0] tape_size = 0;
always @(posedge clk_sys) if (tape_dl & ioctl_wr) tape_size <= ioctl_addr + 25'd1;
wire        tape_poll, tape_motor, tape_level, tape_out, tape_ended, ppi_wr;
wire        tape_sec_tick, tape_total_ok;
wire [15:0] tape_total_sec;
wire [24:0] tape_pos, tape_data_start, tape_data_end;
wire        tape_loaded = |tape_size & ~tape_dl;
// Tape speed (status[23]: 0 = 4x) is taken when the deck starts
reg  turbo_sel = 0, motor_r = 0;
always @(posedge clk_sys) begin
	motor_r <= tape_motor;
	if (tape_motor & ~motor_r) turbo_sel <= ~status[23];
end
wire deck_plays = tape_motor & tape_loaded & ~tape_ended;
assign turbo_req = turbo_sel & deck_plays;
wire [24:0] tape_a;
wire        tape_rd;
wire  [7:0] tape_q;
wire        tape_ready;
sc3000_tape_motor tape_motor_det
(
	.clk(clk_sys),
	.reset(reset | status[17] | tape_dl),
	.ce(ce_cpu_p),
	.poll(tape_poll & tape_loaded & ~tape_ended),
	.ppi_wr(ppi_wr),
	.motor(tape_motor)
);
sc3000_tape tape
(
	.clk(clk_sys),
	.reset(status[17] | tape_dl),
	.ce(ce_cpu_p),
	.play(tape_motor),
	.size(tape_dl ? 25'd0 : tape_size),
	.mem_addr(tape_a),
	.mem_rd(tape_rd),
	.mem_data(tape_q),
	.mem_ready(tape_ready),
	.level(tape_level),
	.ended(tape_ended),
	.position(tape_pos),
	.data_end(tape_data_end),
	.data_start(tape_data_start),
	.sec_tick(tape_sec_tick),
	.total_sec(tape_total_sec),
	.total_ok(tape_total_ok)
);

// Tape save: what SAVE writes on PC4 goes to a .bit file (sc3000_tape_rec.sv)
wire rec_active;
assign sd_rd[1] = 1'b0;
sc3000_tape_rec tape_rec
(
	.clk(clk_sys),
	.ce_cpu(ce_cpu_p),
	.tape_out(tape_out),
	.img_mounted(img_mounted[1]),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba[1]),
	.sd_wr(sd_wr[1]),
	.sd_ack(sd_ack[1]),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_din(sd_buff_din[1]),
	.active(rec_active),
	.recording(),
	.full(),
	.length()
);

wire [223:0] tape_status_word;
wire         tape_status_req, tape_status_ack;
sc3000_tape_status tape_status
(
	.clk(clk_sys),
	.rewind(status[17] | tape_dl),
	.loaded(tape_loaded),
	.playing(deck_plays),
	.fast(turbo_active),
	.sec_tick(tape_sec_tick),
	.total_sec(tape_total_sec),
	.total_ok(tape_total_ok),
	.position(tape_pos),
	.data_start(tape_data_start),
	.data_end(tape_data_end),
	.status(tape_status_word),
	.req(tape_status_req),
	.ack(tape_status_ack)
);

/////////////////  CARTRIDGE BRAM  ////////////////

// Cartridges up to 64 KB also live in block RAM and are read from there: the
// SDRAM's miss latency (about 7 clk_sys) is less than a Z80 T-state at 1x
// (12) but not at turbo 4x (3), and wait states there would upset the tape
// loaders' timing loops (BASIC runs from the cartridge). Bigger images
// (multicarts) are read from SDRAM.
reg  [7:0] cart_bram[65536];
reg  [7:0] cart_bram_q;
always @(posedge clk_sys) begin
	if (cart_dl & ioctl_wr & ~|ioctl_addr[24:16]) cart_bram[ioctl_addr[15:0]] <= ioctl_dout;
	cart_bram_q <= cart_bram[rom_addr[15:0]];
end
wire cart_small = ~|cart_size[23:17] & ~(cart_size[16] & |cart_size[15:0]);   // <= 64 KB
wire [7:0] rom_q_sd;
assign rom_q = cart_small ? cart_bram_q : rom_q_sd;

/////////////////  SDRAM  /////////////////////////

assign SDRAM_CLK = ~clk_sys;

sdram sdram
(
	.*,
	.init(~pll_locked),
	.clk(clk_sys),

	// ch0: the cartridge image, and the download that fills it
	.ch0_addr(cart_dl ? ioctl_addr : {1'b0, rom_addr}),
	.ch0_rd(rom_rd & ~cart_dl & ~cart_small),
	.ch0_wr(ioctl_wr & cart_dl),
	.ch0_din(ioctl_dout),
	.ch0_dout(rom_q_sd),
	.ch0_ready(rom_ready),

	// ch1: the tape image, from 16 MB
	.ch1_addr({1'b1, tape_dl ? ioctl_addr[23:0] : tape_a[23:0]}),
	.ch1_rd(tape_rd & ~tape_dl),
	.ch1_wr(ioctl_wr & tape_dl),
	.ch1_din(ioctl_dout),
	.ch1_dout(tape_q),
	.ch1_ready(tape_ready)
);

assign ioctl_wait = (cart_dl & ~rom_ready) | (tape_dl & ~tape_ready);

/////////////////  VRAM  //////////////////////////

wire [13:0] vram_a;
wire        vram_we;
wire  [7:0] vram_do;
reg   [7:0] vram_di;
reg   [7:0] vram[16384];
always @(posedge clk_sys) begin
	if (vram_we) vram[vram_a] <= vram_do;
	vram_di <= vram[vram_a];
end

/////////////////  INPUT  /////////////////////////

wire [31:0] joya = status[3] ? joy1 : joy0;
wire [31:0] joyb = status[3] ? joy0 : joy1;
// HPS {.., Pause 6, B2 5, B1 4, up 3, down 2, left 1, right 0}
// -> machine {TR, TL, right, left, down, up}, active low
wire [5:0] joy1_n = ~{joya[5], joya[4], joya[0], joya[1], joya[2], joya[3]};
wire [5:0] joy2_n = ~{joyb[5], joyb[4], joyb[0], joyb[1], joyb[2], joyb[3]};

wire  [2:0] kbd_row;
wire [11:0] kbd_keys;
sc3000_keyboard keyboard
(
	.clk_sys(clk_sys),
	.reset(reset),
	.pc_layout(~status[22]),
	.row_sel(kbd_row),
	.ps2_key(ps2_key),
	.row_data(kbd_keys)
);

// SC-3000 RESET key / SG-1000 PAUSE button -> Z80 NMI: F10 (as MAME) or a pad's Start
reg f10 = 0;
always @(posedge clk_sys) begin
	reg old_stb;
	old_stb <= ps2_key[10];
	if (old_stb != ps2_key[10] && ps2_key[8:0] == 9'h009) f10 <= ps2_key[9];
end
wire nmi_key = (f10 | joya[6] | joyb[6]) & ~model_omv;   // the OMV has no PAUSE

// Othello Multivision keypad: 1-9, 0, A-H
wire [17:0] omv_keys;
omv_keypad omv_keypad
(
	.clk(clk_sys),
	.reset(reset),
	.ps2_key(ps2_key),
	.keys(omv_keys)
);

/////////////////  MACHINE  ///////////////////////

wire  [7:0] R, G, B;
wire        hsync_n, vsync_n, hblank, vblank;
wire signed [10:0] audio;

sc3000 machine
(
	.clk(clk_sys),
	.reset(reset),
	.ce_10m7(ce_10m7),
	.ce_cpu_p(ce_cpu_p),
	.ce_cpu_n(ce_cpu_n),
	.ce_psg(ce_psg),
	.turbo(turbo_active),

	.model_sg1000(model_sg1000),
	.model_omv(model_omv),
	.cart_in(cart_in),
	.bios_wr(bios_dl & ioctl_wr),
	.bios_addr(ioctl_addr[13:0]),
	.bios_data(ioctl_dout),
	.omv_keys(omv_keys),
	.pal(pal),
	.border(cfg[6]),

	.cart_a(cart_a),
	.cart_rd(cart_rd),
	.cart_wr(cart_wr),
	.cart_do(cart_do),
	.cart_di(cart_di),
	.cart_ram_sel_i(cart_ram_sel),
	.wait_n(~(rom_rd & ~rom_ready & ~sf7000_on & ~cart_small)),
	.cart_m1(),

	.ext_iorq(),
	.ext_io_rd(ext_io_rd),
	.ext_io_wr(ext_io_wr),
	.ext_io_en(sf_io_en),
	.ext_io_di(sf_io_q),

	.kbd_row(kbd_row),
	.kbd_pa(kbd_keys[7:0]),
	.kbd_pb(kbd_keys[11:8]),
	.joy1_n(joy1_n),
	.joy2_n(joy2_n),
	.nmi_key(nmi_key),

	.tape_in(tape_level),
	.tape_out(tape_out),
	.tape_poll(tape_poll),
	.ppi_wr(ppi_wr),
	.printer_busy(1'b0),
	.printer_fault_n(1'b1),

	.vram_a(vram_a),
	.vram_we(vram_we),
	.vram_do(vram_do),
	.vram_di(vram_di),

	.rgb_r(R),
	.rgb_g(G),
	.rgb_b(B),
	.hsync_n(hsync_n),
	.vsync_n(vsync_n),
	.hblank(hblank),
	.vblank(vblank),

	.audio(audio),

	.dbg_a(), .dbg_di(), .dbg_do(), .dbg_m1_n(), .dbg_mreq_n(), .dbg_iorq_n(),
	.dbg_rd_n(), .dbg_wr_n(), .dbg_rfsh_n(), .dbg_halt_n(), .dbg_int_n(),
	.dbg_ppi_pc(), .dbg_reg()
);

/////////////////  AUDIO  /////////////////////////

// Tape audio (P4): the tape signal mixed in quietly, as a deck's speaker would
wire signed [15:0] tape_snd = status[19] ? ((tape_level ^ tape_out) ? 16'sd2048 : -16'sd2048) : 16'sd0;
wire signed [15:0] mix = {audio, 5'd0} + tape_snd;
assign AUDIO_L   = mix;
assign AUDIO_R   = mix;
assign AUDIO_S   = 1;
assign AUDIO_MIX = 0;

/////////////////  VIDEO  /////////////////////////

assign CLK_VIDEO = clk_sys;
assign VGA_F1    = 0;

// Aspect ratio, Scale and Scandoubler Fx act at once (video-standard.md rule 3).
wire [2:0] sfx = status[9:7];
wire [2:0] sl3 = sfx - 3'd1;
wire [1:0] sl  = (sfx >= 3'd2 && sfx <= 3'd4) ? sl3[1:0] : 2'd0;
assign VGA_SL  = sl;

reg hs_o, vs_o;
always @(posedge CLK_VIDEO) begin
	hs_o <= ~hsync_n;
	if (~hs_o & ~hsync_n) vs_o <= ~vsync_n;
end

wire [23:0] ov_rgb;
sc3000_tape_overlay #(.FACTOR(4'd4)) tape_overlay
(
	.clk(CLK_VIDEO),
	.ce_pix(ce_5m37),
	.hblank(hblank),
	.vblank(vblank),
	.enable(~status[24]),
	.status(tape_status_word),
	.req(tape_status_req),
	.ack(tape_status_ack),
	.rgb_in({R, G, B}),
	.rgb_out(ov_rgb)
);

wire vga_de;
wire freeze_sync;
video_mixer #(.LINE_LENGTH(400), .GAMMA(1)) video_mixer
(
	.*,
	.ce_pix(ce_5m37),
	.scandoubler((sfx != 3'd0) || forced_scandoubler),
	.hq2x(sfx == 3'd1),
	.VGA_DE(vga_de),
	.R(ov_rgb[23:16]),
	.G(ov_rgb[15:8]),
	.B(ov_rgb[7:0]),
	.HSync(hs_o),
	.VSync(vs_o),
	.HBlank(hblank),
	.VBlank(vblank)
);

// Original aspect ratio: same VDP and pixel clock as the SVI-328 core, whose
// values were measured on hardware (video-standard.md "Sizes"):
//   NTSC 256x192 32:21, NTSC border 2272:1687, PAL 3932:2147, PAL border 3969:2971
wire [1:0] ar = status[2:1];
reg [11:0] orig_x, orig_y;
always @(posedge CLK_VIDEO) begin
	if      (~pal & ~cfg[6]) {orig_x, orig_y} <= {12'd32,   12'd21};
	else if (~pal)           {orig_x, orig_y} <= {12'd2272, 12'd1687};
	else if (~cfg[6])        {orig_x, orig_y} <= {12'd3932, 12'd2147};
	else                     {orig_x, orig_y} <= {12'd3969, 12'd2971};
end

video_freak video_freak
(
	.*,
	.VGA_DE_IN(vga_de),
	.ARX((!ar) ? orig_x : {10'd0, ar - 2'd1}),
	.ARY((!ar) ? orig_y : 12'd0),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE({1'b0, status[11:10]})
);

endmodule
