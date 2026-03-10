# Build 工具说明

文件: `build/build.ps1`
用途: 一键调用 SCons 编译 Godot，并可选直接导出项目。

## 默认行为
- 默认平台自动识别（Windows 优先为 windows）
- 默认构建目标: `template_release`（可用于发布客户端的模板）
- 默认并行数: CPU 核数
- 日志输出: `build/logs/build-<platform>-<target>-<time>.log`

## 最常用命令

```powershell
# 一键默认构建（推荐先装好依赖）
pwsh -NoProfile -File build/build.ps1

# 首次在当前机子上离线准备 SCons（可选，适合手动预置）
python -m pip download --no-deps --only-binary=:all: -d build\deps scons
python -m pip install --target build\pydeps build\deps\scons-*.whl

# build.ps1 已支持自动处理：
# 1) 先检测 build/pydeps 下是否已有本地 SCons
# 2) 再尝试从 build/deps 下的 scons wheel 安装到 build/pydeps
# 3) 如果本地没有 wheel 且带 -AutoInstallSCons，会尝试联网下载并安装
pwsh -NoProfile -File build/build.ps1 -Target template_release -Jobs 12 -SConsOptions d3d12=no

# 构建编辑器（有调试/编辑需求时）
pwsh -NoProfile -File build/build.ps1 -Target editor

# 指定平台和并行线程数
pwsh -NoProfile -File build/build.ps1 -Platform windows -Jobs 16

# 先清理再构建
pwsh -NoProfile -File build/build.ps1 -Clean
```

## 一键导出客户端（可选）

```powershell
pwsh -NoProfile -File build/build.ps1 `
  -Target template_release `
  -Export `
  -ProjectPath "D:\MyGodotProject" `
  -ExportPreset "Windows Desktop" `
  -ExportOutput "D:\MyGodotProject\dist\MyGame.exe"
```

说明：
- `-Export` 开启后会在构建成功后调用生成出的客户端二进制执行 `--headless --export-release`。
- `-ExportPreset` 来自 Godot 导出 preset 名称；必须和编辑器里完全一致。

## 注意
- 第一次构建可能耗时较长，需要安装依赖（见仓库文档/README）。
- 若系统无 `scons`，脚本会尝试用 `python -m SCons` 兜底。
