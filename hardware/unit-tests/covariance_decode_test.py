from coyote_test import fpga_test_case, fpga_stream, fpga_register, simulation_time


# -- Minimal Thrift/Parquet helpers --------------------------------------------------
# Inlined from parcore's page_header_parser_test / column_chunk_decoder_test so this
# test stays self-contained (no pyarrow dependency, no extra PYTHONPATH entry).

def _zigzag_encode(n: int) -> int:
    return (n << 1) ^ (n >> 31)


def _encode_varint(n: int) -> bytearray:
    n = _zigzag_encode(n)
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            b |= 0x80
        out.append(b)
        if not n:
            break
    return out


def _make_data_page_header(num_values: int, uncompressed_size: int,
                           compressed_size: int, encoding: int) -> bytearray:
    """Minimal Thrift compact DataPageHeader (no CRC, no statistics)."""
    h = bytearray()
    h += b'\x15' + _encode_varint(0)                # fid1: page_type=DATA_PAGE(0)
    h += b'\x15' + _encode_varint(uncompressed_size)
    h += b'\x15' + _encode_varint(compressed_size)
    h += b'\x2c'                                     # fid5: data_page_header STRUCT
    h += b'\x15' + _encode_varint(num_values)        # inner fid1: num_values
    h += b'\x15' + _encode_varint(encoding)          # inner fid2: encoding
    h += b'\x15' + _encode_varint(0)                 # inner fid3: def_level_enc=PLAIN
    h += b'\x15' + _encode_varint(0)                 # inner fid4: rep_level_enc=PLAIN
    h += b'\x00'                                     # inner STOP
    h += b'\x00'                                     # outer STOP
    return h


def _make_def_levels(num_values: int) -> bytes:
    # RLE/bit-packing hybrid, bit_width=1, all values = 1 (all present).
    header = num_values << 1
    varint = []
    v = header
    while True:
        b = v & 0x7f
        v >>= 7
        if v:
            varint.append(b | 0x80)
        else:
            varint.append(b)
            break
    rle_body = bytes(varint) + bytes([0x01])
    return len(rle_body).to_bytes(4, 'little') + rle_body


class CovarianceDecodeTestCase(fpga_test_case.FPGATestCase):
    """
    Integration test: ColumnChunkDecoder -> covariance.

    A PLAIN-encoded int32 column chunk is decoded by ParCore; the decoded values
    then flow through the covariance operator. The decoder decodes ONE column, so
    covariance consumes 16 int32/beat and treats each beat as one row of 16 features
    (single-column reshape -- this validates the decode->covariance SEAM, not real
    multi-column statistics). SINGLE pass -> raw sums streamed out (306 int32 words).

    Feed len(values) must be a multiple of 16 (whole rows), so every beat is full.
    """

    alternative_vfpga_top_file = "vfpga-tops/covariance_decode_test.sv"
    debug_mode = True

    N_FEAT = 16
    TYPE_T_INT32 = 1  # stream_type_to_libstf_type_t(SIGNED_INT_32)

    @staticmethod
    def _to_s32(x: int) -> int:
        x &= 0xFFFFFFFF
        return x - (1 << 32) if x >= (1 << 31) else x

    def _i64_words(self, v: int) -> list[int]:
        v &= 0xFFFFFFFFFFFFFFFF
        return [self._to_s32(v & 0xFFFFFFFF), self._to_s32(v >> 32)]

    def _golden_words(self, values: list[int]) -> list[int]:
        n_feat = self.N_FEAT
        rows = [values[r:r + n_feat] for r in range(0, len(values), n_feat)]
        num_rows = len(rows)

        sum_self = [sum(r[i] for r in rows) for i in range(n_feat)]
        sum_product = []
        for i in range(n_feat):
            for j in range(i, n_feat):
                sum_product.append(sum(r[i] * r[j] for r in rows))

        words: list[int] = []
        for v in sum_product:
            words += self._i64_words(v)
        for v in sum_self:
            words += self._i64_words(v)
        words += self._i64_words(num_rows)
        return words                       # 306 words

    def _plain_int32_chunk(self, items: list[int]) -> bytearray:
        values = fpga_stream.Stream(fpga_stream.StreamType.SIGNED_INT_32, items).data_to_bytearray()
        def_levels = _make_def_levels(len(items))
        payload = bytearray(def_levels) + bytearray(values)
        hdr = _make_data_page_header(len(items), len(payload), len(payload), encoding=0)  # PLAIN
        return bytearray(hdr) + payload

    def _chunk_register(self, num_values: int, compression: int = 0) -> bytearray:
        # column_chunk_conf_t (MSB->LSB): compression[1] | num_values[32] | type_t[3]
        packed = (compression << 35) | ((num_values & 0xFFFFFFFF) << 3) | (self.TYPE_T_INT32 & 0x7)
        return bytearray(packed.to_bytes(8, 'little'))

    def run_covariance(self, values: list[int]):
        assert len(values) % self.N_FEAT == 0, "feed must be a whole number of 16-feature rows"
        chunk = self._plain_int32_chunk(values)
        words = self._golden_words(values)

        print(f"\n[covariance_decode] {self._testMethodName}")
        print(f"  values   = {values}   ({len(values)//self.N_FEAT} rows x {self.N_FEAT})")
        print(f"  expected = {len(words)} words (should be 306)")

        # decode + covariance is a long pipeline -> run till the design finishes.
        self.overwrite_simulation_time(simulation_time.SimulationTime.till_finished())

        # SINGLE pass: one chunk-config register write, one decode. GlobalConfig
        # occupies regs 0..2, so the chunk config is register 3 (as in the decoder test).
        self.write_register(fpga_register.vFPGARegister(3, self._chunk_register(len(values))))
        self.set_stream_input(0, chunk)
        self.set_expected_output(0, fpga_stream.Stream(fpga_stream.StreamType.SIGNED_INT_32, words))

        self.simulate_fpga()
        self.assert_simulation_output()


class CovarianceDecodeTest(CovarianceDecodeTestCase):
    def test_two_rows(self):
        self.run_covariance(list(range(1, 33)))          # 32 values = 2 rows of 16

    def test_three_rows(self):
        self.run_covariance([v % 7 - 3 for v in range(48)])  # 48 values = 3 rows of 16
