`timescale 1ns / 1ps

// -- Operator select (build-time) -----------------------------------------------------------------
// Uncomment to synthesize the COVARIANCE vertical (single-pass, streams raw sums for host-side
// finalize). Leave commented for the default z-score vertical.
//`define EN_COVARIANCE

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

// [4]=card buffer only exists with EN_MEM: it hands the decode-once replay its host-allocated HBM
// scratch buffer. GlobalConfig's ADDR_SPACE_SIZES must list exactly NUM_CONFIGS entries, so the slot
// is added and removed together with the `ifdef below.
`ifdef EN_MEM
localparam NUM_CONFIGS   = 5;   // [0]=mem, [1]=decoder, [2]=read-req, [3]=z-score profile, [4]=card buffer
`else
localparam NUM_CONFIGS   = 4;   // [0]=mem, [1]=decoder, [2]=read-req, [3]=z-score profile
`endif
`ifdef EN_RDMA
localparam NUM_DECODERS  = NUM_STREAMS - 1;
`else
localparam NUM_DECODERS  = NUM_STREAMS;
`endif

`ifdef EN_MEM
// CardBufferConfig write side needs one buffer_t reg per lane, read side needs 2 (ID, num_lanes).
localparam CARD_BUFFER_CONFIG_NUM_REGS =
    (NUM_CARD_BUFFER_CONFIG_REGS * NUM_DECODERS > CARD_BUFFER_INFO_REGS)
        ? NUM_CARD_BUFFER_CONFIG_REGS * NUM_DECODERS : CARD_BUFFER_INFO_REGS;
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
// Slots 0..NUM_DECODERS-1 are the per-lane z-scores. The NUM_STREAMS slots after them are the egress
// taps on axis_host_send -- see inst_egress_profile below.
localparam NUM_ZSCORE_PROFILES = NUM_DECODERS + NUM_STREAMS;
decoder_profile_i                    zscore_profiles [NUM_ZSCORE_PROFILES]();
`ifdef EN_MEM
mem_config_i                         card_mem_conf[NUM_DECODERS](.*);
`endif

GlobalConfig #(
    .SYSTEM_ID(OASIS_SYSTEM_ID),
    .NUM_CONFIGS(NUM_CONFIGS),
    .ADDR_SPACE_SIZES({
        MEM_CONFIG_NUM_REGS,
        COLUMN_CHUNK_DECODER_READ_REGS(NUM_DECODERS),
        NUM_READ_REQ_CONFIG_REGS * NUM_STREAMS,
        ZSCORE_PROFILE_READ_REGS(NUM_ZSCORE_PROFILES)
`ifdef EN_MEM
        , CARD_BUFFER_CONFIG_NUM_REGS
`endif
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

// Read-only: exposes the per-lane z-score StreamProfiler counters, followed by the per-stream egress
// taps. write_configs[3] is unused (the z-score takes no host configuration); GlobalConfig still
// drives it but nothing consumes it.
ZScoreProfileConfig #(
    .NUM_ZSCORES(NUM_ZSCORE_PROFILES)
) inst_zscore_profile_config (
    .clk(clk),
    .rst_n(rst_n),

    .read_config(read_configs[3]),

    .profile(zscore_profiles)
);

`ifdef EN_MEM
// The host-allocated HBM scratch buffer the decode-once replay caches the decoded column in. See
// card_buffer_config.sv: the vaddr MUST come from the host, because Coyote has no card address space
// for the RTL to pick an address out of.
CardBufferConfig #(
    .NUM_LANES(NUM_DECODERS)
) inst_card_buffer_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[4]),
    .read_config(read_configs[4]),

    .out(card_mem_conf)
);
`endif

// -- Arbiter the read send queue ------------------------------------------------------------------
// Slots 0..NUM_STREAMS-1 = the host/RDMA reads (pass 1). With HBM (EN_MEM) there are extra slots
// NUM_STREAMS..+NUM_DECODERS-1 for the per-lane card reads (pass-2 replay) issued by ZScoreCardReplay.
`ifdef EN_MEM
localparam int N_RD = NUM_STREAMS + NUM_DECODERS;
`else
localparam int N_RD = NUM_STREAMS;
`endif
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
// Only needed for the HBM decode-once path: the single shell write queue (sq_wr/cq_wr) is shared by
// the OutputWriter (slot 0) and the per-lane CardWrite stores (slots 1..NUM_DECODERS). sq_wr is
// round-robin arbitered; completions (cq_wr) are split by strm: STRM_HOST -> OutputWriter,
// STRM_CARD -> CardWrite lanes. Without EN_MEM the OutputWriter owns the queue directly.
//
// `notify` is DELIBERATELY NOT SHARED. It is the host interrupt line, and the host decodes every
// interrupt as [stream_id | bytes_written | last] (OasisContext::handle_interrupt) and dispatches it
// to Scheduler::handle_completion, which pops that stream's front pending output completion --
// ignoring `last` entirely. StreamWriter stamps notify.value[2:0] = AXI_STRM_ID, so a CardWrite lane
// would raise an interrupt indistinguishable from its own z-score lane's OutputWriter completion,
// handing the host its flag buffer early and then popping an empty completion list. A CardWrite's
// notify is purely an internal "the store landed" signal (-> store_done), so each lane consumes its
// own below and only the OutputWriter reaches the shell.
`ifdef EN_MEM
localparam int N_WR = NUM_DECODERS + 1;

metaIntf #(.STYPE(req_t))     wr_sq     [N_WR](.aclk(clk), .aresetn(rst_n));
metaIntf #(.STYPE(irq_not_t)) card_notify[NUM_DECODERS](.aclk(clk), .aresetn(rst_n));
metaIntf #(.STYPE(ack_t))     wr_cq_host       (.aclk(clk), .aresetn(rst_n));
metaIntf #(.STYPE(ack_t))     wr_cq_card_all   (.aclk(clk), .aresetn(rst_n));
metaIntf #(.STYPE(ack_t))     wr_cq_card[NUM_DECODERS](.aclk(clk), .aresetn(rst_n));

MetaIntfArbiter #(.N_INTERFACES(N_WR), .STYPE(req_t)) inst_sq_wr_share (
    .clk(clk), .rst_n(rst_n), .intf_in(wr_sq), .intf_out(sq_wr)
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
`endif // EN_MEM

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
    // z-score path would have driven (the arbiters expect every slot driven). Only present under EN_MEM.
`ifdef EN_MEM
    always_comb axis_card_send[I].tie_off_m();
    always_comb axis_card_recv[I].tie_off_s();
    always_comb wr_sq     [I + 1].tie_off_m();
    always_comb card_notify[I].tie_off_m();
    always_comb wr_cq_card[I].tie_off_s();
    always_comb sq_rd_strm[NUM_STREAMS + I].tie_off_m();
    // CardBufferConfig still drives this lane's slot; nothing here consumes the buffer.
    always_comb card_mem_conf[I].tie_off_s();
`endif
    assign zscore_profiles[I].counters = '0;   // no StreamProfiler in the covariance lane (yet)
`else
`ifdef EN_MEM
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

    // Second copy -> HBM via CardWrite, into the host-allocated card buffer this lane was configured
    // with (card_mem_conf[I], straight off CardBufferConfig).
    AXI4S axi_card_store(.aclk(clk), .aresetn(rst_n));
    NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi_card (
        .clk(clk),
        .rst_n(rst_n),

        .in(out_fork[1]),
        .out(axi_card_store)
    );

    CardWrite #(
        .AXI_STRM_ID(I)
    ) inst_card_write (
        .clk(clk),
        .rst_n(rst_n),

        .sq_wr (wr_sq [I + 1]),   // slot 0 is the OutputWriter; CardWrite lanes follow
        .cq_wr (wr_cq_card[I]),
        .notify(card_notify[I]),  // consumed locally as store_done; never reaches the host

        .mem_config(card_mem_conf[I]),

        .input_data(axi_card_store),
        .output_data(axis_card_send[I])
    );

    // -- Decode-once replay control ---------------------------------------------------------------
    // Pass 1: passes axi_decoded straight to the z-score. Between passes: once the CardWrite store
    // completes, issues a card read of the same buffer. Pass 2: feeds HBM-replayed data to the
    // z-score so the second pass skips the decoder entirely.
    AXI4S axi_card_recv_s(.aclk(clk), .aresetn(rst_n));
    `AXIS_ASSIGN(axis_card_recv[I], axi_card_recv_s)

    // store_done: CardWrite raised its final (last_transfer) notify => pass-1 column is durably in
    // HBM. We are this notify's only consumer, so hold ready high (tie_off_s is exactly ready=1) and
    // it handshakes the cycle it is raised; value[31] is StreamWriter's last_transfer flag.
    always_comb card_notify[I].tie_off_s();

    // value[31] = last_transfer, value[30:3] = bytes_written_to_allocation (StreamWriter's own count
    // of what it put in HBM -- the authoritative replay length).
    logic store_done;
    logic [27:0] store_bytes;
    assign store_done  = card_notify[I].valid && card_notify[I].data.value[31];
    assign store_bytes = card_notify[I].data.value[30:3];

    AXI4S axi_zin_raw(.aclk(clk), .aresetn(rst_n));
    ZScoreCardReplay #(
        .AXI_STRM_ID(I),
        .DATABEAT_SIZE(DATABEAT_SIZE)
    ) inst_replay (
        .clk(clk),
        .rst_n(rst_n),

        .decoded_in(axi_decoded),
        .card_recv(axi_card_recv_s),
        .sq_rd(sq_rd_strm[NUM_STREAMS + I]),

        // Replay exactly what CardWrite stored: same buffer, same byte count.
        .card_vaddr(card_mem_conf[I].buffer_data.vaddr),

        .store_done(store_done),
        .store_bytes(store_bytes),

        .zscore_in(axi_zin_raw)
    );

    // Pipeline the replay mux -> z-score crossing. The pass-1/pass-2 select mux in ZScoreCardReplay
    // is combinational off the FSM state, and z-score's pass-1 datapath reads in.tdata straight into
    // the square (unlike pass 2, which is buffered in x_reg). That put the replay mux + decoder
    // output directly into the a_psq accumulate cone (17 logic levels) -> the worst timing path.
    // This skid buffer makes the crossing register-to-register on BOTH passes (full throughput, +1
    // cycle latency, absorbed by backpressure).
    AXI4S axi_zin(.aclk(clk), .aresetn(rst_n));
    AXISkidBuffer inst_zin_skid (
        .clk(clk),
        .rst_n(rst_n),

        .in(axi_zin_raw),
        .out(axi_zin)
    );

    // -- Post-decoder compute stage: z-score (squared, division-free) -----------------------------
    // Classifies each decoded value as outlier (1) / inlier (0). 2-pass: pass 1 from the decoder,
    // pass 2 replayed from HBM (decode-once).
    AXI4S axi_zout(.aclk(clk), .aresetn(rst_n));
    my_z_score_squared inst_z_score (
        .clk(clk),
        .rst_n(rst_n),

        .in(axi_zin),
        .out(axi_zout),

        .profile(zscore_profiles[I])
    );

    // Pipeline the z-score -> OutputWriter crossing. StreamWriter's inst_len_fifo/s_full_reg feeds
    // the z-score's DSP clock enables (DSP_M_DATA/CEM, delay-line SRL CEs) through 3 LUTs of
    // backpressure logic -- and the placer puts the OutputWriter and the DSPs in different SLRs, so
    // that signal crosses the die boundary TWICE in one cycle (build-25: 4.259ns data path, 95% of
    // it route, 549 of 980 user-side violated paths share this one source). This skid buffer splits
    // the round trip into two register-to-register hops. Mirror of inst_zin_skid on the input side.
    AXISkidBuffer inst_zout_skid (
        .clk(clk),
        .rst_n(rst_n),

        .in(axi_zout),
        .out(axi_out[I])
    );
`else
    // -- No-HBM 2-pass z-score (build-05 topology) ------------------------------------------------
    // The column is decoded TWICE from the host: pass 1 accumulates Sum/Sum^2/count, pass 2
    // classifies. No fork / CardWrite / replay -- the z-score reads straight from the decoder each
    // pass. REQUIRED HOST BEHAVIOUR: the host must submit each row-group TWICE (once per pass).
    AXI4S axi_decoded(.aclk(clk), .aresetn(rst_n));
    NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi (
        .clk(clk),
        .rst_n(rst_n),

        .in(out),
        .out(axi_decoded)
    );

    AXI4S axi_zout(.aclk(clk), .aresetn(rst_n));
    my_z_score_squared inst_z_score (
        .clk(clk),
        .rst_n(rst_n),

        .in(axi_decoded),
        .out(axi_zout),

        .profile(zscore_profiles[I])
    );

    // Same z-score -> OutputWriter backpressure crossing as the EN_MEM branch above.
    AXISkidBuffer inst_zout_skid (
        .clk(clk),
        .rst_n(rst_n),

        .in(axi_zout),
        .out(axi_out[I])
    );
`endif // EN_MEM
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
// With HBM the write queue is shared with the CardWrite stores (slot 0 of the arbiters, host-strm
// completions); without HBM the OutputWriter owns the shell write queue directly.
OutputWriter inst_output_writer (
    .clk(clk),
    .rst_n(rst_n),

`ifdef EN_MEM
    .sq_wr(wr_sq[0]),
    .cq_wr(wr_cq_host),
    .notify(notify),   // the OutputWriter alone owns the host interrupt line -- see the note above
`else
    .sq_wr(sq_wr),
    .cq_wr(cq_wr),
    .notify(notify),
`endif

    .mem_config(mem_conf),

    .data_in(axi_out),
    .data_out(axis_host_send)
);

// -- Egress (PCIe) profiling ----------------------------------------------------------------------
// axis_host_send is the LAST signal user logic can see: past it sits local_credits_host_wr, which
// only accepts a beat when the DMA engine has credit to drain it over PCIe. So `stalled` here means
// the PCIe write path itself has no room -- the one direct measurement of link saturation.
//
// This is why the existing taps cannot answer the question: the decoder's out_stalled and the
// z-score's out_stalled both just say "somebody downstream is full", lumping the z-score, the
// OutputWriter, the shared sq_wr arbiter and PCIe together. Comparing them against these counters
// localises the backpressure to a specific hop.
//
// Read out through the existing ZScoreProfileConfig as rows NUM_DECODERS..NUM_DECODERS+NUM_STREAMS-1
// (no host change needed -- it publishes its own count). Only the `out` half is meaningful: there is
// a single interface to watch, so `in` is tied off.
// Egress bytes = out_handshakes x DATABEAT_SIZE; GB/s = bytes / (total_cycles x 4ns) @250MHz.
stream_profile_i egress_profiles[NUM_STREAMS]();

for (genvar I = 0; I < NUM_STREAMS; I++) begin
    localparam int P = NUM_DECODERS + I;

    assign zscore_profiles[P].counters.in  = '0;
    assign zscore_profiles[P].counters.out = egress_profiles[I].counters;
    assign egress_profiles[I].stop         = zscore_profiles[P].stop;

    StreamProfiler inst_egress_profile (
        .clk(clk),
        .rst_n(rst_n),

        .last (axis_host_send[I].tlast),
        .valid(axis_host_send[I].tvalid),
        .ready(axis_host_send[I].tready),

        .profile(egress_profiles[I])
    );
end
