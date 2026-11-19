//-----------------------------------------------------------------------------
// Othello Multivision keypad from the PS/2 keyboard (hps_io ps2_key).
//
// MAME sg1000.cpp INPUT_PORTS(omv1000), active low:
//   C0 bits 0-5  1 2 3 4 5 6
//   C1 bits 0-3  7 8 9(#) 0(*)
//   C2 bits 0-5  A B C D E F
//   C3 bits 0-1  G H
// keys = {C3[1:0], C2[5:0], C1[3:0], C0[5:0]}, 1 = pressed. PC keys 1-9, 0
// (main row or keypad) and A-H; '#' and '*' are also Shift+3 and Shift+8.
//-----------------------------------------------------------------------------

module omv_keypad (
  input             clk,
  input             reset,
  input      [10:0] ps2_key,
  output reg [17:0] keys = 18'd0
);

  function automatic [4:0] key_bit(input [8:0] c);   // {valid, bit}
    case (c)
      9'h016, 9'h069: key_bit = {1'b1, 4'd0};    // 1
      9'h01E, 9'h072: key_bit = {1'b1, 4'd1};    // 2
      9'h026, 9'h07A: key_bit = {1'b1, 4'd2};    // 3
      9'h025, 9'h06B: key_bit = {1'b1, 4'd3};    // 4
      9'h02E, 9'h073: key_bit = {1'b1, 4'd4};    // 5
      9'h036, 9'h074: key_bit = {1'b1, 4'd5};    // 6
      9'h03D, 9'h06C: key_bit = {1'b1, 4'd6};    // 7
      9'h03E, 9'h075: key_bit = {1'b1, 4'd7};    // 8
      9'h046, 9'h07D: key_bit = {1'b1, 4'd8};    // 9 #
      9'h045, 9'h070: key_bit = {1'b1, 4'd9};    // 0 *
      9'h01C:         key_bit = {1'b1, 4'd10};   // A
      9'h032:         key_bit = {1'b1, 4'd11};   // B
      9'h021:         key_bit = {1'b1, 4'd12};   // C
      9'h023:         key_bit = {1'b1, 4'd13};   // D
      9'h024:         key_bit = {1'b1, 4'd14};   // E
      9'h02B:         key_bit = {1'b1, 4'd15};   // F
      default:        key_bit = 5'd0;
    endcase
  endfunction

  wire [4:0] kb = key_bit(ps2_key[8:0]);
  reg stb_q = 1'b0;
  reg shift = 1'b0;
  always @(posedge clk) begin
    stb_q <= ps2_key[10];
    if (reset) keys <= 18'd0;
    else if (stb_q != ps2_key[10]) begin
      case (ps2_key[8:0])
        9'h012, 9'h059: shift <= ps2_key[9];
        9'h034: keys[16] <= ps2_key[9];                                   // G
        9'h033: keys[17] <= ps2_key[9];                                   // H
        9'h07C: keys[9]  <= ps2_key[9];                                   // keypad * = 0 *
        default: begin
          // Shift+3 = '#' (the 9 key), Shift+8 = '*' (the 0 key)
          // (a release clears both, whatever Shift does in between)
          if (ps2_key[8:0] == 9'h026 && (shift || !ps2_key[9])) keys[8] <= ps2_key[9];
          if (ps2_key[8:0] == 9'h03E && (shift || !ps2_key[9])) keys[9] <= ps2_key[9];
          if (kb[4])
            if (!(shift && ps2_key[9] && (ps2_key[8:0] == 9'h026 || ps2_key[8:0] == 9'h03E)))
              keys[kb[3:0]] <= ps2_key[9];
        end
      endcase
    end
  end

endmodule
