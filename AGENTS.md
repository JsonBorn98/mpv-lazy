# AGENTS.md

## Repo Shape
- This is a portable Windows `mpv` bundle, not a normal source repo. Top-level binaries and runtimes (`mpv.exe`, `umpv.exe`, `python.exe`, `VSPipe.exe`, `Lib/`, `Scripts/`, `vs-plugins/`, `vs-coreplugins/`, `vs-scripts/`) are vendored app assets.
- The main editable surface is `portable_config/`. Start there before touching bundled runtimes or vendor trees.

## Main Wiring
- `portable_config/mpv.conf` is the root config. It sets `input-conf = "~~/input_uosc.conf"` and includes `portable_config/profiles.conf` plus `portable_config/script-opts.conf`.
- `portable_config/mpv.conf` sets `osc = no` and `input-builtin-bindings = no`, so custom behavior depends on the custom input/script files rather than mpv defaults.
- `portable_config/mpv.conf` also has `use-filedir-conf = yes`; media-folder configs outside this repo can affect playback and test results.
- `portable_config/profiles.conf` contains conditional runtime behavior (`profile-cond`), not just optional presets.

## Where To Edit
- Hotkeys and menu-triggered actions: `portable_config/input_uosc.conf`.
- Context menu structure: `portable_config/input_contextmenu_plus.conf`.
- Per-script options (`uosc`, `thumbfast`, `contextmenu_plus`, `save_global_props`, console/stats): `portable_config/script-opts.conf`.
- Global playback/rendering defaults: `portable_config/mpv.conf`.
- Conditional behavior such as HDR/deband/save-position overrides: `portable_config/profiles.conf`.
- Local custom Lua logic lives in `portable_config/scripts/input_plus.lua` and `portable_config/scripts/save_global_props.lua`.

## Vendor Boundaries
- Treat `portable_config/scripts/uosc/` as vendored `uosc` code and `portable_config/scripts/thumbfast.lua` as vendored `thumbfast`; prefer configuration in `script-opts.conf` over source edits.
- `portable_config/scripts/contextmenu_plus.lua` is third-party-derived (`SOURCE_` header points to `tsl0922/mpv-menu-plugin`); prefer `portable_config/input_contextmenu_plus.conf` unless you must patch script behavior.
- `portable_config/input_contextmenu_plus.conf` is not loaded by `mpv.conf`; `script-opts.conf` passes it to `contextmenu_plus` via `contextmenu_plus-input_conf=~~/input_contextmenu_plus.conf`, and its commented lines are menu definitions rather than normal keybinds.
- Many files record upstream source/commit in header comments. Preserve those markers if you edit vendor-derived code.

## Verification Shortcuts
- Focused config sandbox: `installer\mpv-测试模式.bat` runs `mpv.com --config=no --include=installer/mpv-test.conf`.
- Baseline mpv without the bundle config: `installer\mpv-纯净模式.bat`.
- Input debugging / keybind inspection: `installer\mpv-输入模式.bat` runs mpv with `--input-test=yes`.
- Rendering benchmark sandbox: `installer\mpv-跑分模式.bat` runs `mpv.com --config=no --include=installer/mpv-BenchMark.conf --idle=once --force-window=yes`.
- For quick CLI checks, use `mpv.com` from the repo root, not a globally installed `mpv`.

## Gotchas
- `README.MD` explicitly says new/edited text files should stay UTF-8 with LF line endings, or mpv may fail to read them.
- `portable_config/mpv.conf` notes that current presets persist `volume` and `glsl-shaders`; deleting `portable_config/saved-props.json` may be required before those config edits take effect.
- `installer/mpv-test.conf` explicitly says `~~/`-style relative paths are unsupported there.
- `installer/mpv-BenchMark.conf` warns that `~~/` is not relative to `portable_config/` in that mode. Use absolute paths there if needed.
- Batch helpers use `chcp 936`; do not assume UTF-8 console output when editing or running `installer/*.bat`.

## Portable Runtime Details
- `python314._pth` isolates the bundled Python and explicitly adds `vs-scripts`; changes to the Python/VapourSynth environment should account for this portable path setup.
- `portable.vs` is an empty marker file used by the bundled VapourSynth tooling for portable mode detection.

## System-Modifying Scripts
- `installer/umpv-install.bat` and `installer/umpv-uninstall.bat` require admin rights and modify Windows registry/file associations/start-menu entries.
- `installer/mpv-register.bat` and `installer/mpv-unregister.bat` call `mpv.com --register` / `--unregister`; avoid running them unless the task is specifically about shell integration.
