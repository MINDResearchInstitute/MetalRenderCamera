//
//  Shaders.metal
//  Clinktag corner detector
//

#include <metal_stdlib>
#include <metal_atomic>
using namespace metal;

typedef struct {
    float4 renderedCoordinate [[position]];
    float2 textureCoordinate;
} TextureMappingVertex;


constexpr sampler tSampler(address::clamp_to_edge, filter::linear);

constant int NSAMPLES = 23;
constant half SAMPLE_HALF_ANGLE = M_PI_H/NSAMPLES;
constant half SAMPLE_ANGLE = 2*SAMPLE_HALF_ANGLE;
constant int N_CHANNEL_THRESHOLD = NSAMPLES/5;
constant int HALF_N_CHANNEL_THRESHOLD = NSAMPLES/10;
constant uint WIDTH_PIXELS = 1920;
constant uint HEIGHT_PIXELS = 1080;
constant half ASPECT_RATIO = half(WIDTH_PIXELS)/half(HEIGHT_PIXELS);
constant half LUM_DIFF_THRESHOLD = 0.05;
constant half RADIUS_X = 0.009;
constant half RADIUS_Y = RADIUS_X*ASPECT_RATIO;
constant half ORIENTATION_RESOLUTION = 10;
constant half ORIENTATION_XY_SCALE = ORIENTATION_RESOLUTION/2/RADIUS_X;
constant uint GRID_RESOLUTION = 1;
constant uint GRID_DIVS_X = 16*GRID_RESOLUTION;
constant uint GRID_DIVS_Y = 9*GRID_RESOLUTION;
constant uint PIX_PER_CELL_X = WIDTH_PIXELS / GRID_DIVS_X;
constant uint PIX_PER_CELL_Y = HEIGHT_PIXELS / GRID_DIVS_Y;


//COLORS
constant uint RED = 1;
constant uint BLUE = 2;
constant uint YELLOW = 3;

//TAG TYPES
constant uint NUM_TAG_TYPES = 30;
constant uint BOARD_3Part_CW = 0;
constant uint CODE_3Part_CW = 1;
constant uint BOARD_3Part_CCW = 2;
constant uint CODE_3Part_CCW = 3;
constant uint BOARD_4Part_RR = 4;
constant uint MARKER_4Part_YY = 5;
constant uint BOARD_4Part_BB = 6;
/*
 7,8: Y 5-part CW,CCW
 9,10: R 5-part CW,CCW
 11,12: B 5-part CW,CCW
 13-23: 11 6-part tags
 24-26: 3 1-part tags
 27-29: 3 2-part tags
 */


//Grid Cell Metric Offsets
constant uint NUM_METRICS_PER_CELL = 8;
constant uint TOTAL_WEIGHT = 0;
constant uint TYPE_FLAGS = 1;
constant uint TYPE_AVERAGE = 2;
constant uint X_COORD_AVERAGE = 3;
constant uint Y_COORD_AVERAGE = 4;
constant uint X_ORIENTATION_AVERAGE = 5;
constant uint Y_ORIENTATION_AVERAGE = 6;
constant uint DOT_SIZE = 7;

//Reusable Vectors
constant half4 BLACK_PIXEL = half4(0);
constant half4 YELLOW_PIXEL = half4(1,1,0,1);
constant float2 DOT_BALENCE_STEP_X = float2(0.001,0);
constant float2 DOT_BALENCE_STEP_Y = float2(0,0.001*ASPECT_RATIO);


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
    return (rgba.r + rgba.g + rgba.g)/3;
}

void getLumChroma(half4 rgba, thread half & lum, thread half & chroma ){
    half r = rgba.r;
    half g = rgba.g;
    half b = rgba.b;
    lum = (r + g + b)/3;
    chroma = max3(r,g,b) - min3(r,g,b);
}

half2 measureDotBalance_Axis(texture2d<float, access::sample> texture, float2 xy, half centerLum, float2 deltaXY, thread half & dotSize  ){
    half lum;
    
    half rA = 0;
    half rB = 0;
    half i;
    for(i=1; i<10; i++){
        lum = getLum(half4(texture.sample(tSampler, xy-deltaXY*i)));
        if( (lum - centerLum) >= LUM_DIFF_THRESHOLD){
            rA = i;
            break;
        }
    }
    for(i=1; i<10; i++){
        lum = getLum(half4(texture.sample(tSampler, xy+deltaXY*i)));
        if( (lum - centerLum) >= LUM_DIFF_THRESHOLD){
            rB = i;
            break;
        }
    }
    return half2(rA,rB);
}

float4 measureDotXYSizeBalance(texture2d<float, access::sample> texture, float2 xy, half centerLum ){
    half dotSizeX;
    half dotSizeY;
    half2 xBalance = measureDotBalance_Axis(texture, xy,centerLum, DOT_BALENCE_STEP_X, dotSizeX );
    half2 yBalance = measureDotBalance_Axis(texture, xy,centerLum, DOT_BALENCE_STEP_Y, dotSizeY);
    float newX = xy[0] + float((xBalance[1] - xBalance[0])/2)*DOT_BALENCE_STEP_X[0];
    float newY = xy[1] + float((yBalance[1] - yBalance[0])/2)*DOT_BALENCE_STEP_Y[1];
    half dotSize = (xBalance[0]+xBalance[1]+yBalance[0]+yBalance[1]-2)/2;
    half dotBalance = min(min(xBalance[0],xBalance[1])/max(xBalance[0],xBalance[1]),min(yBalance[0],yBalance[1])/max(yBalance[0],yBalance[1]));
    return float4(newX,newY,float(dotSize),float(dotBalance));
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


//TODO: Would it help to move to texture2d<half> instead of float?


fragment half4 displayTexture(  TextureMappingVertex mappingVertex [[ stage_in ]],
                              texture2d<float, access::sample> texture [[ texture(0) ]],
                              device atomic_int &clinkData [[buffer(0)]],
                              
                              constant   int & hline   [[ buffer(1) ]],
                              constant   int & vline   [[ buffer(2) ]] ){
    
    float2 xy = mappingVertex.textureCoordinate;
    
    if(xy[0] <= 0.01 || xy[1] <= 0.01 || xy[0] >= 0.99 || xy[1] >= 0.99){
        return BLACK_PIXEL;
    }
    
    half4 pixel =  half4(texture.sample(tSampler, xy));
    
    half centerLum;
    half centerChromaticity;
    getLumChroma(pixel, centerLum, centerChromaticity);
    half outsideLum;
    half lumDiff;
    half outsideChromaticity;
    half minOutsideLum = 1;
    half orientationX = 0;
    half orientationY = 0;
    int orientationType = 0;
    bool isDarkCenter = true;
    bool isClinkCorner3 = false;
    bool isClinkCorner4 = false;
    int clinkCornerType = -1;
    float2 pt;
    float2 firstPT;
    half4 ptrgb;
    half sinVal;
    half cosVal;
    
    if(centerChromaticity > 0.3 || centerLum > 0.95){
        isDarkCenter = false;
    }
    else{
        for(half i=0; i<NSAMPLES; i++){
            sinVal = sincos(i*SAMPLE_HALF_ANGLE,cosVal);
            pt = float2(RADIUS_X*cosVal,RADIUS_Y*sinVal);
            ptrgb = half4(texture.sample(tSampler, xy+pt));
            getLumChroma(ptrgb, outsideLum, outsideChromaticity);
            lumDiff = outsideLum - centerLum;
            if(lumDiff < LUM_DIFF_THRESHOLD || outsideChromaticity < centerChromaticity){
                isDarkCenter = false;
                break;
            }
            else{
                minOutsideLum = min(minOutsideLum,outsideLum);
            }
            ptrgb = half4(texture.sample(tSampler, xy-pt));
            getLumChroma(ptrgb, outsideLum, outsideChromaticity);
            lumDiff = outsideLum - centerLum;
            if(lumDiff < LUM_DIFF_THRESHOLD || outsideChromaticity < centerChromaticity){
                isDarkCenter = false;
                break;
            }
            else{
                minOutsideLum = min(minOutsideLum,outsideLum);
            }
        }
    }
    
    
    if(isDarkCenter ){
        int redCount = 0;
        int blueCount = 0;
        int yellowCount = 0;
        int otherCount = 0;
        bool isYellow = false;
        int numTransitions = 0;
        int numClockwiseTransitions = 0;
        int numYellowOppRed = 0;
        int numYellowOppBlue = 0;
        int numYellowOppYellow = 0;
        int colorType = 0;
        int lastColorType = 0;
        int firstColorType = 0;
        float2 prevPt;
        
        for(half i=0; i<NSAMPLES; i++){
            sinVal = sincos(i*SAMPLE_ANGLE,cosVal);
            pt = float2(RADIUS_X*cosVal,RADIUS_Y*sinVal);
            ptrgb = half4(texture.sample(tSampler, xy+pt));
            colorType = getColorType(ptrgb);
            isYellow = false;
            switch(colorType){
                case RED: redCount++; break;
                case BLUE: blueCount++; break;
                case YELLOW: isYellow = true; yellowCount++; break;
                default: otherCount++;
            }
            if(colorType > 0){
                if(lastColorType == 0){
                    firstColorType = colorType;
                    firstPT = pt;
                }
                else if(colorType != lastColorType){
                    numTransitions++;
                    switch(lastColorType){
                        case RED: if(colorType==YELLOW){numClockwiseTransitions++;};break;
                        case BLUE: if(colorType==RED){numClockwiseTransitions++;};break;
                        case YELLOW:
                            if(colorType==BLUE){
                                numClockwiseTransitions++;
                                if(orientationType == 0){
                                    orientationType = BLUE;
                                    orientationX = (prevPt[0]+pt[0])*ORIENTATION_XY_SCALE;
                                    orientationY = (prevPt[1]+pt[1])*ORIENTATION_XY_SCALE;
                                }
                            }
                            else{
                                orientationType = RED; //RED beats out BLUE for orientation
                                orientationX = (prevPt[0]+pt[0])*ORIENTATION_XY_SCALE;
                                orientationY = (prevPt[1]+pt[1])*ORIENTATION_XY_SCALE;
                            };
                            break;
                    }
                }
                lastColorType = colorType;
                if(isYellow){
                    ptrgb = half4(texture.sample(tSampler, xy-pt));
                    colorType = getColorType(ptrgb);
                    switch(colorType){
                        case RED: numYellowOppRed++; break;
                        case BLUE: numYellowOppBlue++; break;
                        case YELLOW: numYellowOppYellow++; break;
                    }
                }
            }
            prevPt = pt;
        }
        if(lastColorType != firstColorType){
            numTransitions++;
            switch(lastColorType){
                case RED: if(firstColorType==YELLOW){numClockwiseTransitions++;};break;
                case BLUE: if(firstColorType==RED){numClockwiseTransitions++;};break;
                case YELLOW:
                    if(firstColorType==BLUE){
                        numClockwiseTransitions++;
                        if(orientationType == 0){
                            orientationType = BLUE;
                            orientationX = (firstPT[0]+pt[0])*ORIENTATION_XY_SCALE;
                            orientationY = (firstPT[1]+pt[1])*ORIENTATION_XY_SCALE;
                        }
                    }
                    else{
                        orientationType = RED; //RED beats out BLUE for orientation
                        orientationX = (firstPT[0]+pt[0])*ORIENTATION_XY_SCALE;
                        orientationY = (firstPT[1]+pt[1])*ORIENTATION_XY_SCALE;
                    };
                    break;
            }
        }
        if(otherCount < HALF_N_CHANNEL_THRESHOLD && redCount > N_CHANNEL_THRESHOLD && blueCount > N_CHANNEL_THRESHOLD && yellowCount > N_CHANNEL_THRESHOLD){
            if(numTransitions == 3){
                if(yellowCount <= redCount || yellowCount <= blueCount){
                    isClinkCorner3 = true;
                    if(numClockwiseTransitions == 3){
                        if(numYellowOppRed > numYellowOppBlue && numYellowOppBlue < HALF_N_CHANNEL_THRESHOLD){
                            clinkCornerType = BOARD_3Part_CW;
                        }
                        else{
                            clinkCornerType = CODE_3Part_CW;
                        }
                    }
                    else{
                        if(numYellowOppBlue > numYellowOppRed && numYellowOppRed < HALF_N_CHANNEL_THRESHOLD){
                            clinkCornerType = BOARD_3Part_CCW;
                        }
                        else{
                            clinkCornerType = CODE_3Part_CCW;
                        }
                    }
                }
            }
            else if(numTransitions == 4){
                isClinkCorner4 = true;
                if(yellowCount < redCount && blueCount < redCount && numYellowOppBlue >= N_CHANNEL_THRESHOLD){
                    clinkCornerType = BOARD_4Part_RR;
                }
                else if(yellowCount < blueCount && redCount < blueCount && numYellowOppRed >= N_CHANNEL_THRESHOLD){
                    clinkCornerType = BOARD_4Part_BB;
                }
                else if( redCount < yellowCount && blueCount < yellowCount && numYellowOppYellow >= N_CHANNEL_THRESHOLD){
                    clinkCornerType = MARKER_4Part_YY;
                }
            }
        }
    }
    
    if(clinkCornerType > -1){
        pixel = half4(1,1,0,1);
        atomic_fetch_add_explicit(&clinkData + clinkCornerType, 1, memory_order_relaxed);
        float4 dotXYSizeBalance = measureDotXYSizeBalance(texture, xy, centerLum );
        float newX = dotXYSizeBalance[0];
        float newY = dotXYSizeBalance[1];
        int gridCellX = newX*GRID_DIVS_X;
        int gridCellY = newY*GRID_DIVS_Y;
        int gridCellIndex = GRID_DIVS_X*gridCellY + gridCellX;
        int dataOffset = NUM_TAG_TYPES + NUM_METRICS_PER_CELL*gridCellIndex;
        int pixX = round(WIDTH_PIXELS*newX);
        int pixY = round(HEIGHT_PIXELS*newY);
        int weight = max(1,int(round(dotXYSizeBalance[2]*dotXYSizeBalance[3]*dotXYSizeBalance[3])));
        int typeFlag = 1 << clinkCornerType;
        int typeAvg = weight * clinkCornerType;
        int xCoordAvg = weight * pixX;
        int yCoordAvg = weight * pixY;
        
        int xOrientationAverage = round(orientationX*half(weight));
        int yOrientationAverage = round(orientationY*half(weight));
        int dotSize = dotXYSizeBalance[2]*weight;
        
        atomic_fetch_add_explicit(&clinkData + dataOffset + TOTAL_WEIGHT, weight, memory_order_relaxed);
        atomic_fetch_or_explicit(&clinkData + dataOffset + TYPE_FLAGS, typeFlag, memory_order_relaxed);
        atomic_fetch_add_explicit(&clinkData + dataOffset + TYPE_AVERAGE, typeAvg, memory_order_relaxed);
        atomic_fetch_add_explicit(&clinkData + dataOffset + X_COORD_AVERAGE, xCoordAvg, memory_order_relaxed);
        atomic_fetch_add_explicit(&clinkData + dataOffset + Y_COORD_AVERAGE, yCoordAvg, memory_order_relaxed);
        atomic_fetch_add_explicit(&clinkData + dataOffset + X_ORIENTATION_AVERAGE, xOrientationAverage, memory_order_relaxed);
        atomic_fetch_add_explicit(&clinkData + dataOffset + Y_ORIENTATION_AVERAGE, yOrientationAverage, memory_order_relaxed);
        atomic_fetch_add_explicit(&clinkData + dataOffset + DOT_SIZE, dotSize, memory_order_relaxed);
        
        pixel = YELLOW_PIXEL;
    }
    else{
        pixel = pixel*0.3;
    }
    //atomic_fetch_add_explicit(&clinkData, 1, memory_order_relaxed);
    //atomic_store_explicit(&clinkData + 2, texture.get_height(), memory_order_relaxed);
    
    if(floor(xy[0]*WIDTH_PIXELS) == hline){
        return half4(0,1,1,1);
    }
    
    if(floor(xy[1]*HEIGHT_PIXELS) == vline){
        return half4(0,1,1,1);
    }
    
    return pixel;
}



