# Oasis From Scratch — A Tutorial

This is a teaching document, not a reading list. Every term is defined the first time it appears.
Every module is built line by line with the reasoning shown. You are expected to have written some
digital logic before (VHDL is fine) and to know basic C++ — everything else is explained here.

Work through it in order. Later lessons assume the vocabulary from earlier ones.

**Contents**

- **Part I — The machine and the vocabulary** — L1 the FPGA · L2 host and card · L3 the handshake ·
  L4 beats and lanes · L5 registers and pipelines
- **Part II — Talking to the host** — L6 the config plane · L7 addresses and memory
- **Part III — The data** — L8 Parquet and the decoder
- **Part IV — Build an operator from scratch** — L9 SumOperator · L10 adding a multiplier ·
  L11 reading covariance.sv · L12 two passes and the z-score trick
- **Part V — Integration** — L13 wiring into vfpga_top · L14 testing it
- **Part VI — The host side** — L15 the C++ library · L16 the DuckDB function · L17 feeding the FPGA
- **Part VII — Making it real** — L18 the four counters · L19 build, flash, run

---
---

# Part I — The machine and the vocabulary

---

## Lesson 1 — What you are actually programming

### The chip

An **FPGA** (Field-Programmable Gate Array) is a chip full of small hardware pieces plus programmable
wiring between them. You don't write instructions that a processor executes. You *describe a circuit*,
and a tool physically arranges the chip's pieces into that circuit.

The pieces you will care about, on the **Alveo U55C** card this project targets:

| Piece | What it is | You use it for |
|---|---|---|
| **LUT** (Look-Up Table) | a tiny 6-input truth table | any combinational logic — comparisons, muxes, adders |
| **FF** (Flip-Flop) | stores exactly 1 bit, updated on a clock edge | every register, every pipeline stage |
| **DSP** | a hardened multiply-accumulate block | multiplication. There are ~9000. **They are the currency of this project.** |
| **BRAM / URAM** | small on-chip memories (~36 Kb / ~288 Kb each) | lookup tables, FIFOs, hash tables |
| **HBM** | High-Bandwidth Memory, 16 GB stacked on the card | caching large intermediate data |

The critical intuition: **you have thousands of multipliers and they all run at once.** A CPU has a
handful of ALUs and executes a loop over time. You will build a circuit that does 136 multiplications
*per clock cycle, every cycle*. That is the entire reason this project exists.

### The clock

Everything is synchronised to a **clock** — a square wave. This design runs at **250 MHz**, so a
**clock cycle** is 4 nanoseconds. On each rising edge, every flip-flop in the design simultaneously
captures whatever its input wire happens to be showing at that instant.

That gives you the fundamental constraint of hardware design:

> Any chain of combinational logic between two flip-flops must finish settling in under 4 ns.

If it doesn't, a flip-flop captures a half-finished value and your design produces garbage. The tool
measures this and reports **slack** — time to spare. Negative slack means failure. You'll see
**WNS** (Worst Negative Slack); it must be ≥ 0. Getting there is called **timing closure**, and
Lesson 5 and Lesson 10 are largely about it.

### From text to chip

```
your .sv files
   │  synthesis        "turn this description into gates"      (minutes to hours)
   ▼
   netlist
   │  place & route    "assign real chip locations and wires"  (hours)
   ▼
   bitstream (.bit)    the file that configures the chip
   │  flash            load it onto the card                   (seconds)
   ▼
   working hardware
```

The whole loop is *hours*. This is why simulation exists (Lesson 14) and why you must be deliberate
about what you change between builds (Lesson 19).

### What Oasis does

A query engine (DuckDB) wants to read **Parquet** files — a compressed columnar format used by every
data lake. Normally the CPU decompresses and decodes them, which is expensive and repetitive.

Oasis moves that work onto the FPGA, and while the data is already there, does some maths on it too:

```
compressed Parquet bytes  →  [FPGA: decode]  →  [FPGA: compute]  →  results to DuckDB
```

Your job in this project is mostly the second box.

---

## Lesson 2 — Two computers, one cable

There are two machines and you must always know which one you're talking about.

```
┌─────────────────────────┐                    ┌──────────────────────────┐
│  HOST (an x86 server)   │                    │  CARD (the Alveo U55C)   │
│                         │  ◄── PCIe ──────►  │                          │
│  DuckDB, your C++,      │      ~16 GB/s      │  your RTL, 16 GB HBM     │
│  the Linux driver,      │                    │                          │
│  host RAM               │                    │                          │
└─────────────────────────┘                    └──────────────────────────┘
```

**PCIe** is the cable. **DMA** (Direct Memory Access) means the card reads and writes host RAM by
itself, without the CPU copying anything. This is how all bulk data moves.

### Addresses, and a rule that will bite you

Your C++ program sees **virtual addresses** — the CPU's memory-management unit translates them to
physical RAM locations. The FPGA sits outside the CPU, so it needs its own copy of that translation
table. In Coyote that's the **TLB** (Translation Lookaside Buffer), maintained by the Linux driver.

The consequence, and it is absolute:

> **The FPGA can only touch addresses the host has explicitly allocated and mapped.** Your RTL cannot
> invent an address. A DMA to an unmapped address makes the card page-fault into the driver, and in
> practice takes the node down.

This applies even to HBM — the memory physically on the card. Coyote has no separate card address
space; a card transfer carries a *host* virtual address whose pages the driver shadows into HBM.
There is a comment saying exactly this in
[hardware/src/hdl/common.sv:26-37](hardware/src/hdl/common.sv#L26-L37). Lesson 7 returns to it.

**Hugepages** are 1 GiB memory pages (instead of the usual 4 KiB). Fewer pages means fewer TLB
entries for a big buffer, which means the FPGA doesn't stall doing address translation. You reserve
them before running anything; that's part of board setup (Lesson 19).

### The shell and your logic

You do not write the PCIe controller. **Coyote** is a framework that provides a **shell** — the
permanent infrastructure on the chip: PCIe, DMA engines, the TLB, the RDMA network stack, HBM
controllers. Inside the shell is a slot for user logic called a **vFPGA** (virtual FPGA).

**Everything you write lives in the vFPGA, and it starts at one file:**

```
hardware/src/vfpga_top.svh
```

`.svh` means "SystemVerilog header": it isn't a module with its own `module`/`endmodule`. Coyote
`` `include ``s it *inside* a module it generates for you, which is why the file starts straight in
with declarations and has no port list. The ports (`axis_host_recv`, `sq_wr`, `axi_ctrl`, …) already
exist in the enclosing scope; you just use them.

What the shell hands you:

| Signal | Direction | Purpose |
|---|---|---|
| `axis_host_recv[]` | in | bulk data arriving from host RAM |
| `axis_host_send[]` | out | bulk data going back to host RAM |
| `axi_ctrl` | in/out | small control register access (Lesson 6) |
| `sq_rd` / `sq_wr` | out | **send queue**: "please DMA this much from/to this address" |
| `cq_rd` / `cq_wr` | in | **completion queue**: "that DMA finished" |
| `notify` | out | raise an interrupt on the host CPU |
| `axis_card_recv/send[]` | in/out | HBM streams (only when `EN_MEM` is on) |
| `axis_rreq_*` / `axis_rrsp_*` | in/out | RDMA network streams (only when `EN_RDMA` is on) |

Anything you don't use must be **tied off** — explicitly driven to a safe idle state, or synthesis
complains and the shell may hang waiting on a signal nobody drives:

```systemverilog
always_comb cq_rd.tie_off_s();      // "I am a slave on cq_rd and I want nothing"
```

You'll see a block of these at the top of
[vfpga_top.svh](hardware/src/vfpga_top.svh#L11-L35).

---

## Lesson 3 — The handshake: how one module gives data to another

### The problem

Two modules, `A` produces and `B` consumes, sharing a clock so both wake on every rising edge — 250
million times a second.

Naive approach: `A` puts a number on a wire, `B` reads it. Breaks immediately:

- `A` has nothing to send this cycle → `B` reads leftover garbage and treats it as data.
- `B` is busy and can't take it → `A` sends anyway, the value is lost forever.

Both sides must *agree*, every cycle, that a transfer happened. That agreement is the **handshake**
and it costs two wires.

### The two wires

```
        ┌───────────┐                      ┌───────────┐
        │           │ ──── data ────────►  │           │
        │     A     │ ──── valid ───────►  │     B     │
        │ producer  │                      │ consumer  │
        │           │ ◄─── ready ────────  │           │
        └───────────┘                      └───────────┘
```

**`valid`** — driven by `A`: *"I am offering data right now; the `data` wires are meaningful."*

**`ready`** — driven by `B`: *"I can accept data right now."*

Note the directions. `valid` flows **forward** with the data; `ready` flows **backward** against it.
That backward wire is the whole point — it's how a slow consumer tells a fast producer to wait. That
mechanism is called **backpressure**, and it is the reason this design never loses data no matter
which stage is slowest.

### The one rule

> **A transfer happens on a clock edge if and only if `valid` AND `ready` are both 1.**

You will write this condition constantly:

```systemverilog
if (in.valid && in.ready) begin
    // a beat just moved. Consume it.
end
```

A **beat** is one such transfer — one cycle's worth of data that successfully moved. A 512-bit stream
doing one beat per cycle at 250 MHz carries 16 GB/s.

Four possible states per cycle:

| `valid` | `ready` | Result | Name |
|:---:|:---:|---|---|
| 0 | 0 | nothing | **idle** — nobody wants anything |
| 0 | 1 | nothing | **starved** — B waiting, A has nothing |
| 1 | 0 | nothing | **stalled** — A offering, B refusing |
| 1 | 1 | **transfer** | **handshake** — work got done |

**Memorise this table.** Those four names are literally the four counters `StreamProfiler` measures,
and in Lesson 18 you will diagnose all performance problems by asking which row your design sits in.

### The two rules you must not break

**Rule 1 — `valid` must not depend combinationally on `ready`.**

```systemverilog
assign out.valid = in.valid && out.ready;   // ✗ NEVER
```

`B` decides `ready` by looking at `valid`; now `A` decides `valid` by looking at `ready`. Each waits
for the other *within the same instant* — a **combinational loop**. Not "slow": unresolvable. The
reverse direction is legal: `ready` **may** look at `valid`. Data flows forward, permission flows
backward, and only one of those may be instantaneous.

**Rule 2 — once `valid` is asserted, hold it (with unchanged payload) until the handshake.**

```systemverilog
if (out.valid && !out.ready) out.valid <= 1'b0;   // ✗ withdrawing the offer
```

`B` may have been about to accept. Withdrawing means data silently vanishes. Once you say "I have
data," you are committed until someone takes it.

### Three companion signals

Real streams carry three more wires alongside `data`:

**`last`** (`tlast` in AXI) — 1 on the final beat of a message. Without it, `B` never knows the
column chunk ended and waits forever.

**`keep`** (`tkeep`) — one bit per element, marking which are real. A 512-bit beat holds 16 lanes of
32 bits. A column of 100 values ends with a beat containing only 4 real ones:
`keep = 16'b0000_0000_0000_1111`. Ignore `keep` and you process 12 pieces of garbage — the most
common silent-wrong-answer bug in this project.

**`clk` / `rst_n`** — clock and reset. The `_n` suffix means **active low**: in reset when
`rst_n == 0`, running when `rst_n == 1`.

### Build one

A module that passes data through but **drops beats where nothing is valid** (`keep` all zero — this
really happens after a filter removes everything in a beat).

`data_i` is this project's stream connector: it bundles `data`/`keep`/`last`/`valid`/`ready` so you
don't wire five signals by hand.

```systemverilog
module DropEmptyBeats (
    input logic clk,
    input logic rst_n,

    data_i.s in,    // .s = slave  = I CONSUME this stream
    data_i.m out    // .m = master = I PRODUCE this stream
);
```

`.s` and `.m` are **modports** — they declare which side of the connector you are, and therefore
which wires you're allowed to drive. On `.s` you drive `ready` and read `valid`/`data`; on `.m` the
mirror image. Getting these backwards is the classic first-week error, and the tool tells you:
*"cannot assign to input."*

Now the logic — three questions, in order.

**1. When can I accept input?** When my output can take it, *or* when I'm going to throw the beat
away (throwing away is free):

```systemverilog
logic beat_is_empty;
assign beat_is_empty = (in.keep == '0);   // '0 = "all zeros, whatever the width"

assign in.ready = out.ready || beat_is_empty;
```

Read that again: if the beat is empty I'm ready **regardless** of downstream. That is how the beat
gets consumed and discarded rather than forwarded.

**2. When do I offer output?** When I have real input that isn't empty:

```systemverilog
assign out.valid = in.valid && !beat_is_empty;
```

Check Rule 1 — does `out.valid` mention `out.ready`? No. Legal. ✓

**3. What about the payload?** Straight through:

```systemverilog
assign out.data = in.data;
assign out.keep = in.keep;
assign out.last = in.last;

endmodule
```

Notice what is *absent*: no `always_ff`, no registers, no use of reset. This module is purely
**combinational** — outputs change the instant inputs do, in the same cycle, with zero added latency.
Fine at this size. The cost is that it lengthens the logic path between its neighbours, which is
exactly what eventually breaks the 4 ns budget. Lesson 5 shows the fix.

### Check yourself

1. A beat arrives with `keep = 0` while `out.ready = 0`. Is it consumed?
   *Yes — `in.ready` is 1 via `beat_is_empty`. That's the feature.*
2. There's a real bug here. What if the **last** beat is empty?
   *`last` is dropped with it. Downstream waits forever for an end-of-message that never arrives —
   a genuine deadlock. Fix: forward a beat when `in.last` is set even if it's empty, or latch `last`
   and attach it to the next beat you do forward.*

---

## Lesson 4 — Beats, lanes, and the three stream types

### One beat, sixteen lanes

The data path is **512 bits wide**. That number comes from the PCIe/DMA infrastructure, and
everything else is shaped around it.

If your column holds 32-bit integers, one beat carries 16 of them:

```
 bit 511                                                                    bit 0
 ┌───────┬───────┬───────┬───────┬─── … ───┬───────┬───────┬───────┬───────┐
 │ val15 │ val14 │ val13 │ val12 │         │ val3  │ val2  │ val1  │ val0  │
 └───────┴───────┴───────┴───────┴─── … ───┴───────┴───────┴───────┴───────┘
   32b     32b     32b     32b                32b     32b     32b     32b

 keep:  1       1       0       0     …      1       1       1       1
        └── these two lanes are padding, ignore them ──┘
```

Each 32-bit slot is a **lane**. Sixteen lanes, and **all sixteen are processed simultaneously by
separate hardware.** Your circuit is instantiated 16 times over. That's the parallelism.

### Three ways to look at the same wires

The project has three stream interfaces. They carry the same information; they differ in how
convenient they are.

**1. `AXI4S` — the raw industry-standard stream.** Flat bits. This is what the shell and the decoder
speak.

```systemverilog
in.tdata     // logic [511:0]  — one flat blob
in.tkeep     // logic [63:0]   — one bit per BYTE
in.tlast     // logic
in.tvalid    // logic
in.tready    // logic
```

Note `tkeep` is **per byte**, not per lane. 64 bytes in 512 bits. A 32-bit lane needs 4 keep bits.

**2. `data_i` — libstf's simplified single-value stream.** `data` / `keep` / `last` / `valid` /
`ready`. Used for narrow things (a mask, a control token).

**3. `ndata_i` — libstf's *typed, lane-aware* stream. This is the one you want for operators.**

```systemverilog
ndata_i #(.data_t(logic [31:0]), .NUM_ELEMENTS(16)) nin();
```

Now you write:

```systemverilog
nin.data[7]    // lane 7, already sliced out, already the right type
nin.keep[7]    // ONE bit for lane 7 — not four
nin.valid, nin.ready, nin.last
```

`#(...)` passes **parameters** — compile-time constants that specialise a module or interface. Here
`data_t` is a *type* parameter (SystemVerilog lets you parameterise by type; VHDL can't) and
`NUM_ELEMENTS` is the lane count.

### Converting between them

`AXIToNData` does the slicing for you:

```systemverilog
ndata_i #(.data_t(logic [31:0]), .NUM_ELEMENTS(16)) nin();

AXIToNData #(
    .data_t(logic [31:0]),
    .NUM_ELEMENTS(16)
) inst_axi_to_data (
    .clk(clk),
    .rst_n(rst_n),
    .in(in),        // AXI4S  — flat 512 bits, per-byte keep
    .out(nin)       // ndata_i — 16 typed lanes, per-lane keep
);
```

`NDataToAXI` goes the other way. **Convert once at your module's input, work in `ndata_i`, convert
back at the output.** Every operator in this repo does exactly this — see
[covariance.sv:51-61](hardware/src/hdl/covariance/covariance.sv#L51-L61).

By convention every module instance is named `inst_something`.

### Why an `interface` at all

A SystemVerilog **`interface`** is a named bundle of wires plus the rules for who drives what. Instead
of:

```systemverilog
module Thing (
    input  logic [511:0] in_tdata,  input  logic [63:0] in_tkeep,
    input  logic in_tlast, input logic in_tvalid, output logic in_tready,
    output logic [511:0] out_tdata, output logic [63:0] out_tkeep,
    output logic out_tlast, output logic out_tvalid, input logic out_tready
);
```

you write:

```systemverilog
module Thing (AXI4S.s in, AXI4S.m out);
```

Same wires, no chance of typo'ing one of ten connections, and the modport enforces direction. If you
know VHDL: it's like a record that also knows which fields are inputs and which are outputs.

---

## Lesson 5 — Registers, pipelines, and why your design is too slow

### Two kinds of logic

**Combinational** — output is a pure function of input, right now, no memory:

```systemverilog
always_comb begin
    sum = a + b;
end
// or, for a single expression:
assign sum = a + b;
```

**Sequential** — output updates only on a clock edge, and remembers between edges:

```systemverilog
always_ff @(posedge clk) begin
    sum <= a + b;
end
```

`always_ff` means "I promise these become flip-flops" and the tool checks you. `always_comb` means "I
promise this is pure logic" and the tool warns if you accidentally create memory (a **latch** — a
half-register that appears when a combinational block doesn't assign a value on every path; always a
bug here).

### `<=` versus `=`

This is the single most common source of confusion coming from software, and it maps cleanly if you
know VHDL.

**`<=` is non-blocking**, used in `always_ff`. All right-hand sides are evaluated using the *old*
values, then all left-hand sides update *simultaneously* at the clock edge. It models real
flip-flops.

```systemverilog
always_ff @(posedge clk) begin
    a <= b;
    b <= a;      // swaps a and b — both read the OLD values
end
```

**`=` is blocking**, used in `always_comb`. Executes top to bottom like software.

```systemverilog
always_comb begin
    a = b;
    b = a;      // does NOT swap — a is already b
end
```

Rule: `always_ff` → `<=`. `always_comb` → `=`. Mixing them produces designs that simulate differently
from how they synthesise, which is the worst class of bug you can have.

### Reset

```systemverilog
always_ff @(posedge clk) begin
    if (!rst_n) begin
        counter <= '0;          // active low: reset when rst_n is 0
    end else begin
        counter <= counter + 1;
    end
end
```

The reset signal must reach thousands of flip-flops spread across the chip, and that fan-out is
itself a timing problem. libstf gives you a macro:

```systemverilog
`include "libstf_macros.svh"

module MyThing (...);
`RESET_RESYNC                    // creates a locally-buffered `reset_synced`
// ... then use reset_synced everywhere instead of rst_n
```

You'll see `` `RESET_RESYNC `` at the top of nearly every module here, and `reset_synced` used in the
body — for example [covariance.sv:37](hardware/src/hdl/covariance/covariance.sv#L37) and then
[line 109](hardware/src/hdl/covariance/covariance.sv#L109). Just follow the pattern.

### Latency versus throughput

Two different things, constantly confused.

**Latency** — cycles from an input entering to its result emerging.
**Throughput** — results per cycle, in steady state.

A **pipeline** trades the first for the second. Suppose computing `(a*b) + c` takes 3 ns of logic —
close to your 4 ns budget, and it will fail once routing delay is added. Split it:

```systemverilog
always_ff @(posedge clk) begin
    stage1 <= a * b;          // ~2 ns of work
    stage2 <= stage1 + c;     // ~1 ns of work
end
```

Now no path exceeds 2 ns. **Latency became 2 cycles; throughput is still one result per cycle** —
because while stage 2 works on beat *N*, stage 1 is already working on beat *N+1*. Both stages are
busy every cycle.

This is the central move of FPGA design: **when timing fails, add a register in the middle.** In this
codebase the z-score's pass-1 reduction is deliberately split into four stages for exactly this
reason (per-lane square → reduce 16→4 → reduce 4→1 → accumulate), documented at
[z_score_squared.sv:38-45](hardware/src/hdl/z-score/z_score_squared.sv#L38-L45).

### The bill that comes with pipelining

Pipelining data creates a problem you must handle every single time:

> If the data takes 3 extra cycles, then `valid`, `keep` and `last` must **also** take 3 extra
> cycles, or the metadata describes the wrong beat.

The standard fix is a **delay line** — a shift register carrying metadata alongside the data:

```systemverilog
logic [15:0] keep_reg  [3];     // 3-deep delay line, 16 bits wide
logic        valid_reg [3];

always_ff @(posedge clk) begin
    keep_reg[0]  <= nin.keep;       // stage 0 captures this cycle
    valid_reg[0] <= accepted;
    for (int s = 1; s < 3; s++) begin
        keep_reg[s]  <= keep_reg[s-1];      // everything shifts along
        valid_reg[s] <= valid_reg[s-1];
    end
end
```

After 3 cycles, `keep_reg[2]` describes the beat whose result is arriving *now*. You'll build this in
Lesson 10 and see the production version in Lesson 11.

### The skid buffer

Recall Rule 1: `valid` may not depend on `ready`. Fine — but `ready` propagating backwards through
ten modules combinationally makes one enormous path that blows the 4 ns budget.

A **skid buffer** breaks it. It registers the stream in both directions while never losing a beat,
using two storage slots so it can absorb the beat already in flight when it says "stop".

```systemverilog
AXISkidBuffer inst_skid (.clk(clk), .rst_n(rst_n), .in(fast_side), .out(slow_side));
```

Costs 1 cycle of latency, buys you a clean timing boundary. When a worst-path report points at a long
`ready` chain, this is the fix. Source (worth reading, it's 44 lines):
`parcore/libstf/hardware/src/hdl/util/skid_buffer.sv`.

---
---

# Part II — Talking to the host

---

## Lesson 6 — The config plane: how software sets a value in your circuit

Your operator needs runtime parameters — how many columns, which threshold, where to write output.
These arrive over a completely separate, tiny channel from the bulk data.

### Two channels, different jobs

| | **AXI4-Stream** (`axis_*`) | **AXI4-Lite** (`axi_ctrl`) |
|---|---|---|
| Carries | bulk data | individual register values |
| Width | 512 bits | 64 bits |
| Speed | 16 GB/s | one value at a time, slow |
| Direction | flows continuously | host writes / host reads |
| Think of it as | a firehose | a control panel |

A **register** here means: a location with a number, which host software writes by address and your
RTL reads as a signal. That's the entire abstraction.

### The address map

`GlobalConfig` (from libstf) takes the single `axi_ctrl` port and splits it into several independent
config blocks, each owning a slice of the address space:

```systemverilog
GlobalConfig #(
    .SYSTEM_ID(OASIS_SYSTEM_ID),        // magic number so the host can verify the bitstream
    .NUM_CONFIGS(NUM_CONFIGS),          // how many blocks
    .ADDR_SPACE_SIZES({                 // how many registers each block owns
        MEM_CONFIG_NUM_REGS,                          // [0] output buffers
        COLUMN_CHUNK_DECODER_READ_REGS(NUM_DECODERS), // [1] decoder
        NUM_READ_REQ_CONFIG_REGS * NUM_STREAMS,       // [2] read requests
        ZSCORE_PROFILE_READ_REGS(NUM_DECODERS)        // [3] profiling counters
    })
) inst_config (
    .clk(clk), .rst_n(rst_n),
    .axi_ctrl(axi_ctrl),
    .write_configs(write_configs),      // array of NUM_CONFIGS write channels
    .read_configs(read_configs)         // array of NUM_CONFIGS read channels
);
```

`SYSTEM_ID` is `64'h0A515` ("OASIS" in leetspeak) — the host reads it first to confirm it's talking
to the bitstream it thinks it is. Cheap, and it has caught real mistakes.

> **⚠ The bookkeeping trap.** `ADDR_SPACE_SIZES` must have **exactly** `NUM_CONFIGS` entries.
> Because some blocks only exist under `` `ifdef EN_MEM ``, both the count and the list are wrapped
> in `ifdef`s, in two separate places
> ([vfpga_top.svh:45-49](hardware/src/vfpga_top.svh#L45-L49) and
> [88-96](hardware/src/vfpga_top.svh#L88-L96)). Change one, forget the other, and you get a
> confusing elaboration error. Whenever you add a config block, grep for `NUM_CONFIGS` and fix
> **every** hit.

### Reading a real config block, line by line

[hardware/src/hdl/read_req_config.sv](hardware/src/hdl/read_req_config.sv) is only 61 lines and shows
both directions. Here it is with commentary.

```systemverilog
module ReadReqConfig #(
    parameter NUM_STREAMS
) (
    input logic clk,
    input logic rst_n,

    write_config_i.s write_config,     // host → FPGA
    read_config_i.s  read_config,      // FPGA → host
    ready_valid_i.m  out[NUM_STREAMS]  // the decoded values, one channel per stream
);
```

Note `out` is a `ready_valid_i` — a **stream**, not a plain wire. That's deliberate: config values
here are *consumed*. Each read request is used once and then the next one is needed.

**The read side** — values the host can query:

```systemverilog
logic[AXIL_DATA_BITS - 1:0] values[2];
assign values[0] = READ_REQ_CONFIG_ID;    // "which block am I?"
assign values[1] = NUM_STREAMS;           // "how many streams do I have?"

ConfigReadRegisterFile #(.NUM_REGS(2)) inst_read_regs (
    .clk(clk), .rst_n(reset_synced),
    .in(read_config),
    .values(values)
);
```

You hand it an array of signals; software can read them by index. That's all a read register is. This
is exactly how the performance counters get out in Lesson 18.

**The write side** — values the host pushes in:

```systemverilog
for (genvar I = 0; I < NUM_STREAMS; I++) begin
    ready_valid_i #(vaddress_t) vaddr ();
    ConfigWriteFIFO #(I * NUM_WRITE_REGS + 0, MAX_NUM_ENQUEUED_BUFFERS, vaddress_t)
        inst_vaddr (clk, reset_synced, write_config, vaddr);

    ready_valid_i #(size_t) len ();
    ConfigWriteFIFO #(I * NUM_WRITE_REGS + 1, MAX_NUM_ENQUEUED_BUFFERS, size_t)
        inst_len (clk, reset_synced, write_config, len);

    ReadyValidCombiner inst_ready_combine (.left(vaddr), .right(len), .out(out[I]));
end
```

Four things worth understanding here:

- **`genvar` / `generate`** — a *compile-time* loop. This doesn't loop at runtime; it stamps out
  `NUM_STREAMS` copies of the hardware inside. Same idea as VHDL's `for … generate`.
- **`ConfigWriteFIFO`** rather than a plain register. A **FIFO** (First In First Out queue) lets the
  host **enqueue up to 64 requests ahead of time** instead of waiting for each to be consumed. This
  is your first sighting of the single most important performance idea in the project: *keep work
  queued up so the hardware never waits for software.* Lesson 17 is entirely about this.
- The first parameter (`I * NUM_WRITE_REGS + 0`) is the **register index** — the address the host
  writes to. This number must match the C++ side exactly (Lesson 15).
- **`ReadyValidCombiner`** merges two streams into one that is valid only when *both* inputs are
  valid, so a request only emerges when its address *and* its length have arrived. Without this you
  could act on half a request.

The comment at lines 51-53 is worth reading too: a libstf macro had to be expanded by hand because
its generated instance name broke under Vivado. Real toolchains have sharp edges; when something
inexplicable happens, someone has often already left you a note.

---

## Lesson 7 — Addresses: telling the FPGA where the data is

### The request type

```systemverilog
typedef struct packed {
    vaddress_t vaddr;    // where in host memory
    size_t     len;      // how many bytes
} read_req_t;
```

**`struct packed`** means the fields are laid out as one contiguous bit vector — no padding, fully
synthesisable, and you can treat the whole thing as a number when convenient. (Unpacked structs
exist too, and are not synthesisable. Always use `packed` in RTL.)

### The flow

```
  DuckDB: "I need bytes 4096..8192 of this Parquet file"
        │
        ▼
  C++: allocate a host buffer, get its virtual address
        │
        ▼
  C++: write {vaddr, len} into the ReadReqConfig registers      ← Lesson 6
        │
        ▼
  RTL: ReadReqConfig emits a read_req_t on `out[stream]`
        │
        ▼
  RTL: ReadReqGenerator turns it into a Coyote descriptor on `sq_rd`
        │
        ▼
  Shell: DMAs the bytes; they appear on axis_host_recv[stream]
```

Read [read_req_generator.sv](hardware/src/hdl/read_req_generator.sv) (84 lines) with that picture in
mind.

> **⚠ Stride arithmetic is silent when wrong.** If you compute the address of "the next chunk"
> incorrectly, the hardware happily fetches *some other perfectly valid bytes*. No error, no crash —
> just wrong answers, or a decoder that chokes on what it thinks is a corrupt page. This has cost
> real debugging time on this project. When output is mysteriously wrong, check the addresses being
> requested **before** you suspect your maths.

### The two data sources

- **[local_read.sv](hardware/src/hdl/local_read.sv)** (58 lines) — data is already in host RAM. Used
  when `EN_RDMA` is off.
- **[rdma_read.sv](hardware/src/hdl/rdma_read.sv)** (111 lines) — data is fetched over the network by
  the FPGA itself. **RDMA** (Remote Direct Memory Access) lets one machine read another's memory with
  no CPU involvement on either end. This is the "SmartNIC" part of the pitch: the data never touches
  the host CPU before the FPGA has already decoded it.

### `fix_last.sv` — a lesson in seams

46 lines that exist purely because two components disagree about when `tlast` should be asserted. Not
glamorous, but read it: **most of the work in an integration project is shims like this**, and
recognising "this is a seam problem, not a logic problem" will save you hours.

### Back to the address rule

Lesson 2 said the FPGA can't invent addresses. Here's where it becomes concrete: HBM.

You'd like to say "write this to HBM offset 0" — the memory is physically on the card, after all.
**You cannot.** Coyote has no card address space. A card-stream transfer carries a *host* virtual
address whose pages the driver has shadowed into HBM; the `strm` field picks *which copy* of that
address the DMA hits, not a different address space.

So the decode-once cache (Lesson 12) works like this: the host allocates a normal buffer, gets it
mapped, and passes its vaddr down through `CardBufferConfig` — the FPGA is *given* the address, never
chooses it. The full explanation is in
[common.sv:26-37](hardware/src/hdl/common.sv#L26-L37), written by someone who found out the hard way.

---
---

# Part III — The data

---

## Lesson 8 — Parquet, and what the decoder hands you

You don't have to *build* the decoder, but you must know what comes out of it.

### File structure

```
file.parquet
├── row group 0                ← ~100k rows; the unit the host submits
│   ├── column chunk "price"   ← ONE column's data for those rows; what the decoder eats
│   │   ├── dictionary page    ← (optional) the distinct values
│   │   ├── data page 0        ← header + encoded values
│   │   └── data page 1
│   └── column chunk "qty"
├── row group 1
└── footer                     ← schema + where everything is
```

**Columnar** means values of one column are stored together. That's why FPGA acceleration works at
all: a column chunk is thousands of same-typed values in a row, perfect for 16 lanes of identical
hardware. A row-oriented format would give you 16 lanes of *different* types and no parallelism.

### The encodings ParCore handles

From [parcore/README.md](parcore/README.md): *"Snappy or no compression, plain and dictionary/hybrid
encoding."* Outside that is out of scope — knowing the boundary saves you hunting for code that
doesn't exist.

**PLAIN** — values back to back, fixed width. Trivial.

**Dictionary + RLE/bit-packed hybrid** — instead of values, store *indices* into a dictionary page.
Indices are small, so they're bit-packed at the minimum width, in alternating runs:

```
[varint header][run][varint header][run]...
   header & 1 == 0  →  bit-packed run: header>>1 groups of 8 values
   header & 1 == 1  →  RLE run:        header>>1 repeats of one value
```

A **varint** is a variable-length integer: 7 bits of payload per byte, top bit = "more follows". So
even finding where a run *starts* requires decoding what came before — inherently serial, which is
precisely why it's hard in hardware and why the decoder is the bottleneck.

**Snappy** — LZ77-style compression: literals plus back-references ("copy 12 bytes from 300 bytes
ago"). Handled by `vhsnunzip`, third-party VHDL wrapped for this design.

### What ParCore gives you

```systemverilog
ColumnChunkDecoder   // parcore/hardware/src/hdl/column_chunk_decoder.sv
```

In: compressed Parquet column chunk bytes.
Out: **an `AXI4S` stream of decoded, fixed-width values**, 16 lanes of 32 bits per beat, with `keep`
marking the valid lanes and `last` on the final beat.

That's your input. From Lesson 9 onward, assume it.

### Why the decoder is the ceiling

Every stage of decoding is byte-unaligned and serial. Where your operator does 16 lanes per cycle
trivially, the decoder fights for every beat. Real measured numbers on this project put decoder
throughput around **9 GB/s** against a PCIe link that can do ~16 GB/s.

Two consequences that shape everything downstream:

1. **You have compute budget to spare.** Your operator is not the bottleneck, so prefer designs that
   do more arithmetic rather than more passes.
2. **Reading the data twice costs double the *dominant* cost.** This is what makes the two-pass
   z-score expensive and motivates the HBM cache in Lesson 12.

You can raise the ceiling by instantiating more decoders (`./scripts/synthesize.sh --decoders 4`) —
they run in parallel on separate streams, and area permitting, that's the simplest lever you have.

---
---

# Part IV — Build an operator from scratch

---

## Lesson 9 — SumOperator: your first operator, line by line

**Goal:** consume a decoded column, add up every value, emit the total. Trivial maths, so all the
attention goes to structure — and this structure is exactly what covariance and z-score use.

### Step 1 — The shape

```systemverilog
`timescale 1ns / 1ps

`include "libstf_macros.svh"

module SumOperator #(
    parameter int ELEM_BITS = 32
) (
    input  logic clk,
    input  logic rst_n,

    AXI4S.s in,     // decoded values from the decoder
    AXI4S.m out     // our result, going to the OutputWriter
);
```

`` `timescale 1ns / 1ps `` sets simulation time units. Copy it; it doesn't affect synthesis.

Why `AXI4S` at the boundary and not `ndata_i`? Because that's what the neighbours speak. **Raw AXI at
the edges, typed view inside.**

### Step 2 — Derived constants

```systemverilog
`RESET_RESYNC   // gives us reset_synced

    localparam int IN_BITS = in.AXI4S_DATA_BITS;   // 512, read from the interface itself
    localparam int N       = IN_BITS / ELEM_BITS;  // 16 lanes
```

**`localparam`** is a constant computed at elaboration time, not overridable from outside (unlike
`parameter`). Deriving `N` rather than hardcoding 16 means the module still works if someone builds
with 64-bit elements.

### Step 3 — The typed view

```systemverilog
    ndata_i #(.data_t(logic [ELEM_BITS-1:0]), .NUM_ELEMENTS(N)) nin();

    AXIToNData #(
        .data_t(logic [ELEM_BITS-1:0]),
        .NUM_ELEMENTS(N)
    ) inst_axi_to_data (
        .clk(clk),
        .rst_n(reset_synced),
        .in(in),
        .out(nin)
    );
```

Now `nin.data[i]` is lane `i` and `nin.keep[i]` is its single keep bit. (Lesson 4.)

### Step 4 — State

```systemverilog
    logic signed [63:0] sum;
    logic        [31:0] num_rows;
```

64 bits for the sum: adding millions of 32-bit values overflows 32 bits fast. **Sizing accumulators
is a real design decision** — the real covariance module has a comment noting its 64-bit sums are
bounded by TPC-H-scale data. Silent overflow is silent wrong answers.

`signed` matters: without it, `>>` and comparisons treat the value as unsigned and negative numbers
break.

### Step 5 — The state machine

The operator has three phases, so it needs a **finite state machine** (FSM) — a register holding
"which phase am I in", and rules for moving between phases.

```systemverilog
    typedef enum logic [1:0] {accumulate, prep, stream} state_t;
    state_t state;
```

- **`accumulate`** — consume input, add it up.
- **`prep`** — input finished; arrange the answer for output.
- **`stream`** — push the answer out, then reset for the next column.

An `enum` gives readable names to bit patterns; `logic [1:0]` says 2 bits, enough for 3 states. In
waveforms you'll see the names, not `2'b01` — worth it for that alone.

### Step 6 — Backpressure

```systemverilog
    assign nin.ready = (state == accumulate);
```

*"I accept input only while accumulating."* During `prep` and `stream` I'm busy, so `ready` drops and
the decoder upstream stalls — correctly, automatically, because of backpressure (Lesson 3).

Check Rule 1: does this mention `out.tready`? No. ✓

### Step 7 — Accumulate

```systemverilog
    always_ff @(posedge clk) begin
        if (!reset_synced) begin
            state      <= accumulate;
            sum        <= '0;
            num_rows   <= '0;
            out.tvalid <= 1'b0;
            out.tlast  <= 1'b0;
        end else begin
            case (state)

            accumulate: begin
                automatic logic accepted = nin.valid && nin.ready;

                if (accepted) begin
                    automatic logic signed [63:0] beat_total = '0;
                    automatic int                 beat_count = 0;

                    for (int i = 0; i < N; i++) begin
                        if (nin.keep[i]) begin
                            beat_total = beat_total + signed'(nin.data[i]);
                            beat_count = beat_count + 1;
                        end
                    end

                    sum      <= sum + beat_total;
                    num_rows <= num_rows + beat_count;

                    if (nin.last) state <= prep;
                end
            end
```

Unpack this carefully:

- `accepted` is the handshake condition from Lesson 3. Everything is conditional on it — **only act
  on data that actually moved.**
- `automatic` variables are local to this invocation of the block, like a local variable in a
  function. They use blocking `=` because they're intermediate scratch, not registers.
- **The `for` loop is not a loop.** It is *unrolled at synthesis into 16 parallel adders* forming a
  tree. All 16 lanes are summed in the same cycle. This is the parallelism from Lesson 4, and it's
  why hardware wins.
- `if (nin.keep[i])` — skip padding lanes. Forget this and your sum includes garbage.
- `signed'(...)` is a **cast**, forcing signed interpretation before the addition widens it.
- `sum <= sum + beat_total` uses `<=` because `sum` is a real register.

**A quiet timing hazard:** that 16-input adder tree, plus the accumulate, is one long combinational
path. At 16 lanes of 32 bits it will probably close at 250 MHz. At 16 lanes with a multiply in front
of it, it will not — which is exactly why the real z-score splits its reduction into four registered
stages. Lesson 10.

### Step 8 — Prep

```systemverilog
            prep: begin
                out.tdata  <= '0;
                out.tdata[63:0]   <= sum;         // lower 8 bytes: the sum
                out.tdata[95:64]  <= num_rows;    // next 4 bytes: the count
                out.tkeep  <= 64'h0000_0000_0000_0FFF;   // 12 bytes valid
                out.tlast  <= 1'b1;
                out.tvalid <= 1'b1;
                state      <= stream;
            end
```

`out.tdata[63:0] <= sum` is a **bit-slice** assignment. `tkeep` is per *byte* (Lesson 4), and we're
emitting 12 bytes, so 12 bits set.

Why is `prep` a separate state rather than part of `accumulate`? Because it keeps each state's logic
short. Cramming everything into one state produces a huge combinational cone and fails timing. **In
hardware, more states is usually cheaper than more logic per state.**

### Step 9 — Stream, and reset for reuse

```systemverilog
            stream: begin
                if (out.tvalid && out.tready) begin
                    // handshake happened: the result is delivered
                    out.tvalid <= 1'b0;
                    out.tlast  <= 1'b0;
                    sum        <= '0;
                    num_rows   <= '0;
                    state      <= accumulate;
                end
            end

            endcase
        end
    end

endmodule
```

We hold `tvalid` high until the consumer takes it (Rule 2), then clear our state so the *next* column
chunk starts clean. **Forgetting to reset accumulators here means run 2 of a query is wrong while run
1 was right** — a genuinely nasty bug class, because your first test passes.

### What you just built

```
      AXI4S in                                                    AXI4S out
         │                                                            ▲
         ▼                                                            │
   ┌───────────┐    16 lanes    ┌──────────────┐    sum      ┌────────────┐
   │AXIToNData │───────────────►│ keep-masked  │────────────►│ FSM: prep  │
   └───────────┘  nin.data[i]   │  adder tree  │             │ then stream│
                                └──────────────┘             └────────────┘
                                       │                            ▲
                                  accumulate ──── nin.last ─────────┘
```

Every operator in this repo is this skeleton plus more arithmetic.

### Exercises

1. Make it compute the **maximum** instead of the sum. (What's the correct reset value? Careful with
   signed.)
2. Make it compute sum **and** max simultaneously. (Notice they don't interfere — parallel hardware
   is free until you run out of chip.)
3. `num_rows` is 32 bits. At 16 GB/s of 32-bit values, how long until it overflows? Is that
   acceptable?

---

## Lesson 10 — Adding a multiplier, and the latency it drags in

**Goal:** sum of squares — `Σx²`. One extra operation. It changes everything about the module's
structure, and understanding *why* is the point of this lesson.

### The naive version, and why it fails

```systemverilog
beat_total = beat_total + signed'(nin.data[i]) * signed'(nin.data[i]);   // ✗ won't close timing
```

Written this way, the multiply is **combinational**: 16 multipliers, then a 16-input adder tree, then
the accumulate — all in one 4 ns window. A 32×32 multiply alone eats most of that budget. This is
precisely the bottleneck the z-score module hit, and its fix is recorded in the source:

> *"stage a is a pipelined 32x32 DSP square (int_mult_32) instead of a combinational number\*number
> (which was the timing bottleneck)."*
> — [z_score_squared.sv:48-51](hardware/src/hdl/z-score/z_score_squared.sv#L48-L51)

### The fix: a hardened, pipelined multiplier

The chip has thousands of **DSP** blocks — dedicated multiply-accumulate hardware, far faster and
smaller than a multiplier built from LUTs. You access them through an **IP core**: a pre-built,
Xilinx-provided component instantiated like a module.

```systemverilog
int_mult_32 inst_square (
    .CLK (clk),
    .CE  (1'b1),                         // Clock Enable: 1 = always running
    .A   (signed'(nin.data[i])),
    .B   (signed'(nin.data[i])),
    .P   (product)                       // P = A * B, but SQ_LAT cycles later
);
```

The IP is declared in `init_ip.tcl` (a Tcl script that tells Vivado to generate it) with a chosen
number of **pipeline stages**. More stages = higher clock speed, more latency.

> **⚠⚠ The rule that will burn you.** The latency you assume in RTL must equal the `PipeStages` set
> in `init_ip.tcl`. Nothing checks this. A mismatch produces *silently misaligned data* — no error,
> no warning, just wrong numbers. Both real modules shout about it:
>
> ```systemverilog
> localparam int SQ_LAT = 6;   // !! MUST match int_mult_32 PipeStages in init_ip.tcl
> localparam int lat    = 6;   // !! MUST match int_mult_32 PipeStages in init_ip.tcl
> ```
>
> Write that `// !!` comment in your own code. Every time.

### The consequence: metadata falls out of sync

Feed beat *N* into the multiplier at cycle *T*; its product appears at cycle *T+6*. But
`nin.keep` for beat *N* was only valid at cycle *T*. Six cycles later the input wires show beat
*N+6*'s keep mask.

**If you use `nin.keep` to decide whether to accumulate the product, you use the wrong beat's mask.**

```
cycle:        T      T+1    T+2    T+3    T+4    T+5    T+6
input beat:   N     N+1    N+2    N+3    N+4    N+5    N+6
product out:  -      -      -      -      -      -    N²     ← arrives now
nin.keep:   keep_N  ...                              keep_N+6  ← WRONG one
```

### The fix: a delay line for metadata

Delay `keep`, `valid` and `last` by exactly the same 6 cycles:

```systemverilog
    localparam int SQ_LAT = 6;                  // !! MUST match init_ip.tcl
    localparam int TAIL   = SQ_LAT - 1;

    logic [N-1:0] keep_reg  [SQ_LAT];
    logic         valid_reg [SQ_LAT];
    logic         last_reg  [SQ_LAT];
```

Why is the tail index `SQ_LAT - 1` and not `SQ_LAT`? Because `keep_reg[0]` is *written* at cycle `T`
and therefore *readable* from `T+1`. So `keep_reg[SQ_LAT-1]` is readable at `T+SQ_LAT` — exactly when
the product lands. The production code spells this out at
[covariance.sv:91-95](hardware/src/hdl/covariance/covariance.sv#L91-L95). Off-by-one here is the
single easiest mistake to make in the whole project.

```systemverilog
            accumulate: begin
                automatic logic accepted = nin.valid && nin.ready;

                // --- metadata delay line: stage 0 captures now, the rest shift ---
                valid_reg[0] <= accepted;
                keep_reg [0] <= nin.keep;
                last_reg [0] <= accepted && nin.last;
                for (int s = 1; s < SQ_LAT; s++) begin
                    valid_reg[s] <= valid_reg[s-1];
                    keep_reg [s] <= keep_reg [s-1];
                    last_reg [s] <= last_reg [s-1];
                end

                // --- immediate work: no multiplier, so no delay needed ---
                if (accepted) begin
                    for (int i = 0; i < N; i++)
                        if (nin.keep[i]) sum <= sum + signed'(nin.data[i]);
                    if (nin.last) draining <= 1'b1;      // see below
                end

                // --- delayed work: products for the beat presented SQ_LAT cycles ago ---
                if (valid_reg[TAIL]) begin
                    for (int i = 0; i < N; i++)
                        if (keep_reg[TAIL][i])           // that beat's mask, not this one's
                            sum_sq <= sum_sq + products[i];
                end

                // --- the last beat's products have now landed: we're done ---
                if (valid_reg[TAIL] && last_reg[TAIL]) begin
                    draining <= 1'b0;
                    state    <= prep;
                end
            end
```

**Two accumulators now run on different timelines.** `sum` updates immediately; `sum_sq` updates six
cycles behind. That's fine — they're independent registers. But it means you cannot declare yourself
finished when the last input arrives.

### Draining

```systemverilog
    logic draining;
    assign nin.ready = (state == accumulate) && !draining;
```

When `last` arrives, six beats' worth of products are still travelling through the multipliers. If
you jump to `prep` immediately, you lose them.

So: on `last`, set `draining` — which drops `ready`, stopping new input — but **stay in
`accumulate`** so the tail logic keeps running. Only when `last_reg[TAIL]` fires (the final beat's
products have landed) do you move on.

**This is the number-one bug in pipelined operators.** Symptom: your answer is correct for small
inputs and slightly wrong for large ones — or off by exactly the last few beats. If you see that, the
drain is missing or mistimed.

### Exercises

1. What breaks if `SQ_LAT` in your RTL is 6 but `init_ip.tcl` says 4? Be specific about *which* beats
   get the wrong mask.
2. Why does `sum` (no multiplier) need no delay line while `sum_sq` does?
3. Sketch a waveform: 3 beats then `last`, with `SQ_LAT = 2`. Mark the cycle where `state` moves to
   `prep`.

---

## Lesson 11 — Reading covariance.sv, which you now understand

Open [hardware/src/hdl/covariance/covariance.sv](hardware/src/hdl/covariance/covariance.sv). It's 220
lines and contains **no ideas you haven't met**. This lesson is a guided read.

### What it computes and why the shape is clever

Covariance between features *i* and *j*:

```
cov(i,j) = (N·Σxᵢxⱼ − Σxᵢ·Σxⱼ) / N²
```

The expensive part is `Σxᵢxⱼ` — for every row, every pair of features. With 16 features that's
**136 multiply-accumulates per row** (16·17/2 upper-triangular pairs; the matrix is symmetric so you
skip half). Over a million rows, that's 136 million MACs.

The cheap part is the final divide: one per pair, 136 total, **regardless of row count**.

> **The design decision that makes this operator good: the FPGA does the O(M²·N) reduction and streams
> out raw sums; the host does the O(M²) finalisation.** No divider on the chip — dividers are large,
> slow, and here entirely unnecessary.

Internalise this. When designing any operator, ask: *what's the smallest thing I can send the host
that still lets it finish the job?* Usually it's raw moments — `Σx`, `Σx²`, `Σxy`, `N`.

### The layout

One beat = **one row** (observation), lanes = features. Different from the sum operator, where one
beat was 16 independent values. Same wires, different meaning — a reminder that `keep`/`last`
semantics are a *contract with the producer*, not a property of the hardware.

### The multiplier array

```systemverilog
    genvar i, j;
    generate
        for (i = 0; i < n; i = i + 1) begin : gen_row
            for (j = i; j < n; j = j + 1) begin : gen_col
                localparam int k = i*n - (i*(i-1))/2 + (j - i);
                int_mult_32 i_mult (
                    .CLK(clk), .CE(1'b1),
                    .A(signed'(nin.data[i])),
                    .B(signed'(nin.data[j])),
                    .P(results[k])
                );
            end
        end
    endgenerate
```

- Nested `generate` loops stamp out **136 physical multipliers**. `j` starts at `i`, which is what
  restricts it to the upper triangle.
- `k` is the flattening formula converting `(i,j)` into a single array index — the same formula the
  host uses to unpack the results. **Both sides must agree exactly.**
- `begin : gen_row` names the generate block; the name shows up in waveforms and error messages.

136 multipliers, all producing a result every cycle. This is what an FPGA is for.

### Everything else you already know

| Lines | What | From |
|---|---|---|
| [51-61](hardware/src/hdl/covariance/covariance.sv#L51-L61) | `AXIToNData` typed view | Lesson 4 |
| [63-66](hardware/src/hdl/covariance/covariance.sv#L63-L66) | 64-bit accumulators | Lesson 9 |
| [69-71](hardware/src/hdl/covariance/covariance.sv#L69-L71) | FSM + `draining` | Lessons 9, 10 |
| [91-98](hardware/src/hdl/covariance/covariance.sv#L91-L98) | `keep_reg` delay line and the `TAIL` derivation | Lesson 10 |
| [105](hardware/src/hdl/covariance/covariance.sv#L105) | `ready` gated by state and draining | Lesson 10 |
| [139-145](hardware/src/hdl/covariance/covariance.sv#L139-L145) | immediate accumulators (`sum_self`, `num_rows`) | Lesson 10 |
| [148-156](hardware/src/hdl/covariance/covariance.sv#L148-L156) | delayed accumulators, gated on **both** lanes' keep | Lesson 10 |
| [159-162](hardware/src/hdl/covariance/covariance.sv#L159-L162) | finish only when the last products land | Lesson 10 |
| [166-179](hardware/src/hdl/covariance/covariance.sv#L166-L179) | `prep`: pack sums into 32-bit words | Lesson 9 |
| [182-214](hardware/src/hdl/covariance/covariance.sv#L182-L214) | `stream`: emit 16 words/beat, then self-reset | Lesson 9 |

Two details worth pausing on:

**The double keep check** at line 152:
```systemverilog
if (keep_reg[TAIL][a] && keep_reg[TAIL][b])
```
A cross-product is only valid if **both** features were present in that row. One missing feature
invalidates the pair, not the whole row.

**The partial-beat keep computation** at line 192:
```systemverilog
out.tkeep <= (~64'h0) >> (64 - rem*4);   // contiguous from LSB
```
306 words don't divide evenly by 16, so the last beat is partial. `~64'h0` is all ones; shifting right
by `64 - rem*4` leaves exactly `rem*4` bits set (4 keep bits per 32-bit word). A neat idiom — steal it.

### Exercise

Work out the byte offset, in the 306-word output, of `Σx₃x₇`. Then find the host-side code that
unpacks it and check you agree. If you don't, one of you is wrong — and that's exactly the class of
bug that produces plausible-looking but incorrect covariance matrices.

---

## Lesson 12 — When one pass isn't enough

### Some statistics can't be streamed

Sum needs one pass. So does covariance — because `Σx`, `Σxy` and `N` are all **accumulable**: you can
update them from each row independently, in any order.

Now consider the **z-score**: how many standard deviations a value is from the mean.

```
z = (x − μ) / σ
```

To judge the *first* value you need μ, which needs *all* the values. You physically cannot do it in
one pass over a stream. Two passes:

1. **Pass 1** — accumulate `Σx`, `Σx²`, `n`. From these, μ and σ follow.
2. **Pass 2** — see every value again, now knowing μ and σ.

### Trick one: kill the square root and the division

Naively pass 2 needs `σ = sqrt((n·Σx² − (Σx)²)/n²)` and then a division per value. Square roots and
dividers are large and slow in hardware.

But you don't need `z` — you need to know whether `|z| > k`. So rearrange:

```
        |x − μ| > k·σ
  square both sides (both non-negative, so this is exact):
        (x − μ)² > k²·σ²
  substitute μ = S/n and σ² = (n·Q − S²)/n²  where S = Σx, Q = Σx²
  multiply through by n²:
        (n·x − S)² > k²·(n·Q − S²)
```

**No square root. No division. Integer arithmetic throughout.** With k = 3, `k²` is the constant 9.
The right-hand side is computed *once* when pass 1 ends. Per value, you need one subtract and one
square — both cheap.

That's the module name: `z_score_squared.sv`. Read
[lines 17-24](hardware/src/hdl/z-score/z_score_squared.sv#L17-L24) and you'll now recognise every
line.

> **Generalise this.** Before building a divider or a square-root, spend twenty minutes on the
> algebra. Reformulating maths to avoid expensive operators is the single highest-leverage move in
> FPGA design, and it is *free* — it costs no chip area at all.

### Trick two: don't decode twice

Pass 2 needs the data again. The obvious approach — ask the host to send it again — means decoding it
again. And the decoder is your bottleneck (Lesson 8), so **two passes costs 2× the dominant cost.**

The fix: during pass 1, write the *decoded* values into HBM. During pass 2, replay from HBM.
Decoding happens once.

```
        ┌──────────┐      ┌──────────┐
pass 1  │ decoder  ├─────►│ z-score  │  accumulate S, Q, n
        └──────────┘   │  └──────────┘
                       │
                       └─►┌──────────────┐
                          │  card_write  ├──► HBM
                          └──────────────┘

pass 2                    ┌────────────────────┐      ┌──────────┐
              HBM ───────►│ zscore_card_replay ├─────►│ z-score  │  flag outliers
                          └────────────────────┘      └──────────┘
```

Files: [card_write.sv](hardware/src/hdl/card_write.sv),
[zscore_card_replay.sv](hardware/src/hdl/zscore_card_replay.sv),
[card_buffer_config.sv](hardware/src/hdl/card_buffer_config.sv). All under `` `ifdef EN_MEM ``.

And remember Lesson 7: **the host allocates that HBM scratch buffer and passes its vaddr down**. The
FPGA never chooses an address.

### How to know it's actually working

This matters more than it sounds. "It ran and the numbers were right" does **not** prove replay
engaged — if replay silently failed and the design fell back to re-decoding, you'd still get correct
answers, just slowly.

> **The real test: the decoder's input handshake count must HALVE.** Read it from the profiler
> counters (Lesson 18). If it didn't halve, pass 2 is still decoding and the feature is doing nothing.

Wall-clock time alone won't tell you this reliably, because other bottlenecks may be hiding the gain.

### Exercise

Redo the algebra for a two-sided test with k = 2.5. `k²` is now 6.25 — not an integer. How do you
keep everything in integer arithmetic? *(Hint: scale both sides by 4.)*

---
---

# Part V — Integration

---

## Lesson 13 — Wiring your operator into the design

Your module now has to join the real pipeline in
[hardware/src/vfpga_top.svh](hardware/src/vfpga_top.svh).

### One design, many variants

Oasis isn't a single build. `` `ifdef `` selects a family member at synthesis time:

```systemverilog
`ifdef EN_RDMA
    // ... RDMA source, one stream slot reserved as a bypass
`else
    // ... local host-memory source
`endif
```

An `` `ifdef `` is a **preprocessor** directive — the text inside is included or deleted *before*
compilation. Code in a disabled branch may as well not exist.

| Flag | Set by | Effect |
|---|---|---|
| `EN_RDMA` | `synthesize.sh` (default on; `--no-rdma` off) | network source instead of host streams |
| `EN_MEM` | shell config | HBM streams exposed; enables decode-once replay |
| `EN_COVARIANCE` | hand-edited at [vfpga_top.svh:6](hardware/src/vfpga_top.svh#L6) | covariance vertical instead of z-score |
| `N_DECODERS` | `--decoders N` | how many decoder lanes |

```bash
./scripts/synthesize.sh --no-rdma --decoders 4
```

### The checklist for adding an operator

**1. Instantiate it in the datapath**, after the decoder:

```systemverilog
AXI4S op_out[NUM_DECODERS](.aclk(clk), .aresetn(rst_n));

for (genvar I = 0; I < NUM_DECODERS; I++) begin
    SumOperator #(.ELEM_BITS(32)) inst_sum (
        .clk(clk), .rst_n(rst_n),
        .in(decoder_out[I]),
        .out(op_out[I])
    );
end
```

One instance **per decoder lane**. They're independent; that's the parallelism.

**2. Add a config block** if you need parameters — and update `NUM_CONFIGS` *and*
`ADDR_SPACE_SIZES`, remembering both live behind `ifdef`s (Lesson 6).

**3. Add profiler taps** (Lesson 18). Do this now, not later.

**4. Connect to the `OutputWriter`.** This is the module that DMAs results back to host RAM:

```systemverilog
OutputWriter inst_output_writer (
    .clk(clk), .rst_n(rst_n),
    .sq_wr(sq_wr),           // "please write N bytes"
    .cq_wr(cq_wr),           // "that write completed"
    .notify(notify),         // "interrupt the CPU, we're done"
    .mem_config(mem_conf),   // WHERE to write — host-supplied addresses
    .data_in(op_out),
    .data_out(axis_host_send)
);
```

**Why `mem_config` exists:** the host cannot know in advance how much output a query produces (think
of a filter). So it hands the FPGA pre-allocated buffers, the FPGA fills them and reports how much it
wrote. This is called an **FPGA-initiated transfer**, and it's why the output path is more elaborate
than the input path.

**5. Tie off anything unused**, or the shell waits forever on an undriven signal:

```systemverilog
for (genvar I = 3; I < N_STRM_AXI; I++) begin
    always_comb axis_out[I].tie_off_m();
end
```

### Sanity check before you burn three hours

Ask yourself: *"is my module reachable from `vfpga_top.svh`?"* A module nobody instantiates is never
elaborated — it won't be synthesised, and **its errors stay hidden**. If your operator has no effect
after a build, check this first.

---

## Lesson 14 — Testing it, without waiting three hours

**Simulation** runs your RTL as software. Slow (seconds of simulated time take minutes) but the
feedback loop is minutes rather than hours, and you can see every signal.

### Setup

```bash
./scripts/setup_simulation.sh
```

This builds a Vivado simulation project. **Re-run it whenever you add or rename a file.** And a
gotcha that will cost you an afternoon: *Vivado only registers files that were syntactically valid at
setup time.* A "file not found" error usually means "your file has a syntax error."

Tests then appear in VSCode's testing panel (the flask icon).

### Three files per test

**1. The golden model** — a Python implementation of what the hardware *should* do:

```python
def expected_sum(values):
    return sum(values), len(values)
```

**Write this first.** It forces you to pin down the specification before you build anything, and it's
what the hardware is checked against.

**2. A test top** — `hardware/unit-tests/vfpga-tops/sum_test.sv`, a minimal `vfpga_top` containing
*only* your operator. You are testing one module, not the whole design.

**3. The test itself** — `hardware/unit-tests/sum_test.py`:

```python
class SumTest(fpga_test_case.FPGATestCase):
    alternative_vfpga_top_file = "vfpga-tops/sum_test.sv"

    def test_simple(self):
        values = list(range(1000))
        self.set_stream_input(0, Int32Column("v", values))
        self.set_expected_output(0, expected_sum(values))
        self.simulate_fpga()
        self.assert_simulation_output()
```

### What to test, in order

1. **A round number** — 1600 values = exactly 100 full beats. If this fails, your basic logic is wrong.
2. **A partial last beat** — 1003 values. This is where `keep` handling breaks.
3. **Empty input** — 0 values. Does it hang?
4. **Two runs back to back** — does run 2 give the same answer as run 1, or did you forget to clear
   the accumulators? (Lesson 9, Step 9.)
5. **Behind a real decoder** — the `*_decode_test.py` variants. Your operator works in isolation;
   does it survive real decoder timing, with its gaps and bursts? **This is the configuration that
   ships, so this test is not optional.**

Existing examples to copy: [covariance_test.py](hardware/unit-tests/covariance_test.py) (standalone)
and [covariance_decode_test.py](hardware/unit-tests/covariance_decode_test.py) (behind the decoder).

### Waveforms

Tests dump a `.vcd` file — every signal's value at every cycle. Open it with the **Surfer** VSCode
extension.

**The debugging move that works,** and it's basically the only one you need:

1. Find the first cycle where reality differs from expectation.
2. Walk *backwards* through the signals that feed it.
3. Repeat until you hit the cause.

Signals to put on screen first, every time: `state`, `nin.valid`, `nin.ready`, `nin.last`,
`draining`, and your accumulators. Nine times out of ten the story is visible in those six.

---
---

# Part VI — The host side

---

## Lesson 15 — The C++ that drives it

Three layers, bottom to top:

```
libstf        buffers, hugepage memory pool, TLB management, output buffer manager
   ↑
oasis lib     operators, scheduler, configuration  (software/oasis/)
   ↑
extension     DuckDB table functions              (extension/src/)
```

### The mirror rule

[software/oasis/configuration.hpp](software/oasis/configuration.hpp) writes the config registers your
RTL reads.

> **Every register index and bit layout here must match `hardware/src/hdl/common.sv` exactly.**

There is no compiler checking this. A mismatch means the FPGA reads a length as an address, or a mode
flag out of the wrong bit position. Symptoms range from wrong answers to a hung board. **When you
change a register layout, change both sides in the same commit** — and re-read Lesson 6's note that
the register index is the `ConfigWriteFIFO`'s first parameter.

### The operator model

[software/oasis/operator.hpp](software/oasis/operator.hpp): a query is a small graph of operators.

```cpp
class Operator { ... };
class SourceOperator : public Operator {};       // where data comes from
class RDMASourceOperator  final : public SourceOperator {};   // over the network
class LocalSourceOperator final : public SourceOperator {};   // from host RAM
class DecodeColumnChunkOperator final : public Operator {};   // run it through the decoder
class LocalSinkOperator final : public Operator {};           // deliver to the host
```

### Splinters and the scheduler

A **splinter** ([query_splinter.hpp](software/oasis/query_splinter.hpp)) is one unit of work handed
to the FPGA — typically one column chunk of one row group.

The [Scheduler](software/oasis/scheduler.hpp) submits splinters and collects completions. Its member
types tell you the whole story:

```cpp
struct InFlight { ... };            // submitted, FPGA is working on it
struct Pending { ... };             // ready to submit, waiting for a slot
struct PendingCompletion { ... };   // finished, waiting to be collected
struct StreamState { ... };         // per-stream bookkeeping
```

Everything is **asynchronous**: you submit, you don't block, you collect later. That's not
over-engineering — it is the *only* way to keep the FPGA busy, as the next lesson shows.

---

## Lesson 16 — The DuckDB table function

The bridge from SQL to your hardware:

```sql
SELECT * FROM zscore('data.parquet', 'price');
```

Any function usable in `FROM` is a **table function**, and DuckDB requires four callbacks. Learn the
shape once from [extension/src/zscore_scan.cpp](extension/src/zscore_scan.cpp); every Oasis entry
point follows it.

### 1. Bind — "what will this return?"

```cpp
unique_ptr<FunctionData> ZScoreBind(ClientContext &context, TableFunctionBindInput &input,
                                    vector<LogicalType> &return_types, vector<string> &names) {
    // read the arguments, open the file, inspect the Parquet footer
    return_types.push_back(LogicalType::BIGINT);   names.push_back("row_id");
    return_types.push_back(LogicalType::DOUBLE);   names.push_back("value");
    return std::move(bind_data);
}
```

Runs **once at query planning**, before any data moves. Its job is declaring the output schema.

### 2. InitGlobal — state shared by the whole query

```cpp
unique_ptr<GlobalTableFunctionState> ZScoreInitGlobal(...);
```

One instance. Anything shared across threads lives here — and must be thread-safe.

### 3. InitLocal — state per worker thread

```cpp
unique_ptr<LocalTableFunctionState> ZScoreInitLocal(...) {
    // Each worker owns its file handle: DuckDB FileHandles are not safe to share across threads.
}
```

DuckDB runs your function on several threads at once. That comment is from the real source and it's a
genuine hazard: sharing a file handle across workers causes rare, confusing corruption.

### 4. The function — produce one chunk

```cpp
void ZScoreFunction(ClientContext &, TableFunctionInput &data_p, DataChunk &output) {
    // fill `output` with up to 2048 rows; set cardinality to 0 to signal "done"
}
```

Called repeatedly until it reports zero rows. A **DataChunk** is DuckDB's vector of ~2048 values —
its unit of work, analogous to your 512-bit beat.

### Registering it

```cpp
TableFunction zscore("zscore", {LogicalType::VARCHAR, LogicalType::VARCHAR},
                     ZScoreFunction, ZScoreBind, ZScoreInitGlobal, ZScoreInitLocal);
loader.RegisterFunction(zscore);
```

### Build order — non-negotiable

```bash
# 1. software library FIRST
cmake -S software -B software/build -DCMAKE_INSTALL_PREFIX=$HOME/opt
cmake --build software/build -j && cmake --install software/build

# 2. then the extension
cd extension && make -j
```

> **⚠ The ABI trap.** There is exactly **one** `liboasis.so` in `~/opt` at a time, and different
> branches export different symbols. An undefined-symbol error at link or load time almost always
> means *"you're linking the library built from a different branch."* Rebuild and install the
> software library from your current branch **first**. (And note this breaks binaries built on the
> other branch — expect to re-install when you switch back.)

---

## Lesson 17 — Feeding the beast

Your hardware can absorb 16 GB/s. Whether it *does* depends almost entirely on the host, and this is
where the largest real speedups on this project came from.

### The problem: submit one, wait, submit one

```
host:  [prepare]──submit──[........... waiting ...........]──collect──[prepare]──submit──
FPGA:            idle     [work]      idle idle idle idle            idle     [work]
                          └──────── mostly idle ────────┘
```

Each round trip has fixed overhead — allocate a buffer, write registers, wait for an interrupt,
collect. While the host does that, the FPGA has nothing to chew on. Measured on this project: **72-75%
idle.**

### The fix: a sliding window

Keep *N* submissions in flight at all times. When one completes, immediately top the window back up:

```
host:  [prep][prep][prep][prep][collect+prep][collect+prep][collect+prep]...
FPGA:        [work][work][work][work][work][work][work][work][work]...
                    └────────── continuously busy ──────────┘
```

In [extension/src/zscore_scan.cpp:248](extension/src/zscore_scan.cpp#L248):

```cpp
constexpr size_t WINDOW = 8;
while (lstate.in_flight.size() < WINDOW) {
    // submit the next row group
}
```

Eight lines, roughly. **Measured effect on the covariance vertical: idle down 27-42×, throughput
3.2 → 11.3 GB/s.** Nothing about the hardware changed.

**The window costs memory.** Each in-flight submission holds a hugepage buffer, and DuckDB runs
several threads, so you need `threads × WINDOW` buffers simultaneously — noted in the source at
[line 66](extension/src/zscore_scan.cpp#L66). Too large a window and you exhaust your hugepage
reservation. This is a tuning parameter; sweep it.

### The second lever: host CPU work

Once the window is deep and idle is still high, the host itself is the bottleneck — not the feed, the
*work*. Two changes that mattered here:

- **Sparse emission** — only materialise the rows you actually need. For outlier detection, that's a
  tiny fraction.
- **Multithreaded emission** — spread the materialisation across DuckDB's worker threads.

Together these took z-score from 0.145 s to 0.072 s — a **2× speedup with no hardware change at
all**, and idle cycles fell from 14.4M to 220k.

> **The lesson to carry:** when the number is disappointing, the FPGA is often not the problem. Check
> which of the four counters is large *before* you decide what to fix.

---
---

# Part VII — Making it real

---

## Lesson 18 — The four counters

Lesson 3 gave you four names for what a stream is doing each cycle. `StreamProfiler` counts them in
hardware.

### The instrument

```systemverilog
StreamProfiler inst_profile (
    .clk(clk), .rst_n(rst_n),
    .valid(stream.tvalid),
    .ready(stream.tready),
    .last(stream.tlast),
    .stop(all_done),
    .handshakes_cycles(...), .starved_cycles(...),
    .stalled_cycles(...),    .idle_cycles(...)
);
```

It taps a stream without disturbing it — pure observation. **Put one on the input and one on the
output of every operator you write.** They're cheap, and without them you are guessing.

The counters reach software through a read-config block
([zscore_profile_config.sv](hardware/src/hdl/zscore_profile_config.sv), the pattern from Lesson 6)
and are exposed to SQL:

```sql
SELECT * FROM oasis_stream_profile();
```

### Reading the result

| Dominant counter | Meaning | What to fix |
|---|---|---|
| **handshakes** | working | nothing — you're at the hardware limit |
| **starved** | upstream too slow | usually the decoder: more lanes, better decoder, decode-once |
| **stalled** | downstream too slow | output path: DMA, OutputWriter, buffer sizing |
| **idle** | nobody's asking | **the host**: deepen the window, reduce CPU work (Lesson 17) |

### The trap that catches everyone once

> **Fixing `starved` often converts it into `idle`, one-for-one, with zero wall-clock improvement.**

This genuinely happened on this project: a new decoder generation cut starved cycles by 2.75× and
delivered ~0% speedup at 100M rows — because the bottleneck simply moved to the host feed. The FPGA
stopped waiting on the decoder and started waiting on software instead.

Three rules that follow:

1. **Read all four counters** before and after, never just the one you targeted.
2. **Confirm with wall-clock time.** Counters explain *why*; only the clock proves *faster*.
3. **Change one variable per build.** Synthesis is hours; a 2×2 experiment is a day. Plan it
   deliberately.

### CPU-side profiling

libstf integrates **Caliper** (an instrumentation library — you wrap regions of code and it times
them). Two traps:

- You must build **libstf from its own directory** with `-DLIBSTF_WITH_PROFILING=ON`. Passing that
  flag to the Oasis CMake does **nothing** if `find_package` resolves to a prebuilt libstf. That one
  has wasted an afternoon.
- Overhead is large. Keep separate install prefixes (`~/opt` vs `~/opt-prof`) so your normal builds
  stay fast, and remember it only measures what you explicitly wrapped.

---

## Lesson 19 — Build, flash, run

The operational discipline. Skipping it costs hours per mistake, and — worse — produces confident
wrong conclusions about your code.

### Synthesis

```bash
./scripts/synthesize.sh --no-rdma --decoders 4
```

Runs detached, so you can disconnect. Progress in `hardware/build-NN/bitgen.log`. **Hours**, often
silent for long stretches.

Afterwards, check timing. **WNS must be ≥ 0.** Negative means the design cannot run at 250 MHz —
don't flash it and don't trust anything it produces. If it's negative, go back to Lesson 5: find the
worst path, add a register or a skid buffer, rebuild.

### Label your builds

`hardware/build-NN/` accumulates fast — this repo is already at build-31. Every directory should
contain a `BUILD_INFO.txt`:

```
4 x decoder + zscore pipeline with latest commit of hoca profiler
```

**Write one every time.** And when comparing results months later, determine the configuration from
the **frozen RTL inside the build directory**, not from timestamps or memory of what you were working
on. Which decoder generation was in a build changes the numbers more than almost anything else you
might vary.

### On the board

Use the `setup-board` skill, or manually: compile the Coyote driver against the node's kernel, reserve
1 GiB hugepages, program the bitstream, load the driver, then open DuckDB.

> **⚠⚠ A hung run poisons the board.** After any hang, *every* subsequent run fails — including code
> you know is good. **Reflash the bitstream before every run** while debugging.
>
> Not knowing this produces a specific, expensive failure mode: you change something, it still hangs,
> you conclude your change was wrong, you revert it, it still hangs. On this project that pattern
> invalidated three separate diagnoses in one day. When a remote node misbehaves, get *its* output
> before theorising.

Two more environment facts:

- `EN_MEM=1` builds hit a hugepage ceiling that `EN_MEM=0` builds don't. Allocations that worked
  before may not work now.
- `hacc-build-02` has **no FPGA** — building and simulation only.

### The order of operations for a change

```
1. Write the Python golden model
2. Write / edit the RTL
3. Simulate — standalone test, then the decode test
4. Synthesize. Check WNS ≥ 0. Write BUILD_INFO.txt
5. Flash
6. Verify CORRECTNESS on small input
7. Only then benchmark, and read all four counters
```

Steps 3 and 6 are the ones people skip when they're in a hurry, and they're the two that prevent the
long expensive detours.

---
---

# Where to go next

You now have the vocabulary and the patterns. Suggested progression:

1. **Build `SumOperator`** from Lesson 9 for real. Test it standalone, then behind the decoder.
2. **Extend it to sum-of-squares** using Lesson 10. Get the delay line and the drain right — that's
   the skill.
3. **Read `covariance.sv` end to end** (Lesson 11). It should feel familiar rather than dense.
4. **Design something of your own.** Pick a statistic and ask the Lesson 11 question first: *what's
   the smallest thing I can send the host that lets it finish?* Good candidates: min/max, a quantile
   sketch, a linear regression via the covariance datapath.
5. **Take it all the way** — config block, `vfpga_top` wiring, C++ mirror, DuckDB table function with
   a windowed submit loop, profiler taps, and an end-to-end number you can defend from the counters.

## Quick reference

| Term | Meaning |
|---|---|
| **beat** | one clock cycle's worth of data that successfully transferred |
| **lane** | one element's slot within a 512-bit beat (16 lanes of 32 bits) |
| **handshake** | `valid && ready` both high — the transfer condition |
| **backpressure** | `ready` going low to stop an upstream producer |
| **keep** | per-element (or per-byte) mask of which parts of a beat are real |
| **last** | marks the final beat of a message |
| **drain** | finishing the beats still inside a pipeline after `last` arrives |
| **delay line** | shift register keeping metadata aligned with pipelined data |
| **skid buffer** | 2-slot register that breaks a `ready` timing path without losing beats |
| **modport** | which side of an interface you are (`.m` produce, `.s` consume) |
| **WNS** | Worst Negative Slack — must be ≥ 0 or the design won't run at speed |
| **DSP** | hardened multiply block; the resource that matters for compute |
| **IP core** | pre-built vendor component (e.g. `int_mult_32`), declared in `init_ip.tcl` |
| **shell / vFPGA** | Coyote's fixed infrastructure / your slot inside it |
| **TLB** | address translation table letting the FPGA reach host memory |
| **hugepage** | 1 GiB memory page; fewer TLB entries, fewer stalls |
| **splinter** | one unit of work submitted to the FPGA |
| **DataChunk** | DuckDB's ~2048-row unit of work |

## The gotcha list

- `valid` must never depend combinationally on `ready`.
- Once `valid` is high, hold it until the handshake.
- Always mask by `keep`, or you process padding as data.
- Pipeline latency must be mirrored onto `valid`/`keep`/`last` with a delay line.
- `SQ_LAT` / `lat` / `MULT_LAT` must match `PipeStages` in `init_ip.tcl` — nothing checks this.
- Drain the pipeline after `last`, or you lose the final beats.
- Clear accumulators after emitting, or run 2 is wrong while run 1 was right.
- `NUM_CONFIGS` and `ADDR_SPACE_SIZES` must agree — and both sit behind `ifdef`s.
- Register layouts in `configuration.hpp` must mirror `common.sv` exactly.
- RTL can never invent an address; the host allocates and maps.
- To prove decode-once works, check decoder handshakes **halve**.
- One `liboasis.so` in `~/opt`: rebuild the software lib from your branch before the extension.
- Reflash before every run while debugging; a hung run poisons the board.
- Fixing `starved` often just converts it to `idle`. Read all four, confirm with wall-clock.
- A module not reachable from `vfpga_top.svh` is never elaborated — its errors stay hidden.
