//
//  Shaders.metal
//  First pass at a clinktag corner detector
//

#include <metal_stdlib>
#include <metal_atomic>
using namespace metal;

typedef struct {
    float4 renderedCoordinate [[position]];
    float2 textureCoordinate;
} TextureMappingVertex;

//constant half3 kRec709Luma = half3(0.2126, 0.7152, 0.0722);

constant int NSAMPLES = 24;
constant float ASPECT_RATIO = 1.7777777778;
constant half OUTSIDE_LUM_SCALE = 0.90;
constant float RADIUS = 0.009;


constant uint RED = 1;
constant uint BLUE = 2;
constant uint YELLOW = 3;

uint getColorType(half4 rgba){
    half r = rgba.r;
    half g = rgba.g;
    half b = rgba.b;
    half redness = (r>g && r>b) ? r-((g+b)/2)-.03 : 0;
    half blueness = (b>r && b>g) ? b-((r+g)/2) : 0;
    half yellowness = (b<g && b<r) ? ((r+g)/2)-b : 0;
    if(redness > blueness && redness > yellowness){
        return RED;
    }
    else if(blueness > redness && blueness > yellowness){
        return BLUE;
    }
    else if(yellowness > 0){
        return YELLOW;
    }
    return 0;
}

half getLum(half4 rgba){
    return (rgba.r + rgba.g + rgba.b)/3;
}

vertex TextureMappingVertex mapTexture(unsigned int vertex_id [[ vertex_id ]]) {
    float4x4 renderedCoordinates = float4x4(float4( -1.0, -1.0, 0.0, 1.0 ),
                                            float4(  1.0, -1.0, 0.0, 1.0 ),
                                            float4( -1.0,  1.0, 0.0, 1.0 ),
                                            float4(  1.0,  1.0, 0.0, 1.0 ));
    
    float4x2 textureCoordinates = float4x2(float2( 0.0, 1.0 ),
                                           float2( 1.0, 1.0 ),
                                           float2( 0.0, 0.0 ),
                                           float2( 1.0, 0.0 ));
    TextureMappingVertex outVertex;
    outVertex.renderedCoordinate = renderedCoordinates[vertex_id];
    outVertex.textureCoordinate = textureCoordinates[vertex_id];
    
    return outVertex;
}

fragment half4 displayTexture(  TextureMappingVertex mappingVertex [[ stage_in ]],
                              texture2d<float, access::sample> texture [[ texture(0) ]]){
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    
    float2 xy = mappingVertex.textureCoordinate;
    half4 pixel =  half4(texture.sample(s, xy));
    return pixel;
}


kernel void clinkCornerKernel(texture2d<half, access::sample> texture [[ texture(0) ]],
                              texture2d<half, access::write> outputTexture [[texture(1)]],
                              device atomic_int &clinkCornerCounter [[buffer(0)]],
                              
                              uint2 gid [[thread_position_in_grid]]){
    
    // Check if the pixel is within the bounds of the output texture
    if((gid.x >= outputTexture.get_width()) || (gid.y >= outputTexture.get_height()))
    {
        // Return early if the pixel is out of bounds
        return;
    }
    
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    
    float2 xy = float2(float(gid.x)/float(outputTexture.get_width()),float(gid.y)/float(outputTexture.get_height()));
    half4 pixel =  half4(texture.sample(s, xy));
    half centerLum = getLum(pixel);
    bool isDarkCenter = true;
    bool isClinkCorner3 = false;
    bool isClinkCorner4 = false;
    int numClockwiseTransitions = 0;
    float2 pt;
    half4 ptrgb;
    float sinVal;
    float cosVal;
    
    for(int i=0; i<NSAMPLES; i++){
        sinVal = sincos(i*M_PI_F/NSAMPLES,cosVal);
        pt = float2(RADIUS*cosVal,ASPECT_RATIO*RADIUS*sinVal);
        //pt = float2(RADIUS*cos(i*M_PI_F/NSAMPLES),ASPECT_RATIO*RADIUS*sin(i*M_PI_F/NSAMPLES));
        ptrgb = half4(texture.sample(s, xy+pt));
        if(getLum(ptrgb)*OUTSIDE_LUM_SCALE < centerLum){
            isDarkCenter = false;
            break;
        }
        ptrgb = half4(texture.sample(s, xy-pt));
        if(getLum(ptrgb)*OUTSIDE_LUM_SCALE < centerLum){
            isDarkCenter = false;
            break;
        }
    }
    
    if(isDarkCenter){
        int redCount = 0;
        int blueCount = 0;
        int yellowCount = 0;
        int otherCount = 0;
        int numTransitions = 0;
        int colorType = 0;
        int lastColorType = 0;
        int firstColorType = 0;
        
        for(int i=0; i<NSAMPLES; i++){
            sinVal = sincos(i*2*M_PI_F/NSAMPLES,cosVal);
            pt = float2(RADIUS*cosVal,ASPECT_RATIO*RADIUS*sinVal);
            //pt = float2(RADIUS*cos(i*2*M_PI_F/NSAMPLES),ASPECT_RATIO*RADIUS*sin(i*2*M_PI_F/NSAMPLES));
            ptrgb = half4(texture.sample(s, xy+pt));
            colorType = getColorType(ptrgb);
            switch(colorType){
                case RED: redCount++; break;
                case BLUE: blueCount++; break;
                case YELLOW: yellowCount++; break;
                default: otherCount++;
            }
            if(colorType > 0){
                if(lastColorType == 0){
                    firstColorType = colorType;
                }
                else if(colorType != lastColorType){
                    numTransitions++;
                    switch(lastColorType){
                        case RED: if(colorType==YELLOW){numClockwiseTransitions++;};break;
                        case YELLOW: if(colorType==BLUE){numClockwiseTransitions++;};break;
                        case BLUE: if(colorType==RED){numClockwiseTransitions++;};break;
                    }
                }
                lastColorType = colorType;
            }
        }
        if(lastColorType != firstColorType){
            numTransitions++;
            switch(lastColorType){
                case RED: if(firstColorType==YELLOW){numClockwiseTransitions++;};break;
                case YELLOW: if(firstColorType==BLUE){numClockwiseTransitions++;};break;
                case BLUE: if(firstColorType==RED){numClockwiseTransitions++;};break;
            }
            
        }
        if(otherCount == 0 && redCount > 3 && blueCount > 3 && yellowCount > 3){
            if(numTransitions == 3){
                isClinkCorner3 = (yellowCount <= redCount || yellowCount <= blueCount);
            }
            else if(numTransitions == 4){
                isClinkCorner4 = true;
            }
        }
        //isClinkCorner3 = numTransitions == 3 && redCount > 4 && blueCount > 4 && yellowCount > 3 && yellowCount <= redCount && yellowCount <= blueCount;
    }
    
    if(isClinkCorner3){
        pixel = half4(1,1,0,1);
        outputTexture.write(pixel*0.3,gid);
        if(numClockwiseTransitions == 3){
            atomic_fetch_add_explicit(&clinkCornerCounter, 1, memory_order_relaxed);
        }
        else{
            atomic_fetch_add_explicit(&clinkCornerCounter + 1, 1, memory_order_relaxed);
        }
    }
    else if(isClinkCorner4){
        pixel = half4(0,1,1,1);
    }
    else{
        pixel = pixel*0.3;
    }
    outputTexture.write(pixel,gid);
}



