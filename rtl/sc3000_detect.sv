//-----------------------------------------------------------------------------
// Cartridge mapper detection while the image downloads (ioctl stream).
//
// 1. CRC32 of the whole image against the MAME hash lists (sc3000_cart_db.vh,
//    tools/gen_cart_db.py): every listed cart with a non-plain slot type.
// 2. Otherwise MAME's heuristics (sega8_slot.cpp get_cart_type), the ones that
//    apply to SG-1000 / SC-3000 carts:
//      "ASCII 1986" at 1CC3                      -> castle
//      "SC-3000 BASIC Level 3 ver 1" at 6A20     -> level3
//      "SC-3000 BASIC Level 2 ver" at 6543       -> othello (2 KB at 8000; MAME
//                                                   only knows it from the list)
//      "annakmn" at 13B3                          -> terebi
//      "PIANO" / "music" at 0841                  -> music_editor
//      size 2 MB / 4 MB                           -> multicart / megacart
//    and one of our own: an image over 64 KB that nothing else claims can't run
//    as plain ROM, so it gets the Sega 315-5208 page register at FFFF
//    (Loretta no Shouzou; SMS-style images with an SG-1000 mode)
// The Dahjee RAM-expansion heuristic (LD (2xxx/Dxxx),A counts) is not done:
// every known Dahjee dump is in the CRC table.
//
// mapper is valid from the end of the download until the next one starts.
//-----------------------------------------------------------------------------

module sc3000_detect (
  input               clk,
  input               dl_busy,     // ioctl_download for the cartridge index
  input               dl_wr,
  input        [24:0] dl_addr,
  input        [7:0]  dl_data,
  output reg   [3:0]  mapper = 4'd0,
  output reg   [24:0] size = 25'd0,
  output reg   [31:0] crc_out = 32'd0
);

`include "sc3000_cart_db.vh"

  // CRC32 (IEEE, reflected), one byte per write
  function automatic [31:0] crc32_byte(input [31:0] c, input [7:0] d);
    reg [31:0] x;
    integer i;
    begin
      x = c ^ {24'd0, d};
      for (i = 0; i < 8; i = i + 1) x = x[0] ? (x >> 1) ^ 32'hEDB88320 : (x >> 1);
      crc32_byte = x;
    end
  endfunction

  // Signature strings: matched byte by byte as the image streams past
  localparam [8*10-1:0] S_CASTLE = "ASCII 1986";
  localparam [8*27-1:0] S_L3     = "SC-3000 BASIC Level 3 ver 1";
  localparam [8*25-1:0] S_L2     = "SC-3000 BASIC Level 2 ver";
  localparam [8*7-1:0]  S_TEREBI = "annakmn";
  localparam [8*5-1:0]  S_PIANO  = "PIANO";
  localparam [8*5-1:0]  S_MUSIC  = "music";

  function automatic match(input [24:0] a, input [7:0] d, input [24:0] base, input integer len,
                           input [8*27-1:0] str);
    // str is right-aligned (shorter strings zero-extend on the left): byte k = str[8*(len-1-k) +: 8]
    integer k;
    begin
      match = 1'b1;
      if (a >= base && a < base + len) begin
        k = a - base;
        match = d == str[8*(len-1-k) +: 8];
      end
    end
  endfunction

  reg [31:0] crc = 32'hFFFFFFFF;
  reg ok_castle, ok_l3, ok_l2, ok_terebi, ok_piano, ok_music;
  reg busy_q = 1'b0;
  reg [24:0] last;

  always @(posedge clk) begin
    busy_q <= dl_busy;
    if (dl_busy & ~busy_q) begin
      crc <= 32'hFFFFFFFF;
      {ok_castle, ok_l3, ok_l2, ok_terebi, ok_piano, ok_music} <= 6'b111111;
      last <= 25'd0;
    end else if (dl_busy & dl_wr) begin
      crc  <= crc32_byte(crc, dl_data);
      last <= dl_addr;
      ok_castle <= ok_castle & match(dl_addr, dl_data, 25'h1CC3, 10, S_CASTLE);
      ok_l3     <= ok_l3     & match(dl_addr, dl_data, 25'h6A20, 27, S_L3);
      ok_l2     <= ok_l2     & match(dl_addr, dl_data, 25'h6543, 25, S_L2);
      ok_terebi <= ok_terebi & match(dl_addr, dl_data, 25'h13B3, 7,  S_TEREBI);
      ok_piano  <= ok_piano  & match(dl_addr, dl_data, 25'h0841, 5,  S_PIANO);
      ok_music  <= ok_music  & match(dl_addr, dl_data, 25'h0841, 5,  S_MUSIC);
    end else if (~dl_busy & busy_q) begin : decide
      // end of the download: decide (strings must lie inside the image)
      reg [4:0]  db;
      reg [24:0] len;
      db  = cart_db(~crc);
      len = last + 25'd1;
      size    <= len;
      crc_out <= ~crc;
      if (db[4])                                   mapper <= db[3:0];
      else if (len == 25'h200000)                  mapper <= 4'd8;
      else if (len == 25'h400000)                  mapper <= 4'd9;
      else if (ok_l3     && len >= 25'h6A20 + 27)  mapper <= 4'd1;
      else if (ok_l2     && len >= 25'h6543 + 25)  mapper <= 4'd3;
      else if (ok_castle && len >= 25'h1CC3 + 10)  mapper <= 4'd2;
      else if (ok_terebi && len >= 25'h13B3 + 7)   mapper <= 4'd4;
      else if ((ok_piano | ok_music) && len >= 25'h0841 + 5) mapper <= 4'd7;
      else if (len > 25'h010000)                   mapper <= 4'd10;
      else                                         mapper <= 4'd0;
    end
  end

endmodule
