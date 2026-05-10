//_____________________________________________________________/\_______________________________________________________________
//==============================================================================================================================
//
//
//                    AMD FidelityFX SUPER RESOLUTION [FSR 1] ::: SPATIAL SCALING & EXTRAS - v1.20210629
//
//
//------------------------------------------------------------------------------------------------------------------------------
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//------------------------------------------------------------------------------------------------------------------------------
// FidelityFX Super Resolution Sample
//
// Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//------------------------------------------------------------------------------------------------------------------------------
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//------------------------------------------------------------------------------------------------------------------------------
// ABOUT
// =====
// FSR is a collection of algorithms relating to generating a higher resolution image.
// This specific header focuses on single-image non-temporal image scaling, and related tools.
// 
// The core functions are EASU and RCAS:
//  [EASU] Edge Adaptive Spatial Upsampling ....... 1x to 4x area range spatial scaling, clamped adaptive elliptical filter.
//  [RCAS] Robust Contrast Adaptive Sharpening .... A non-scaling variation on CAS.
// RCAS needs to be applied after EASU as a separate pass.
// 
// Optional utility functions are:
//  [LFGA] Linear Film Grain Applicator ........... Tool to apply film grain after scaling.
//  [SRTM] Simple Reversible Tone-Mapper .......... Linear HDR {0 to FP16_MAX} to {0 to 1} and back.
//  [TEPD] Temporal Energy Preserving Dither ...... Temporally energy preserving dithered {0 to 1} linear to gamma 2.0 conversion.
// See each individual sub-section for inline documentation.
//------------------------------------------------------------------------------------------------------------------------------
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//------------------------------------------------------------------------------------------------------------------------------
// FUNCTION PERMUTATIONS
// =====================
// *F() ..... Single item computation with 32-bit.
// *H() ..... Single item computation with 16-bit, with packing (aka two 16-bit ops in parallel) when possible.
// *Hx2() ... Processing two items in parallel with 16-bit, easier packing.
//            Not all interfaces in this file have a *Hx2() form.
//==============================================================================================================================
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//_____________________________________________________________/\_______________________________________________________________
//==============================================================================================================================
//
//                                        FSR - [EASU] EDGE ADAPTIVE SPATIAL UPSAMPLING
//
//------------------------------------------------------------------------------------------------------------------------------
// EASU provides a high quality spatial-only scaling at relatively low cost.
// Meaning EASU is appropiate for laptops and other low-end GPUs.
// Quality from 1x to 4x area scaling is good.
//------------------------------------------------------------------------------------------------------------------------------
// The scalar uses a modified fast approximation to the standard lanczos(size=2) kernel.
// EASU runs in a single pass, so it applies a directionally and anisotropically adaptive radial lanczos.
// This is also kept as simple as possible to have minimum runtime.
//------------------------------------------------------------------------------------------------------------------------------
// The lanzcos filter has negative lobes, so by itself it will introduce ringing.
// To remove all ringing, the algorithm uses the nearest 2x2 input texels as a neighborhood,
// and limits output to the minimum and maximum of that neighborhood.
//------------------------------------------------------------------------------------------------------------------------------
// Input image requirements:
// 
// Color needs to be encoded as 3 channel[red, green, blue](e.g.XYZ not supported)
// Each channel needs to be in the range[0, 1]
// Any color primaries are supported
// Display / tonemapping curve needs to be as if presenting to sRGB display or similar(e.g.Gamma 2.0)
// There should be no banding in the input
// There should be no high amplitude noise in the input
// There should be no noise in the input that is not at input pixel granularity
// For performance purposes, use 32bpp formats
//------------------------------------------------------------------------------------------------------------------------------
// Best to apply EASU at the end of the frame after tonemapping 
// but before film grain or composite of the UI.
//------------------------------------------------------------------------------------------------------------------------------
// Example of including this header for D3D HLSL :
// 
//  #define A_GPU 1
//  #define A_HLSL 1
//  #define A_HALF 1
//  #include "ffx_a.h"
//  #define FSR_EASU_H 1
//  #define FSR_RCAS_H 1
//  //declare input callbacks
//  #include "ffx_fsr1.h"
// 
// Example of including this header for Vulkan GLSL :
// 
//  #define A_GPU 1
//  #define A_GLSL 1
//  #define A_HALF 1
//  #include "ffx_a.h"
//  #define FSR_EASU_H 1
//  #define FSR_RCAS_H 1
//  //declare input callbacks
//  #include "ffx_fsr1.h"
// 
// Example of including this header for Vulkan HLSL :
// 
//  #define A_GPU 1
//  #define A_HLSL 1
//  #define A_HLSL_6_2 1
//  #define A_NO_16_BIT_CAST 1
//  #define A_HALF 1
//  #include "ffx_a.h"
//  #define FSR_EASU_H 1
//  #define FSR_RCAS_H 1
//  //declare input callbacks
//  #include "ffx_fsr1.h"
// 
//  Example of declaring the required input callbacks for GLSL :
//  The callbacks need to gather4 for each color channel using the specified texture coordinate 'p'.
//  EASU uses gather4 to reduce position computation logic and for free Arrays of Structures to Structures of Arrays conversion.
// 
//  AH4 FsrEasuRH(AF2 p){return AH4(textureGather(sampler2D(tex,sam),p,0));}
//  AH4 FsrEasuGH(AF2 p){return AH4(textureGather(sampler2D(tex,sam),p,1));}
//  AH4 FsrEasuBH(AF2 p){return AH4(textureGather(sampler2D(tex,sam),p,2));}
//  ...
//  The FsrEasuCon function needs to be called from the CPU or GPU to set up constants.
//  The difference in viewport and input image size is there to support Dynamic Resolution Scaling.
//  To use FsrEasuCon() on the CPU, define A_CPU before including ffx_a and ffx_fsr1.
//  Including a GPU example here, the 'con0' through 'con3' values would be stored out to a constant buffer.
//  AU4 con0,con1,con2,con3;
//  FsrEasuCon(con0,con1,con2,con3,
//    1920.0,1080.0,  // Viewport size (top left aligned) in the input image which is to be scaled.
//    3840.0,2160.0,  // The size of the input image.
//    2560.0,1440.0); // The output resolution.
//==============================================================================================================================
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//_____________________________________________________________/\_______________________________________________________________
//==============================================================================================================================
//                                                   NON-PACKED 32-BIT VERSION
//==============================================================================================================================
#if defined(A_GPU)&&defined(FSR_EASU_F)
 // Filtering for a given tap for the scalar.
 void FsrEasuTapF(
 thread AF3 &aC, // Accumulated color, with negative lobe.
 thread AF1 &aW, // Accumulated weight.
 AF2 off, // Pixel offset from resolve position to tap.
 AF2 dir, // Gradient direction.
 AF2 len, // Length.
 AF1 lob, // Negative lobe strength.
 AF1 clp, // Clipping point.
 AF3 c){ // Tap color.
  // Rotate offset by direction.
  AF2 v;
  v.x=(off.x*( dir.x))+(off.y*dir.y);
  v.y=(off.x*(-dir.y))+(off.y*dir.x);
  // Anisotropy.
  v*=len;
  // Compute distance^2.
  AF1 d2=v.x*v.x+v.y*v.y;
  // Limit to the window as at corner, 2 taps can easily be outside.
  d2=min(d2,clp);
  // Approximation of lancos2 without sin() or rcp(), or sqrt() to get x.
  //  (25/16 * (2/5 * x^2 - 1)^2 - (25/16 - 1)) * (1/4 * x^2 - 1)^2
  //  |_______________________________________|   |_______________|
  //                   base                             window
  // The general form of the 'base' is,
  //  (a*(b*x^2-1)^2-(a-1))
  // Where 'a=1/(2*b-b^2)' and 'b' moves around the negative lobe.
  AF1 wB=AF1_(2.0/5.0)*d2+AF1_(-1.0);
  AF1 wA=lob*d2+AF1_(-1.0);
  wB*=wB;
  wA*=wA;
  wB=AF1_(25.0/16.0)*wB+AF1_(-(25.0/16.0-1.0));
  AF1 w=wB*wA;
  // Do weighted average.
  aC+=c*w;aW+=w;}
//------------------------------------------------------------------------------------------------------------------------------
 // Accumulate direction and length.
 void FsrEasuSetF(
 thread AF2 &dir,
 thread AF1 &len,
 AF2 pp,
 AP1 biS,AP1 biT,AP1 biU,AP1 biV,
 AF1 lA,AF1 lB,AF1 lC,AF1 lD,AF1 lE){
  // Compute bilinear weight, branches factor out as predicates are compiler time immediates.
  //  s t
  //  u v
  AF1 w = AF1_(0.0);
  if(biS)w=(AF1_(1.0)-pp.x)*(AF1_(1.0)-pp.y);
  if(biT)w=           pp.x *(AF1_(1.0)-pp.y);
  if(biU)w=(AF1_(1.0)-pp.x)*           pp.y ;
  if(biV)w=           pp.x *           pp.y ;
  // Direction is the '+' diff.
  //    a
  //  b c d
  //    e
  // Then takes magnitude from abs average of both sides of 'c'.
  // Length converts gradient reversal to 0, smoothly to non-reversal at 1, shaped, then adding horz and vert terms.
  AF1 dc=lD-lC;
  AF1 cb=lC-lB;
  AF1 lenX=max(abs(dc),abs(cb));
  lenX=APrxLoRcpF1(lenX);
  AF1 dirX=lD-lB;
  dir.x+=dirX*w;
  lenX=ASatF1(abs(dirX)*lenX);
  lenX*=lenX;
  len+=lenX*w;
  // Repeat for the y axis.
  AF1 ec=lE-lC;
  AF1 ca=lC-lA;
  AF1 lenY=max(abs(ec),abs(ca));
  lenY=APrxLoRcpF1(lenY);
  AF1 dirY=lE-lA;
  dir.y+=dirY*w;
  lenY=ASatF1(abs(dirY)*lenY);
  lenY*=lenY;
  len+=lenY*w;}
//------------------------------------------------------------------------------------------------------------------------------
 void FsrEasuF(
 thread AF3 &pix,
 AU2 ip,
 AU4 con0,
 AU4 con1,
 AU4 con2,
 AU4 con3,
 texture2d<float> easu_tex,
 sampler easu_smp){
//------------------------------------------------------------------------------------------------------------------------------
  // Get position of 'f'.
  AF2 pp=AF2(ip)*AF2_AU2(con0.xy)+AF2_AU2(con0.zw);
  AF2 fp=floor(pp);
  pp-=fp;
//------------------------------------------------------------------------------------------------------------------------------
  // 12-tap kernel.
  //    b c
  //  e f g h
  //  i j k l
  //    n o
  // Gather 4 ordering.
  //  a b
  //  r g
  // For packed FP16, need either {rg} or {ab} so using the following setup for gather in all versions,
  //    a b    <- unused (z)
  //    r g
  //  a b a b
  //  r g r g
  //    a b
  //    r g    <- unused (z)
  // Allowing dead-code removal to remove the 'z's.
  AF2 p0=fp*AF2_AU2(con1.xy)+AF2_AU2(con1.zw);
  // These are from p0 to avoid pulling two constants on pre-Navi hardware.
  AF2 p1=p0+AF2_AU2(con2.xy);
  AF2 p2=p0+AF2_AU2(con2.zw);
  AF2 p3=p0+AF2_AU2(con3.xy);
  AF4 bczzR=easu_tex.gather(easu_smp,p0,int2(0),component::x);
  AF4 bczzG=easu_tex.gather(easu_smp,p0,int2(0),component::y);
  AF4 bczzB=easu_tex.gather(easu_smp,p0,int2(0),component::z);
  AF4 ijfeR=easu_tex.gather(easu_smp,p1,int2(0),component::x);
  AF4 ijfeG=easu_tex.gather(easu_smp,p1,int2(0),component::y);
  AF4 ijfeB=easu_tex.gather(easu_smp,p1,int2(0),component::z);
  AF4 klhgR=easu_tex.gather(easu_smp,p2,int2(0),component::x);
  AF4 klhgG=easu_tex.gather(easu_smp,p2,int2(0),component::y);
  AF4 klhgB=easu_tex.gather(easu_smp,p2,int2(0),component::z);
  AF4 zzonR=easu_tex.gather(easu_smp,p3,int2(0),component::x);
  AF4 zzonG=easu_tex.gather(easu_smp,p3,int2(0),component::y);
  AF4 zzonB=easu_tex.gather(easu_smp,p3,int2(0),component::z);
//------------------------------------------------------------------------------------------------------------------------------
  // Simplest multi-channel approximate luma possible (luma times 2, in 2 FMA/MAD).
  AF4 bczzL=bczzB*AF4_(0.5)+(bczzR*AF4_(0.5)+bczzG);
  AF4 ijfeL=ijfeB*AF4_(0.5)+(ijfeR*AF4_(0.5)+ijfeG);
  AF4 klhgL=klhgB*AF4_(0.5)+(klhgR*AF4_(0.5)+klhgG);
  AF4 zzonL=zzonB*AF4_(0.5)+(zzonR*AF4_(0.5)+zzonG);
  // Rename.
  AF1 bL=bczzL.x;
  AF1 cL=bczzL.y;
  AF1 iL=ijfeL.x;
  AF1 jL=ijfeL.y;
  AF1 fL=ijfeL.z;
  AF1 eL=ijfeL.w;
  AF1 kL=klhgL.x;
  AF1 lL=klhgL.y;
  AF1 hL=klhgL.z;
  AF1 gL=klhgL.w;
  AF1 oL=zzonL.z;
  AF1 nL=zzonL.w;
  // Accumulate for bilinear interpolation.
  AF2 dir=AF2_(0.0);
  AF1 len=AF1_(0.0);
  FsrEasuSetF(dir,len,pp,true, false,false,false,bL,eL,fL,gL,jL);
  FsrEasuSetF(dir,len,pp,false,true ,false,false,cL,fL,gL,hL,kL);
  FsrEasuSetF(dir,len,pp,false,false,true ,false,fL,iL,jL,kL,nL);
  FsrEasuSetF(dir,len,pp,false,false,false,true ,gL,jL,kL,lL,oL);
//------------------------------------------------------------------------------------------------------------------------------
  // Normalize with approximation, and cleanup close to zero.
  AF2 dir2=dir*dir;
  AF1 dirR=dir2.x+dir2.y;
  AP1 zro=dirR<AF1_(1.0/32768.0);
  dirR=APrxLoRsqF1(dirR);
  dirR=zro?AF1_(1.0):dirR;
  dir.x=zro?AF1_(1.0):dir.x;
  dir*=AF2_(dirR);
  // Transform from {0 to 2} to {0 to 1} range, and shape with square.
  len=len*AF1_(0.5);
  len*=len;
  // Stretch kernel {1.0 vert|horz, to sqrt(2.0) on diagonal}.
  AF1 stretch=(dir.x*dir.x+dir.y*dir.y)*APrxLoRcpF1(max(abs(dir.x),abs(dir.y)));
  // Anisotropic length after rotation,
  //  x := 1.0 lerp to 'stretch' on edges
  //  y := 1.0 lerp to 2x on edges
  AF2 len2=AF2(AF1_(1.0)+(stretch-AF1_(1.0))*len,AF1_(1.0)+AF1_(-0.5)*len);
  // Based on the amount of 'edge',
  // the window shifts from +/-{sqrt(2.0) to slightly beyond 2.0}.
  AF1 lob=AF1_(0.5)+AF1_((1.0/4.0-0.04)-0.5)*len;
  // Set distance^2 clipping point to the end of the adjustable window.
  AF1 clp=APrxLoRcpF1(lob);
//------------------------------------------------------------------------------------------------------------------------------
  // Accumulation mixed with min/max of 4 nearest.
  //    b c
  //  e f g h
  //  i j k l
  //    n o
  AF3 min4=min(AMin3F3(AF3(ijfeR.z,ijfeG.z,ijfeB.z),AF3(klhgR.w,klhgG.w,klhgB.w),AF3(ijfeR.y,ijfeG.y,ijfeB.y)),
               AF3(klhgR.x,klhgG.x,klhgB.x));
  AF3 max4=max(AMax3F3(AF3(ijfeR.z,ijfeG.z,ijfeB.z),AF3(klhgR.w,klhgG.w,klhgB.w),AF3(ijfeR.y,ijfeG.y,ijfeB.y)),
               AF3(klhgR.x,klhgG.x,klhgB.x));
  // Accumulation.
  AF3 aC=AF3_(0.0);
  AF1 aW=AF1_(0.0);
  FsrEasuTapF(aC,aW,AF2( 0.0,-1.0)-pp,dir,len2,lob,clp,AF3(bczzR.x,bczzG.x,bczzB.x)); // b
  FsrEasuTapF(aC,aW,AF2( 1.0,-1.0)-pp,dir,len2,lob,clp,AF3(bczzR.y,bczzG.y,bczzB.y)); // c
  FsrEasuTapF(aC,aW,AF2(-1.0, 1.0)-pp,dir,len2,lob,clp,AF3(ijfeR.x,ijfeG.x,ijfeB.x)); // i
  FsrEasuTapF(aC,aW,AF2( 0.0, 1.0)-pp,dir,len2,lob,clp,AF3(ijfeR.y,ijfeG.y,ijfeB.y)); // j
  FsrEasuTapF(aC,aW,AF2( 0.0, 0.0)-pp,dir,len2,lob,clp,AF3(ijfeR.z,ijfeG.z,ijfeB.z)); // f
  FsrEasuTapF(aC,aW,AF2(-1.0, 0.0)-pp,dir,len2,lob,clp,AF3(ijfeR.w,ijfeG.w,ijfeB.w)); // e
  FsrEasuTapF(aC,aW,AF2( 1.0, 1.0)-pp,dir,len2,lob,clp,AF3(klhgR.x,klhgG.x,klhgB.x)); // k
  FsrEasuTapF(aC,aW,AF2( 2.0, 1.0)-pp,dir,len2,lob,clp,AF3(klhgR.y,klhgG.y,klhgB.y)); // l
  FsrEasuTapF(aC,aW,AF2( 2.0, 0.0)-pp,dir,len2,lob,clp,AF3(klhgR.z,klhgG.z,klhgB.z)); // h
  FsrEasuTapF(aC,aW,AF2( 1.0, 0.0)-pp,dir,len2,lob,clp,AF3(klhgR.w,klhgG.w,klhgB.w)); // g
  FsrEasuTapF(aC,aW,AF2( 1.0, 2.0)-pp,dir,len2,lob,clp,AF3(zzonR.z,zzonG.z,zzonB.z)); // o
  FsrEasuTapF(aC,aW,AF2( 0.0, 2.0)-pp,dir,len2,lob,clp,AF3(zzonR.w,zzonG.w,zzonB.w)); // n
//------------------------------------------------------------------------------------------------------------------------------
  // Normalize and dering.
  pix=min(max4,max(min4,aC*AF3_(ARcpF1(aW))));}
#endif
