# 免责声明
项目仅适用于个人用户学习使用，不得用于生产环境，产生的侵权后果本人概不负责。  
有bug找altman修，这个是ai slop  
暂不提供Hap包


# OHSurfing

本项目移植自 [BadGhost520/ESurfingClient-CVersion](https://github.com/BadGhost520/ESurfingClient-CVersion)，沿用其 C 语言天翼校园认证模块，原项目采用 Apache-2.0 许可证。

HarmonyOS Stage 应用。ArkTS/ArkUI 负责界面、Wi-Fi SSID、设置和握姿识别；`entry/src/main/cpp` 编译原项目的 C 票据、加解密、登录、心跳和登出流程，并通过 Node-API 暴露给页面。未移植 WebUI、路由器配置、服务守护和时间窗口。

## 功能

- 首页展示累计认证时长、当前 Wi-Fi SSID 和不包含协议密文的运行日志。
- 个人信息页填写账号和密码，选择是否记住凭据，调整系统材质光感强度、开关握姿识别、查看关于信息。开启记住后，账号与密码保存在系统关键资产存储中；关闭后清除已保存凭据。其他设置保存在应用 Preferences。
- 底栏使用 HDS 悬浮式页签及系统沉浸光感材质，含主页、个人信息两个页签及独立的开始/暂停按钮。按钮跟随已识别的左右握持手移动；双手握持或暂未识别时保留上一次位置。设备不支持握姿能力或用户未授权时维持右侧布局。暂停按钮停止验证与心跳，并调用原 C 模块登出流程。
- 状态栏和导航条使用透明背景，页面延伸至系统栏；颜色和图标对比度随系统深色模式切换。页签切换与选中态有过渡动画。
- 使用 HarmonyOS Symbol 图标；蓝色扁平化天翼图形的 SVG 源文件在 `scripts/tianyi_logo.svg`，运行 `python scripts/generate_logo.py` 可生成启动与页面 PNG。

## 构建

请用 DevEco Studio 26.0.0 / HarmonyOS 26 SDK 打开本目录。命令行示例（路径需指向 26.0.0 工具链）：

```powershell
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' assembleHap --mode module -p module=entry@default -p product=default
```

工程的 `modelVersion` 为 `6.1.0`，`targetSdkVersion` 和 `compatibleSdkVersion` 为 `26.0.0`，`module.json5` 已启用系统沉浸材质。工程模型版本与 SDK API 级别是不同配置，应使用支持目标版本的工具链。完整源码已用临时 API 23 配置编译，并在 API 26 真机上检查安全区、底栏及握姿移动；目标 API 26 配置仍需配套工具链构建。

仓库中的构建配置不包含签名材料。真机安装时，请在 DevEco Studio 中配置自己的签名。签名密码、证书、私钥、`local.properties` 和 `build-profile.local.json5` 等本地配置不应上传至仓库。

## 平台适配说明

原项目用 libcurl/OpenSSL 做网络请求与 MD5。当前 HarmonyOS NDK 不提供这两个库，因此这里保留原项目的 C 验证和加解密代码，将 HTTP 请求改为 POSIX socket 实现，MD5 用内置实现。适配层仅支持 `http://` 的校园认证入口；若学校入口升级为 HTTPS，需要补充 TLS 网络实现。后台长时间保活还需申请并实现相应的后台任务能力，目前心跳由应用页面定时触发。没有校园网真机环境时无法验证实际服务器登录结果。
