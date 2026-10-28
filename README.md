# gaea-plugin-qwen-image

Qwen's 20B image family as a [Gaea](https://github.com/xocialize/gaea) plugin: **Qwen-Image-Edit 2511** and
**Qwen-Image Flash**. It is built on [GaeaPluginKit](https://github.com/xocialize/gaea-plugin-kit) over
[qwen-image-edit-swift](https://github.com/xocialize/qwen-image-edit-swift), runs in its own process, and speaks the
Gaea Plugin Protocol v1. Add it to Gaea by its repo URL:

```bash
gaea plugins add https://github.com/xocialize/gaea-plugin-qwen-image
```

## What it offers

| Model | MES operation | Quality tiers | Notes |
|---|---|---|---|
| `qwen-image-edit` | `image.edit` | standard, best | Qwen-Image-Edit 2511: high-fidelity instruction editing with 1–3 references, named "Picture 1", "Picture 2"… in the instruction. 20 steps of true CFG at guidance 4. |
| `qwen-image-flash` | `image.generate` | draft, standard | Qwen-Image Flash, NVIDIA's DMD2 4-step distill of Qwen-Image: strong text rendering and layout. No CFG, so a negative prompt does nothing (`negative_prompt_ignored`). |

- **Edit sizes.** The output is about 1024² in area at the first image's aspect, sides in multiples of 32: a
  1280×768 input is edited at 1312×800. A different size is reported `size_snapped`; a requested `size` and
  `strength` do nothing.
- **Generate sizes.** 256–2048 px a side, at most 1024² in area, in multiples of 16 (`size_snapped`). `count` 1–8,
  each with `seed + i`. A request without a seed gets one, reported in `effective`.
- **Options**, as MES extensions: `x-qwen.steps` (both) and `x-qwen.guidance` (edit).
- **Not yet offered:** per-request LoRA adapters (Flash and Edit Turbo take them), Edit Turbo (the Lightning 4-step
  LoRA, with an int4 tier for smaller Macs), Flash's bf16 lane, and the edit's opt-in step cache.

## Lanes and memory

| Model | Lane | Resident | Peak while running | Gaea schedules |
|---|---|---|---|---|
| `qwen-image-edit` | `bf16` | 42 GB | 21 GB | 63 GB |
| `qwen-image-flash` | `int8` | 22.3 GB | 9.3 GB | 31.6 GB |

The peaks are mostly the Qwen2.5-VL-7B encoder, which loads for each request and leaves before the denoise. With Gaea's
default budget (three quarters of the Mac's memory), Flash fits a 64 GB Mac and Qwen-Image-Edit needs 96 GB or more.

## Weights

Gaea sends its models root in `configure` (MLXEngine's store by default, `gaea models root` to change it). The worker
looks for `Qwen/Qwen-Image-Edit-2511` (54 GB) and `mlx-community/Qwen-Image-Flash-8bit` (28 GB) there and downloads a
missing snapshot on `prepare` or `materialize`.

## Build and check locally

```bash
scripts/build-plugin.sh
```

```bash
scripts/check-plugin.sh
```

`check-plugin.sh` generates one 512² image with Qwen-Image Flash int8 against the weights in MLXEngine's store
(`CHECK_MODELS_ROOT` moves it), with every `.build` folder hidden so MLX can find its metallib only inside the
bundle. A control then shows that the bare worker, outside the bundle, can't. `scripts/release.sh` builds, checks,
notarizes with the fleet's `mlx-notary` profile, and publishes the GitHub release. See the
[demo plugin](https://github.com/xocialize/gaea-plugin-demo) for signing, notarization and CI secrets.

`qwen-inproc` is not part of the plugin: it runs the same lane in-process through MLXServeEngine, the reference that
Gaea's runs are compared against byte for byte.

## Licence

The plugin is Apache-2.0 (Gaea G-21), and qwen-image-edit-swift is MIT.
- **Qwen-Image-Edit 2511's weights** are Apache-2.0 (Qwen).
- **Qwen-Image Flash's weights** are under the NVIDIA Open Model License, which allows commercial use. Gaea shows its
  notice, "Licensed by NVIDIA Corporation under the NVIDIA Open Model License". This plugin doesn't redistribute the
  weights; the worker downloads them from Hugging Face.
