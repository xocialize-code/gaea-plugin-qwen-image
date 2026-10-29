import Foundation
import MLXQwenImageEdit
import MLXQwenImageFlash
import MLXServeCore
import MLXToolKit
import QwenPlugin

// The in-process reference for the plugin: one Qwen lane loaded by MLXServeEngine in this process, with the lane
// configuration the worker uses (QwenPlugin) and the request it would build. A cold run then a warm one; the first
// image is written to --out, and one JSON line of timings is printed. Not part of the plugin bundle.
//
//   qwen-inproc --model qwen-image-flash [--prompt <text>] [--width 1024] [--height 1024] [--steps 4] [--seed 42]
//   qwen-inproc --model qwen-image-edit --image <png> [--image <png> ...] [--prompt <instruction>] [--steps 20]
//               [--guidance 4] [--seed 42]
//   both: [--models-root <dir>] [--out <png>] [--runs 2]
//   flash: [--adapter <id>=<strength> ...]  shipped adapters (qwen-image:<id>), registered and applied as the engine
//          does for the worker; fetched into <models-root>/adapters/<sha256>/ when missing

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func options(_ name: String) -> [String] {
    var values: [String] = []
    while let value = option(name) { values.append(value) }
    return values
}
func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}
func physFootprint() -> UInt64 {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return ok == 0 ? info.ri_phys_footprint : 0
}

let started = ContinuousClock.now
let model = QwenModel(rawValue: option("--model") ?? "qwen-image-flash") ?? .flash
let prompt = option("--prompt") ?? "a red fox sitting in a snowy forest at sunrise, photorealistic"
let width = Int(option("--width") ?? "") ?? 1024
let height = Int(option("--height") ?? "") ?? 1024
let steps = Int(option("--steps") ?? "") ?? model.defaultSteps
let guidance = Double(option("--guidance") ?? "") ?? model.defaultGuidance
let seed = UInt64(option("--seed") ?? "") ?? 42
let runs = Int(option("--runs") ?? "") ?? 2
let imagePaths = options("--image")
let adapterRefs: [AdapterRef] = options("--adapter").map { spec in
    let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
    return AdapterRef(id: parts[0], strength: parts.count > 1 ? Double(parts[1]) : nil)
}
let outPath = option("--out")
let modelsRoot = URL(fileURLWithPath: option("--models-root")
                     ?? NSHomeDirectory() + "/Library/Application Support/MLXEngine/Models", isDirectory: true)

var result: [String: Any] = ["model": model.rawValue, "steps": steps, "guidance": guidance, "seed": seed,
                             "references": imagePaths.count]
if !adapterRefs.isEmpty {
    result["adapters"] = adapterRefs.map { "\($0.id)=\($0.strength.map { String($0) } ?? "default")" }
}

// The budget Gaea sends a worker on a large Mac (wiresWeights off, the automatic pool cap).
let engine = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: 100_000_000_000, wiresWeights: false))
await engine.useModelStore(ModelStore(root: modelsRoot))
let id = PackageID(model.rawValue)
let request: any CapabilityRequest
switch model {
case .edit:
    _ = try await engine.register(QwenImageEditPackage.registration, configuration: QwenLanes.edit(), id: id)
    let images = try imagePaths.map { path in
        Image(format: path.lowercased().hasSuffix(".png") ? .png : .jpeg, data: try Data(contentsOf: URL(fileURLWithPath: path)))
    }
    request = IEditRequest(images: images, prompt: prompt, steps: steps, guidanceScale: guidance, seed: seed)
case .flash:
    _ = try await engine.register(QwenImageFlashPackage.registration, configuration: QwenLanes.flash(), id: id)
    for ref in adapterRefs {
        guard let shipped = flashAdapters.first(where: { $0.id == ref.id }) else {
            FileHandle.standardError.write(Data("no shipped adapter \(ref.id)\n".utf8))
            exit(2)
        }
        try await engine.registerAdapter(shipped.descriptor)
    }
    request = T2IRequest(prompt: prompt, width: width, height: height, steps: steps, guidanceScale: guidance, seed: seed,
                         adapters: adapterRefs)
}

var clock = ContinuousClock.now
_ = try await engine.prepare(model == .edit ? .imageEdit : .textToImage, package: id)
result["prepare_s"] = seconds(since: clock)
result["phys_after_prepare"] = physFootprint()

for run in 1...runs {
    clock = ContinuousClock.now
    let response = try await engine.run(request, package: id)
    result["run\(run)_s"] = seconds(since: clock)
    let image = (response as? T2IResponse)?.image ?? (response as? IEditResponse)?.image
    if run == 1 {
        result["cold_s"] = seconds(since: started)
        if let image {
            result["width"] = image.width ?? 0
            result["height"] = image.height ?? 0
            if let outPath { try image.data.write(to: URL(fileURLWithPath: outPath)) }
        }
    }
}
result["phys_after_runs"] = physFootprint()

let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
