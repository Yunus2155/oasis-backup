#pragma once

#include "libstf/common.hpp"
#include <coyote/cThread.hpp>
#include <libstf/configuration.hpp>
#include <parcore/configuration.hpp> // parcore::DecoderProfile (reused for the z-score stage)

namespace oasis {

constexpr const uint64_t OASIS_SYSTEM_ID = 0x0A515;

// Per-stream write registers: [0] vaddr, [1] size. MUST match NUM_READ_REQ_CONFIG_REGS in
// hardware/src/hdl/common.sv -- the hardware lays the per-stream FIFOs out at this stride, so a
// mismatch makes stream N's writes land in stream N+1's registers.
constexpr const uint64_t READ_REQ_CONFIG_REGS = 2;
constexpr const uint64_t READ_REQ_CONFIG_ID   = 0x2f966a70f04c0e93;

// Read-side register layout of the ZScoreProfileConfig: 2 info registers ([0]=ID, [1]=num_zscores)
// followed by 8 profiling counters per z-score lane (4 input + 4 output). Mirrors the HW layout in
// hardware/src/hdl/common.sv.
constexpr const uint64_t ZSCORE_PROFILE_CONFIG_ID   = 0x7a5c012e9b3d4f60;
constexpr const uint32_t ZSCORE_PROFILE_INFO_REGS    = 2;
constexpr const uint32_t ZSCORE_PROFILE_PROFILE_REGS = 8;

/**
 * Configues a hardware read request module to fetch data.
 */
class ReadReqConfig : public libstf::Config {
  public:
    ReadReqConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                   uint32_t num_regs);

    /**
     * For RDMA reads, sets the base vaddr of the remote region that read addresses are relative to.
     * It must be set before the first enqueue_read().
     */
    void set_base_vaddr(uintptr_t base_vaddr);

    // NOTE: there is deliberately no set_pid(). The hardware has no pid register -- ReadReqConfig
    // instantiates only the vaddr and len FIFOs per stream, and ReadReqGenerator hardcodes
    // sq_rd.data.pid = 0. Giving each stream its own ctid (for parallel RDMA queue pairs) needs a
    // third per-stream register in hardware first, and NUM_READ_REQ_CONFIG_REGS bumped to match.

    /**
     * Triggers a read request using the `RDMARead` or `LocalRead` module.
     *
     * Reads are relative to the base virtual address set via set_base_vaddr().
     */
    void enqueue_read(libstf::stream_t stream, size_t vaddr, size_t size);

    const libstf::stream_t num_streams() const;

    static constexpr size_t MAXIMUM_NUM_ENQUEUED_REQUESTS = 64;

    static constexpr uint64_t ID = READ_REQ_CONFIG_ID;

  private:
    libstf::stream_t num_streams_;
    uintptr_t        base_vaddr_ = 0;
};

/**
 * Read-only access to the per-lane z-score StreamProfiler counters (one z-score lane per decoder).
 * Mirrors parcore::ColumnChunkDecoderConfig::read_profile, against the ZScoreProfileConfig slot.
 */
class ZScoreProfileConfig : public libstf::Config {
  public:
    ZScoreProfileConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                        uint32_t num_regs);

    /**
     * Reads the input and output StreamProfiler counters for the given z-score lane.
     *
     * @param zscore The z-score lane whose profiling counters to read.
     */
    parcore::DecoderProfile read_profile(libstf::stream_t zscore);

    const libstf::stream_t num_zscores() const;

    static constexpr uint64_t ID = ZSCORE_PROFILE_CONFIG_ID;

  private:
    libstf::stream_t num_zscores_;
};

} // namespace oasis
