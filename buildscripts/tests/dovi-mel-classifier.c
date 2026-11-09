#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include "video/dovi_mel.h"

// Host-side test; include deps/mpv and prefix/arm64/include, no linkage needed.
struct fixture {
    AVDOVIMetadata meta;
    AVDOVIRpuDataHeader header;
    AVDOVIDataMapping mapping;
    AVDOVIColorMetadata color;
};

int main(void)
{
    struct fixture x = {0};
    x.meta.header_offset = offsetof(struct fixture, header);
    x.meta.mapping_offset = offsetof(struct fixture, mapping);
    x.meta.color_offset = offsetof(struct fixture, color);
    x.header.coef_log2_denom = 23;
    x.mapping.nlq_method_idc = AV_DOVI_NLQ_LINEAR_DZ;
    for (int c = 0; c < 3; c++) x.mapping.nlq[c].vdr_in_max = 1ULL << 23;
    assert(!mp_dovi_is_mel(NULL));
    assert(mp_dovi_is_mel(&x.meta));
    for (int c = 0; c < 3; c++) {
        x.mapping.nlq[c].linear_deadzone_slope = 2048;
        assert(!mp_dovi_is_mel(&x.meta));
        x.mapping.nlq[c].linear_deadzone_slope = 0;
        x.mapping.nlq[c].linear_deadzone_threshold = 1;
        assert(!mp_dovi_is_mel(&x.meta));
        x.mapping.nlq[c].linear_deadzone_threshold = 0;
        x.mapping.nlq[c].nlq_offset = 512;
        assert(!mp_dovi_is_mel(&x.meta));
        x.mapping.nlq[c].nlq_offset = 0;
        x.mapping.nlq[c].vdr_in_max = 0;
        assert(!mp_dovi_is_mel(&x.meta));
        x.mapping.nlq[c].vdr_in_max = 1ULL << 23;
    }
    x.header.disable_residual_flag = 1;
    assert(!mp_dovi_is_mel(&x.meta));
    x.header.disable_residual_flag = 0;
    x.header.coef_log2_denom = 63;
    assert(!mp_dovi_is_mel(&x.meta));
    x.header.coef_log2_denom = 23;
    x.mapping.nlq_method_idc = AV_DOVI_NLQ_NONE;
    assert(!mp_dovi_is_mel(&x.meta));
    puts("MEL classifier: 17 assertions passed; FEL/unknown retained");
}
