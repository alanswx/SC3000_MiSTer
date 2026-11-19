//-----------------------------------------------------------------------------
// Clock enables from clk_sys = 42.954545 MHz (4 x 10.738635):
//   ce_10m7   VDP master clock, /4
//   ce_5m37   pixels, /8
//   ce_psg    SN76489 3.579545 MHz, /12 (never sped up)
//   ce_cpu_p/ce_cpu_n  Z80 T-state phases: /12 (3.579545 MHz), or /3 (14.32 MHz,
//             4x) while turbo is requested. The spacing changes only at a CPU
//             clock boundary, so p and n always alternate and never share a clock.
//-----------------------------------------------------------------------------

module sc3000_clocks (
  input        clk,
  input        turbo_req,
  output reg   ce_10m7 = 1'b0,
  output reg   ce_5m37 = 1'b0,
  output reg   ce_psg = 1'b0,
  output reg   ce_cpu_p = 1'b0,
  output reg   ce_cpu_n = 1'b0,
  output reg   turbo = 1'b0     // spacing in use for the current CPU clock
);

  reg [2:0] div = 3'd0;
  reg [3:0] d12 = 4'd0;
  always @(posedge clk) begin
    div     <= div + 3'd1;
    ce_10m7 <= div[1:0] == 2'd0;
    ce_5m37 <= div == 3'd0;
    d12     <= (d12 == 4'd11) ? 4'd0 : d12 + 4'd1;
    ce_psg  <= d12 == 4'd0;
  end

  reg [3:0] cpu_div = 4'd0;
  always @(posedge clk) begin
    ce_cpu_p <= 1'b0;
    ce_cpu_n <= 1'b0;
    if (cpu_div == 4'd0) begin
      ce_cpu_p <= 1'b1;
      turbo    <= turbo_req;
      cpu_div  <= turbo_req ? 4'd2 : 4'd11;
    end else begin
      cpu_div <= cpu_div - 4'd1;
      if (cpu_div == (turbo ? 4'd1 : 4'd6)) ce_cpu_n <= 1'b1;
    end
  end

endmodule
