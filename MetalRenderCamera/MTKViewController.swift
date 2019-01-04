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
        initializeComputePipelineState()
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
    
    internal var clinkCornerResults = [Int32](repeating:0, count: 100)
    
    internal var clinkCornerBuffer: MTLBuffer?
    
    /// Metal device command queue
    lazy internal var commandQueue: MTLCommandQueue? = {
        return device?.makeCommandQueue()
    }()
    
    /// Metal pipeline state we use for rendering
    internal var renderPipelineState: MTLRenderPipelineState?
    
    /// Metal pipeline state we use for computing
    internal var computePipelineState: MTLComputePipelineState?
    
    // Texture object which serves as the output for our image processing
    //    internal var outputTexture: MTLTexture?
    
    // Compute kernel dispatch parameters
    internal var threadgroupSize: MTLSize = MTLSizeMake(64, 64, 1);
    internal var threadgroupCount: MTLSize = MTLSizeMake(64, 64, 1);
    
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
    fileprivate func initializeComputePipelineState() {
        guard
            let device = device,
            let library = device.makeDefaultLibrary()
            else { return }
        
        let kernelFunction = library.makeFunction(name: "clinkCornerKernel")
        
        do {
            try computePipelineState = device.makeComputePipelineState(function: kernelFunction!)
        }
        catch {
            assertionFailure("Failed creating a compute state pipeline.")
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
            
            clinkCornerBuffer = device.makeBuffer(bytes: &clinkCornerResults,
                                                  length: 100 * sizeInt32,
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
        let imageBuffer = CMSampleBufferGetImageBuffer(self.sampleBuffer!)
        CVPixelBufferLockBaseAddress(imageBuffer!,[])
        
        let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer!)
        let width = CVPixelBufferGetWidth(imageBuffer!)
        let height = CVPixelBufferGetHeight(imageBuffer!)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer!)
        
        let offset = 1000
        let r = baseAddress!.load(fromByteOffset: offset+0, as: UInt8.self)
        let g = baseAddress!.load(fromByteOffset: offset+1, as: UInt8.self)
        let b = baseAddress!.load(fromByteOffset: offset+2, as: UInt8.self)
        print("rgb ",r,g,b)

        testOpenCV()
        
        guard
            let computePipelineState = computePipelineState,
            let computeEncoder = commandBuffer.makeComputeCommandEncoder()
            else {
                semaphore.signal()
                return
        }
        
        // Calculate the number of rows and columns of threadgroups given the width of the input image
        // Ensure that you cover the entire image (or more) so you process every pixel
        threadgroupCount.width  = (texture.width  + threadgroupSize.width -  1) / threadgroupSize.width
        threadgroupCount.height = (texture.height + threadgroupSize.height - 1) / threadgroupSize.height
        
        // Since we're only dealing with a 2D data set, set depth to 1
        threadgroupCount.depth = 1
        
        let textureDescriptor = MTLTextureDescriptor.init()
        
        // Indicate we're creating a 2D texture.
        textureDescriptor.textureType = MTLTextureType.type2D
        
        // Indicate that each pixel has a Red, Green, Blue and Alpha channel,
        //    each in an 8 bit unnormalized value (0 maps 0.0 while 255 maps to 1.0)
        textureDescriptor.pixelFormat = .rgba8Unorm_srgb
        textureDescriptor.width = texture.width
        textureDescriptor.height = texture.height
        textureDescriptor.usage = MTLTextureUsage(rawValue: MTLTextureUsage.shaderWrite.rawValue | MTLTextureUsage.shaderRead.rawValue)
        
        let outputTexture = device.makeTexture(descriptor: textureDescriptor)
        
        computeEncoder.setComputePipelineState(computePipelineState)
        computeEncoder.setTexture(texture,index:0)
        computeEncoder.setTexture(outputTexture,index:1)
        computeEncoder.setBuffer(clinkCornerBuffer, offset: 0, index: 0)
        computeEncoder.dispatchThreadgroups(threadgroupSize, threadsPerThreadgroup: threadgroupCount)
        computeEncoder.endEncoding()
        
        let renderOutput = true
        if (renderOutput) {
            guard
                let currentRenderPassDescriptor = metalView.currentRenderPassDescriptor,
                let currentDrawable = metalView.currentDrawable,
                let renderPipelineState = renderPipelineState,
                let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: currentRenderPassDescriptor)
                else {
                    semaphore.signal()
                    return
            }
            
            renderEncoder.pushDebugGroup("RenderFrame")
            renderEncoder.setRenderPipelineState(renderPipelineState)
            renderEncoder.setFragmentTexture(outputTexture, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
            renderEncoder.popDebugGroup()
            renderEncoder.endEncoding()
            
            commandBuffer.present(currentDrawable)
        }
        
        commandBuffer.addScheduledHandler { [weak self] (buffer) in
            guard let unwrappedSelf = self else { return }
            
            unwrappedSelf.didRenderTexture(texture, withCommandBuffer: buffer, device: device)
            unwrappedSelf.semaphore.signal()
        }
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        let data = clinkCornerBuffer?.contents().bindMemory(to: Int32.self, capacity: 100)
        let t1 = CFAbsoluteTimeGetCurrent()
        print("\nclink pixels, CW: \(data![0]), CCW: \(data![1])    \(t1-t0)secs\n")
    }
}

#endif
