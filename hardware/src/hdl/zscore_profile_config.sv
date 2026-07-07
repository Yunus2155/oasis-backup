`timescale 1ns / 1ps

import libstf::*;
import oasis::*;

`include "libstf_macros.svh"

// Read-only config that exposes the per-lane z-score StreamProfiler counters to the host. It mirrors
// the readout half of ColumnChunkDecoderConfig (same register layout, same stop-on-last-read
// behaviour) but has no write path, because the z-score stage takes no host configuration.
module ZScoreProfileConfig #(
    parameter NUM_ZSCORES
) (
    input logic clk,
    input logic rst_n,

    read_config_i.s read_config,

    decoder_profile_i.s profile[NUM_ZSCORES]
);

localparam NUM_INFO_REGS    = ZSCORE_PROFILE_INFO_REGS;
localparam NUM_PROFILE_REGS = ZSCORE_PROFILE_PROFILE_REGS;
localparam NUM_READ_REGS    = ZSCORE_PROFILE_READ_REGS(NUM_ZSCORES);

`RESET_RESYNC // Reset pipelining

// -- Read -----------------------------------------------------------------------------------------
logic[AXIL_DATA_BITS - 1:0] values[NUM_READ_REGS];
assign values[0] = ZSCORE_PROFILE_CONFIG_ID;
assign values[1] = NUM_ZSCORES;

for (genvar I = 0; I < NUM_ZSCORES; I++) begin
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 0] = profile[I].counters.in.handshakes_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 1] = profile[I].counters.in.starved_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 2] = profile[I].counters.in.stalled_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 3] = profile[I].counters.in.idle_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 4] = profile[I].counters.out.handshakes_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 5] = profile[I].counters.out.starved_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 6] = profile[I].counters.out.stalled_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 7] = profile[I].counters.out.idle_cycles;
end

ConfigReadRegisterFile #(
    .NUM_REGS(NUM_READ_REGS)
) inst_read_regs (
    .clk(clk),
    .rst_n(reset_synced),

    .in(read_config),
    .values(values)
);

// -- Profile stop ---------------------------------------------------------------------------------
// The host reads a lane's 8 profile counters in ascending order. We detect the last read handshake
// and pulse stop[I] so the profilers reset once the full snapshot has been read out.
logic read_handshake;
assign read_handshake = read_config.read_valid && read_config.read_ready;

for (genvar I = 0; I < NUM_ZSCORES; I++) begin
    localparam int LAST_PROFILE_REG = NUM_INFO_REGS + NUM_PROFILE_REGS * (I + 1) - 1;
    assign profile[I].stop = read_handshake && (read_config.read_addr == LAST_PROFILE_REG);
end

endmodule
