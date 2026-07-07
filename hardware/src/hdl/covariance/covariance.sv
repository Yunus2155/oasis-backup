`timescale 1ns / 1ps

`include "libstf_macros.svh"

// =============================================================================
// covariance
// -----------------------------------------------------------------------------
// Streaming covariance accumulator over up to n columns.
//
// Layout: one input beat = one observation (row) of up to n feature values,
//   lane i = feature i.  For M features (M <= 16) lanes M..15 are unused (keep=0).
//
// One streaming pass builds the running sums that a covariance needs:
//   sum_self[i]    = Sigma x_i                 (per feature)
//   sum_product[k] = Sigma x_i * x_j           (per upper-triangular pair)
//   num_rows       = number of observations
// pair k = (i,j), j >= i, packed as  k = i*N - i*(i-1)/2 + (j-i).
//
// The final divide  cov(i,j) = (N*sum_product - sum_i*sum_j) / N^2  is done ON
// THE HOST (exact, trivial O(M^2), no on-chip divider).  The FPGA does the
// expensive O(M^2 * N) reduction -- up to 136 MACs/cycle -- and streams the raw
// sums out.
//
// Timing note: the 136 cross-products go through pipelined int_mult_32 IPs
// (latency lat), so the per-lane keep mask is delayed lat cycles (keep_reg
// pipeline) to line up with the product when it is accumulated.  sum_self /
// num_rows do NOT go through a multiplier, so they accumulate immediately; a
// lat drain after tlast lets the last beats' products land before finalize.
// =============================================================================
module covariance
#(parameter int ELEM_BITS = 32)
 (input  logic clk,
  input  logic rst_n,
    AXI4S.s in,
    AXI4S.m out);

`RESET_RESYNC // provides reset_synced

    localparam int IN_BITS    = in.AXI4S_DATA_BITS;       // 512
    localparam int n       = IN_BITS / ELEM_BITS;      // 16 lanes
    localparam int num_pairs  = n * (n + 1) / 2;    // 136 upper-triangular pairs
    localparam int lat   = 6;                        // !! MUST match int_mult_32 PipeStages in init_ip.tcl

    // Output packing: raw sums as 32-bit words (64-bit values split lo/hi).
    //   sum_product[136] -> 272 words, sum_self[16] -> 32 words, num_rows -> 2 words
    localparam int SP_BASE     = 0;
    localparam int SS_BASE     = 2 * num_pairs;              // 272
    localparam int NR_BASE     = 2 * num_pairs + 2 * n;   // 304
    localparam int TOTAL_WORDS = 2 * num_pairs + 2 * n + 2; // 306

    // ---- typed input view: nin.data[i] / nin.keep[i] / nin.valid / nin.ready / nin.last
    ndata_i #(.data_t(logic [ELEM_BITS-1:0]), .NUM_ELEMENTS(n)) nin();
    AXIToNData #(
        .data_t(logic [ELEM_BITS-1:0]),
        .NUM_ELEMENTS(n)
    ) inst_axi_to_data (
        .clk(clk),
        .rst_n(reset_synced),
        .in(in),
        .out(nin)
    );

    // ---- accumulators (TPC-H-scale bound: sums fit 64-bit, see design notes) ----
    logic signed [63:0]  sum_self    [n];
    logic signed [63:0]  sum_product [num_pairs];
    logic        [31:0]  num_rows;

    // ---- FSM ----
    typedef enum logic [1:0] {accumulate, prep, stream} state_t;
    state_t state;
    logic   draining;                                     // last accepted, flushing the product pipe

    // ---- cross-product multiplier array (structural: this is the compute core) ----
    logic signed [63:0] results [num_pairs];
    genvar i, j;
    generate
        for (i = 0; i < n; i = i + 1) begin : gen_row
            for (j = i; j < n; j = j + 1) begin : gen_col
                localparam int k = i*n - (i*(i-1))/2 + (j - i);
                int_mult_32 i_mult (
                    .CLK (clk),
                    .CE  (1'b1),
                    .A   (signed'(nin.data[i])),
                    .B   (signed'(nin.data[j])),
                    .P   (results[k])
                );
            end
        end
    endgenerate

    // ---- keep_reg pipeline: delay keep/valid/last to align with the IP result ----
    // Inputs feed the mult combinationally, so beat@T -> result@T+lat.
    // keep_reg[0] latches @T (readable T+1), so keep_reg[lat-1] (=TAIL) is readable
    // @T+lat -- exactly when results[k] for beat@T is valid.
    localparam int TAIL = lat - 1;
    logic [n-1:0] keep_reg  [lat];
    logic            valid_reg [lat];
    logic            last_reg  [lat];

    // ---- output staging ----
    logic [31:0] out_words [TOTAL_WORDS];
    logic [15:0] word_ptr;

    // tready: accept in pass 1 until the pipe is draining; never during prep/stream.
    assign nin.ready = (state == accumulate) && !draining;

    integer s;
    always_ff @(posedge clk) begin
        if (!reset_synced) begin
            state      <= accumulate;
            draining   <= 1'b0;
            num_rows   <= '0;
            word_ptr   <= '0;
            out.tvalid <= 1'b0;
            out.tdata  <= '0;
            out.tkeep  <= '0;
            out.tlast  <= 1'b0;
            for (int p = 0; p < num_pairs; p++) sum_product[p] <= '0;
            for (int q = 0; q < n;     q++) sum_self[q]     <= '0;
            for (s = 0; s < lat; s++)      valid_reg[s]   <= 1'b0;
        end else begin
            case (state)

            // ================= accumulate: build running sums =================
            accumulate: begin
                automatic logic accepted = nin.valid && nin.ready;

                // keep_reg pipeline: stage 0 = this cycle, shift the rest every clock
                valid_reg[0] <= accepted;
                keep_reg [0] <= nin.keep;
                last_reg [0] <= accepted && nin.last;
                for (s = 1; s < lat; s++) begin
                    valid_reg[s] <= valid_reg[s-1];
                    keep_reg [s] <= keep_reg [s-1];
                    last_reg [s] <= last_reg [s-1];
                end

                // immediate accumulators (no multiplier latency)
                if (accepted) begin
                    for (int a = 0; a < n; a++)
                        if (nin.keep[a])
                            sum_self[a] <= sum_self[a] + signed'(nin.data[a]);
                    num_rows <= num_rows + 1'b1;
                    if (nin.last) draining <= 1'b1;       // stop accepting, flush the pipe
                end

                // pipe tail: products for the beat presented lat cycles ago
                if (valid_reg[TAIL]) begin
                    automatic int kk = 0;
                    for (int a = 0; a < n; a++)
                        for (int b = a; b < n; b++) begin
                            if (keep_reg[TAIL][a] && keep_reg[TAIL][b])
                                sum_product[kk] <= sum_product[kk] + results[kk];
                            kk = kk + 1;
                        end
                end

                // last beat's products just landed -> finalize
                if (valid_reg[TAIL] && last_reg[TAIL]) begin
                    draining <= 1'b0;
                    state    <= prep;
                end
            end

            // ================= prep: pack raw sums into output words =================
            prep: begin
                for (int p = 0; p < num_pairs; p++) begin
                    out_words[SP_BASE + 2*p]     <= sum_product[p][31:0];
                    out_words[SP_BASE + 2*p + 1] <= sum_product[p][63:32];
                end
                for (int q = 0; q < n; q++) begin
                    out_words[SS_BASE + 2*q]     <= sum_self[q][31:0];
                    out_words[SS_BASE + 2*q + 1] <= sum_self[q][63:32];
                end
                out_words[NR_BASE]     <= num_rows;
                out_words[NR_BASE + 1] <= 32'd0;
                word_ptr <= '0;
                state    <= stream;
            end

            // ================= stream: emit 16 words/beat =================
            stream: begin
                if (out.tready || !out.tvalid) begin
                    if (word_ptr < 16'(TOTAL_WORDS)) begin
                        automatic int rem = TOTAL_WORDS - word_ptr;
                        for (int l = 0; l < n; l++)
                            out.tdata[l*32 +: 32] <=
                                (word_ptr + l < 16'(TOTAL_WORDS)) ? out_words[word_ptr + l] : 32'd0;
                        out.tvalid <= 1'b1;
                        if (rem <= n) begin
                            out.tlast <= 1'b1;
                            out.tkeep <= (~64'h0) >> (64 - rem*4);   // contiguous from LSB
                        end else begin
                            out.tlast <= 1'b0;
                            out.tkeep <= '1;                          // full beat
                        end
                        word_ptr <= word_ptr + 16'(n);
                    end else begin
                        out.tvalid <= 1'b0;
                    end
                end

                // last beat accepted -> reset for the next table
                if (out.tvalid && out.tready && out.tlast) begin
                    out.tvalid <= 1'b0;
                    out.tlast  <= 1'b0;
                    num_rows   <= '0;
                    draining   <= 1'b0;
                    for (int p = 0; p < num_pairs; p++) sum_product[p] <= '0;
                    for (int q = 0; q < n;     q++) sum_self[q]     <= '0;
                    for (s = 0; s < lat; s++)      valid_reg[s]   <= 1'b0;
                    state <= accumulate;
                end
            end

            endcase
        end
    end

endmodule
