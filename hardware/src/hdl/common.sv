package oasis;

import libstf::vaddress_t;
import libstf::size_t;

parameter longint unsigned OASIS_SYSTEM_ID = 64'h0A515;

parameter int NUM_READ_REQ_CONFIG_REGS = 2;
parameter longint unsigned READ_REQ_CONFIG_ID = 64'h2f966a70f04c0e93;

typedef struct packed {
    vaddress_t vaddr;
    size_t     len;
} read_req_t;

// -- ZScoreProfileConfig: read-only readout of the per-lane z-score StreamProfiler counters --------
// Layout mirrors the decoder profile readout: [0] = CONFIG_ID, [1] = NUM_ZSCORES, then 8 counters
// per z-score lane (4 input-stream + 4 output-stream).
parameter longint unsigned ZSCORE_PROFILE_CONFIG_ID    = 64'h7a5c012e9b3d4f60;
parameter longint unsigned ZSCORE_PROFILE_INFO_REGS    = 2;
parameter longint unsigned ZSCORE_PROFILE_PROFILE_REGS = 8;
function automatic longint unsigned ZSCORE_PROFILE_READ_REGS(input int num_zscores);
    return ZSCORE_PROFILE_INFO_REGS + ZSCORE_PROFILE_PROFILE_REGS * num_zscores;
endfunction

endpackage
