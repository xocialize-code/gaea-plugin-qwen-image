import Foundation
import GaeaPluginKit
import GaeaProtocol
import ImageIO
import MLXQwenImageEdit
import MLXQwenImageFlash
import MLXToolKit
import QwenImageEdit

// gaea-plugin-qwen-image: Qwen's 20B image family as a Gaea plugin, on qwen-image-edit-swift through MLXServeEngine
// (Gaea AB-T-0368).
//
// - qwen-image-edit: Qwen-Image-Edit 2511 (Apache-2.0), the strongest instruction editor in the collection: 1–3
//   references, 20 steps of true CFG, an output of about 1024² at the first image's aspect. One lane, bf16: 42 GB
//   resident plus a 21 GB peak.
// - qwen-image-flash: Qwen-Image Flash (NVIDIA's DMD2 4-step distill, NVIDIA Open Model License), text to image with
//   strong text rendering and layout. One lane, int8 (the pre-quantized mlx-community snapshot): 22.3 GB resident plus
//   9.3 GB.
//
// Weights come from the models root Gaea sends in configure (MLXEngine's store by default); the engine materializes a
// missing snapshot there.

/// Both models' envelope in mlx-image-runtime's catalog: about 1024² of output.
public let targetArea = 1024 * 1024
public let maxReferences = 3
let minSide = 256, maxSide = 2048

public enum QwenModel: String, Sendable {
    case edit = "qwen-image-edit"
    case flash = "qwen-image-flash"

    public var defaultSteps: Int { self == .edit ? 20 : 4 }
    /// Edit runs true CFG at 4; Flash internalized guidance in its distillation and runs at 1.
    public var defaultGuidance: Double { self == .edit ? 4 : 1 }
}

/// The package configurations, one per lane; qwen-inproc builds the same ones.
public enum QwenLanes {
    public static func edit() -> QwenImageEditConfiguration { QwenImageEditConfiguration() }
    public static func flash() -> QwenImageFlashConfiguration { QwenImageFlashConfiguration(quant: .int8) }
}

/// The size Qwen-Image-Edit draws for a first image of `width`×`height`: about 1024² in area at its aspect, sides in
/// multiples of 32. The package ignores a requested size.
public func editSize(width: Int, height: Int) -> (width: Int, height: Int) {
    let (w, h) = QwenVLPromptEncoder.calculateDimensions(targetArea: targetArea, ratio: Double(width) / Double(height))
    return (w, h)
}

/// The MES size a job asks for (`size`, or `aspect` with `megapixels`, Image profile §2), else `fallback`.
func requestedSize(_ job: Job, fallback: (Int, Int)) throws -> (Int, Int) {
    if let size = job.param("size") {
        guard let w = size["width"]?.intValue, let h = size["height"]?.intValue, w > 0, h > 0 else {
            throw GPPError(.invalidRequest, "size is {width, height} in pixels.")
        }
        return (w, h)
    }
    if let aspect = job.param("aspect")?.stringValue {
        let parts = aspect.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { throw GPPError(.invalidRequest, "aspect is W:H, e.g. 16:9.") }
        let pixels = (job.param("megapixels")?.doubleValue ?? 1.0) * 1_000_000
        let height = (pixels * parts[1] / parts[0]).squareRoot()
        return (Int(height * parts[0] / parts[1]), Int(height))
    }
    return fallback
}

/// Fits a Flash size to the envelope: scaled down to 1024² in area, keeping the aspect, then floored to multiples of
/// 16. A change is reported as `size_snapped`.
public func flashSize(_ size: (Int, Int)) throws -> (width: Int, height: Int, warning: Warning?) {
    var (w, h) = (Double(size.0), Double(size.1))
    if w * h > Double(targetArea) {
        let scale = (Double(targetArea) / (w * h)).squareRoot()
        w *= scale
        h *= scale
    }
    let width = Int(w) / 16 * 16, height = Int(h) / 16 * 16
    guard min(width, height) >= minSide, max(width, height) <= maxSide else {
        throw GPPError(.invalidRequest, "Qwen-Image Flash draws \(minSide)–\(maxSide) px a side and at most 1024² in area; "
            + "\(size.0)×\(size.1) doesn't fit.", detail: ["param": "size"])
    }
    let warning = (width, height) == size ? nil : Warning(
        code: "size_snapped", message: "Drew \(width)×\(height) for \(size.0)×\(size.1): multiples of 16, at most 1024² in area.",
        param: "size")
    return (width, height, warning)
}

func steps(_ job: Job, _ model: QwenModel) throws -> Int {
    let steps = job.param("x-qwen.steps")?.intValue ?? model.defaultSteps
    guard (1...100).contains(steps) else { throw GPPError(.invalidRequest, "x-qwen.steps is 1–100.") }
    return steps
}

func promptEnhanceWarning(_ job: Job) -> [Warning] {
    job.param("prompt_enhance")?.stringValue == "on"
        ? [Warning(code: "prompt_enhance_ignored", message: "This plugin doesn't rewrite prompts; Gaea's enhancer does.",
                   param: "prompt_enhance")]
        : []
}

/// MES image.generate on Flash: one engine call per image, each with seed + i.
let flashGenerate = EngineOperation("image.generate", outputNames: ["image": "images"]) { job in
    guard let prompt = try job.text("prompt"), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw GPPError(.invalidRequest, "image.generate needs a prompt.")
    }
    let count = job.param("count")?.intValue ?? 1
    guard (1...8).contains(count) else { throw GPPError(.invalidRequest, "count is 1–8.") }
    let size = try flashSize(try requestedSize(job, fallback: (1024, 1024)))
    let steps = try steps(job, .flash)
    var warnings = (size.warning.map { [$0] } ?? []) + promptEnhanceWarning(job)
    if job.param("negative_prompt")?.stringValue.map({ !$0.isEmpty }) == true {
        warnings.append(Warning(code: "negative_prompt_ignored",
                                message: "Qwen-Image Flash runs without CFG (its guidance is distilled in), so a negative prompt does nothing.",
                                param: "negative_prompt"))
    }
    // Image profile §2: a request without a seed still gets one, reported in effective.
    let seed = job.seed ?? UInt64.random(in: 0..<(1 << 31))
    let effective: [String: JSONValue] = [
        "size": ["width": .int(Int64(size.width)), "height": .int(Int64(size.height))], "count": .int(Int64(count)),
        "seed": .int(Int64(seed)), "x-qwen.steps": .int(Int64(steps)),
    ]
    return (0..<count).map { i in
        EngineCall(T2IRequest(prompt: prompt, width: size.width, height: size.height, steps: steps,
                              guidanceScale: QwenModel.flash.defaultGuidance, seed: seed + UInt64(i)),
                   effective: effective, warnings: warnings)
    }
}

/// MES image.edit on Qwen-Image-Edit 2511: 1–3 references ("Picture 1", "Picture 2", … in the instruction), one
/// output of about 1024² at the first image's aspect.
let edit = EngineOperation("image.edit", outputNames: ["image": "image"]) { job in
    guard let instruction = try job.text("instruction"), !instruction.isEmpty else {
        throw GPPError(.invalidRequest, "image.edit needs an instruction.")
    }
    let references = job.inputs["images"] ?? []
    guard (1...maxReferences).contains(references.count) else {
        throw GPPError(.invalidRequest, "image.edit takes 1–\(maxReferences) images; got \(references.count).",
                       detail: ["param": "images"])
    }
    guard let source = CGImageSourceCreateWithURL(references[0] as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let inputWidth = properties[kCGImagePropertyPixelWidth] as? Int,
          let inputHeight = properties[kCGImagePropertyPixelHeight] as? Int else {
        throw GPPError(.invalidRequest, "image.edit needs readable PNG or JPEG images.")
    }
    let steps = try steps(job, .edit)
    let guidance = job.param("x-qwen.guidance")?.doubleValue ?? QwenModel.edit.defaultGuidance
    guard (1...20).contains(guidance) else { throw GPPError(.invalidRequest, "x-qwen.guidance is 1–20.") }
    let out = editSize(width: inputWidth, height: inputHeight)
    var warnings = promptEnhanceWarning(job)
    if (out.width, out.height) != (inputWidth, inputHeight) || job.param("size") != nil {
        warnings.insert(Warning(code: "size_snapped",
                                message: "Qwen-Image-Edit draws about 1024² at the first image's aspect: \(out.width)×\(out.height) "
                                    + "for a \(inputWidth)×\(inputHeight) input.",
                                param: "size"), at: 0)
    }
    if job.param("strength") != nil {
        warnings.append(Warning(code: "param_ignored", message: "Qwen-Image-Edit is an instruction editor, so strength does nothing.",
                                param: "strength"))
    }
    let seed = job.seed ?? UInt64.random(in: 0..<(1 << 31))
    var effective: [String: JSONValue] = [
        "size": ["width": .int(Int64(out.width)), "height": .int(Int64(out.height))],
        "seed": .int(Int64(seed)), "x-qwen.steps": .int(Int64(steps)), "x-qwen.guidance": .double(guidance),
    ]
    effective["references"] = .int(Int64(references.count))
    let images = try references.indices.map { try job.image("images", index: $0) }
    return [EngineCall(IEditRequest(images: images, prompt: instruction, steps: steps, guidanceScale: guidance, seed: seed),
                       effective: effective, warnings: warnings)]
}

let apache: JSONValue = ["spdx": "Apache-2.0", "commercial_use": true, "terms_url": "https://www.apache.org/licenses/LICENSE-2.0"]
let nvidia: JSONValue = [
    "spdx": "LicenseRef-NVIDIA-Open-Model", "commercial_use": true,
    "terms_url": "https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/",
    "notice": "Licensed by NVIDIA Corporation under the NVIDIA Open Model License",
]

func stepsParam(_ model: QwenModel) -> JSONValue {
    ["type": "integer", "minimum": 1, "maximum": 100, "default": .int(Int64(model.defaultSteps)),
     "description": .string(model == .flash ? "Denoising steps. Flash is distilled for 4." : "Denoising steps; fewer is faster and coarser."),
     "x-mes-ui": ["widget": "slider", "label": "Steps", "advanced": true]]
}

let editParams: JSONValue = [
    "type": "object", "additionalProperties": false,
    "properties": [
        "x-qwen.steps": stepsParam(.edit),
        "x-qwen.guidance": ["type": "number", "minimum": 1, "maximum": 20, "default": 4,
                            "description": "True classifier-free guidance: how strongly the instruction steers. 1 turns CFG off.",
                            "x-mes-ui": ["widget": "slider", "label": "Guidance", "advanced": true]],
    ],
]
let flashParams: JSONValue = ["type": "object", "additionalProperties": false, "properties": ["x-qwen.steps": stepsParam(.flash)]]

public let qwenPlugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.qwen-image",
    version: "0.1.1",
    minGaea: "0.2.0",
    team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize-code/gaea-plugin-qwen-image",
    title: "Qwen-Image",
    summary: "Qwen's 20B image family: Qwen-Image-Edit 2511 (Apache-2.0), a high-fidelity instruction editor with up to 3 "
        + "references, and Qwen-Image Flash (NVIDIA Open Model License), 4-step text to image with strong text rendering.",
    license: "Apache-2.0",
    executable: "gaea-qwen-image-worker",
    models: [
        .engine(QwenImageEditPackage.self, id: QwenModel.edit.rawValue, title: "Qwen-Image-Edit 2511",
                lanes: [LaneDefinition(id: "bf16", default: true, configuration: QwenLanes.edit())],
                operations: [edit]),
        .engine(QwenImageFlashPackage.self, id: QwenModel.flash.rawValue, title: "Qwen-Image Flash",
                lanes: [LaneDefinition(id: "int8", default: true, configuration: QwenLanes.flash())],
                operations: [flashGenerate]),
    ],
    offers: [
        PluginManifest.Offer(
            operation: "image.edit", profile: "image",
            model: ["id": "qwen-image-edit", "title": "Qwen-Image-Edit 2511", "license": apache, "memory_class": "xlarge",
                    "speed_class": "slow", "quality_tiers": ["standard", "best"],
                    "notes": .string("Instruction editing with up to 3 references, named \"Picture 1\", \"Picture 2\"… in the instruction. "
                        + "Draws about 1024² at the first image's aspect; 20 steps of true CFG. Needs about 63 GB.")],
            params: editParams,
            limits: PluginManifest.Limits(maxPixels: targetArea, sizeMultiple: 32, maxImages: maxReferences)),
        PluginManifest.Offer(
            operation: "image.generate", profile: "image",
            model: ["id": "qwen-image-flash", "title": "Qwen-Image Flash", "license": nvidia, "memory_class": "large",
                    "speed_class": "standard", "quality_tiers": ["draft", "standard"],
                    "notes": "4 distilled steps without CFG: negative prompts do nothing. Strong text rendering and layout."],
            params: flashParams, defaults: ["count": 1],
            limits: PluginManifest.Limits(maxPixels: targetArea, minSide: minSide, maxSide: maxSide, sizeMultiple: 16)),
    ])
