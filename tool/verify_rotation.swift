// Checks how a rotated video lands on the rectangle its video composition
// renders into, which is where a rotated clip can come out fully black while
// its audio plays on. Reports the translation the file authored, the one each
// implementation of fixTransform derives from it, and the fraction of the
// rendered frame that carries any visible colour.
//
//   swiftc -O -o verify tool/verify_rotation.swift && ./verify <file>
//
// A frame that lands outside the render rectangle comes back at roughly 0.

import AVFoundation
import CoreGraphics
import Foundation

func degrees(_ t: CGAffineTransform) -> Int {
  var d = Int((atan2(t.b, t.a) * 180 / .pi).rounded())
  if d < 0 { d += 360 }
  return d
}

/// The shipped implementation before the change.
func fixTransformOld(_ track: AVAssetTrack) -> CGAffineTransform {
  var t = track.preferredTransform
  if t.tx == 0 && t.ty == 0 {
    let deg = degrees(t)
    if deg == 90 { t.tx = track.naturalSize.height; t.ty = 0 }
    else if deg == 270 { t.tx = 0; t.ty = track.naturalSize.width }
  }
  return t
}

/// The implementation after the change.
func fixTransformNew(_ track: AVAssetTrack) -> CGAffineTransform {
  var t = track.preferredTransform
  let deg = degrees(t)
  if deg == 0 { return t }
  let n = track.naturalSize
  if deg == 90 { t.tx = n.height; t.ty = 0 }
  else if deg == 180 { t.tx = n.width; t.ty = n.height }
  else if deg == 270 { t.tx = 0; t.ty = n.width }
  return t
}

func composition(_ asset: AVAsset, _ track: AVAssetTrack,
                 _ transform: CGAffineTransform) -> AVMutableVideoComposition {
  let instruction = AVMutableVideoCompositionInstruction()
  instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
  let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
  layer.setTransform(transform, at: .zero)
  instruction.layerInstructions = [layer]
  let comp = AVMutableVideoComposition()
  comp.instructions = [instruction]
  var w = track.naturalSize.width, h = track.naturalSize.height
  let deg = degrees(transform)
  if deg == 90 || deg == 270 { swap(&w, &h) }
  comp.renderSize = CGSize(width: w, height: h)
  comp.frameDuration = CMTime(value: 1, timescale: 30)
  return comp
}

/// Fraction of pixels that carry any visible colour.
func litFraction(_ image: CGImage) -> Double {
  let w = image.width, h = image.height
  var buf = [UInt8](repeating: 0, count: w * h * 4)
  let cs = CGColorSpaceCreateDeviceRGB()
  guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { return -1 }
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  var lit = 0
  for i in stride(from: 0, to: buf.count, by: 4) {
    if Int(buf[i]) + Int(buf[i+1]) + Int(buf[i+2]) > 24 { lit += 1 }
  }
  return Double(lit) / Double(w * h)
}

func render(_ asset: AVAsset, _ comp: AVMutableVideoComposition) -> Double {
  let gen = AVAssetImageGenerator(asset: asset)
  gen.videoComposition = comp
  gen.requestedTimeToleranceBefore = .zero
  gen.requestedTimeToleranceAfter = .zero
  do {
    let img = try gen.copyCGImage(at: CMTime(value: 1, timescale: 2), actualTime: nil)
    return litFraction(img)
  } catch {
    print("    render failed: \(error.localizedDescription)")
    return -1
  }
}

let path = CommandLine.arguments[1]
let asset = AVURLAsset(url: URL(fileURLWithPath: path))
guard let track = asset.tracks(withMediaType: .video).first else {
  print("no video track"); exit(1)
}
let t = track.preferredTransform
print("file            \((path as NSString).lastPathComponent)")
print("naturalSize     \(Int(track.naturalSize.width))x\(Int(track.naturalSize.height))")
print("rotation        \(degrees(t))")
print(String(format: "authored tx,ty  %.0f, %.0f", t.tx, t.ty))
let old = fixTransformOld(track), new = fixTransformNew(track)
print(String(format: "old   tx,ty     %.0f, %.0f", old.tx, old.ty))
print(String(format: "new   tx,ty     %.0f, %.0f", new.tx, new.ty))
print(String(format: "old   lit       %.3f", render(asset, composition(asset, track, old))))
print(String(format: "new   lit       %.3f", render(asset, composition(asset, track, new))))
