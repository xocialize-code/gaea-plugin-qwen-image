import GaeaPluginKit
import QwenPlugin

// The plugin's worker: QwenPlugin's definition over GPP (GaeaPluginKit). `--manifest <path>` writes manifest.json.
await GaeaPluginMain.run(qwenPlugin)
