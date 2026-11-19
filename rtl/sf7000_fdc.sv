//-----------------------------------------------------------------------------
// uPD765A subset for the SF-7000's 3" drive, raw .sf7 images.
//
// Image: MAME sf7000_dsk.cpp: 40 tracks x 1 side x 16 sectors x 256 bytes,
// sector IDs C = track, H = 0, R = 1..16, N = 1, stored in order
// (offset = (track * 16 + R - 1) * 256). The image comes through hps_io's SD
// block interface (512-byte blocks), one block buffered here.
//
// Commands: SPECIFY, SENSE DRIVE STATUS, SENSE INTERRUPT STATUS, RECALIBRATE,
// SEEK, READ DATA, READ DELETED DATA (as READ DATA), WRITE DATA, WRITE
// DELETED DATA (as WRITE DATA), READ ID, FORMAT TRACK (fills the sectors
// with the filler byte; the IDs written must be the standard ones). Anything
// else is invalid (ST0 = 80h). Non-DMA mode only (the SF-7000 has no DMA):
// INT is high while a data byte waits in the execution phase and from the
// end of a command until its first result byte is read; after SEEK /
// RECALIBRATE until SENSE INTERRUPT STATUS. Seeks are immediate; there is
// no overrun timing (the CPU may take as long as it likes per byte).
// TC (PPI PC2 on the SF-7000) ends a READ / WRITE after the current sector.
//-----------------------------------------------------------------------------

module sf7000_fdc (
  input               clk,
  input               reset,

  // CPU
  input               cs,          // E0 / E1
  input               a0,          // 0 = MSR, 1 = data
  input               rd,          // level, qualified by cs
  input               wr,
  input        [7:0]  din,
  output logic [7:0]  dout,
  output              int_o,
  input               tc,
  input               motor,       // drive motor on (not needed for access)
  output              disk_in,     // an image is mounted

  // image (hps_io SD)
  input               img_mounted,
  input               img_readonly,
  input        [31:0] img_size,
  output logic [31:0] sd_lba,
  output logic        sd_rd,
  output logic        sd_wr,
  input               sd_ack,
  input        [8:0]  sd_buff_addr,
  input        [7:0]  sd_buff_dout,
  output logic [7:0]  sd_buff_din,
  input               sd_buff_wr
);

  // ---------------------------------------------------------------- image
  reg        present = 1'b0;
  reg        wprot   = 1'b0;
  reg [6:0]  tracks  = 7'd0;
  always @(posedge clk) if (img_mounted) begin
    present <= img_size != 0;
    wprot   <= img_readonly;
    tracks  <= (img_size[18:12] == 0) ? 7'd40 : img_size[18:12];   // size / 4096
  end

  assign disk_in = present;

  // one 512-byte block
  reg  [7:0] buf_mem [0:511];
  reg  [8:0] buf_a;
  reg  [7:0] buf_q;
  reg        buf_we;
  reg  [7:0] buf_d;
  always @(posedge clk) begin
    if (sd_ack & sd_buff_wr) buf_mem[sd_buff_addr] <= sd_buff_dout;
    else if (buf_we)         buf_mem[buf_a] <= buf_d;
    buf_q <= buf_mem[buf_a];
  end
  always @(posedge clk) sd_buff_din <= buf_mem[sd_buff_addr];

  // ---------------------------------------------------------------- CPU port edges
  reg rd_q = 1'b0, wr_q = 1'b0;
  always @(posedge clk) begin rd_q <= cs & rd; wr_q <= cs & wr; end
  wire rd_end   = rd_q & ~(cs & rd);        // a read finished: advance
  wire wr_start = (cs & wr) & ~wr_q;

  // ---------------------------------------------------------------- state
  typedef enum logic [4:0] {
    P_CMD, P_EXEC_SETUP, P_SD_READ, P_SD_WAIT, P_XFER, P_SECTOR_DONE,
    P_SD_WRITE, P_SD_WWAIT, P_FORMAT, P_FMT_RD, P_FMT_RWAIT, P_FMT_FILL, P_RESULT
  } phase_t;
  phase_t ph;

  reg [7:0] cmd;
  reg [7:0] prm [0:8];
  reg [3:0] np, need;                  // parameter bytes received / needed
  reg [7:0] res [0:6];
  reg [2:0] nr, rcount;                // result byte index / count
  reg [7:0] pcn = 8'd0;                // present cylinder
  reg       seek_int = 1'b0;           // SEEK / RECALIBRATE finished, not yet sensed
  reg [7:0] seek_st0;
  reg       xfer_int;                  // execution-phase byte ready
  reg       res_int;                   // result phase INT
  reg       rqm, dio, exm;

  reg [7:0] c, h, r, n, eot, fill;
  reg [8:0] bi;                        // byte within the sector (0-255)
  reg       is_write, is_format, tc_seen, nd;
  reg [7:0] st0, st1;
  reg [4:0] fmt_sec;                   // FORMAT: sectors done
  reg [15:0] gap;                      // CRC + gap after a sector: time for the CPU to raise TC
  reg [1:0] fmt_b;                     // FORMAT: ID byte index

  assign int_o = xfer_int | res_int | seek_int;

  wire [7:0] msr = {rqm, dio, exm, (ph != P_CMD) || (np != 0), 4'b0000};
  always_comb dout = a0 ? (ph == P_RESULT ? res[nr] : (ph == P_XFER && !is_write) ? buf_q : 8'hFF) : msr;

  function automatic [3:0] params_for(input [7:0] k);
    case (k[4:0])
      5'h03: params_for = 4'd2;          // SPECIFY
      5'h04: params_for = 4'd1;          // SENSE DRIVE STATUS
      5'h07: params_for = 4'd1;          // RECALIBRATE
      5'h08: params_for = 4'd0;          // SENSE INTERRUPT STATUS
      5'h0F: params_for = 4'd2;          // SEEK
      5'h0A: params_for = 4'd1;          // READ ID
      5'h0D: params_for = 4'd5;          // FORMAT TRACK
      5'h05, 5'h06, 5'h09, 5'h0C: params_for = 4'd8;   // WRITE / READ (DELETED) DATA
      default: params_for = 4'd0;
    endcase
  endfunction

  // byte offset of sector R on track pcn, and its block / half
  wire [10:0] sec_idx = {pcn[6:0], 4'd0} + {6'd0, r[4:0]} - 11'd1;   // track * 16 + R - 1 (R is 1-16)
  wire [18:0] sec_off = {sec_idx, 8'd0};

  task automatic finish(input [7:0] s0, input [7:0] s1, input [7:0] s2);
    begin
`ifdef FDC_LOG
      $display("FDC result %02X %02X %02X  C=%0d R=%0d", s0, s1, s2, c, r);
`endif
      res[0] <= s0; res[1] <= s1; res[2] <= s2;
      res[3] <= c;  res[4] <= h;  res[5] <= r; res[6] <= n;
      rcount <= 3'd7; nr <= 3'd0;
      ph <= P_RESULT; rqm <= 1'b1; dio <= 1'b1; exm <= 1'b0;
      xfer_int <= 1'b0; res_int <= 1'b1;
    end
  endtask

  always @(posedge clk) begin
    buf_we <= 1'b0;
    if (reset) begin
      ph <= P_CMD; np <= 0; rqm <= 1'b1; dio <= 1'b0; exm <= 1'b0;
      xfer_int <= 1'b0; res_int <= 1'b0; seek_int <= 1'b0;
      sd_rd <= 1'b0; sd_wr <= 1'b0; tc_seen <= 1'b0;
    end else begin
      if (tc) tc_seen <= 1'b1;

      case (ph)
        // ------------------------------------------------ command phase
        P_CMD: if (wr_start && a0) begin
          if (np == 0) begin
            cmd <= din; need <= params_for(din);
            if (params_for(din) == 0) begin
              np <= 0;
              if (din[4:0] == 5'h08) begin           // SENSE INTERRUPT STATUS
                if (seek_int) begin res[0] <= seek_st0; res[1] <= pcn; rcount <= 3'd2; seek_int <= 1'b0; end
                else begin res[0] <= 8'h80; rcount <= 3'd1; end
              end else begin res[0] <= 8'h80; rcount <= 3'd1; end   // invalid
              nr <= 0; ph <= P_RESULT; dio <= 1'b1;
            end else np <= 1;
          end else begin
            prm[np - 1] <= din;
            if (np == need) begin np <= 0; ph <= P_EXEC_SETUP; rqm <= 1'b0; end
            else np <= np + 1'd1;
          end
        end

        // ------------------------------------------------ execution setup
        P_EXEC_SETUP: begin
          tc_seen <= 1'b0;
`ifdef FDC_LOG
          $display("FDC cmd %02X  %02X %02X %02X %02X %02X %02X %02X %02X  pcn=%0d", cmd,
                   prm[0], prm[1], prm[2], prm[3], prm[4], prm[5], prm[6], prm[7], pcn);
`endif
          case (cmd[4:0])
            5'h03: begin ph <= P_CMD; rqm <= 1'b1; dio <= 1'b0; end          // SPECIFY
            5'h04: begin                                                     // SENSE DRIVE STATUS
              res[0] <= {1'b0, wprot, present, pcn == 8'd0, 1'b0, 1'b0, prm[0][1:0]};   // ST3: FT WP RY T0 TS HD US
              rcount <= 3'd1; nr <= 0; ph <= P_RESULT; rqm <= 1'b1; dio <= 1'b1;
            end
            5'h07, 5'h0F: begin                                              // RECALIBRATE / SEEK
              pcn <= (cmd[4:0] == 5'h07) ? 8'd0 : prm[1];
              seek_st0 <= {2'b00, 1'b1, 1'b0, ~present, 1'b0, prm[0][1:0]} | (prm[0][1:0] != 0 ? 8'h48 : 8'h00);
              seek_int <= 1'b1;
              ph <= P_CMD; rqm <= 1'b1; dio <= 1'b0;
            end
            5'h0A: begin                                                     // READ ID
              c <= pcn; h <= 8'd0; r <= 8'd1; n <= 8'd1;
              if (!present || prm[0][1:0] != 0) finish({5'b01001, 1'b0, prm[0][1:0]}, 8'h00, 8'h00);
              else finish({5'b00000, 1'b0, prm[0][1:0]}, 8'h00, 8'h00);
            end
            5'h0D: begin                                                     // FORMAT TRACK
              n <= prm[1]; fill <= prm[4]; fmt_sec <= 0; fmt_b <= 0;
              c <= pcn; h <= 8'd0; r <= 8'd1;
              is_write <= 1'b1; is_format <= 1'b1;
              if (!present || prm[0][1:0] != 0) finish({5'b01001, 1'b0, prm[0][1:0]}, 8'h00, 8'h00);
              else if (wprot) finish({5'b01000, 1'b0, prm[0][1:0]}, 8'h02, 8'h00);
              else begin ph <= P_FORMAT; rqm <= 1'b1; dio <= 1'b0; exm <= 1'b1; xfer_int <= 1'b1; end
            end
            5'h05, 5'h09, 5'h06, 5'h0C: begin                                // WRITE / READ DATA
              c <= prm[1]; h <= prm[2]; r <= prm[3]; n <= prm[4]; eot <= prm[5];
              is_write <= ~cmd[1]; is_format <= 1'b0;
              if (!present || prm[0][1:0] != 0) finish({5'b01001, 1'b0, prm[0][1:0]}, 8'h00, 8'h00);
              else if (~cmd[1] && wprot) finish({5'b01000, 1'b0, prm[0][1:0]}, 8'h02, 8'h00);
              else ph <= P_SD_READ;
            end
            default: begin res[0] <= 8'h80; rcount <= 3'd1; nr <= 0; ph <= P_RESULT; rqm <= 1'b1; dio <= 1'b1; end
          endcase
        end

        // ------------------------------------------------ sector fetch
        P_SD_READ: begin
          // the sector must exist: right cylinder, head 0, R 1-16, N 1, track on the image
          if (c != pcn || h != 8'd0 || r == 8'd0 || r > 8'd16 || n != 8'd1 || pcn >= {1'b0, tracks})
            finish({5'b01000, 1'b0, 2'b00}, 8'h04, (c != pcn) ? 8'h10 : 8'h00);   // ND (+ WC)
          else begin
            sd_lba <= {23'd0, sec_off[17:9]};
            sd_rd  <= 1'b1;
            ph     <= P_SD_WAIT;
          end
        end
        P_SD_WAIT: begin
          if (sd_ack) sd_rd <= 1'b0;
          if (~sd_rd & ~sd_ack) begin
            bi <= 9'd0;
            buf_a <= {sec_off[8], 8'd0};
            ph <= P_XFER; rqm <= 1'b1; dio <= ~is_write; exm <= 1'b1; xfer_int <= 1'b1;
          end
        end

        // ------------------------------------------------ one byte per CPU access
        P_XFER: begin
          if (!is_write && rd_end && a0) begin
            if (bi == 9'd255) begin ph <= P_SECTOR_DONE; rqm <= 1'b0; xfer_int <= 1'b0; gap <= 16'hFFFF; end
            else begin bi <= bi + 1'd1; buf_a <= buf_a + 1'd1; end
          end
          if (is_write && wr_start && a0) begin
            buf_d <= din; buf_we <= 1'b1;
            if (bi == 9'd255) begin ph <= P_SD_WRITE; rqm <= 1'b0; xfer_int <= 1'b0; end
            else begin bi <= bi + 1'd1; end
          end
          if (buf_we) buf_a <= buf_a + 1'd1;
        end

        P_SD_WRITE: begin
          sd_lba <= {23'd0, sec_off[17:9]};
          sd_wr  <= 1'b1;
          ph     <= P_SD_WWAIT;
        end
        P_SD_WWAIT: begin
          if (sd_ack) sd_wr <= 1'b0;
          if (~sd_wr & ~sd_ack) begin
            if (is_format) begin ph <= P_FORMAT; rqm <= 1'b1; dio <= 1'b0; xfer_int <= 1'b1; end
            else begin ph <= P_SECTOR_DONE; gap <= 16'hFFFF; end
          end
        end

        // the CRC and the gap pass before the next sector: a TC raised in that
        // time (the SF-7000 IPL strobes it right after the 256th byte) ends the command
        P_SECTOR_DONE: if (gap != 0 && !(tc_seen || tc)) gap <= gap - 16'd1; else begin
          if (tc_seen || tc) begin
            // normal end: R points past the last sector transferred
            if (r == eot) begin r <= 8'd1; c <= c + 8'd1; end else r <= r + 8'd1;
            finish(8'h00, 8'h00, 8'h00);
          end else if (r == eot) begin
            // no TC: end of cylinder (ST0 abnormal, ST1 EN), as a real 765 in non-DMA mode
            r <= 8'd1; c <= c + 8'd1;
            finish(8'h40, 8'h80, 8'h00);
          end else begin
            r <= r + 8'd1;
            ph <= P_SD_READ;
          end
        end

        // ------------------------------------------------ FORMAT: 4 ID bytes per sector, then fill it
        P_FORMAT: begin
          if (fmt_sec == prm[2][4:0]) finish({5'b00000, 1'b0, prm[0][1:0]}, 8'h00, 8'h00);
          else if (wr_start && a0) begin
            fmt_b <= fmt_b + 2'd1;
            if (fmt_b == 2'd2) r <= din;
            if (fmt_b == 2'd3) begin rqm <= 1'b0; xfer_int <= 1'b0; ph <= P_FMT_RD; end
          end
        end
        P_FMT_RD: begin
          if (r == 8'd0 || r > 8'd16 || pcn >= {1'b0, tracks}) begin
            fmt_sec <= fmt_sec + 5'd1; ph <= P_FORMAT; rqm <= 1'b1; xfer_int <= 1'b1;   // not on the image: skip
          end else begin
            sd_lba <= {23'd0, sec_off[17:9]}; sd_rd <= 1'b1; ph <= P_FMT_RWAIT;
          end
        end
        P_FMT_RWAIT: begin
          if (sd_ack) sd_rd <= 1'b0;
          if (~sd_rd & ~sd_ack) begin bi <= 9'd0; buf_a <= {sec_off[8], 8'd0}; ph <= P_FMT_FILL; end
        end
        P_FMT_FILL: begin
          if (!buf_we && bi != 9'd256) begin buf_d <= fill; buf_we <= 1'b1; bi <= bi + 1'd1; end
          if (buf_we) buf_a <= buf_a + 1'd1;
          if (bi == 9'd256 && !buf_we) begin
            fmt_sec <= fmt_sec + 5'd1;
            ph <= P_SD_WRITE;
          end
        end

        // ------------------------------------------------ result phase
        P_RESULT: begin
          if (rd_end && a0) begin
            res_int <= 1'b0;
            if (nr == rcount - 1) begin ph <= P_CMD; dio <= 1'b0; rqm <= 1'b1; end
            else nr <= nr + 1'd1;
          end
        end
        default: ph <= P_CMD;
      endcase
    end
  end

endmodule
