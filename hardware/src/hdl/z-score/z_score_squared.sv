`timescale 1ns / 1ps

`include "libstf_macros.svh"

module my_z_score_squared
#(parameter int ELEM_BITS = 32)
 (input  logic clk,
  input  logic rst_n,
    AXI4S.s in,
    AXI4S.m out,
    decoder_profile_i.m profile);   // in = pass1+pass2 input stream, out = pass2 flag output stream

`RESET_RESYNC // Reset pipelining (provides reset_synced)

    localparam int IN_BITS   = in.AXI4S_DATA_BITS;   // 512
    localparam int N_IN      = IN_BITS / ELEM_BITS;  // 16 input lanes
    localparam int KEEP_PER  = ELEM_BITS / 8;        // 4 keep bits per lane
    localparam int K         = 3;                    // threshold multiplier (k^2 = 9)
    localparam int WIDE      = 160;                  // wide enough for diff^2 and threshold
    localparam int DIFF_W    = 64;                   // diff = n*x - S; 64b (mult IP max). Assumes |n*x - S| < 2^63.
    localparam int MULT_LAT  = 18;                   // !! MUST match int_mult_64 PipeStages in init_ip.tcl (optimum for 64x64)
    // Pass-2 datapath latency, input beat -> squared output: n*x IP (MULT_LAT) + subtract reg (1)
    // + squaring IP (MULT_LAT). The metadata pipeline is this deep so valid/keep/last stay aligned.
    localparam int PASS2_LAT = 2*MULT_LAT + 1;

    // ---- accumulator + state ----
    typedef enum logic [2:0] {accumulate, compute_wait, compute_sub, compute_scale, output_z_score} state_t;
    state_t state;
    logic signed [63:0]     sum_reg;
    logic signed [63:0]     sum_square_reg;
    logic        [31:0]     count_reg;
    logic        [4:0]      wait_cnt;               // counts the compute-multiplier latency (up to MULT_LAT)

    logic signed [WIDE-1:0] nq_minus_s2_reg;        // n*Q - S^2
    logic signed [WIDE-1:0] threshold_reg;          // k^2 * (n*Q - S^2), computed once

    // ---- pass-1 accumulate pipeline ------------------------------------------------------------
    // The per-beat reduction is split so it isn't one deep multiply+tree+accumulate cone:
    //   stage a : per-lane number^2 / number / popcount  (DSP mults, registered)
    //   stage b : reduce 16 -> 4   (sum of 4 each)
    //   stage c : reduce 4  -> 1   (per-beat totals)
    //   stage d : accumulate into sum / sum_square / count  (one add)
    // Throughput stays 1 beat/cycle; a 3-cycle drain after tlast flushes the last beats.
    logic signed [63:0]  a_psq [N_IN];
    logic signed [63:0]  a_psm [N_IN];
    logic        [4:0]   a_cnt;
    logic                a_valid, a_last;
    logic signed [63:0]  b_g4sq [4];
    logic signed [63:0]  b_g4sm [4];
    logic        [4:0]   b_cnt;
    logic                b_valid, b_last;
    logic signed [63:0]  c_bsq;
    logic signed [63:0]  c_bsm;
    logic        [4:0]   c_cnt;
    logic                c_valid, c_last;
    logic                draining;                  // pass-1 done; flushing the accumulate pipe

    // ---- pass-2 stage 0: input buffer (registers in.tdata so the decoder->z-score crossing is
    //      register-to-register with no logic in it) ----
    logic signed [ELEM_BITS-1:0] x_reg [N_IN];
    // ---- pass-2 stage 1: diff = n*x - S, per lane (drives the squaring IPs) ----
    logic signed [DIFF_W-1:0] s1_diff [N_IN];

    // ---- metadata pipeline: valid/keep/last delayed PASS2_LAT cycles to align with IP output ----
    logic                 meta_valid [PASS2_LAT+1];
    logic [IN_BITS/8-1:0] meta_keep  [PASS2_LAT+1];
    logic                 meta_last  [PASS2_LAT+1];

    // The pipeline advances when the output slot is free or draining.
    logic pipe_adv;
    assign pipe_adv = out.tready || !out.tvalid;

    // ---- multiplier IPs --------------------------------------------------------------------------
    // Compute multiplies (run once per stream; inputs are stable so CE is tied high).
    logic [127:0] ip_ss_p;                          // sum * sum          (S^2)
    logic [127:0] ip_nq_p;                          // count * sum_square (n*Q)
    wire  [63:0]  ss_a = sum_reg;                    // sum     (signed 64b)
    wire  [63:0]  nq_a = {32'b0, count_reg};         // count   (>= 0)
    wire  [63:0]  nq_b = sum_square_reg;             // sum_sq  (>= 0)
    int_mult_64 mult_ss (.CLK(clk), .CE(1'b1), .A(ss_a), .B(ss_a), .P(ip_ss_p));
    int_mult_64 mult_nq (.CLK(clk), .CE(1'b1), .A(nq_a), .B(nq_b), .P(ip_nq_p));

    // Pass-2 stage 1 input: n*x per lane via DSP IP, fed from the x_reg input buffer (in phase with
    // meta[0]). The n*x multiply is pipelined instead of combinational. n = count_reg, constant
    // throughout pass 2. CE = pipe_adv so it freezes with the rest of the pipe.
    logic [127:0] ip_nx_p [N_IN];
    wire  [63:0]  nx_a = {32'b0, count_reg};         // n (>= 0) as signed 64b
    generate
        for (genvar gi = 0; gi < N_IN; gi++) begin : gen_nx
            wire [63:0] nx_b = {{(64-ELEM_BITS){x_reg[gi][ELEM_BITS-1]}}, x_reg[gi]};   // x sign-extended to 64b
            int_mult_64 mult_nx (
                .CLK(clk), .CE(pipe_adv),
                .A(nx_a), .B(nx_b),
                .P(ip_nx_p[gi])
            );
        end
    endgenerate

    // Pass-2 squares: dsq = diff*diff per lane. CE = pipe_adv so the whole pipe freezes together.
    logic [127:0] ip_dsq_p [N_IN];
    generate
        for (genvar gi = 0; gi < N_IN; gi++) begin : gen_dsq
            int_mult_64 mult_dsq (
                .CLK(clk), .CE(pipe_adv),
                .A(s1_diff[gi]), .B(s1_diff[gi]),
                .P(ip_dsq_p[gi])
            );
        end
    endgenerate

    // tready: pass 1 ready until the pipe is draining; pass 2 ready when it can advance.
    assign in.tready = (state == accumulate)     ? !draining :
                       (state == output_z_score) ? pipe_adv  :
                                                   1'b0;

    integer k;
    always_ff @(posedge clk) begin
        if (!reset_synced) begin
            state           <= accumulate;
            sum_reg         <= '0;
            sum_square_reg  <= '0;
            count_reg       <= '0;
            wait_cnt        <= '0;
            nq_minus_s2_reg <= '0;
            threshold_reg   <= '0;
            a_valid <= 1'b0; b_valid <= 1'b0; c_valid <= 1'b0;
            a_last  <= 1'b0; b_last  <= 1'b0; c_last  <= 1'b0;
            draining        <= 1'b0;
            for (k = 0; k <= PASS2_LAT; k++) meta_valid[k] <= 1'b0;
            out.tvalid      <= 1'b0;
            out.tdata       <= '0;
            out.tkeep       <= '0;
            out.tlast       <= 1'b0;
        end else begin
            case (state)
                // ---- pass 1: accumulate Sum, Sum^2, count (pipelined) ----
                accumulate: begin
                    // stage a: per-lane products (bubble in when no beat is accepted)
                    begin
                        automatic logic [4:0] cnt = '0;
                        for (int i = 0; i < N_IN; i++) begin
                            automatic logic signed [ELEM_BITS-1:0] number = signed'(in.tdata[i*ELEM_BITS +: ELEM_BITS]);
                            if (&in.tkeep[i*KEEP_PER +: KEEP_PER]) begin
                                a_psq[i] <= number * number;
                                a_psm[i] <= 64'(number);
                                cnt = cnt + 1'b1;
                            end else begin
                                a_psq[i] <= '0;
                                a_psm[i] <= '0;
                            end
                        end
                        a_cnt <= cnt;
                    end
                    a_valid <= in.tvalid && in.tready;
                    a_last  <= in.tvalid && in.tready && in.tlast;

                    // stage b: 16 -> 4
                    for (int j = 0; j < 4; j++) begin
                        b_g4sq[j] <= a_psq[4*j] + a_psq[4*j+1] + a_psq[4*j+2] + a_psq[4*j+3];
                        b_g4sm[j] <= a_psm[4*j] + a_psm[4*j+1] + a_psm[4*j+2] + a_psm[4*j+3];
                    end
                    b_cnt   <= a_cnt;
                    b_valid <= a_valid;
                    b_last  <= a_last;

                    // stage c: 4 -> 1 (per-beat totals)
                    c_bsq   <= b_g4sq[0] + b_g4sq[1] + b_g4sq[2] + b_g4sq[3];
                    c_bsm   <= b_g4sm[0] + b_g4sm[1] + b_g4sm[2] + b_g4sm[3];
                    c_cnt   <= b_cnt;
                    c_valid <= b_valid;
                    c_last  <= b_last;

                    // stage d: accumulate the per-beat totals into the running registers
                    if (c_valid) begin
                        sum_reg        <= sum_reg        + c_bsm;
                        sum_square_reg <= sum_square_reg + c_bsq;
                        count_reg      <= count_reg      + 32'(c_cnt);
                    end

                    // pass 1 ends at tlast: stop accepting, then drain the pipe
                    if (in.tvalid && in.tready && in.tlast) draining <= 1'b1;

                    // last beat fully accumulated -> compute the threshold
                    if (c_valid && c_last) begin
                        state    <= compute_wait;
                        wait_cnt <= '0;
                        draining <= 1'b0;
                        a_valid  <= 1'b0;
                        b_valid  <= 1'b0;
                        c_valid  <= 1'b0;
                    end
                end

                // ---- wait for the (free-running) compute multipliers to settle ----
                compute_wait: begin
                    if (wait_cnt == 5'(MULT_LAT)) state <= compute_sub;
                    else                          wait_cnt <= wait_cnt + 1'b1;
                end
                compute_sub: begin
                    nq_minus_s2_reg <= $signed(ip_nq_p) - $signed(ip_ss_p);   // n*Q - S^2
                    state           <= compute_scale;
                end
                compute_scale: begin
                    threshold_reg <= K*K*nq_minus_s2_reg;                     // * 9
                    for (k = 0; k <= PASS2_LAT; k++) meta_valid[k] <= 1'b0;   // clear pass-2 pipe
                    state         <= output_z_score;
                end

                // ---- pass 2: classify. diff -> [squaring IP, MULT_LAT cycles] -> compare ----
                output_z_score: begin
                    if (pipe_adv) begin
                        // output stage: compare the squared diffs (IP output) to the threshold
                        automatic logic [IN_BITS-1:0] flags = '0;
                        for (int i = 0; i < N_IN; i++) begin
                            if ((&meta_keep[PASS2_LAT][i*KEEP_PER +: KEEP_PER]) &&
                                ($signed(ip_dsq_p[i]) > threshold_reg))
                                flags[i*ELEM_BITS +: ELEM_BITS] = 32'd1;
                        end
                        out.tvalid <= meta_valid[PASS2_LAT];
                        out.tdata  <= flags;
                        out.tkeep  <= meta_keep [PASS2_LAT];
                        out.tlast  <= meta_last [PASS2_LAT];

                        // shift the metadata pipeline (aligns with the total pass-2 latency)
                        for (k = PASS2_LAT; k >= 1; k--) begin
                            meta_valid[k] <= meta_valid[k-1];
                            meta_keep [k] <= meta_keep [k-1];
                            meta_last [k] <= meta_last [k-1];
                        end

                        // stage 0: buffer the input and latch metadata, all in phase
                        meta_valid[0] <= in.tvalid;     // in.tready == pipe_adv here
                        meta_keep [0] <= in.tkeep;
                        meta_last [0] <= in.tlast;
                        for (int i = 0; i < N_IN; i++) begin
                            x_reg[i] <= signed'(in.tdata[i*ELEM_BITS +: ELEM_BITS]);
                        end

                        // stage 1 (subtract): the n*x IPs (gen_nx) have produced n*x for the beat now
                        // at this stage; subtract S. |n*x - S| < 2^63 is assumed (see DIFF_W), so the
                        // low DIFF_W bits of the signed product carry the value.
                        for (int i = 0; i < N_IN; i++) begin
                            s1_diff[i] <= $signed(ip_nx_p[i][DIFF_W-1:0]) - sum_reg;
                        end
                    end

                    // end of stream: last output beat delivered -> reset & restart
                    if (out.tvalid && out.tready && out.tlast) begin
                        out.tvalid     <= 1'b0;
                        sum_reg        <= '0;
                        sum_square_reg <= '0;
                        count_reg      <= '0;
                        threshold_reg  <= '0;
                        a_valid <= 1'b0; b_valid <= 1'b0; c_valid <= 1'b0;
                        draining       <= 1'b0;
                        for (k = 0; k <= PASS2_LAT; k++) meta_valid[k] <= 1'b0;
                        state          <= accumulate;
                    end
                end
            endcase
        end
    end

    // ------ Stream profiling ------------------------
    // Same pattern as ColumnChunkDecoder: tap the input (decoded values, both passes) and the output
    // (pass-2 flags). out_starved high => z-score is the producer limiter; out_stalled high =>
    // OutputWriter backpressures us; in_starved high => decoder isn't feeding us fast enough.
    stream_profile_i profile_in ();
    stream_profile_i profile_out();

    assign profile.counters.in  = profile_in.counters;
    assign profile.counters.out = profile_out.counters;
    assign profile_in.stop      = profile.stop;
    assign profile_out.stop     = profile.stop;

    StreamProfiler inst_profile_in (
        .clk(clk),
        .rst_n(reset_synced),

        .last (in.tlast),
        .valid(in.tvalid),
        .ready(in.tready),

        .profile(profile_in)
    );

    StreamProfiler inst_profile_out (
        .clk(clk),
        .rst_n(reset_synced),

        .last (out.tlast),
        .valid(out.tvalid),
        .ready(out.tready),

        .profile(profile_out)
    );

endmodule
