`timescale 1ns / 1ps

import oasis::*;

`include "axi_macros.svh"

// Standalone test of the celeris covariance operator in the oasis sim environment.
// Single-pass, host-side finalize: one beat = one row of 16 features, the operator
// streams out the raw sums (sum_product / sum_self / num_rows) for the host to divide.
// Build sim with -DN_DECODERS=2 (even streams); this test uses stream 0, ties off the rest.

// -- Tie-off unused interfaces and signals --------------------------------------------------------
always_comb sq_rd.tie_off_m();
always_comb cq_rd.tie_off_s();

for (genvar I = 1; I < N_STRM_AXI; I++) begin
    always_comb axis_host_recv[I].tie_off_s();
end

// Card/HBM interfaces are unused here -> tie them off (else tvalid is X -> $fatal).
for (genvar I = 0; I < N_CARD_AXI; I++) begin
    always_comb axis_card_recv[I].tie_off_s();
    always_comb axis_card_send[I].tie_off_m();
end

// -- Fix clock and reset names --------------------------------------------------------------------
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

// -- Signals --------------------------------------------------------------------------------------
AXI4S cov_in(.aclk(clk), .aresetn(rst_n));
AXI4S cov_out[N_STRM_AXI](.aclk(clk), .aresetn(rst_n));

for (genvar I = 1; I < N_STRM_AXI; I++) begin
    always_comb cov_out[I].tie_off_m();
end

// -- Configuration --------------------------------------------------------------------------------
// MemConfig write side needs NUM_STREAMS+1 regs, read side needs 3.
localparam int MEM_REGS = (N_STRM_AXI + 1 > 3) ? N_STRM_AXI + 1 : 3;

write_config_i write_configs[1](.*);
read_config_i  read_configs [1](.*);

GlobalConfig #(
    .SYSTEM_ID(OASIS_SYSTEM_ID),
    .NUM_CONFIGS(1),
    .ADDR_SPACE_SIZES({MEM_REGS})
) inst_config (
    .clk(clk),
    .rst_n(rst_n),

    .axi_ctrl(axi_ctrl),

    .write_configs(write_configs),
    .read_configs(read_configs)
);

mem_config_i mem_config[N_STRM_AXI](.*);
MemConfig #(
    .NUM_STREAMS(N_STRM_AXI)
) inst_mem_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[0]),
    .read_config(read_configs[0]),

    .out(mem_config)
);

// -- Covariance (single-pass accumulate, host-side finalize) --------------------------------------
`AXIS_ASSIGN(axis_host_recv[0], cov_in) // AXI4SR to AXI4S

covariance inst_covariance (
    .clk(clk),
    .rst_n(rst_n),

    .in(cov_in),
    .out(cov_out[0])
);

// -- Output writer --------------------------------------------------------------------------------
OutputWriter inst_output_writer (
    .clk(clk),
    .rst_n(rst_n),

    .sq_wr(sq_wr),
    .cq_wr(cq_wr),
    .notify(notify),

    .mem_config(mem_config),

    .data_in(cov_out),
    .data_out(axis_host_send)
);
