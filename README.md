# LutCam

一个干净的 iOS 相机 App：**原生相机采集 + 实时 3D LUT 预览 + 成片直出调色**。

从零重写，取代 `iOS-CameraLUT`。旧项目经过 11 个版本迭代，补丁层层叠加，
改一处动全身；这个项目按正确的结构重新组织。

---

## 功能

- **实时 LUT 预览**：取景画面直接套 LUT，看到什么拍出来就是什么
- **LUT 导入**：支持 `.cube`（3D 和 1D，1D 自动转 3D）
- **强度调节**：0–100%，在 LUT 数据上插值，不是简单图像混合
- **底部滤镜条**：每个 LUT 用当前画面实时渲染缩略图，点一下切换
- **变焦**：虚拟多摄设备（Triple / DualWide），系统负责镜头切换与交叉淡化，全程不重建会话
- **点击对焦 + 曝光补偿**：官方 `focusPointOfInterest` / `setExposureTargetBias`
- **前后摄切换**：前摄预览镜像、照片不镜像（同原生）

---

## 结构

```
Sources/
  App/          LutCamApp.swift           入口
  Camera/       CameraController.swift    会话、变焦、对焦、曝光、拍照
  LUT/          LUTCube.swift             .cube 解析 + 滤镜构建
                LUTLibrary.swift          文件管理、选择、缩略图
  Pipeline/     RenderPipeline.swift      统一的 CIContext
  Media/        PhotoProcessor.swift      LUT 烘进照片
                PhotoWriter.swift         写入相册
  UI/           CameraScreen.swift        主界面
                LUTStrip.swift            底部滤镜条
                SettingsScreen.swift      LUT 管理
                MetalPreview.swift        MTKView 预览渲染
                DocumentPicker.swift      原生文件选择器
```

状态用 `@Observable`（Observation 框架），不用 `ObservableObject` + Combine。
旧项目里用 `assign(to:)` 把 session 状态绑回界面状态，结果用户开关被诊断值覆盖，
这个坑在这里从根上不存在。

---

## 踩过的坑（都写进代码注释了）

| 问题 | 结论 |
|---|---|
| 预览和成片色彩不一致（成片更浓） | 预览与成片的 `CIContext` 工作空间必须都锁 sRGB，并用 `CIColorCubeWithColorSpace` |
| 玻璃按钮点不动 / 要长按 | 不能给 `Button` 手动贴 `.glassEffect(.interactive())`，它自带的手势会吞掉点击；用官方 `.buttonStyle(.glass)` |
| 玻璃按钮/Menu 标签不刷新 | 状态相关的控件加 `.id("...\(state)")` 强制重建 |
| 文件选择器「看得见但点不动」 | 不用 `.fileImporter`，改用 `UIDocumentPickerViewController(asCopy: true)`，并在设置页内部弹出 |
| 镜头档位消失 | `virtualDeviceSwitchOverVideoZoomFactors` 可能为空，回退用 `constituentDevices` 推导 |
| 照片在相册里方向不对 | 重编码时保留原始 properties 字典，不把旋转烘进像素 |

---

## 构建

推送到 `main` 会自动触发 GitHub Actions，产出未签名 IPA 并发布到 `latest` Release。

本地生成工程：

```bash
brew install xcodegen
xcodegen generate
open LutCam.xcodeproj
```

打包脚本 `scripts/make_ipa.py` 会把 `Info.plist` 强制排在 zip 的前几位——
部分签名工具（如全能签）只扫描前几个本地文件头来定位主包。

---

## 路线图

- [x] 实时 LUT 预览 / 拍照 / 导入 / 强度
- [x] 虚拟多摄变焦、点击对焦、曝光补偿、前后摄
- [ ] 视频录制（实时套 LUT）
- [ ] 手动控制（ISO / 快门 / 白平衡）
- [ ] 仿 Log 曲线（ProRAW + log 映射）
- [ ] 应用内图库与照片编辑
