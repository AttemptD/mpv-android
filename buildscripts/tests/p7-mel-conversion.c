/* Host regression for the FFmpeg converter used by native Android playback.
 * Compile against a prepared host FFmpeg build containing the dovi_mel BSF.
 * Arguments: vector directory, converted RPU output path.
 */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libavcodec/dovi_mel.h"
#include "libavutil/intreadwrite.h"
#include "libavutil/log.h"
#include "libavutil/mem.h"

static int checks;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); exit(1); } checks++; } while (0)
static const uint8_t base[] = {0,0,0,1, 0x02,0x01,0x80,0x55};
static const uint8_t el[] = {0,0,0,1, 0x7e,0x01,0x02,0x01,0x80,0xa5};

static uint8_t *read_file(const char *directory, const char *name, int *size)
{
    char path[4096];
    snprintf(path,sizeof(path),"%s/%s",directory,name);
    FILE *f=fopen(path,"rb");CHECK(f);
    CHECK(fseek(f,0,SEEK_END)==0);*size=ftell(f);rewind(f);
    uint8_t *p=malloc(*size);CHECK(p);CHECK(fread(p,1,*size,f)==*size);fclose(f);
    CHECK(*size>4 && AV_RB32(p)==1);
    return p;
}
static AVPacket *packet(const uint8_t *rpu, int size)
{
    AVPacket *p=av_packet_alloc();CHECK(p);
    int bytes=sizeof(base)+sizeof(el)+(size ? size+2 : 0);
    CHECK(av_new_packet(p,bytes)==0);
    memcpy(p->data,base,sizeof(base));memcpy(p->data+sizeof(base),el,sizeof(el));
    if(size) {
        uint8_t *dst=p->data+sizeof(base)+sizeof(el);
        AV_WB32(dst,1);dst[4]=0x7c;dst[5]=1;memcpy(dst+6,rpu+4,size-4);
    }
    p->pts=100;p->dts=99;p->duration=1;p->flags=AV_PKT_FLAG_KEY;
    return p;
}
/* Parse the independent libdovi result, including its CRC, then encode it in
 * FFmpeg's canonical block order. FFmpeg groups static blocks before dynamic
 * blocks; byte equality with libdovi's original order would reject equivalent
 * metadata solely because the block order and CRC differ. */
static void reference_matches(const H2645NAL *actual, const uint8_t *ref, int size)
{
    AVPacket *p=packet(ref,size);
    H2645Packet split={0};DOVIContext in={0},out={0};
    AVDOVIMetadata *metadata=NULL;uint8_t *canonical=NULL;int bytes=0;
    CHECK(ff_h2645_packet_split(&split,p->data,p->size,NULL,4,AV_CODEC_ID_HEVC,H2645_FLAG_SMALL_PADDING)==0);
    CHECK(split.nb_nals==3 && split.nals[2].type==62);
    H2645NAL *nal=&split.nals[2];
    CHECK(ff_dovi_rpu_parse(&in,nal->data+2,nal->size-2,AV_EF_CRCCHECK|AV_EF_EXPLODE)==0);
    CHECK(ff_dovi_get_metadata(&in,&metadata)>0);
    CHECK(av_dovi_get_header(metadata)->disable_residual_flag);
    out.cfg=(AVDOVIDecoderConfigurationRecord){.dv_version_major=1,.dv_profile=8,.dv_level=3,
        .rpu_present_flag=1,.bl_present_flag=1,.dv_bl_signal_compatibility_id=1};
    CHECK(ff_dovi_rpu_generate(&out,metadata,FF_DOVI_WRAP_NAL,&canonical,&bytes)==0);
    CHECK(actual->raw_size==bytes+2);
    CHECK(!memcmp(actual->raw_data+2,canonical,bytes));
    av_free(canonical);av_free(metadata);ff_dovi_ctx_unref(&in);ff_dovi_ctx_unref(&out);
    ff_h2645_packet_uninit(&split);av_packet_free(&p);
}
static void rejected(DOVIMELContext *ctx, AVPacket *p)
{
    int size=p->size;uint8_t *saved=malloc(size);CHECK(saved);memcpy(saved,p->data,size);
    CHECK(ff_dovi_mel_convert(ctx,p)<0);
    CHECK(p->size==size && !memcmp(p->data,saved,size));
    free(saved);av_packet_free(&p);
}
int main(int argc,char **argv)
{
    CHECK(argc==3);av_log_set_level(AV_LOG_QUIET);
    int mel_size,ref_size,fel_size,other_size;
    uint8_t *mel=read_file(argv[1],"mel_orig.bin",&mel_size);
    uint8_t *ref=read_file(argv[1],"mel_to_81.bin",&ref_size);
    uint8_t *fel=read_file(argv[1],"fel_orig.bin",&fel_size);
    uint8_t *other=read_file(argv[1],"profile8.bin",&other_size);
    AVDOVIDecoderConfigurationRecord cfg={.dv_version_major=1,.dv_profile=7,.dv_level=3,
        .rpu_present_flag=1,.el_present_flag=1,.bl_present_flag=1,.dv_bl_signal_compatibility_id=6};
    DOVIMELContext ctx={0};CHECK(ff_dovi_mel_init(&ctx,NULL,&cfg)==0);
    CHECK(ctx.output.cfg.dv_profile==8 && ctx.output.cfg.dv_bl_signal_compatibility_id==1);
    CHECK(!ctx.output.cfg.el_present_flag && ctx.output.cfg.rpu_present_flag);
    AVPacket *p=packet(mel,mel_size);
    CHECK(ff_dovi_mel_convert(&ctx,p)==0);
    CHECK(p->pts==100 && p->dts==99 && p->duration==1 && (p->flags&AV_PKT_FLAG_KEY));
    H2645Packet parsed={0};
    CHECK(ff_h2645_packet_split(&parsed,p->data,p->size,NULL,4,AV_CODEC_ID_HEVC,H2645_FLAG_SMALL_PADDING)==0);
    CHECK(parsed.nb_nals==2 && parsed.nals[0].type==1 && parsed.nals[1].type==62);
    CHECK(parsed.nals[0].raw_size>=sizeof(base)-4);
    CHECK(!memcmp(parsed.nals[0].raw_data,base+4,sizeof(base)-4));
    for(int i=sizeof(base)-4;i<parsed.nals[0].raw_size;i++) CHECK(parsed.nals[0].raw_data[i]==0);
    H2645NAL *rpu=&parsed.nals[1];
    FILE *out=fopen(argv[2],"wb");CHECK(out);
    CHECK(fwrite(ref,1,4,out)==4);
    CHECK(fwrite(rpu->raw_data+2,1,rpu->raw_size-2,out)==rpu->raw_size-2);
    fclose(out);
    CHECK(rpu->raw_size==ref_size-4+2);
    CHECK(rpu->raw_data[0]==0x7c && rpu->raw_data[1]==1);
    reference_matches(rpu,ref,ref_size);
    ff_h2645_packet_uninit(&parsed);
    av_packet_free(&p);
    CHECK(ctx.converted_rpus==1);
    // A late FEL RPU must not pass because the decoder saw MEL earlier.
    rejected(&ctx,packet(fel,fel_size));
    ff_dovi_mel_flush(&ctx);
    p=packet(mel,mel_size);CHECK(ff_dovi_mel_convert(&ctx,p)==0);av_packet_free(&p);
    rejected(&ctx,packet(other,other_size));
    rejected(&ctx,packet(NULL,0));
    uint8_t *bad=malloc(mel_size);CHECK(bad);memcpy(bad,mel,mel_size);
    bad[mel_size-4]^=1;rejected(&ctx,packet(bad,mel_size));
    memcpy(bad,mel,mel_size);bad[5]=0;rejected(&ctx,packet(bad,mel_size));
    p=packet(mel,mel_size);
    AVDOVIDecoderConfigurationRecord *changed=(void *)av_packet_new_side_data(p,AV_PKT_DATA_DOVI_CONF,sizeof(cfg));
    CHECK(changed);*changed=ctx.output.cfg;rejected(&ctx,p);
    // CM v4.0: variable-length L8 trims must retain all values, not only L1/L6.
    int cm_size,cm_ref_size;
    uint8_t *cm=read_file(argv[1],"mel_variable_l8_length13.bin",&cm_size);
    uint8_t *cm_ref=read_file(argv[1],"mel_variable_l8_length13_to81.bin",&cm_ref_size);
    ff_dovi_mel_flush(&ctx);p=packet(cm,cm_size);
    CHECK(ff_dovi_mel_convert(&ctx,p)==0);
    CHECK(ff_h2645_packet_split(&parsed,p->data,p->size,NULL,4,AV_CODEC_ID_HEVC,H2645_FLAG_SMALL_PADDING)==0);
    CHECK(parsed.nb_nals==2);reference_matches(&parsed.nals[1],cm_ref,cm_ref_size);
    char cm_path[4096];snprintf(cm_path,sizeof(cm_path),"%s.cmv4.bin",argv[2]);
    out=fopen(cm_path,"wb");CHECK(out);CHECK(fwrite(cm_ref,1,4,out)==4);
    CHECK(fwrite(parsed.nals[1].raw_data+2,1,parsed.nals[1].raw_size-2,out)==parsed.nals[1].raw_size-2);
    fclose(out);ff_h2645_packet_uninit(&parsed);av_packet_free(&p);free(cm);free(cm_ref);
    ff_dovi_mel_close(&ctx);
    cfg.dv_bl_signal_compatibility_id=1;
    CHECK(ff_dovi_mel_init(&ctx,NULL,&cfg)<0);
    free(mel);free(ref);free(fel);free(other);free(bad);
    printf("PASS: P7 MEL conversion, %d assertions; FEL/corrupt/missing RPU rejected without modifying input\n",checks);
    return 0;
}
