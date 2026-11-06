# Runbook：发布到 Steam 创意工坊

创意工坊物品：[3829355835](https://steamcommunity.com/sharedfiles/filedetails/?id=3829355835)（2026-10-29 首次上传，0.1.0 测试版；2026-11-03 起公开）。物品 ID 记在 `docs/release/workshop-item-id.txt`，页面标题与说明在 `docs/release/workshop-description.txt`（第二行是标题，“说明”之后是 BBCode 正文）。

## 上传方式

`tools/workshop_upload.py` 通过本机已登录的 Steam 客户端上传，调用游戏自带的 `steam_api64.dll`（ISteamUGC），不需要输入任何账号信息，也不改动游戏目录。每次上传设置：标题、说明、可见性（默认公开，`--friends-only` 改为仅好友可见）、内容（只含发布 zip 的文件夹，与 Brotato Online 的工坊物品结构相同）、预览图与截图，并把 Brotato Online（3741034628）设为所需物品（已设置时显示 already set）。

讨论区（Steamworks 没有讨论区接口，在网页上操作）：置顶两个讨论“Bug 反馈 / Bug reports”和“功能建议与新增 / Feature requests”。

游戏自带的 `GodotWorkshopUtility.exe` 也能上传，但游戏目录没有 `steam_appid.txt`，直接双击时连不上 Steam；需要带 `SteamAppId=1942280` 环境变量启动（Steam 启动游戏时就是这样做的）。

## 步骤

1. 回归：`check.ps1`、`test.ps1 -Suite Unit`、`test.ps1 -Suite Integration`。
2. 打发布包（不含 `debug/`），并用隐藏实例冒烟一次：

   ```powershell
   Import-Module ./tools/lib/Common.psm1 -Force
   New-DeterministicZip -RelativePaths (Get-PackageFileList) -OutPath .local/release/CoopPlus-OnlineExtendedCoop.zip
   pwsh ./tools/instance.ps1 -Action New -Name rel -Mods "BrotatoOnline,Extension" -WithDlc
   pwsh ./tools/instance.ps1 -Action Start -Name rel -StopAfterSec 40 -ExtraArgs "--audio-driver,Dummy"
   ```

   日志里应有 `runtime gate: extended`、`queued 24 of 24 extensions`、`installed 2 of 2 enter_tree extensions`，没有 `SCRIPT ERROR`（Brotato Online 11-05 起用绝对路径 preload；更早的版本会有 3 条无害的 `Can't preload resource`，见 EV-0038）。
3. 预览图放在 `.local/release/preview.jpg`（小于 1 MB；当前是 16 人第 20 波战斗截图缩到 1280x720）。页面上的其他截图放在 `.local/release/gallery/`（按文件名排序，每张小于 1 MB；当前 9 张 1600x900，除 DLC 图标那张（6 人）外都是 16 人：角色选择、商店本机放大（状态条逐个滚动）、展开其他玩家（状态条第二页）、四人视图、升级、结算、扩展房间的玩家 DLC 图标（没装的玩家为灰色）、第 20 波战斗与紧凑 HUD、设置里的翻页开关），每次上传都替换物品现有的截图；文件夹为空或不存在时不动。截图是游戏画面，只放本机、不入库；用本地模拟的截图（`--coopplus-local-sim-menus`、`-kit=perf`、`-options-shot`，见 [local-simulation.md](local-simulation.md)）。
4. 先试连，再上传：

   ```powershell
   python tools/workshop_upload.py --dry-run
   python tools/workshop_upload.py --upload --note "0.1.1：……"
   ```

   上传后在物品页（中英文各一次）核对截图数量。2026-11-04 一次上传在截图 05 超时失败后，物品仍登记着 9 张，但页面只显示 1 张：后几张的图片没有传上去。之后用 `--keep-media` 的上传不会补上它们；不带 `--keep-media` 重新上传即可，Steam 只补传缺的那几张（未变的会跳过）。
   每次上传都会带上预览图与截图（Steam 跳过没变的图片）。2026-11-04～06 曾用 `--keep-media` 只传内容和文字，结果三次都让页面只剩 1 张截图，已去掉该选项。上传因网络失败（`EResult 2` 清单失败、`EResult 16` 图片超时）时隔一分钟重跑即可。

   Steam 客户端必须在运行并已登录。上传期间 Steam 会显示你在玩 Brotato。结果以 `D:\steam\logs\workshop_log.txt`（Steam 安装目录下的 `logs`）中的 `Upload finished for workshop item … : OK` 为准。
   上传后本机订阅的副本不一定马上更新：这台电脑的 Steam 可能要过一阵才发现新版本，游戏在此之前一直加载旧版（2026-11-04 上传 25 分钟后仍是旧版）。关掉游戏后运行 `python tools/workshop_upload.py --refresh-local`，让 Steam 立即下载最新版本，再核对 `steamapps/workshop/content/1942280/3829355835/` 里 zip 的 SHA-256 与发布包一致。
5. 更新 `manifest.json` 的版本号与 CHANGELOG。物品已公开，每次上传都直接对所有订阅者生效。

## 注意

- 每次上传都会用 `workshop-description.txt` 覆盖页面上的标题和说明；在网页上改过的话，先把改动抄回这个文件。
- Steam 按语言分别保存标题和说明，观看者看到的是自己客户端语言的那份。物品有一份简体中文的（在中文网页上编辑时产生），以前只更新英文那份，中文客户端一直显示旧的 5～8 人说明（2026-11-04）。现在每次上传对 `TEXT_LANGUAGES`（english、schinese）各提交一次同样的标题和说明；只改文字时用 `python tools/workshop_upload.py --text-only --note "……"`，不重新上传内容。核对中文页面：`https://steamcommunity.com/sharedfiles/filedetails/?id=3829355835&l=schinese`。
- 账号未接受创意工坊法律协议时，工具会提示，物品在接受之前一直隐藏；协议由账号本人在物品页面接受。
- 不要把截图或日志里的 Steam ID 放进仓库。
