MoonLightKernel config fragments
================================

Put reusable Kconfig fragments here and pass them with:

./moonlight_build.sh --device heat --config-fragment packaging/config-fragments/<name>.config

Default seeds:
- `heat` and `fire` now share `arch/arm64/configs/moonlight_mt6768_defconfig`
- the build script auto-applies the matching device fragment for the final appended DTB

Intended use:
- keep branch-specific config deltas small
- share the same base defconfig between `vanilla`, `nethunter`, and `kernelsu`
- keep device-specific deltas tiny and obvious

Guidelines:
- one concern per fragment
- only keep the symbols that actually differ from the base defconfig
- prefer fragments over duplicating full `.config` files
- current fragments:
  - `device-heat.config`: sets the appended DTB target to `mediatek/heat`
  - `device-fire.config`: sets the appended DTB target to `mediatek/fire`
  - `device-universal.config`: sets the appended DTB targets to both `mediatek/heat` and `mediatek/fire`
  - `nethunter.config`: USB monitor, USB/IP, mac80211, cfg80211 debugfs, and external Bluetooth adapter support for the stock-MIUI NetHunter profile
  - `kernelsu.config`: enables KernelSU on top of the shared stock-compatible base
