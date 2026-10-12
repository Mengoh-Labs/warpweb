#include "CWarpWeb.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <zlib.h>
static unsigned read32(const unsigned char *p){return p[0]*16777216u+p[1]*65536u+p[2]*256u+p[3];}
int main(void){
 unsigned seed=17;
 for(int i=0;i<60;i++) {
  size_t w=1+(i*73)%521,h=1+(i*17)%233,row=w*4,stride=row+12,n;
  unsigned char *src=malloc(stride*h);
  for(size_t j=0;j<stride*h;j++){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;src[j]=seed;}
  for(size_t y=0;y<h;y++)for(size_t x=3;x<row;x+=4)src[y*stride+x]=255;
  unsigned char *png=warpweb_encode_png_rgba(src,w,h,stride,NULL,0,&n);assert(png);
  unsigned char *compressed=malloc(n);size_t total=0;
  for(size_t p=8;p<n;){unsigned len=read32(png+p);assert(p+len+12<=n);assert(read32(png+p+8+len)==crc32(0,png+p+4,len+4));if(!memcmp(png+p+4,"IDAT",4)){memcpy(compressed+total,png+p+8,len);total+=len;}p+=len+12;}
  uLongf size=(row+1)*h;unsigned char *raw=malloc(size);assert(uncompress(raw,&size,compressed,total)==Z_OK);assert(size==(row+1)*h);
  for(size_t y=0;y<h;y++){assert(raw[y*(row+1)]==2);for(size_t x=0;x<row;x++){unsigned char v=raw[y*(row+1)+1+x]+(y?src[(y-1)*stride+x]:0);assert(v==src[y*stride+x]);}}
  free(raw);free(compressed);free(png);
  src[(h-1)*stride+3]=128;assert(!warpweb_encode_png_rgba(src,w,h,stride,NULL,0,&n));assert(n==0);free(src);
 }
 puts("PASS: 60 noisy/padded PNG round trips, CRCs, transparency fallback; ASan/UBSan clean");
}
