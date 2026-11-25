/* Synthetic P7 lifecycle fixture. The EL duplicates the input HEVC video so it
 * is decodable and has matching PTS; it is not a mastered Dolby residual.
 * Arguments: HDR10 MP4, output MP4, RPU .bin, optional second RPU and switch PTS.
 * Compile/link against the host FFmpeg libraries, including libavformat.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libavformat/avformat.h"
#include "libavutil/dovi_meta.h"
#include "libavutil/intreadwrite.h"
#include "libavutil/mem.h"
#define OK(x) do { int ret=(x); if(ret<0) {char msg[256];av_strerror(ret,msg,sizeof(msg));fprintf(stderr,"line %d: %s: %s\n",__LINE__,#x,msg);exit(1);} } while(0)
#define REQUIRE(x) do {if(!(x)){fprintf(stderr,"line %d: %s\n",__LINE__,#x);exit(1);}}while(0)
static uint8_t *read_rpu(const char *path,int *size) {
    FILE *f=fopen(path,"rb");REQUIRE(f);fseek(f,0,SEEK_END);*size=ftell(f);rewind(f);
    uint8_t *r=av_malloc(*size);REQUIRE(r);REQUIRE(fread(r,1,*size,f)==*size);fclose(f);
    REQUIRE(*size>4 && AV_RB32(r)==1);return r;
}
int main(int argc,char **argv) {
    REQUIRE(argc==4 || argc==6);AVFormatContext *in=NULL,*out=NULL;
    int rpu_size,second_size=0,count=0;
    uint8_t *rpu=read_rpu(argv[3],&rpu_size),*second=argc==6?read_rpu(argv[4],&second_size):NULL;
    double change=argc==6?atof(argv[5]):0;
    OK(avformat_open_input(&in,argv[1],NULL,NULL));OK(avformat_find_stream_info(in,NULL));
    OK(avformat_alloc_output_context2(&out,NULL,"mp4",argv[2]));out->strict_std_compliance=FF_COMPLIANCE_UNOFFICIAL;
    int video=-1;
    for(int i=0;i<in->nb_streams;i++) {
        AVStream *src=in->streams[i],*dst=avformat_new_stream(out,NULL);REQUIRE(dst);
        OK(avcodec_parameters_copy(dst->codecpar,src->codecpar));dst->time_base=src->time_base;
        dst->avg_frame_rate=src->avg_frame_rate;dst->codecpar->codec_tag=0;
        if(dst->codecpar->codec_type==AVMEDIA_TYPE_VIDEO) {
            video=i;REQUIRE(dst->codecpar->codec_id==AV_CODEC_ID_HEVC);
            REQUIRE(dst->codecpar->extradata_size>=23 && (dst->codecpar->extradata[21]&3)==3);
            AVPacketSideData *sd=av_packet_side_data_new(&dst->codecpar->coded_side_data,
                &dst->codecpar->nb_coded_side_data,AV_PKT_DATA_DOVI_CONF,sizeof(AVDOVIDecoderConfigurationRecord),0);
            REQUIRE(sd);AVDOVIDecoderConfigurationRecord *cfg=(void *)sd->data;
            *cfg=(AVDOVIDecoderConfigurationRecord){.dv_version_major=1,.dv_profile=7,.dv_level=3,
                .rpu_present_flag=1,.el_present_flag=1,.bl_present_flag=1,.dv_bl_signal_compatibility_id=6};
            uint8_t *el_cfg=av_memdup(dst->codecpar->extradata,dst->codecpar->extradata_size);REQUIRE(el_cfg);
            REQUIRE(av_packet_side_data_add(&dst->codecpar->coded_side_data,&dst->codecpar->nb_coded_side_data,
                AV_PKT_DATA_HEVC_CONF,el_cfg,dst->codecpar->extradata_size,0));
        }
    }
    REQUIRE(video>=0);OK(avio_open(&out->pb,argv[2],AVIO_FLAG_WRITE));OK(avformat_write_header(out,NULL));
    AVPacket *p=av_packet_alloc();REQUIRE(p);
    while(av_read_frame(in,p)>=0) {
        int stream=p->stream_index;
        if(stream==video) {
            double pts=p->pts*av_q2d(in->streams[video]->time_base);
            uint8_t *use=second && pts>=change?second:rpu;int use_size=second && pts>=change?second_size:rpu_size;
            int extra=use_size+2;
            for(int off=0;off<p->size;) {REQUIRE(off+4<=p->size);int len=AV_RB32(p->data+off);REQUIRE(len>=2 && len<=p->size-off-4);extra+=len+6;off+=len+4;}
            int original=p->size;OK(av_grow_packet(p,extra));int dst=original;
            for(int off=0;off<original;) {
                int len=AV_RB32(p->data+off);AV_WB32(p->data+dst,len+2);dst+=4;
                p->data[dst++]=0x7e;p->data[dst++]=1;memcpy(p->data+dst,p->data+off+4,len);dst+=len;off+=len+4;
            }
            AV_WB32(p->data+dst,use_size-4+2);dst+=4;p->data[dst++]=0x7c;p->data[dst++]=1;
            memcpy(p->data+dst,use+4,use_size-4);dst+=use_size-4;REQUIRE(dst==p->size);count++;
        }
        av_packet_rescale_ts(p,in->streams[stream]->time_base,out->streams[stream]->time_base);
        OK(av_interleaved_write_frame(out,p));av_packet_unref(p);
    }
    OK(av_write_trailer(out));avio_closep(&out->pb);avformat_free_context(out);avformat_close_input(&in);av_packet_free(&p);
    av_free(rpu);av_free(second);printf("Synthetic P7: %d AUs, BL unchanged, decodable duplicate EL\n",count);return 0;
}
