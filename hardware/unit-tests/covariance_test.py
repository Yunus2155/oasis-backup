from libstf_utils.output_writer_test_case import OutputWriterTestCase
from coyote_test import fpga_stream
from unit_test.io_writer import CoyoteOperator, CoyoteStreamType


class CovarianceTestCase(OutputWriterTestCase):
    """
    Drives the celeris covariance operator in the oasis sim: streaming covariance
    accumulator with host-side finalize.

    SINGLE-PASS.  Input is ROW-MAJOR: one beat = one observation (row) of N_FEAT
    features (lane i = feature i).  This test uses N_FEAT = 16 so every beat is full
    (all keep = 1); a flat column of 16*N ints becomes N rows automatically.

    The FPGA does NOT divide -- it streams the RAW sums:
        sum_product[k] = sum_r x_i*x_j   (k = upper-triangular pair (i,j), j>=i)
        sum_self[i]    = sum_r x_i
        num_rows       = N
    Output layout (each 64-bit value = two int32 words, lo then hi):
        [ sum_product[0..135] | sum_self[0..15] | num_rows ]  = 136*2 + 16*2 + 2 = 306 words.
    """

    alternative_vfpga_top_file = "vfpga-tops/covariance_test.sv"

    debug_mode = True

    N_FEAT = 16                              # features per row (= N_IN in the RTL)
    NUM_PAIRS = N_FEAT * (N_FEAT + 1) // 2   # 136

    def setUp(self):
        super().setUp()
        self.rows: list[list[int]] = None    # list of N_FEAT-wide rows

    @staticmethod
    def _to_s32(x: int) -> int:
        x &= 0xFFFFFFFF
        return x - (1 << 32) if x >= (1 << 31) else x

    def _i64_words(self, v: int) -> list[int]:
        # 64-bit value -> [lo32, hi32] as signed int32, matching the RTL packing.
        v &= 0xFFFFFFFFFFFFFFFF
        return [self._to_s32(v & 0xFFFFFFFF), self._to_s32(v >> 32)]

    def _golden_words(self, rows: list[list[int]]) -> list[int]:
        n_feat = self.N_FEAT
        num_rows = len(rows)

        sum_self = [sum(r[i] for r in rows) for i in range(n_feat)]
        sum_product = []
        for i in range(n_feat):
            for j in range(i, n_feat):
                sum_product.append(sum(r[i] * r[j] for r in rows))

        words: list[int] = []
        for v in sum_product:          # 136 * 2 = 272 words
            words += self._i64_words(v)
        for v in sum_self:             # 16 * 2 = 32 words
            words += self._i64_words(v)
        words += self._i64_words(num_rows)   # 2 words
        return words                   # 306 words total

    def simulate_fpga(self):
        assert self.rows, "need input rows"
        assert all(len(r) == self.N_FEAT for r in self.rows), "each row must be N_FEAT wide"

        flat = [x for r in self.rows for x in r]      # row-major: beat r = row r
        words = self._golden_words(self.rows)
        column   = fpga_stream.Stream(fpga_stream.StreamType.SIGNED_INT_32, flat)
        expected = fpga_stream.Stream(fpga_stream.StreamType.SIGNED_INT_32, words)

        print(f"\n[covariance] {self._testMethodName}")
        print(f"  rows     = {self.rows}   ({len(self.rows)} rows x {self.N_FEAT} feat)")
        print(f"  expected = {len(words)} words (should be 306)")

        self.simulate_fpga_non_blocking()

        # single-pass feed: one LOCAL_READ transfer from one allocation (oasis idiom).
        io = self.get_io_writer()
        data = column.data_to_bytearray()
        vaddr = io.allocate_and_write_to_next_free_sim_memory(data)
        io.invoke_transfer(CoyoteOperator.LOCAL_READ, CoyoteStreamType.STREAM_HOST, 0, vaddr, len(data), True)

        self.set_expected_output(0, expected)
        self.finish_fpga_simulation()


class CovarianceTest(CovarianceTestCase):
    def test_two_rows(self):
        self.rows = [
            [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
            [2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32],
        ]
        self.simulate_fpga()
        self.assert_simulation_output()

    def test_three_rows(self):
        self.rows = [
            [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160],
            [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
            [-5, 0, 5, -5, 0, 5, -5, 0, 5, -5, 0, 5, -5, 0, 5, -5],
        ]
        self.simulate_fpga()
        self.assert_simulation_output()
