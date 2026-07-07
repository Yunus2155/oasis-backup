cmake_minimum_required(VERSION 3.0)
project(oasis)

set(CYT_DIR ${CMAKE_SOURCE_DIR}/../parcore/libstf/coyote)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${CYT_DIR}/cmake)

# These must be set BEFORE find_package(CoyoteHW), which caches "0"/default values that would
# otherwise win (same gotcha as FDEV_NAME).
set(FDEV_NAME u55c CACHE STRING "Target FPGA device (u55c, v80, ...)")
# Number of ColumnChunkDecoders. The number of streams is equal to this in local mode. If RDMA is
# enabled, there will be an additional RDMA bypass stream for the RDMAFileSystem.
set(N_DECODERS 1 CACHE STRING "Number of ColumnChunkDecoders (default=1)")
# Enable card-memory (HBM) streams so the shell exposes axis_card_send/recv + STRM_CARD DMA. Required
# for the decode-once z-score path (CardWrite stores the decoded column to HBM in pass 1, CardRead
# replays it in pass 2). FORCE because find_package(CoyoteHW) caches EN_MEM=0 by default.
set(EN_MEM 1 CACHE STRING "Enable memory (HBM) streams" FORCE)
set(N_CARD_AXI ${N_DECODERS} CACHE STRING "Number of card (HBM) AXI streams" FORCE)

find_package(CoyoteHW REQUIRED)

# Include Coyote's RDMA stack during synthesis (disable with -DENABLE_RDMA=OFF)
option(ENABLE_RDMA "Enable RDMA stack" ON)

# Number of vFPGAs (user applications)
set(N_REGIONS 1)
set(EN_STRM 1)

if(ENABLE_RDMA)
    math(EXPR N_STREAMS "${N_DECODERS} + 1")
    set(EN_RDMA 1)
    set(N_RDMA_AXI ${N_STREAMS})
    set(N_STRM_AXI ${N_STREAMS})
else()
    set(EN_RDMA 0)
    set(N_STRM_AXI ${N_DECODERS})
endif()

# Build with optimization, since timing closure can be difficult
set(COMP_CORES 32)
set(BUILD_OPT 1)

# Enable 1 GiB huge pages in the TLB
set(TLBL_BITS 30)

validation_checks_hw()

load_apps (
    VFPGA_C0_0 "src ../parcore/libstf/hardware/src ../parcore/vhsnunzip/src ../parcore/hardware/src"
)

create_hw()
