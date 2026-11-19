//-----------------------------------------------------------------------------
// Virtual tape motor. The SC-3000 has no motor line (PPI PC3 is n.c.; MAME
// sk1100.cpp), so the deck plays while the program polls the tape input:
// a loader reads PPI port B (PB7) thousands of times a second, the keyboard
// scan a few dozen times per frame. The deck starts when a window of WIN CPU
// clocks (about 1/60 s) holds at least MIN_POLLS reads, and stops after HOLD
// windows in a row with fewer (about 0.5 s), so short gaps while the loader
// prints "Found:" or decodes a block don't stop it. A window in which the CPU
// wrote the PPI (a keyboard scan changes the row) does not count: a game
// waiting for a key polls port B quickly too, but between row changes.
//-----------------------------------------------------------------------------

module sc3000_tape_motor #(
  parameter WIN       = 59659,   // CPU clocks per window (3.579545 MHz / 60)
  parameter MIN_POLLS = 200,
  parameter HOLD      = 30
) (
  input        clk,
  input        reset,
  input        ce,          // CPU clock enable
  input        poll,        // one pulse per read of PPI port B
  input        ppi_wr,      // a PPI write (row select): this window is a keyboard scan
  output reg   motor = 1'b0
);

  reg [15:0] t = 0;
  reg [15:0] n = 0;
  reg [5:0]  quiet = 0;
  reg        kbd = 0;        // the window saw a PPI write

  always @(posedge clk) begin
    if (reset) begin
      t <= 0; n <= 0; quiet <= 0; motor <= 1'b0; kbd <= 1'b0;
    end else begin
      if (poll && n != 16'hFFFF) n <= n + 16'd1;
      if (ppi_wr) kbd <= 1'b1;
      if (ce) begin
        if (t == WIN - 1) begin
          t <= 0;
          n <= poll ? 16'd1 : 16'd0;
          kbd <= ppi_wr;
          if (n >= MIN_POLLS && !kbd) begin motor <= 1'b1; quiet <= 0; end
          else if (motor) begin
            if (quiet == HOLD - 1) motor <= 1'b0;
            else quiet <= quiet + 6'd1;
          end
        end else t <= t + 16'd1;
      end
    end
  end

endmodule
