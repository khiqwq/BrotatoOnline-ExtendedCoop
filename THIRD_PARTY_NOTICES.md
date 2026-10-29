# 第三方来源与许可

记录进入仓库或运行时依赖的外部代码与资源。任何参考代码在进入仓库前先在此登记来源与许可。

| 名称 | 来源 | 用途 | 是否进入仓库/安装包 | 许可 | 状态 |
| ---- | ---- | ---- | ------------------- | ---- | ---- |
| Brotato（游戏本体、资源、内置 Godot Mod Loader 6.3.0） | Steam App 1942280，build 23429717 | 运行目标；本机审计 | 否。还原脚本只存放在 `.local/` | 商业软件 | — |
| Brotato Online `six666-BrotatoOnline` 6.6.6 | 工坊 3741034628 | 运行依赖，扩展其脚本 | 否（玩家自行订阅）；本扩展的适配脚本会继承其脚本，若包含其方法的修改片段，按 GPL-3.0 在此逐项登记 | 工坊 zip 内无 LICENSE；GitHub 快照 `53d3fd45…` 为 GPL-3.0 | 待确认工坊版许可与快照一致（D-003） |
| CoopFix-OnlineMouseUI 1.0.1 | 工坊 3803857989 | 不在支持范围（R07），仅用于冲突检测 | 否 | 包内含 LICENSE | — |
| Extended Coop | 工坊 3629226509 | 行为参考 | 否，无源码 | 未知 | 仅参考公开页面 |
| Extended Coop - 8 players local + remote | 工坊 3792682639 | 行为参考 | 否，无源码 | 未知 | 仅参考公开页面 |

本仓库自有代码以 GPL-3.0 发布（见 LICENSE）。除下文所列片段外未复制第三方代码；LICENSE 文本取自 GNU 官方 GPL v3（SHA-256 `8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903`）。

## 含第三方代码片段的文件

### Brotato Online 6.6.6（GPL-3.0）

以下文件包含 Brotato Online 方法的修改片段（AP-006），文件开头均有两行说明（来源、许可、改动）。路径相对 `mods-unpacked/CoopPlus-OnlineExtendedCoop/`；来源行号指工坊版 6.6.6 的 `res://mods-unpacked/six666-BrotatoOnline/`。

| 文件 | 来源片段 | 改动 |
| ---- | -------- | ---- |
| `extensions/bo/session_manager_ext.gd` | `scripts/session_manager.gd`：`_remote_connection_rejection_reason`（:778-793，分支顺序）、`_publish_session_metadata`（:1146-1159）、`_get_lobby_status_text`（:8556-8580） | 人数上限取自运行时开关而非 `MAX_LOBBY_MEMBERS`；满员拒绝通知、LAN 旧连接释放 |
| `extensions/bo/lan_transport_ext.gd` | `scripts/lan_transport.gd:39-52` `start_host` | ENet 服务器 peer 上限按容量加余量 |
| `scripts/bo/resume_identity_patch.gd` | `scripts/player_identity_manager.gd:126-128` `prepare_resume_if_needed`（由槽位重建 `_lan_hashes` 的循环） | 运行时调整 BO 身份管理器：超过 4 槽的登记表、面板加高、4 人以上禁用离线继续 |
| `extensions/bo/public_lobby_browser_ext.gd` | `scripts/public_lobby_browser.gd:1166-1186` `_read_lobby_entry`（joinable 的判断式） | 扩展房间的 mod_version 标记在本机可加入时视为兼容 |
| `extensions/bo/network_heartbeat_ext.gd` | `scripts/network_heartbeat.gd:152-166` `_receive_host_disconnect_status` | 断线列表上限为容量 - 1 而非 3 |
| `extensions/bo/menu_sync_manager_ext.gd` | `scripts/menu_sync_manager.gd:8007-8015` `_get_online_coop_layout_player_count`、`:5988-5996` `_set_node_array_value` | 人数按容量限制；补位使用中性值 |
| `extensions/bo/online_player_slot_manager_ext.gd` | `scripts/online_player_slot_manager.gd:496-627` `apply_host_selection_layout`、`:745-769` `_add_remote_steam_id`、`:1175-1200` `_remove_untracked_remote_placeholder_slots` | 远程座位按容量分配到虚拟设备号；拒绝可查询；超容量布局整体拒绝 |
| `extensions/vanilla/entity_spawner_ext.gd` | `extensions/entity_spawner_online_player_count_guard.gd:66-88`（人数读取与名单辅助） | 人数按容量限制，不生成无数据的玩家 |
| `extensions/vanilla/main_ext.gd` | `extensions/main_safe_pool_exit.gd:80-88`（人数读取） | 同上 |

`extensions/bo/steam_transport_ext.gd` 只沿用方法签名（`start_host`），不含方法体，未加说明行。`debug/` 下的探针不含第三方代码。

### Brotato 游戏代码（商业软件，非 GPL）

仓库中不含游戏代码。原先 `extensions/vanilla/main_ext.gd` 复述了 `Main.on_gold_picked_up`，已按 D-006 改为：调用游戏自己的方法，只把其分配结果重新分给 5～8 人（EV-0032）；该复述也已从仓库历史中移除。

| 文件 | 片段 | 原因 | 状态 |
| ---- | ---- | ---- | ---- |
| `extensions/vanilla/main_ext.gd` | （已移除）`main.gd:827-892` `Main.on_gold_picked_up` 的复述 | 原方法用局部数组 `[0, 0, 0, 0]` 分配材料/经验，无法从外部扩展（BAT-04、DATA-12） | **已解决（D-006，2026-10-28）**：游戏方法在人数限为 4 的一次调用中运行，材料/经验发放被捕获后按人轮流分给全部玩家 |
