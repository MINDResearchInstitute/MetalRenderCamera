//
//  MTKViewController.swift
//  MetalShaderCamera
//
//  Created by Alex Staravoitau on 26/04/2016.
//  Copyright © 2016 Old Yellow Bricks. All rights reserved.
//


import UIKit
import Metal
import AVFoundation

#if arch(i386) || arch(x86_64)
#else
import MetalKit
#endif

let sizeInt32 = MemoryLayout<Int32>.stride
let NUM_PIX_X = 1920
let NUM_PIX_Y = 1080
let BYTES_PER_ROW = 7680
let GRID_RESOLUTION = 1
var gridDivisionsX = 16*GRID_RESOLUTION
var gridDivisionsY = 9*GRID_RESOLUTION
var clinkDataSize = valuesPerCell*gridDivisionsX*gridDivisionsY + numTagTypes
var numGridCells = gridDivisionsX*gridDivisionsY

//Debug lines. We can remove later:
var hLine:Int32 = 1920/2
var vLine:Int32 = 400

//Corner Types
let numTagTypes = 30
let BOARD_3Part_CW = 0
let CODE_3Part_CW = 1
let BOARD_3Part_CCW = 2
let CODE_3Part_CCW = 3
let BOARD_4Part_RR = 4
let MARKER_4Part_YY = 5
let BOARD_4Part_BB = 6

let VALID_CLINKCODE_DIAGONALS = [28, 23, 49, 19, 52, 46, 13, 59]

func isClinkboardType(type: Int) -> Bool {
    switch type {
    case BOARD_3Part_CW, BOARD_3Part_CCW, BOARD_4Part_BB, BOARD_4Part_RR :
        return true
    default:
        return false
    }
}

func isClinkcodeType(type: Int) -> Bool {
    switch type {
    case CODE_3Part_CW, CODE_3Part_CCW :
        return true
    default:
        return false
    }
}

func readRBGFromPixelBuffer( baseAddress:UnsafeRawPointer, xy:(x:Double, y:Double) ) -> (r:UInt8, g:UInt8, b:UInt8)? {
    let x = Int(round(xy.x))
    let y = Int(round(xy.y))
    guard x >= 0 && x < NUM_PIX_X && y >= 0 && y < NUM_PIX_Y else{
        return nil
    }
    let offset:Int = y*BYTES_PER_ROW + x*4
    let r:UInt8 = baseAddress.load(fromByteOffset: offset+0, as: UInt8.self)
    let g:UInt8 = baseAddress.load(fromByteOffset: offset+1, as: UInt8.self)
    let b:UInt8 = baseAddress.load(fromByteOffset: offset+2, as: UInt8.self)
    return (r:r,g:g,b:b)
}

func simpleHash(_ s:String ) -> Int {
    var h = 0;
    for c in s.utf8{
        h = (31*h + Int(c)) & 0xffffffff;
    }
    return h
}

//Per-Cell Data Fields
let valuesPerCell = 8

let TOTAL_WEIGHT = 0
let TYPE_FLAGS = 1
let TYPE_AVERAGE = 2
let X_COORD_AVERAGE = 3
let Y_COORD_AVERAGE = 4
let X_ORIENTATION_AVERAGE = 5
let Y_ORIENTATION_AVERAGE = 6
let DOT_SIZE = 7

struct ExtractedTag{
    var weight:Double
    var typeFlags:Int32
    var type:Int
    var x:Double
    var y:Double
    var orientX:Double
    var orientY:Double
    var orientHypot:Double
    var dotSize:Double
    var cellIndex:Int
    var xy: (x:Double, y:Double) { return (self.x, self.y) }
    
    func distTo(_ tag:ExtractedTag ) -> Double{
        return hypot(tag.x-x, tag.y-y)
    }
    
    func getErrorPointingTo(_ tag:ExtractedTag ) -> Double{
        let dist = self.distTo(tag)
        let pxy = (x:self.x + dist*self.orientX/self.orientHypot, y:self.y + dist*self.orientY/self.orientHypot)
        let error = hypot(pxy.x - tag.x, pxy.y - tag.y)
        return error
    }
}

struct OppositeTagPair{
    var tagA:ExtractedTag
    var tagB:ExtractedTag
    var centerXY:(x:Double, y:Double) {
        return (x:(self.tagA.x + self.tagB.x)/2.0, y:(self.tagA.y + self.tagB.y)/2.0)
    }
    var separation:Double {
        return hypot(self.tagA.x - self.tagB.x, self.tagA.y - self.tagB.y)
    }
    
    func isCompatable(_ withPair:OppositeTagPair ) -> Bool{
        let dist:Double = hypot( self.centerXY.x - withPair.centerXY.x, self.centerXY.y - withPair.centerXY.y )
        let distThresh:Double = min(self.separation, withPair.separation) / 2.0
        return dist < distThresh
    }
}


struct ClinkCode{
    var topLeft:ExtractedTag
    var topRight:ExtractedTag
    var bottomLeft:ExtractedTag
    var bottomRight:ExtractedTag
    
    var isValid:Bool = false
    var projectionMatrix:[Double] = []
    var code:Int32 = 0
    var centerXY:(x:Double, y:Double) = (-1,-1)
    
    init( cwPair:OppositeTagPair, ccwPair:OppositeTagPair, pixelBufferBaseAddress:UnsafeRawPointer ){
        (topLeft, bottomRight) = (cwPair.tagA, cwPair.tagB)
        if(topLeft.y > bottomRight.y){
            (topLeft, bottomRight) = (bottomRight, topLeft) //swap assuming up is actually up
        }
        (topRight, bottomLeft) = (ccwPair.tagA, ccwPair.tagB)
        let errorToBottom = topLeft.getErrorPointingTo(bottomLeft)
        let errorToRight = topLeft.getErrorPointingTo(topRight)
        if(errorToRight < errorToBottom){
            (bottomLeft, topRight) = (topRight, bottomLeft) //swap to align better
        }
        projectionMatrix = buildClinkcodeProjectionMatrix(&self)
        guard !projectionMatrix.contains(where:{!$0.isFinite}) else{
            return
        }
        code = self.readCode(pixelBufferBaseAddress)
        guard code != 0 else{
            return
        }
        if(code == -1){
            //rotate by 180 degrees
            (topLeft, topRight, bottomRight, bottomLeft ) = ( bottomRight, bottomLeft, topLeft, topRight )
            projectionMatrix = buildClinkcodeProjectionMatrix(&self)
            code = self.readCode(pixelBufferBaseAddress)
            guard code > 0 else{
                return
            }
        }
        centerXY = projectPoint(m:projectionMatrix, pt:(x:2.5, y:2.5))
        isValid = true
    }
    
    func readCode(_ pixelBufferBaseAddress:UnsafeRawPointer ) -> Int32 {
        var diagonalA:[Int] = []
        var diagonalB:[Int] = []
        let m = self.projectionMatrix
        var avgLum:Int = 0
        for i in 0..<6 {
            var pt = projectPoint(m:m , pt: (x:Double(i), y: Double(i)))
            var rgb = readRBGFromPixelBuffer(baseAddress: pixelBufferBaseAddress, xy:pt)
            guard rgb != nil else{
                return 0
            }
            var lum = Int(rgb!.r) + Int(rgb!.g) + Int(rgb!.b)
            avgLum += lum
            diagonalA.append(lum)
            pt = projectPoint(m:m , pt: (x:Double(5-i), y: Double(i)))
            rgb = readRBGFromPixelBuffer(baseAddress: pixelBufferBaseAddress, xy:pt)
            guard rgb != nil else{
                return 0
            }
            lum = Int(rgb!.r) + Int(rgb!.g) + Int(rgb!.b)
            avgLum += lum
            diagonalB.append(lum)
        }
        avgLum = avgLum / 12
        var diagonalValue:Int = 0
        var reverseDiagonalValue:Int = 0
        for i in 0..<6 {
            diagonalA[i] = (diagonalA[i] < avgLum) ? 1 : 0
            diagonalB[i] = (diagonalB[i] < avgLum) ? 1 : 0
            guard diagonalA[i] != diagonalB[i] else{
                return 0 //0 here means no chance of it working after a 180deg rotation
            }
            if(diagonalA[i] == 1){
                reverseDiagonalValue = reverseDiagonalValue | (1 << i)
                diagonalValue = diagonalValue | (1 << (5-i))
            }
        }
        
        if( VALID_CLINKCODE_DIAGONALS.contains(reverseDiagonalValue )){
            return -1 // here -1 means it'll work if we do a 180deg rotation
        }
        guard VALID_CLINKCODE_DIAGONALS.contains(diagonalValue) else{
            return 0 // no chance to work after 180deg rot
        }
        
        var codeValue:Int32 = 0
        var bitIndex:Int = 0
        for x in 0..<6 {
            for y in 0..<6 {
                guard x != y && x != 5-y else{
                    continue
                }
                let pt = projectPoint(m:m , pt: (x:Double(x), y: Double(y)))
                let rgb = readRBGFromPixelBuffer(baseAddress: pixelBufferBaseAddress, xy:pt)
                guard rgb != nil else{
                    return 0
                }
                let lum = Int(rgb!.r) + Int(rgb!.g) + Int(rgb!.b)
                if(lum < avgLum){
                    codeValue = codeValue | (1 << bitIndex)
                }
                bitIndex = bitIndex + 1
            }
        }
        let binString = String(codeValue, radix:2)
        let hash = (simpleHash(binString) - 12) % 64
        guard hash == diagonalValue else{
            return 0
        }
        return codeValue
    }
}




/**
 * A `UIViewController` that allows quick and easy rendering of Metal textures. Currently only supports textures from single-plane pixel buffers, e.g. it can only render a single RGB texture and won't be able to render multiple YCbCr textures. Although this functionality can be added by overriding `MTKViewController`'s `willRenderTexture` method.
 */
open class MTKViewController: UIViewController {
    // MARK: - Public interface
    
    
    /// Metal texture to be drawn whenever the view controller is asked to render its view. Please note that if you set this `var` too frequently some of the textures may not being drawn, as setting a texture does not force the view controller's view to render its content.
    open var texture: MTLTexture?
    
    open var sampleBuffer: CMSampleBuffer?
    
    /**
     This method is called prior rendering view's content. Use `inout` `texture` parameter to update the texture that is about to be drawn.
     
     - parameter texture:       Texture to be drawn
     - parameter commandBuffer: Command buffer that will be used for drawing
     - parameter device:        Metal device
     */
    open func willRenderTexture(_ texture: inout MTLTexture, withCommandBuffer commandBuffer: MTLCommandBuffer, device: MTLDevice) {
        /**
         * Override if neccessary
         */
    }
    
    /**
     This method is called after rendering view's content.
     
     - parameter texture:       Texture that was drawn
     - parameter commandBuffer: Command buffer we used for drawing
     - parameter device:        Metal device
     */
    open func didRenderTexture(_ texture: MTLTexture, withCommandBuffer commandBuffer: MTLCommandBuffer, device: MTLDevice) {
        /**
         * Override if neccessary
         */
    }
    
    // MARK: - Public overrides
    
    override open func loadView() {
        super.loadView()
        #if arch(i386) || arch(x86_64)
        NSLog("Failed creating a default system Metal device, since Metal is not available on iOS Simulator.")
        #else
        assert(device != nil, "Failed creating a default system Metal device. Please, make sure Metal is available on your hardware.")
        #endif
        initializeMetalView()
        initializeRenderPipelineState()
    }
    
    // MARK: - Private Metal-related properties and methods
    
    /**
     initializes and configures the `MTKView` we use as `UIViewController`'s view.
     
     */
    fileprivate func initializeMetalView() {
        #if arch(i386) || arch(x86_64)
        #else
        metalView = MTKView(frame: view.bounds, device: device)
        metalView.delegate = self
        metalView.framebufferOnly = true
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.contentScaleFactor = UIScreen.main.scale
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(metalView, at: 0)
        #endif
    }
    
    #if arch(i386) || arch(x86_64)
    #else
    /// `UIViewController`'s view
    internal var metalView: MTKView!
    #endif
    
    /// Metal device
    internal var device = MTLCreateSystemDefaultDevice()
    
    //Clink Data
    internal var clinkData = [Int32](repeating:0, count: clinkDataSize)
    internal var clinkDataBuffer: MTLBuffer?
    
    /// Metal device command queue
    lazy internal var commandQueue: MTLCommandQueue? = {
        return device?.makeCommandQueue()
    }()
    
    /// Metal pipeline state we use for rendering
    internal var renderPipelineState: MTLRenderPipelineState?
    
    /// A semaphore we use to syncronize drawing code.
    fileprivate let semaphore = DispatchSemaphore(value: 1)
    
    /**
     initializes render pipeline state with a default vertex function mapping texture to the view's frame and a simple fragment function returning texture pixel's value.
     */
    fileprivate func initializeRenderPipelineState() {
        guard
            let device = device,
            let library = device.makeDefaultLibrary()
            else { return }
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.sampleCount = 1
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.depthAttachmentPixelFormat = .invalid
        
        /**
         *  Vertex function to map the texture to the view controller's view
         */
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "mapTexture")
        /**
         *  Fragment function to display texture's pixels in the area bounded by vertices of `mapTexture` shader
         */
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "displayTexture")
        
        
        do {
            try renderPipelineState = device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        }
        catch {
            assertionFailure("Failed creating a render state pipeline. Can't render the texture without one.")
            return
        }
    }
}

#if arch(i386) || arch(x86_64)
#else

// MARK: - MTKViewDelegate and rendering
extension MTKViewController: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        NSLog("MTKView drawable size will change to \(size)")
    }
    
    public func draw(in: MTKView) {
        _ = semaphore.wait(timeout: DispatchTime.distantFuture)
        
        autoreleasepool {
            guard
                var texture = texture,
                let device = device,
                let commandBuffer = commandQueue?.makeCommandBuffer()
                else {
                    _ = semaphore.signal()
                    return
            }
            
            clinkDataBuffer = device.makeBuffer(bytes: &clinkData,
                                                length: clinkDataSize * sizeInt32,
                                                options: .storageModeShared)
            
            
            willRenderTexture(&texture, withCommandBuffer: commandBuffer, device: device)
            render(texture: texture, withCommandBuffer: commandBuffer, device: device)
        }
    }
    
    private func testOpenCV() {
        print("\(Calib3D.openCVVersionString())")
        
        var src:[Double] = [ 0, 0, 0,
                             1, -1, 1,
                             0, -1,-1,
                             2, 0, 1]
        var dst:[Double] = [0,0,0,0,0,0,0,0]
        Calib3D.convertPointsFromHomogeneous(withSrc:&src,dst:&dst)
        print("dst",dst)
    }
    
    
    /**
     Renders texture into the `UIViewController`'s view.
     
     - parameter texture:       Texture to be rendered
     - parameter commandBuffer: Command buffer we will use for drawing
     */
    private func render(texture: MTLTexture, withCommandBuffer commandBuffer: MTLCommandBuffer, device: MTLDevice) {
        
        let t0 = CFAbsoluteTimeGetCurrent()
        
        guard
            let currentRenderPassDescriptor = metalView.currentRenderPassDescriptor,
            let currentDrawable = metalView.currentDrawable,
            let renderPipelineState = renderPipelineState,
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: currentRenderPassDescriptor)
            else {
                semaphore.signal()
                return
        }
        
        encoder.pushDebugGroup("RenderFrame")
        encoder.setRenderPipelineState(renderPipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBuffer(clinkDataBuffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&hLine, length: sizeInt32, index: 1)
        encoder.setFragmentBytes(&vLine, length: sizeInt32, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
        encoder.popDebugGroup()
        encoder.endEncoding()
        
        commandBuffer.addScheduledHandler { [weak self] (buffer) in
            guard let unwrappedSelf = self else { return }
            
            unwrappedSelf.didRenderTexture(texture, withCommandBuffer: buffer, device: device)
            unwrappedSelf.semaphore.signal()
        }
        commandBuffer.present(currentDrawable)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        /*let rowBytes = texture.width * 4
         let length = 400
         let bgraBytes = [UInt8](repeating: 0, count: length)
         let region = MTLRegionMake2D(0, 0, 10, 10)
         texture.getBytes(UnsafeMutableRawPointer(mutating: bgraBytes), bytesPerRow: 40, from: region, mipmapLevel: 0)
         var pformat = texture.pixelFormat
         */
        
        let imageBuffer = CMSampleBufferGetImageBuffer(self.sampleBuffer!)
        CVPixelBufferLockBaseAddress(imageBuffer!,[])
        let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer!)
        
        //testOpenCV()
        
        hLine = Int32(0)
        vLine = Int32(0)
        
        let data = (clinkDataBuffer?.contents().bindMemory(to: Int32.self, capacity: clinkDataSize))!
        
        var clinkboardDetected = (data[BOARD_4Part_RR] > 0 && data[BOARD_4Part_BB] > 0 && data[BOARD_3Part_CW] > 0 && data[BOARD_3Part_CCW] > 0)
        var clinkcodeDetected = (data[CODE_3Part_CW] > 1 && data[CODE_3Part_CCW] > 1)
        
        if(clinkboardDetected || clinkcodeDetected){
            var tagsByType = extractTagsByType(data)
            clinkboardDetected = clinkboardDetected && tagsByType[BOARD_3Part_CW] != nil && tagsByType[BOARD_3Part_CCW] != nil && tagsByType[BOARD_4Part_BB] != nil && tagsByType[BOARD_4Part_RR] != nil
            
            clinkcodeDetected = clinkcodeDetected && tagsByType[CODE_3Part_CW] != nil && tagsByType[CODE_3Part_CCW] != nil && tagsByType[CODE_3Part_CW]!.count > 1 && tagsByType[CODE_3Part_CW]!.count > 1
            
            if(clinkcodeDetected){
                let cwPairs = generateOppositeTagPairs(tagsByType[CODE_3Part_CW]!)
                let ccwPairs = generateOppositeTagPairs(tagsByType[CODE_3Part_CCW]!)
                
                for p1 in cwPairs{
                    for p2 in ccwPairs{
                        if( p1.isCompatable(p2)){
                            let clinkcode = ClinkCode(cwPair: p1, ccwPair: p2, pixelBufferBaseAddress:baseAddress!)
                            if(clinkcode.isValid){
                                print("Found clinkcode: \(clinkcode.code)")
                                hLine = Int32(clinkcode.centerXY.x)
                                vLine = Int32(clinkcode.centerXY.y)
                            }
                        }
                    }
                }
                
                
            }
        }
        CVPixelBufferUnlockBaseAddress(imageBuffer!,[])
        let t1 = CFAbsoluteTimeGetCurrent()
        print("\(t1-t0)secs\n")
    }
}

/* Helper Functions */

func generateOppositeTagPairs(_ fromCodeTags:[ExtractedTag] ) -> [OppositeTagPair]{
    var pairs:[OppositeTagPair] = []
    
    for (i,tag) in fromCodeTags.enumerated(){
        let oppTags = findPossibleOppositeCornerTags(codeTag:tag, possibleMatches:fromCodeTags, startAt:i+1 )
        for oppTag in oppTags{
            pairs.append(OppositeTagPair(tagA:tag,tagB:oppTag))
        }
    }
    return pairs
}

func findPossibleOppositeCornerTags( codeTag:ExtractedTag, possibleMatches:[ExtractedTag], startAt:Int ) -> [ExtractedTag] {
    var matches:[(tag:ExtractedTag,mag:Double)] = []
    let orientDiffThresh = codeTag.orientHypot/1.5;
    if(startAt < possibleMatches.count){
        for tag in possibleMatches[startAt...]{
            guard tag.cellIndex != codeTag.cellIndex else{
                continue
            }
            let sumX = codeTag.orientX + tag.orientX
            let sumY = codeTag.orientY + tag.orientY
            let mag = hypot(sumX,sumY)
            if(mag < orientDiffThresh){
                let i = matches.index(where: { (m) -> Bool in m.mag > mag })
                if(i == nil){
                    matches.append((tag:tag, mag:mag))
                }
                else{
                    matches.insert((tag:tag, mag:mag), at: i!)
                }
            }
        }
    }
    return matches.map {$0.tag}
}

func extractTagsByType(_ data:UnsafeMutablePointer<Int32> ) -> [Int:[ExtractedTag]] {
    var tagsByType:[Int:[ExtractedTag]] = [:]
    for n in 0..<numGridCells {
        let offset = numTagTypes + valuesPerCell*n
        let weight:Double = Double(data[offset + TOTAL_WEIGHT])
        if(weight > 0){
            let typeTotal:Double = Double(data[offset + TYPE_AVERAGE])
            let type:Int = Int(round(typeTotal / weight))
            if(isClinkcodeType(type: type) || isClinkboardType(type: type)){
                let typeFlags:Int32 = data[offset + TYPE_FLAGS]
                let xCoord:Double = Double(data[offset + X_COORD_AVERAGE]) / weight
                let yCoord:Double = Double(data[offset + Y_COORD_AVERAGE]) / weight
                let orientX:Double = Double(data[offset + X_ORIENTATION_AVERAGE]) / weight
                let orientY:Double = Double(data[offset + Y_ORIENTATION_AVERAGE]) / weight
                let dotSize:Double = Double(data[offset + DOT_SIZE]) / weight
                let extractedTag = ExtractedTag(
                    weight:weight,
                    typeFlags:typeFlags,
                    type:type,
                    x:xCoord,
                    y:yCoord,
                    orientX:orientX,
                    orientY:orientY,
                    orientHypot:hypot(orientX,orientY),
                    dotSize:dotSize,
                    cellIndex:n)
                if(tagsByType[type] == nil){
                    tagsByType[type] = [extractedTag]
                }
                else{
                    tagsByType[type]!.append(extractedTag)
                }
            }
        }
    }
    return tagsByType
}

func sortTagsByWeight(_ tagArray:[ExtractedTag]) -> [ExtractedTag]{
    var tags:[ExtractedTag] = []
    for tag in tagArray{
        let i = tags.index(where: { (t) -> Bool in t.weight < tag.weight })
        if(i == nil){
            tags.append(tag)
        }
        else{
            tags.insert(tag, at: i!)
        }
    }
    return tags
}

func buildClinkcodeProjectionMatrix(_ clinkcode :  inout ClinkCode ) -> [Double] {
    let numBlocks:Double = 6
    //print("buildMatrix(-1,-1,\(clinkcode.topLeft.x),\(clinkcode.topLeft.y),\(numBlocks),-1,\(clinkcode.topRight.x),\(clinkcode.topRight.y),-1,\(numBlocks),\(clinkcode.bottomLeft.x),\(clinkcode.bottomLeft.y),\(numBlocks),\(numBlocks),\(clinkcode.bottomRight.x),\(clinkcode.bottomRight.y))")
    let s = formBasis(p1:(x:-1, y:-1), p2:(x:numBlocks, y:-1), p3:(x:-1, y:numBlocks), p4:(x:numBlocks, y:numBlocks))
    let d = formBasis(p1:clinkcode.topLeft.xy, p2:clinkcode.topRight.xy, p3:clinkcode.bottomLeft.xy, p4:clinkcode.bottomRight.xy)
    var t = multiplyMatrices3(a:d, b:adjugate3(s))
    
    for i in 0..<9{
        t[i] = t[i]/t[8]
    }
    
    clinkcode.projectionMatrix = [
        t[0], t[3], 0, t[6],
        t[1], t[4], 0, t[7],
        0   , 0   , 1, 0   ,
        t[2], t[5], 0, t[8]]
    
    //print("Matrix: \(clinkcode.projectionMatrix)")
    return clinkcode.projectionMatrix
}

func formBasis( p1:(x:Double, y:Double), p2:(x:Double, y:Double), p3:(x:Double, y:Double), p4:(x:Double, y:Double) ) -> [Double] {
    let m:[Double] = [
        p1.x, p2.x, p3.x,
        p1.y, p2.y, p3.y,
        1,  1,  1 ]
    let pt4:[Double] = [p4.x, p4.y, 1]
    var v = multiplyMatrixAndVector3( m:adjugate3(m), v:pt4)
    return multiplyMatrices3(a:m, b:[
        v[0], 0, 0,
        0, v[1], 0,
        0, 0, v[2]
        ])
}


func adjugate3(_ m:[Double] ) -> [Double] {
    return [
        m[4]*m[8]-m[5]*m[7], m[2]*m[7]-m[1]*m[8], m[1]*m[5]-m[2]*m[4],
        m[5]*m[6]-m[3]*m[8], m[0]*m[8]-m[2]*m[6], m[2]*m[3]-m[0]*m[5],
        m[3]*m[7]-m[4]*m[6], m[1]*m[6]-m[0]*m[7], m[0]*m[4]-m[1]*m[3]
    ]
}

func multiplyMatrices3( a:[Double], b:[Double]) -> [Double] {
    var c:[Double] = [0,0,0,0,0,0,0,0,0]
    for i in 0..<3{
        for j in 0..<3{
            var cij:Double = 0
            for k in 0..<3{
                cij += a[3*i + k]*b[3*k + j]
            }
            c[3*i + j] = cij
        }
    }
    return c
}

func multiplyMatrixAndVector3(m:[Double], v:[Double]) -> [Double] {
    return [
        m[0]*v[0] + m[1]*v[1] + m[2]*v[2],
        m[3]*v[0] + m[4]*v[1] + m[5]*v[2],
        m[6]*v[0] + m[7]*v[1] + m[8]*v[2]
    ]
}

func projectPoint(m:[Double], pt:(x:Double, y:Double)) -> (x:Double, y:Double) {
    let s:Double = 1/(m[ 3 ] * pt.x + m[ 7 ] * pt.y + m[ 15 ])
    let x:Double = s*(m[ 0 ] * pt.x + m[ 4 ] * pt.y + m[ 12 ])
    let y:Double = s*(m[ 1 ] * pt.x + m[ 5 ] * pt.y + m[ 13 ])
    return (x:x, y:y)
}

#endif
