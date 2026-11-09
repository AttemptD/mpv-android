# 手机 HW+ 杜比映射实验库（2026-09-10）

这是 **MPV / mpv-android** 的四架构原生库，不是 Media3 / Exo 的 FFmpeg 扩展。
本轮重新编译四个 ABI 的 FFmpeg、MPV 和 JNI；其余第三方依赖沿用本机既有构建。
映射算法来自 gpu-next/libplacebo，本地补丁提供 MediaCodec 的 RPU 元数据与 OES 原始
YUV 到 GPU 三平面纹理的衔接。默认 `android-dovi-yuv=no`，不会只因替换 so 自动开启。

## 文件与接入位置

`jniLibs/` 包含 `arm64-v8a`、`armeabi-v7a`、`x86`、`x86_64`。
每个 ABI 必须使用同一包内成套的库，不要只复制 `libmpv.so`，也不要将 MPV 的
`libavcodec.so` 与 Exo FFmpeg 扩展的 JNI 库互换。

当前手机工程的 MPV 模块配置为：

```text
/Users/attempt/AndroidStudioProject/AfuseKt/mpv/src/main/libs/<ABI>/*.so
```

该目录由模块的 `jniLibs.srcDirs` 指定，因此将交付包 `jniLibs/<ABI>/` 中的库对应接入
上述目录，而不是额外套一层 `jniLibs`。本轮**没有替换手机工程或 TV 工程的库**。
接入前保留旧库以便回滚；还需验证整个应用的打包、混淆、其他 native 模块和 C++ 运行库
冲突。不能用 Gradle `pickFirst` 随意掩盖两套不兼容的同名 FFmpeg 库。

`libplayer.so` 绑定 `is.xyz.mpv.MPVLib`。包内附有本次对应的 `MPVLib.kt` 和 JNI 源码。
本轮确认它与当前 AfuseKt 的 `MPVLib.kt` 文件一致；这只确认绑定接口，不能替代正式应用
集成测试。MPV 的证书/字体等 Java 层初始化仍由应用原有逻辑负责。

## 开启方式：独立的手动“HW+ 杜比映射到 SDR”模式

在播放器初始化前应用下列配置，切换后重建/重新打开播放器，确保应用后续的设置逻辑
没有再覆盖它们。不要将这组固定 SDR 输出参数无条件加到原生 HDR/杜比直出模式。

```ini
vo=gpu-next
gpu-context=android
gpu-api=opengl
hwdec=mediacodec
android-dovi-yuv=yes

android-hdr-output=no
target-colorspace-hint=no
target-prim=bt.709
target-trc=bt.1886
target-peak=100
tone-mapping=bt.2390
```

不要复制测试配置里的 `audio=no`、`sub=no`、暂停、脚本和测试文件路径到正式配置。
当前实现**没有自动判定设备杜比能力后切换模式，也没有 GPU 桥接失败后的自动恢复**。
失败时可由用户切回原有 HW (`hwdec=mediacodec-copy`) 模式，重新打开播放器；不要在
同一失败播放器中无限重试。电视默认不要开启本实验模式，既有卡顿/停滞问题仍未解决。

开启成功至少应同时看到：

```text
Using hardware decoding (mediacodec).
Dolby Vision RPU side data active for MediaCodec output
Experimental HW+ Dolby Vision YUV bridge initialized
HW+ Dolby Vision raw YUV sampling active: ...
```

并检查 `hwdec-current=mediacodec`、`current-vo=gpu-next`，而不是只相信 UI 的 HW+ 标签。
需要 GLES 3、`GL_EXT_YUV_target`、三个可渲染 R16F 附件和可用的 Android 硬件图像互操作。
只有 ABI 匹配不代表设备 GPU/驱动支持。缺少能力会报错；不会自动补齐硬件能力。

## 验证范围

三星 SM-S9110 / Adreno 740 使用本轮 ARM64 库和独立 `is.xyz.mpv.yuvtest` APK 复测。
用户在测试时确认画面“正常”。具体短片结果见 `HWPLUS_DOVI.md` 的 2026-09-10 记录。
本轮未实机验证 ARMv7、x86、x86_64；它们是编译及 ELF 静态检查通过，不是播放认证。

`MANIFEST.json` 记录所有 so 的 SHA-256、架构、动态依赖、LOAD 对齐和源码基准版本。
`SHA256SUMS` 可核对解压内容。打包工具检查四 ABI 都含 YUV 桥接及 FFmpeg RPU 补丁标记，
非系统动态依赖齐全，64 位 ABI 的 ELF LOAD 至少 16 KiB 对齐；32 位 ABI 检查至少
4 KiB（包括 NDK 自带的 32 位 libc++）。三星本次运行在 4 KiB 页设备上，
**不是 16 KiB 页系统实机测试**；最终 APK 的 ZIP 对齐也需由集成工程保证。

包内没有电影、样片、私人播放链接或账户令牌。附带源码补丁、JNI、版本记录以及 MPV/
FFmpeg 上游许可证文本，便于内部接入和追溯；这不是完整对应源码发布包，也不是完整的
第三方许可清单。正式对外分发前需要另行准备相应的完整源码和许可材料。

## 本轮构建与打包

在已有匹配依赖的 mpv-android 根目录：

```sh
for abi in arm64 armv7l x86 x86_64; do
  ./buildscripts/buildAfusekt.sh -n --arch "$abi" ffmpeg
  ./buildscripts/buildAfusekt.sh -n --arch "$abi" mpv
done
buildscripts/sdk/android-ndk-r29/ndk-build -C app/src/main -j4 \
  APP_ABI='armeabi-v7a arm64-v8a x86 x86_64' \
  PREFIX32="$PWD/buildscripts/prefix/armv7l" \
  PREFIX64="$PWD/buildscripts/prefix/arm64" \
  PREFIX_X86="$PWD/buildscripts/prefix/x86" \
  PREFIX_X64="$PWD/buildscripts/prefix/x86_64"
./gradlew -I buildscripts/tests/yuv-test.init.gradle :app:assembleDefaultDebug
python3 buildscripts/tests/package-hwplus.py \
  app/build/outputs/apk/default/debug/app-default-universal-debug.apk \
  build/hwplus-delivery/mpv-hwplus-dovi-20260910
```

打包目录必须不存在，工具拒绝覆盖既有交付。so 从刚构建的 APK 中提取，避免把旧 ABI
构建目录误当成新产物；新安装到三星的 ARM64 so 与交付 APK 的 ARM64 内容另做逐项哈希比对。
