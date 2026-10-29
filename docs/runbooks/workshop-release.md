# Runbook：发布到 Steam 创意工坊

创意工坊物品：[3829355835](https://steamcommunity.com/sharedfiles/filedetails/?id=3829355835)（2026-10-29 首次上传，0.1.0 测试版，仅好友可见）。物品 ID 记在 `docs/release/workshop-item-id.txt`，页面标题与说明在 `docs/release/workshop-description.txt`（第二行是标题，“说明”之后是 BBCode 正文）。

## 上传方式

`tools/workshop_upload.py` 通过本机已登录的 Steam 客户端上传，调用游戏自带的 `steam_api64.dll`（ISteamUGC），不需要输入任何账号信息，也不改动游戏目录。每次上传设置：标题、说明、可见性（默认仅好友可见，`--public` 改为公开）、内容（只含发布 zip 的文件夹，与 Brotato Online 的工坊物品结构相同）、预览图与截图，并把 Brotato Online（3741034628）设为所需物品（已设置时显示 already set）。

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

   日志里应有 `runtime gate: extended`、`queued 22 of 22 extensions`、0 个 `SCRIPT ERROR`。
3. 预览图放在 `.local/release/preview.jpg`（小于 1 MB；当前是 8 人战斗截图缩到 1280x720）。页面上的其他截图放在 `.local/release/gallery/`（按文件名排序，每张小于 1 MB；当前 6 张 1600x900：角色选择、商店本机放大、展开其他玩家、四人视图、升级、结算），每次上传都替换物品现有的截图；文件夹为空或不存在时不动。截图是游戏画面，只放本机、不入库。
4. 先试连，再上传：

   ```powershell
   python tools/workshop_upload.py --dry-run
   python tools/workshop_upload.py --upload --note "0.1.1：……"
   ```

   Steam 客户端必须在运行并已登录。上传期间 Steam 会显示你在玩 Brotato。结果以 `D:\steam\logs\workshop_log.txt`（Steam 安装目录下的 `logs`）中的 `Upload finished for workshop item … : OK` 为准。
5. 更新 `manifest.json` 的版本号与 CHANGELOG；改成公开前先完成多机联机验收（M1）。

## 注意

- 每次上传都会用 `workshop-description.txt` 覆盖页面上的标题和说明；在网页上改过的话，先把改动抄回这个文件。
- 账号未接受创意工坊法律协议时，工具会提示，物品在接受之前一直隐藏；协议由账号本人在物品页面接受。
- 不要把截图或日志里的 Steam ID 放进仓库。
