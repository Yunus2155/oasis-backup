`timescale 1ns / 1ps

// -- Operator select (build-time) -----------------------------------------------------------------
// Uncomment to synthesize the COVARIANCE vertical (single-pass, streams raw sums for host-side
// finalize). Leave commented for the default z-score decode-once vertical.
`define EN_COVARIANCE

import oasis::*;
import parcore::*;

// -- Tie-off unused interfaces and signals --------------------------------------------------------
always_comb cq_rd.tie_off_s();

// Card-memory (HBM) streams. Exposed by the shell when EN_MEM=1. Tied off for now; the decode-once
// path will drive axis_card_send via CardWrite (pass 1) and consume axis_card_recv via CardRead
// (pass 2). cq_wr/sq_wr/sq_rd are shared with the host path and arbitrated as today.
// Card streams are now fully used: axis_card_send <= CardWrite (pass-1 store), axis_card_recv =>
// ZScoreCardReplay's CardRead (pass-2 replay). No tie-offs needed.

`ifdef EN_RDMA
always_comb rq_rd.tie_off_s();
always_comb rq_wr.tie_off_s();

for (genvar I = 0; I < N_STRM_AXI; I++) begin
    always_comb axis_host_recv[I].tie_off_s();
end

for (genvar I = 0; I < N_RDMA_AXI; I++) begin
    always_comb axis_rrsp_send[I].tie_off_m();
    always_comb axis_rrsp_recv[I].tie_off_s();
    always_comb axis_rreq_send[I].tie_off_m();
end

`ASSERT_ELAB(N_STRM_AXI == N_RDMA_AXI)
`endif

localparam NUM_STREAMS        = N_STRM_AXI;
localparam DATABEAT_SIZE      = AXI_DATA_BITS / 8;
// MemConfig write side needs NUM_STREAMS+1 regs, read side needs 3 (ID, num_streams, max_enqueued).
localparam MEM_CONFIG_NUM_REGS = (NUM_STREAMS + 1 > 3) ? NUM_STREAMS + 1 : 3;

localparam NUM_CONFIGS   = 4;   // [0]=mem, [1]=decoder, [2]=read-req, [3]=z-score profile
`ifdef EN_RDMA
localparam NUM_DECODERS  = NUM_STREAMS - 1;
`else
localparam NUM_DECODERS  = NUM_STREAMS;
`endif

// -- Fix clock and reset names --------------------------------------------------------------------
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

// -- Configuration --------------------------------------------------------------------------------
write_config_i                       write_configs[NUM_CONFIGS](.*);
read_config_i                        read_configs [NUM_CONFIGS](.*);
mem_config_i                         mem_conf[NUM_STREAMS](.*);
ready_valid_i #(read_req_t)          read_conf[NUM_STREAMS](.*);
ready_valid_i #(column_chunk_conf_t) column_chunk_conf[NUM_DECODERS](.*);
decoder_profile_i                    decoder_profiles[NUM_DECODERS]();
decoder_profile_i                    zscore_profiles [NUM_DECODERS]();

GlobalConfig #(
    .SYSTEM_ID(OASIS_SYSTEM_ID),
    .NUM_CONFIGS(NUM_CONFIGS),
    .ADDR_SPACE_SIZES({
        MEM_CONFIG_NUM_REGS,
        COLUMN_CHUNK_DECODER_READ_REGS(NUM_DECODERS),
        NUM_READ_REQ_CONFIG_REGS * NUM_STREAMS,
        ZSCORE_PROFILE_READ_REGS(NUM_DECODERS)
    })
) inst_config (
    .clk(clk),
    .rst_n(rst_n),

    .axi_ctrl(axi_ctrl),

    .write_configs(write_configs),
    .read_configs(read_configs)
);

MemConfig #(
    .NUM_STREAMS(NUM_STREAMS)
) inst_mem_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[0]),
    .read_config(read_configs[0]),

    .out(mem_conf)
);

ColumnChunkDecoderConfig #(
    .NUM_DECODERS(NUM_DECODERS)
) inst_column_chunk_decoder_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[1]),
    .read_config(read_configs[1]),

    .out(column_chunk_conf),

    .profile(decoder_profiles)
);

ReadReqConfig #(
    .NUM_STREAMS(NUM_STREAMS)
) inst_read_req_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[2]),
    .read_config(read_configs[2]),

    .out(read_conf)
);

// Read-only: exposes the per-lane z-score StreamProfiler counters. write_configs[3] is unused (the
// z-score takes no host configuration); GlobalConfig still drives it but nothing consumes it.
ZScoreProfileConfig #(
    .NUM_ZSCORES(NUM_DECODERS)
) inst_zscore_profile_config (
    .clk(clk),
    .rst_n(rst_n),

    .read_config(read_configs[3]),

    .profile(zscore_profiles)
);

// -- Arbiter the read send queue ------------------------------------------------------------------
// Slots 0..NUM_STREAMS-1 = the host/RDMA reads (pass 1). Slots NUM_STREAMS..+NUM_DECODERS-1 = the
// per-lane card reads (pass-2 HBM replay) issued by ZScoreCardReplay.
localparam int N_RD = NUM_STREAMS + NUM_DECODERS;
metaIntf #(.STYPE(req_t)) sq_rd_strm [N_RD](.aclk(clk), .aresetn(rst_n));

MetaIntfArbiter #(
    .N_INTERFACES(N_RD),
    .STYPE(req_t)
) inst_sq_wr_arbiter (
    .clk(clk),
    .rst_n(rst_n),

    .intf_in(sq_rd_strm),
    .intf_out(sq_rd)
);

// -- Write send-queue sharing -------------------------------------------------------------------
// The single shell write queue (sq_wr/cq_wr/notify) is now shared by the OutputWriter (slot 0) and
// the per-lane CardWrite stores (slots 1..NUM_DECODERS). sq_wr/notify are round-robin arbitered;
// completions (cq_wr) are split by strm: STRM_HOST -> OutputWriter, STRM_CARD -> CardWrite lanes.
localparam int N_WR = NUM_DECODERS + 1;
// Fixed per-lane HBM buffer: 1 GiB at card vaddr (lane << CARD_BUF_LOG2_BYTES). Holds up to ~256M
// int32 values per lane; the host must allocate/own the same card region for the eventual replay.
localparam int CARD_BUF_LOG2_BYTES = 30;

metaIntf #(.STYPE(req_t))     wr_sq     [N_WR](.aclk(clk), .aresetn(rst_n));
metaIntf #(.STYPE(irq_not_t)) wr_notify [N_WR](.aclk(clk), .aresetn(rst_n));
metaIntf #(.STYPE(ack_t))     wr_cq_host       (.aclk(clk), .aresetn(rst_n));
metaIntf #(.STYPE(ack_t))     wr_cq_card_all   (.aclk(clk), .aresetn(rst_n));
metaIntf #(.STYPE(ack_t))     wr_cq_card[NUM_DECODERS](.aclk(clk), .aresetn(rst_n));

MetaIntfArbiter #(.N_INTERFACES(N_WR), .STYPE(req_t)) inst_sq_wr_share (
    .clk(clk), .rst_n(rst_n), .intf_in(wr_sq), .intf_out(sq_wr)
);
MetaIntfArbiter #(.N_INTERFACES(N_WR), .STYPE(irq_not_t)) inst_notify_share (
    .clk(clk), .rst_n(rst_n), .intf_in(wr_notify), .intf_out(notify)
);

// Split shell completions by strm. VERIFY IN SIM: assumes cq_wr.data.strm distinguishes host vs card
// completions and that CQDemultiplexer routes by the dest field (CardWrite lane I uses dest = I).
always_comb begin
    wr_cq_host.valid     = cq_wr.valid && (cq_wr.data.strm == STRM_HOST);
    wr_cq_host.data      = cq_wr.data;
    wr_cq_card_all.valid = cq_wr.valid && (cq_wr.data.strm == STRM_CARD);
    wr_cq_card_all.data  = cq_wr.data;
    cq_wr.ready = (cq_wr.data.strm == STRM_CARD) ? wr_cq_card_all.ready : wr_cq_host.ready;
end
CQDemultiplexer #(.N_STREAMS(NUM_DECODERS)) inst_card_cq_demux (
    .clk(clk), .rst_n(rst_n), .data_in(wr_cq_card_all), .data_out(wr_cq_card)
);

// -- Data path ------------------------------------------------------------------------------------
AXI4S axi_out[NUM_STREAMS](.aclk(clk), .aresetn(rst_n));
for (genvar I = 0; I < NUM_DECODERS; I++) begin
    AXI4S axi_in (.aclk(aclk), .aresetn(aresetn));
    ndata_i       #(data8_t, DATABEAT_SIZE) decoder_in(.*);
    typed_ndata_i #(DATABEAT_SIZE)          typed_out(.*);
    ndata_i       #(data8_t, DATABEAT_SIZE) out(.*);

`ifdef EN_RDMA
    // AXI4SR to AXI4S
    `AXIS_ASSIGN(axis_rreq_recv[I], axi_in)

    RDMARead #(
        .AXI_STRM_ID(I),
        .DATABEAT_SIZE(DATABEAT_SIZE)
    ) inst_rdma_read (
        .clk(clk),
        .rst_n(rst_n),

        .conf(read_conf[I]),
        .sq_rd(sq_rd_strm[I]),

        .in(axi_in),
        .out(decoder_in)
    );
`else
    // AXI4SR to AXI4S
    `AXIS_ASSIGN(axis_host_recv[I], axi_in)

    LocalRead #(
        .AXI_STRM_ID(I),
        .DATABEAT_SIZE(DATABEAT_SIZE)
    ) inst_local_read (
        .clk(clk),
        .rst_n(rst_n),

        .conf(read_conf[I]),
        .sq_rd(sq_rd_strm[I]),

        .in(axi_in),
        .out(decoder_in)
    );
`endif

    ColumnChunkDecoder #(
        .DATABEAT_SIZE(DATABEAT_SIZE)
    ) inst_column_chunk_decoder (
        .clk(clk),
        .rst_n(rst_n),

        .conf(column_chunk_conf[I]),

        .in(decoder_in),
        .out(typed_out),

        .profile(decoder_profiles[I])
    );

    // Discard typed
    `DATA_ASSIGN(typed_out, out);

`ifdef EN_COVARIANCE
    // -- Post-decoder compute stage: covariance (single-pass, host-side finalize) -----------------
    // One streaming pass over the decoded column; streams out the raw cross-product / self sums for
    // the host to finish (cov = (N*Sxy - Sx*Sy)/N^2). No 2-pass / HBM replay, so the CardWrite and
    // card-read machinery is unused for this lane -> tie those shared slots off.
    AXI4S axi_decoded(.aclk(clk), .aresetn(rst_n));
    NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi (
        .clk(clk),
        .rst_n(rst_n),

        .in(out),
        .out(axi_decoded)
    );

    covariance inst_covariance (
        .clk(clk),
        .rst_n(rst_n),

        .in(axi_decoded),
        .out(axi_out[I])
    );

    // This lane uses neither the card streams nor the HBM store/replay -> tie off the slots the
    // z-score path would have driven (the arbiters expect every slot driven).
    always_comb axis_card_send[I].tie_off_m();
    always_comb axis_card_recv[I].tie_off_s();
    always_comb wr_sq     [I + 1].tie_off_m();
    always_comb wr_notify [I + 1].tie_off_m();
    always_comb wr_cq_card[I].tie_off_s();
    always_comb sq_rd_strm[NUM_STREAMS + I].tie_off_m();
    assign zscore_profiles[I].counters = '0;   // no StreamProfiler in the covariance lane (yet)
`else
    // -- Fork the decoded column: one copy feeds the z-score, one copy is stored into HBM ----------
    // EXPERIMENTAL decode-once (SIM BEFORE SYNTH): pass 1 decodes from host AND stores the decoded
    // column into a per-lane HBM buffer via CardWrite (strm=STRM_CARD). Pass 2 is replayed from HBM
    // by ZScoreCardReplay below, so the z-score's second pass skips the decoder entirely.
    // REQUIRED HOST CHANGE: the host must now send the column ONCE (not twice) -- the hardware
    // self-issues the pass-2 card read. If the host still sends twice, the second decode stream
    // backpressures (replay holds decoded_in.tready low in pass 2) and the decoder stalls.
    ndata_i #(data8_t, DATABEAT_SIZE) out_fork[2](.*);
    NDataDuplicator #(2) inst_decoded_fork (
        .clk(clk),
        .rst_n(rst_n),

        .in(out),
        .out(out_fork)
    );

    // Decoded values as an AXI4S stream (16 int32 lanes per 512b beat).
    AXI4S axi_decoded(.aclk(clk), .aresetn(rst_n));
    NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi (
        .clk(clk),
        .rst_n(rst_n),

        .in(out_fork[0]),
        .out(axi_decoded)
    );

    // Second copy -> HBM via CardWrite. Fixed per-lane card buffer at (lane << CARD_BUF_LOG2_BYTES).
    AXI4S axi_card_store(.aclk(clk), .aresetn(rst_n));
    NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi_card (
        .clk(clk),
        .rst_n(rst_n),

        .in(out_fork[1]),
        .out(axi_card_store)
    );

    mem_config_i card_mem_conf(clk, rst_n);
    assign card_mem_conf.buffer_data.vaddr = I << CARD_BUF_LOG2_BYTES;
    assign card_mem_conf.buffer_data.size  = 1 << CARD_BUF_LOG2_BYTES;
    assign card_mem_conf.buffer_valid      = 1'b1;
    assign card_mem_conf.flush_buffers     = 1'b0;

    CardWrite #(
        .AXI_STRM_ID(I)
    ) inst_card_write (
        .clk(clk),
        .rst_n(rst_n),

        .sq_wr (wr_sq [I + 1]),   // slot 0 is the OutputWriter; CardWrite lanes follow
        .cq_wr (wr_cq_card[I]),
        .notify(wr_notify[I + 1]),

        .mem_config(card_mem_conf),

        .input_data(axi_card_store),
        .output_data(axis_card_send[I])
    );

    // -- Decode-once replay control ---------------------------------------------------------------
    // Pass 1: passes axi_decoded straight to the z-score. Between passes: once the CardWrite store
    // completes, issues a card read of the same buffer. Pass 2: feeds HBM-replayed data to the
    // z-score so the second pass skips the decoder entirely.
    AXI4S axi_card_recv_s(.aclk(clk), .aresetn(rst_n));
    `AXIS_ASSIGN(axis_card_recv[I], axi_card_recv_s)

    // store_done: CardWrite raised its final (last_transfer) notify => pass-1 column is durably in HBM.
    logic store_done;
    assign store_done = wr_notify[I + 1].valid && wr_notify[I + 1].ready && wr_notify[I + 1].data.value[31];

    AXI4S axi_zin(.aclk(clk), .aresetn(rst_n));
    ZScoreCardReplay #(
        .AXI_STRM_ID(I),
        .DATABEAT_SIZE(DATABEAT_SIZE),
        .CARD_VADDR(I << CARD_BUF_LOG2_BYTES)
    ) inst_replay (
        .clk(clk),
        .rst_n(rst_n),

        .decoded_in(axi_decoded),
        .card_recv(axi_card_recv_s),
        .sq_rd(sq_rd_strm[NUM_STREAMS + I]),

        .store_done(store_done),

        .zscore_in(axi_zin)
    );

    // -- Post-decoder compute stage: z-score (squared, division-free) -----------------------------
    // Classifies each decoded value as outlier (1) / inlier (0). 2-pass: pass 1 from the decoder,
    // pass 2 replayed from HBM (decode-once).
    my_z_score_squared inst_z_score (
        .clk(clk),
        .rst_n(rst_n),

        .in(axi_zin),
        .out(axi_out[I]),

        .profile(zscore_profiles[I])
    );
`endif
end

// -- RDMA bypass stream (last stream slot, no decoder) --------------------------------------------
`ifdef EN_RDMA
localparam BYPASS_ID = NUM_STREAMS - 1;

AXI4S axi_in (.aclk(aclk), .aresetn(aresetn));
ndata_i #(data8_t, DATABEAT_SIZE) bypass_ndata();

// AXI4SR to AXI4S
`AXIS_ASSIGN(axis_rreq_recv[BYPASS_ID], axi_in)

RDMARead #(
    .AXI_STRM_ID(BYPASS_ID),
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_rdma_read_bypass (
    .clk(clk),
    .rst_n(rst_n),

    .conf(read_conf[BYPASS_ID]),
    .sq_rd(sq_rd_strm[BYPASS_ID]),    

    .in(axi_in),
    .out(bypass_ndata)
);

NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi_bypass (
    .clk(clk),
    .rst_n(rst_n),

    .in(bypass_ndata),
    .out(axi_out[BYPASS_ID])
);
`endif

// -- Output writer --------------------------------------------------------------------------------
// Shares the write queue with the CardWrite stores: slot 0 of the arbiters, host-strm completions.
OutputWriter inst_output_writer (
    .clk(clk),
    .rst_n(rst_n),

    .sq_wr(wr_sq[0]),
    .cq_wr(wr_cq_host),
    .notify(wr_notify[0]),

    .mem_config(mem_conf),

    .data_in(axi_out),
    .data_out(axis_host_send)
);
