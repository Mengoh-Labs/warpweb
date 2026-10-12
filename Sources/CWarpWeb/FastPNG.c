#include "CWarpWeb.h"
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <zlib.h>

// A single RFC 1950 stream assembled from byte-aligned raw DEFLATE blocks.
// Each non-final worker ends with FULL_FLUSH, not a final stream marker.
// PNG's Up filter is reversible and reads the preceding ORIGINAL scanline,
// so worker boundaries do not change the decoded pixels.
typedef struct {
    uint8_t *bytes;
    size_t size, input_size;
    uLong adler;
} Part;
typedef struct {
    const uint8_t *rgba;
    size_t width, height, stride, count;
    Part *parts;
} Job;

static void encode_part(void *opaque, size_t index) {
    Job *job = opaque;
    Part *part = &job->parts[index];
    size_t first = job->height*index/job->count;
    size_t end = job->height*(index+1)/job->count;
    size_t row = job->width*4, length = (row+1)*(end-first);
    uint8_t *scan = malloc(length);
    if (!scan) return;
    for (size_t y=first; y<end; ++y) {
        const uint8_t *src = job->rgba+y*job->stride;
        // Premultiplied translucent pixels require unpremultiplication and
        // platform color handling; leave those uncommon frames to ImageIO.
        for (size_t x=3; x<row; x+=4) {
            if (src[x]!=255) { free(scan); return; }
        }
        uint8_t *dst = scan+(y-first)*(row+1);
        *dst++ = 2;
        if (y) {
            const uint8_t *above = src-job->stride;
            for (size_t x=0; x<row; ++x) dst[x] = src[x]-above[x];
        } else { memcpy(dst,src,row); }
    }
    z_stream z = {0};
    if (deflateInit2(&z,1,Z_DEFLATED,-15,8,Z_DEFAULT_STRATEGY)!=Z_OK) {
        free(scan); return;
    }
    size_t capacity = deflateBound(&z,length)+32;
    part->bytes = malloc(capacity);
    if (part->bytes) {
        z.next_in=scan; z.avail_in=(uInt)length;
        z.next_out=part->bytes; z.avail_out=(uInt)capacity;
        int final = index+1==job->count;
        int result=deflate(&z,final ? Z_FINISH : Z_FULL_FLUSH);
        if (result==(final ? Z_STREAM_END : Z_OK) && !z.avail_in && z.avail_out) {
            part->size=z.total_out; part->input_size=length;
            part->adler=adler32(adler32(0,NULL,0),scan,(uInt)length);
        }
    }
    deflateEnd(&z); free(scan);
}
static void big32(uint8_t *p, uint32_t value) {
    p[0]=value>>24; p[1]=value>>16; p[2]=value>>8; p[3]=value;
}
static uint8_t *chunk(uint8_t *out, const char *type, const uint8_t *data, size_t size) {
    big32(out,(uint32_t)size); memcpy(out+4,type,4);
    if (size) memcpy(out+8,data,size);
    big32(out+8+size,(uint32_t)crc32(0,out+4,(uInt)size+4));
    return out+size+12;
}
uint8_t *warpweb_encode_png_rgba(const uint8_t *rgba, size_t width, size_t height,
    size_t row_bytes, const uint8_t *icc, size_t icc_size, size_t *output_size) {
    if (!output_size) return NULL;
    *output_size=0;
    if (!rgba || !width || !height || width>7680 || height>4320 ||
        row_bytes<width*4 || row_bytes>SIZE_MAX/height ||
        icc_size>1024*1024 || (icc_size && !icc)) return NULL;
    long cpus=sysconf(_SC_NPROCESSORS_ONLN);
    size_t count=cpus>0 ? (size_t)cpus : 1;
    if (count>8) count=8;
    if (count>height) count=height;
    Part parts[8] = {0};
    Job job={rgba,width,height,row_bytes,count,parts};
    dispatch_apply_f(count,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),&job,encode_part);
    uint8_t *profile=NULL, *output=NULL;
    size_t capacity=8+25+12+14+16; // signature, IHDR, IEND, zlib header/trailer IDATs
    uLong checksum=adler32(0,NULL,0);
    for (size_t i=0; i<count; ++i) {
        if (!parts[i].size) goto cleanup;
        capacity+=12+parts[i].size;
        checksum=adler32_combine(checksum,parts[i].adler,(z_off_t)parts[i].input_size);
    }
    uLongf profile_size=0;
    if (icc_size) {
        profile_size=compressBound(icc_size);
        profile=malloc(profile_size+9);
        if (!profile) goto cleanup;
        memcpy(profile,"warpweb\0\0",9); // profile name, NUL, compression method
        if (compress2(profile+9,&profile_size,icc,(uLong)icc_size,1)!=Z_OK) goto cleanup;
        profile_size+=9; capacity+=12+profile_size;
    }
    output=malloc(capacity);
    if (!output) goto cleanup;
    memcpy(output,"\x89PNG\r\n\x1a\n",8);
    uint8_t ihdr[13]={0}; big32(ihdr,(uint32_t)width); big32(ihdr+4,(uint32_t)height);
    ihdr[8]=8; ihdr[9]=6; // RGBA8, no interlace
    uint8_t *cursor=chunk(output+8,"IHDR",ihdr,13);
    if (profile) cursor=chunk(cursor,"iCCP",profile,profile_size);
    const uint8_t header[2]={0x78,0x01};
    cursor=chunk(cursor,"IDAT",header,2);
    for (size_t i=0; i<count; ++i) cursor=chunk(cursor,"IDAT",parts[i].bytes,parts[i].size);
    uint8_t trailer[4]; big32(trailer,(uint32_t)checksum);
    cursor=chunk(cursor,"IDAT",trailer,4);
    cursor=chunk(cursor,"IEND",NULL,0);
    *output_size=(size_t)(cursor-output);
cleanup:
    for (size_t i=0; i<count; ++i) free(parts[i].bytes);
    free(profile);
    return output;
}
