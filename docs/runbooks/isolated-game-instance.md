# Runbook：隔离游戏实例

用途：AP-003 基线、AP-005 生命周期探针、AP-007 多实例验证。工具：`tools/instance.ps1`。前置：已运行 `tools/setup.ps1`。

## 原理（已在 2026-10-28 实测）

| 问题 | 做法 | 依据 |
| ---- | ---- | ---- |
| 不改游戏目录 | 引擎复制到 `.local/instances/<名>/steamapps/common/Brotato/`，用 `--main-pack <游戏>\Brotato.pck` 读取原版资源 | Godot 3 命令行 |
| 不被 Steam 重启成正式游戏 | 实例目录放 `steam_appid.txt`（1942280） | `res://singletons/platforms/steam.gd:37` 调用 `restartAppIfNecessary` |
| DLC | 把 `BrotatoAbyssalTerrors.pck` 复制进实例目录（`-WithDlc`） | `res://singletons/progress_data.gd:447` 从可执行文件目录加载 |
| 不碰真实存档 | `APPDATA` 指向 `.local/userdata/instance-<名>/`，`user://` 变为 `<该目录>\Brotato\` | Godot 3 Windows 用户目录取自 `APPDATA` |
| Mod 来源 | Steam 版 Mod Loader 选项 `steam_workshop_enabled = true`，**只加载工坊条目文件夹中的 zip，忽略本地 `mods/`**，且只加载当前账号已订阅的条目 | `res://addons/mod_loader/mod_loader.gd:235`、`internal/third_party/steam.gd`，选项 `options/profiles/steam.tres` |
| 工坊目录 | Mod Loader 把“可执行文件目录上溯三级 + `workshop/content/<appid>`”当作工坊目录，因此实例使用自己的 `steamapps/workshop/content/1942280/` | `internal/third_party/steam.gd` `_get_path_to_workshop` |
| 加载开发版扩展 | 开发版 zip 放进实例中 Brotato Online 条目的文件夹（`3741034628/`），与逐字节相同的 Brotato Online zip 并列；Mod Loader 会加载已订阅条目文件夹内的全部 zip | 同上 `load_zips_in_folder` |

`steam_data.json` 也需复制，否则 Mod Loader 读取不到 app id（日志报错且工坊路径缺少 appid）。

## 操作

```powershell
pwsh ./tools/instance.ps1 -Action New -Name baseline -Mods BrotatoOnline -WithDlc
pwsh ./tools/instance.ps1 -Action Start -Name baseline -StopAfterSec 50 -ExtraArgs '--audio-driver','Dummy'
```

- `-Mods` 可选 `BrotatoOnline`、`Extension`、`MouseUI`；`Extension` 需要同时包含 `BrotatoOnline`。`-DevBuild` 把排除于正式包的 `debug/` 一并打入开发 zip。
- 默认 `--no-window`；需要操作界面时加 `-ShowWindow`。探针运行建议加 `--audio-driver Dummy` 避免播放声音。
- 日志：`.local/userdata/instance-<名>/Brotato/logs/godot.log`、`modloader.log`；进程输出 `.local/instances/<名>/stdout.log`。
- 结束：`-Action Stop`；清理：`-Action Remove`（删除实例与其隔离用户数据）。

## 已知限制与注意

- 实例使用当前登录的 Steam 账号，Steam 好友会看到“正在玩 Brotato”。同一账号的多个实例共享同一个 Steam ID；Brotato Online 用 Steam ID 作为身份/peer key，因此**同账号多实例的 LAN 测试会发生身份冲突**，AP-007 的八实例验证需要另行设计（多账号或无 Steam 身份的 LAN 模式，待 AP-004 结论）。
- 隔离用户目录初始没有任何解锁进度；需要特定解锁时，只能使用测试专用存档（`tests/fixtures`），不得复制玩家真实存档。
- 实例中 Brotato Online 的 `mod_data/six666-BrotatoOnline/` 身份文件也写在隔离目录。
- 上游原有错误（基线即存在，不计为新故障）：Mod Loader 安装 `player.gd` 扩展时报 `Cannot load source code from file 'res://tests/partial_doubles/pd_player.gd'`，玩家真实日志中同样出现。

## 隔离验证记录

2026-10-28：运行 `baseline` 实例 50 s 前后比较 `%APPDATA%\Brotato` 下 38 个文件的大小与修改时间，0 处变化；实例存档全部写入 `.local/userdata/instance-baseline/Brotato/<平台用户 ID>/`。见 evidence/index.md EV-0004。
