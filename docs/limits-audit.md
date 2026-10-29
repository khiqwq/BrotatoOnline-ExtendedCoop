# 5～8 人扩展限制审计（AP-004）

- 日期：2026-10-28
- 机器可读来源：`docs/audit/findings.json`（与本文同一批数据，含核验记录）
- 适用读者：实现 AP-005 起各工作项的工程师

## 0. 版本锁与来源说明

| 项 | 锁定值 |
| --- | --- |
| 游戏 | Brotato 1.1.15.4（Steam build 23429717） |
| 引擎 | Godot 3.7.dev.custom_build.74e86be54（Godot 3.x，GDScript 1） |
| Mod Loader | 游戏自带 `res://addons/mod_loader`，代码版本 6.3.0（`res://addons/mod_loader/mod_loader_store.gd:15`） |
| DLC | Abyssal Terrors（已安装） |
| 联机 Mod | Brotato Online，mod id `six666-BrotatoOnline`，6.6.6，工坊 3741034628（不修改） |
| 已安装的其他 Mod | CoopFix-OnlineMouseUI 1.0.1，工坊 3803857989（依赖 Brotato Online） |

来源说明：

- 游戏脚本由 `.gdc` 字节码还原。验证方式：用同一引擎分别加载原字节码与还原源码，384 个可加载脚本结构一致、没有语法级错误。还原源码没有注释，行号等于原始源码行号。
- 场景与资源（`.tscn`/`.tres`/`project.binary`）取自游戏包，路径与 `res://` 相同。
- Brotato Online 与 CoopFix 取自工坊下载目录的 `mods-unpacked`。
- 本次审计只读源码，没有运行游戏。凡标“需实测”的结论都要在 AP-005 及之后用运行证据确认。

路径缩写（表格中使用）：

- `BO/` = `res://mods-unpacked/six666-BrotatoOnline/`
- `CF/` = `res://mods-unpacked/CoopFix-OnlineMouseUI/`
- 其余均为游戏 `res://` 路径；DLC 脚本为 `res://dlcs/...`

可行性缩写：覆盖方法（子脚本覆盖实例方法）、数据补丁（运行时修改 var 数据）、场景扩展（向场景注入节点或替换资源）、包装信号、仅环境（扩展无法改，只能靠环境或发布流程规避）、不改（与人数无关或保持原样）、未知。后接置信度（高/中/低），“需实测”表示必须运行验证。

核验结果说明：

- 确认：独立核验者复核后结论成立。
- 已纠正：结论大体成立，但核验者纠正了部分事实；表中已经采用纠正后的事实，括号内写纠正要点。
- 核验新增：核验阶段新发现的问题（原审计遗漏）。
- 单轮：缺口审计（GAP1～GAP4）只经过一轮审计，没有独立核验。

统计：共 280 条发现；没有被驳回的发现。

| 领域 | 条数 | 确认 | 已纠正 | 驳回 | 核验新增 | 单轮 |
| --- | --- | --- | --- | --- | --- | --- |
| CAP 大厅/会话容量与传输 | 23 | 16 | 3 | 0 | 4 | 0 |
| INP 槽位、设备与虚拟输入 | 15 | 5 | 7 | 0 | 3 | 0 |
| MENU 菜单同步 | 21 | 12 | 5 | 0 | 4 | 0 |
| BAT 战斗复制、生成与场景守卫 | 31 | 18 | 4 | 0 | 9 | 0 |
| DATA 局内数据与逐玩家数组 | 24 | 11 | 9 | 0 | 4 | 0 |
| UI 5～8 号玩家界面 | 35 | 15 | 11 | 0 | 9 | 0 |
| LIFE Mod Loader 生命周期与扩展机制 | 27 | 18 | 5 | 0 | 4 | 0 |
| SAVE 存档、身份、重连与继续 | 26 | 15 | 4 | 0 | 7 | 0 |
| NET 网络协议、消息与 API | 25 | 13 | 6 | 0 | 6 | 0 |
| GAP1 局中移除与 roster 重映射 | 13 | — | — | — | — | 13 |
| GAP2 失败、重试、胜利、结算后新局 | 10 | — | — | — | — | 10 |
| GAP3 二级菜单（难度、暂停、重试、提示） | 16 | — | — | — | — | 16 |
| GAP4 共享全局上限与放大效应 | 14 | — | — | — | — | 14 |
| 合计 | 280 | 123 | 54 | 0 | 50 | 53 |

## 1. 结论摘要

### 1.1 独立补丁路线的主要障碍

1. **人数上限是常量，并被大量实例方法直接读取。** `MAX_LOBBY_MEMBERS=4` 在 `BO/scripts/session_manager.gd` 的 10 个方法里读取（CAP-01），`MAX_CLIENTS=3`（`BO/scripts/lan_transport.gd:9`）、`MAX_REMOTE_PLAYERS=3`（`BO/scripts/online_player_slot_manager.gd:7`）、`CoopService.get_max_players()` 固定返回 4（`res://singletons/coop_service.gd:156-158`）、`UI_MAX_PLAYER_COUNT=4`（`res://singletons/coop_service.gd:53`）。子脚本不能重声明父类常量，父方法编译时已经内联常量值，只能逐个覆盖读取它的方法。
2. **Brotato Online 自身的保护逻辑把人数夹到 4 并截断数据。** `clamp(…,1,4)` 出现在 `BO/extensions/entity_spawner_online_player_count_guard.gd:81/:88`、`BO/extensions/main_safe_pool_exit.gd:88`、`BO/scripts/menu_sync_manager.gd:8015`，随后 `RunData.set_player_count(4, false)` 执行 `players_data.resize`（`res://singletons/run_data.gd:282-292`），P5～P8 的角色、装备和金币被永久删除（BAT-01/02、MENU-01、INP-M01）。这是首要阻断项。
3. **虚拟输入通道不够。** 远程占位设备池只有 `[1,2,3,4,5,0]`（`BO/scripts/online_player_slot_manager.gd:14`），InputService 只为设备 0～7 生成每设备动作（`res://singletons/input_service.gd:235`），设备 0 同时绑定本机键盘和物理手柄 0（INP-04）。8 人局每台机器需要 7 个远程通道，现状最多约 6 个且有串位。
4. **逐玩家固定 4 项的数据结构到处都是。** RunData 的 11 个平行数组、TempStats/LinkedStats、`Utils._stat_caches`（所有属性读取都经过它）、`main.gd` 的升级/箱子队列与金币分配局部数组、EntitySpawner 的建筑/宠物队列、PopupManager、BaseShop、BaseSelection、UpgradesUI、`player_colors`（4 色）等。多处会在每波或每局被重新写成 4 项字面量，只补一次不够（DATA-01/02、BAT-03/04/05、UI-01）。
5. **UI 场景写死 1～4 号面板、FocusEmulator1～4 与 HUD P1～P4 节点。** Godot 3 的 `_ready`/`_enter_tree`/`_process`/`_input` 在继承链每一层都会自动调用，子类无法替换原版回调，只能提前扩容、在 `_enter_tree` 注入节点、覆盖原版回调调用的普通访问器，再在子类 `_ready` 中幂等补完（UI-04、MENU-M02）。逻辑画布固定 1920x1080（UI-M07）。
6. **存档不能交给原版入口。** 原版 v3 读写器把商店相关数组固定为 4 项（`res://singletons/progress_data_loader_v3.gd:390/:406/:603/:609`），`ProgressDataLoaderV3` 是 `class_name`，ProgressData 编译时已绑定原脚本，扩展 loader 预计无效（SAVE-03）。BO 身份表拒绝超过 4 人（`BO/scripts/player_identity_registry.gd:29`），而且 manager 的 `const preload` 会在扩展排序阶段提前绑定原版 registry（SAVE-M01）。
7. **缺少能力门控。** Host 在 Steam 大厅成员变化时就注册连接并分配槽位，早于 hello（CAP-13、NET-15）；被拒成员留在大厅占名额（CAP-M03）；菜单阶段离开的成员仍占名额（CAP-M04、NET-M04）。未装扩展的客户端可能进入超四人房间。
8. **加载与生命周期陷阱。** 扩展排序阶段以原版为父类编译子脚本，用裸标识符访问 BO 新增成员会产生 SCRIPT ERROR（LIFE-M-01）；上一次日志里任何涉及 `mods-unpacked` 的 ERROR 会让 CrashReporter 在下一次启动禁用全部 Mod（LIFE-03）；槽位管理器第 15 行的常量依赖 CoopService 自动加载，如果在 `_init` 中安装其扩展，可能编译失败（INP-M02）；Steam 版只加载已订阅工坊条目（LIFE-01）。
9. **导出模板未确认。** 可执行文件中找不到 GDScript 调试专用错误串，推断为 release 模板：越界读得到 null、越界写被丢弃、不写日志，对 null 调用内建方法可能直接崩溃（DATA-M01、UI-M01、BAT-M09）。很多“中断/卡死”只在 debug 模板出现，release 下更常见的是数据静默丢失。所有测试都必须以数据断言为准。

### 1.2 可行接入点

- BO 的 23 个管理器（含 SessionManager、Steam/LAN Transport、NetworkHeartbeat、OnlinePlayerSlotManager、PlayerIdentityManager、MenuSyncManager、StateSnapshot、BattleReplicaManager、PlayerRemovalManager、BrotatoOnlineAPI）都在 BO `mod_main._ready` 中用 `load()`+`set_script()` 创建（`BO/mod_main.gd:332/:342`），晚于 `ModLoader._init` 中的 `handle_script_extensions`（`res://addons/mod_loader/mod_loader.gd:180`），所以在本扩展 `mod_main._init` 中对这些 BO 脚本路径调用 `install_script_extension` 会生效（CAP-19、LIFE-06）。
- 排在 ModLoader 之后的自动加载（Utils、ProgressData、RunData、TempStats、LinkedStats、InputService、CoopService、DebugService、SoundManager）可以扩展，也可以在本扩展 `mod_main._ready` 中修改其 var 数据（此时它们已实例化但尚未 `_ready`）。
- `main.tscn` 及各菜单场景在扩展安装之后才加载；manifest 依赖 BO 后，本扩展对同一原版路径的扩展会链在 BO 之上，可以覆盖 BO 的 `_brotato_online_*` 辅助方法（BAT-01/02、LIFE-04）。
- 运行时数据补丁足以处理：`CoopService.player_colors`、RunData/TempStats/LinkedStats/Utils 的逐玩家数组、`RunData._players_die_args`、`ProgressData.saved_run_state` 中恢复商店用的数组。
- 不改线上协议版本的协商通道：hello 可选字段（先例 `player_list_enabled`，`BO/scripts/session_manager.gd:3770-3772`）、Steam 大厅元数据新键、LAN 发现应答新键、`transport_identity` 新键、握手后的 `bo_mod_message`（`BO/scripts/brotato_online_api.gd:144`）。

### 1.3 必须运行时验证的问题

1. 发行版是 debug 还是 release 模板（打印 `OS.is_debug_build()`），以及越界读写、对 null 调用方法的实际后果。
2. 扩展是否真的作用到 BO 创建的管理器实例：打印 `get_script().resource_path`、`get_meta("extension_script_path")` 和 `get_base_script()` 链，确认 `_ready` 只运行一次。
3. 在 `_init` 安装 `online_player_slot_manager.gd` 扩展时，第 15 行 `CoopService.PlayerType` 常量能否编译（INP-M02）。
4. 本扩展与 BO、CoopFix 对 `focus_emulator.gd`、`utils.gd`、`main.gd`、`entity_spawner.gd` 的扩展链顺序（UI-20、LIFE-04）。
5. Godot 3.7 自定义构建的多级回调语义、信号按 ObjectID 派发的顺序（LIFE-08、LIFE-22）。
6. `ProgressDataLoaderV3.new()` 与 `PlayerUIElements.new()` 实际创建的是哪个脚本（SAVE-03、UI-14）；`player_identity_manager.gd` 的 preload 绑定（LIFE-07、SAVE-M01）。
7. GodotSteam 是否提供 `setLobbyMemberLimit`、`setLobbyMemberData`、`getLobbyMemberData`（CAP-03、CAP-13）。
8. ENet 断线 peer 的超时时长，以及 LAN 重连时 `duplicate_identity` 竞态（CAP-05、CAP-M01）。
9. 8 人时各类报文的实际字节数、分块数、发送队列长度与 Host 帧时间（BAT-11、NET-09、MENU-M04、GAP4-14）。
10. 同机多实例的 user:// 隔离、Steam `restartAppIfNecessary` 行为与工坊路径推导（LIFE-02、LIFE-15、LIFE-16）。

## 2. 按领域的限制表

表头统一为：编号 | 位置 | 现状 | 5～8 人影响 | 接入方案 | 可行性 | 风险 Fxx | 用例 Txx | 核验结果。

### 2.1 CAP：大厅/会话容量与传输

| 编号 | 位置 | 现状 | 5～8 人影响 | 接入方案 | 可行性 | 风险 | 用例 | 核验结果 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CAP-01 | `BO/scripts/session_manager.gd:5`（读取于 499、652、791、1134、1142、1151、1155、1346、1349、1748、1758、2230、2247、8569） | `MAX_LOBBY_MEMBERS=4` 是会话总人数（含本地、Steam、LAN），由 10 个方法直接读取，外部无读取 | 第 5 人在 Steam 原生上限、会话准入、LAN 发现、状态文本四层被挡；只改一层会出现半加入 | 子脚本逐个覆盖读取方法，改读 CapacityPolicy；建房上限改走 `steam_transport.start_host`（CAP-03）；`_handle_transport_identity` 的 member_limit 仅展示，可不覆盖 | 覆盖方法；高 | F01、F17 | T01、T17 | 确认（`_handle_transport_welcome` 范围为 687-728） |
| CAP-02 | `BO/scripts/session_manager.gd:791` | `_remote_connection_rejection_reason` 对新身份在冻结或人数≥4 时返回 room_full；Steam 侧只 closeSessionWithUser，不通知 | 第 5 名起被拒；只放宽 Steam 上限时会停在“加入中”遮罩，hello 每 8s 无限重试 | 整函数覆盖（17 行，保持前四个分支顺序），容量改读 CapacityPolicy；Steam 拒绝时补发 `player_kicked` 或扩展消息 | 覆盖方法；高；需实测 | F01、F09 | T01、T09、T10 | 确认（`_rejected_peer_keys.erase` 在 806；resume 计数分支 918-919；只有 room_full 才 close_peer） |
| CAP-03 | `BO/scripts/session_manager.gd:1346`、`:1349`；`BO/scripts/steam_transport.gd:49-53` | createLobby 上限固定 4（含回退分支）；全 Mod 无 setLobbyMemberLimit；原生计数不含 LAN 与本地玩家 | Steam 方式最多 4 名成员；提高到 8 后未装扩展的客户端也看到 x/8 | 覆盖 `steam_transport.start_host(lobby_type, member_limit)` 改传容量；回退分支在 `_on_lobby_created` super 后调用 setLobbyMemberLimit（先确认 `_lobby_id` 非 0） | 覆盖方法；高；需实测 | F01、F17 | T01、T13 | 确认（子脚本不要重声明 steam_transport 的 `_ready` 同名成员） |
| CAP-04 | `BO/scripts/session_manager.gd:1151`、`:1155`、`:2230`、`:2247`、`:1748`、`:1758` | `_publish_session_metadata` 每 125ms 写 member_limit=4、joinable=count<4，写入有缓存去重 | 4 人后 Steam 不可加入；若“先 super 再改写”，每轮翻转并触发 lobby_data_update 风暴 | `_publish_session_metadata` 整函数覆盖且不调 super；`_setup_lobby_data`、`set_public_lobby_enabled`、`_prepare_friends_only_lobby_for_invite` super 后重算；保留 1565、1740 的 false 写入 | 覆盖方法；高；需实测 | F01、F18 | T01、T18 | 确认 |
| CAP-05 | `BO/scripts/lan_transport.gd:9`、`:43` | `MAX_CLIENTS=3` 只在 `start_host` 传给 create_server；满额时客户端看到“无法连接”或超时 | LAN 最多 4 人；满房时断线重连可能因旧 peer 未释放失败 | 整函数覆盖 `start_host(port)`，上限取远程容量加余量，准入以 CAP-02 为准；不要改 `set_channel_count(4)` 与 `clamp(channel+1,1,3)`（ENet 通道号） | 覆盖方法；高；需实测 | F01、F10 | T01、T10 | 确认（调用在 session_manager.gd:1336；只加余量不能让重连通过，见 CAP-M01） |
| CAP-06 | `BO/scripts/session_manager.gd:1134`、`:1142`；`BO/scripts/public_lobby_browser.gd:1226` | LAN 发现应答 member_limit=4、joinable=count<4；浏览器缺省按 4 判满 | 4 人后 LAN 房间显示满员，无法从浏览器加入 | 覆盖 `get_lan_discovery_info()`：super 后改写 member_limit/joinable 并追加能力键；不改发现协议版本 | 覆盖方法；高 | F01 | T01、T13 | 确认（lan_discovery 会追加 protocol 字段） |
| CAP-07 | `BO/scripts/session_manager.gd:499`（调用于 484、2394）；`res://singletons/coop_service.gd:111`、`:356`、`:369-379` | 本地加入监听按 <4 置位，真正的闸门是 `_can_add_new_device`；远程占位经 `_add_player` 绕过；监听时拔手柄按设备号删玩家 | get_max_players 全局改 8 会让本地长按与远程争名额；占位 1～5 只在同号实体手柄“占位后才插入、再拔出”时会被误删（占位 0 不受影响） | 覆盖 `_sync_host_local_join_listening_state`；CoopService 子脚本覆盖 `_can_add_new_device`，把本机设备上限与会话容量分开 | 覆盖方法；高；需实测 | F03 | T02、T03 | 已纠正（调用点 484；漏写入方 coop_service.gd:175；误删条件收窄，0 号先被改写为 6） |
| CAP-08 | `BO/scripts/online_player_slot_manager.gd:752`、`:755`、`:313` | `_add_remote_steam_id` 在远程≥3、人数≥get_max_players 或无占位设备时返回 -1，调用方忽略 | 第 5 名起没有槽位和输入映射，会话人数与槽位数不一致 | 整函数覆盖 `_add_remote_steam_id`，上限改读 CapacityPolicy，失败时上报会话层 | 覆盖方法；高 | F01 | T01、T11 | 确认（`get_available_remote_slot_count` 无调用者） |
| CAP-09 | `BO/scripts/online_player_slot_manager.gd:14`、`:1271`、`:1282`；`res://singletons/input_service.gd:235` | 占位池只有 6 个号，并跳过本机手柄；InputService 只为 0～7 生成动作 | 单机最多约 6 个远程角色，第 8 名分不到槽位 | 扩展虚拟设备号（避开 0～7 与调试 8～11），覆盖两个池方法与 `InputService._copy_device_actions` | 覆盖方法；高；需实测 | F02 | T02 | 确认（占位 0 会接收本机物理输入） |
| CAP-10 | `res://singletons/coop_service.gd:156-158`；`res://main.gd:215`；`res://ui/menus/run/character_selection.gd:412`、`:418` | `get_max_players()` 固定 4；main._ready 与选人面板按它遍历只有 4 个的节点 | 保持 4 时 BO 远程占位卡在 4；全局改 8 时 main._ready 对 null 调 hide 报错 | 不全局覆盖；覆盖 BO 读取点与 `_can_add_new_device`；UI 节点就绪后才可覆盖 | 覆盖方法；高；需实测 | F01、F04 | T01、T04 | 确认（`_on_element_focused:447` 的越界转 UI 处理） |
| CAP-11 | `res://singletons/coop_service.gd:53` | `UI_MAX_PLAYER_COUNT=4` 被 upgrades_ui:47、base_selection:112、coop_end_run:34/53、coop_shop:21 直接读 | P5～P8 没有面板 | 逐个覆盖读取函数；这些多在 `_ready` 中，只能在子类 `_ready` 追加；base_selection 的方法可整函数覆盖 | 覆盖方法；高；需实测 | F04 | T04 | 确认 |
| CAP-12 | `BO/scripts/session_manager.gd:7`、`:10`；`BO/scripts/public_lobby_browser.gd:8`；`BO/scripts/lan_discovery.gd:6` | 协议版本 "5.0.0"、LAN 3、发现 1 全部精确比较 | 改版本会破坏 1～4 人互通 | 线上版本不变；在 hello、元数据、发现、transport_identity 追加可选键，或握手后用 bo_mod_message；不新增 msg_type | 覆盖方法；高 | F17 | T13、T17 | 确认（未知 msg_type 跳过会话过滤；resume 挂起时 bo_mod_message 被丢弃） |
| CAP-13 | `BO/scripts/session_manager.gd:2343`、`:3060` | Steam 成员在 hello 之前就被注册并分配槽位；被拒成员的 hello 在会话过滤处被丢弃 | 未装扩展的客户端可以作为 P5～P8 进入 | 方案 A：setLobbyMemberData 写能力键；方案 B：覆盖 `_should_drop_p2p_message_for_session` 读取被拒 hello；方案 C：容量>4 时改写元数据 mod_version 标记 | 覆盖方法；中；需实测 | F17（建议按 AP-009 追踪） | T13、T16 | 确认（原文的 F13/F16 映射不准，已改） |
| CAP-14 | `BO/scripts/session_manager.gd:920`（resume 分支 917-919） | 人数=max(1,本地槽数)+`_session_remote_peer_keys`（含保留槽） | 断线者以及菜单阶段离开者都占名额 | 保持语义，只改各闸门的比较对象；每机一人时本地数限为 1 | 覆盖方法；高 | F09、F11 | T09、T10 | 已纠正（行号 920；菜单阶段离开也保留名额，见 CAP-M04） |
| CAP-15 | `BO/scripts/session_manager.gd:8183` | 局内冻结只按阶段判断；首次加锁时对 connected_players 拍快照 | 没有数字上限；若加锁前已被截到 4，会被快照固化 | 覆盖 `set_online_run_slots_locked`：super 后校验快照大小等于 RunData 人数 | 覆盖方法；高；需实测 | F01 | T01、T06、T09 | 确认 |
| CAP-16 | `BO/scripts/network_heartbeat.gd:164` | 客户端只保留 Host 报告的前 3 个断线 peer | 4～7 人同时断线时客户端漏报 | 覆盖 `_receive_host_disconnect_status`，上限改为容量-1 | 覆盖方法；高 | F09 | T09 | 确认 |
| CAP-17 | `BO/scripts/player_identity_registry.gd:29`、`:42`；`BO/scripts/player_identity_manager.gd:122` | `load_metadata` 拒绝 >4 人，继续时退为手动分配，不再拦截陌生身份 | 5～8 人继续没有身份保护 | 覆盖 `load_metadata`；若同时扩展 manager，改在 manager 扩展中替换 registry（SAVE-M01） | 覆盖方法；中；需实测 | F10、F13 | T10 | 已纠正（调用在 :122） |
| CAP-18 | `BO/scripts/session_manager.gd:59`、`:7636` | 大包分片全局每帧只发 1 片 | 7 个客户端时大状态到达约为 4 人的 2.3 倍（估算） | 实测需要时整函数覆盖 `_poll_pending_p2p_chunk_sends` | 覆盖方法；中；需实测 | F18 | T18 | 确认 |
| CAP-19 | `BO/mod_main.gd:332`、`:342`；`res://addons/mod_loader/mod_loader.gd:180` | BO 管理器在 `_ready` 中 load()+set_script，晚于扩展安装；CoopService 自动加载排在 ModLoader 之后 | 从加载时机看路线 A 可行 | `_init` 中 install_script_extension，manifest 依赖 BO；只覆盖普通方法；节点名不变 | 覆盖方法；中；需实测 | F17 | T17 | 确认（自动加载顺序：ModLoader 第 6、InputService 第 20、CoopService 第 26） |
| CAP-M01 | `BO/scripts/session_manager.gd:785` | LAN 客户端用新 peer 重连时旧连接仍在，被判 duplicate_identity，客户端 leave_lobby | 满房断网重连失败，与人数无关的 F10 阻断点 | 覆盖 `_handle_transport_identity` 主机分支：令牌校验通过后先逐出旧 LAN 连接，再 super | 覆盖方法；中；需实测 | F10 | T10 | 核验新增 |
| CAP-M02 | `BO/scripts/player_identity_manager.gd:34` | installation_id 存在 user://，同一系统用户多开时共享 | 单机多开 LAN 测试从第二个实例起被拒，会被误判为容量问题 | 每实例独立用户或虚拟机；或只在测试构建按命令行替换 id，不进正式包 | 覆盖方法；高；需实测 | F10 | T01 | 核验新增 |
| CAP-M03 | `BO/scripts/session_manager.gd:803` | 被拒 Steam 成员只被关闭 P2P，不离开大厅，没有通知也没有超时 | 原生上限提到 8 后，滞留者占名额，合法玩家看到“大厅已满” | 拒绝时限频发 `player_kicked`（原版客户端会 leave_lobby），扩展客户端另发原因；不复用 detach_kicked_peer | 覆盖方法；高；需实测 | F01、F09 | T01、T13 | 核验新增 |
| CAP-M04 | `BO/scripts/session_manager.gd:2348` | 角色选择阶段离开的成员仍留在 `_session_remote_peer_keys`，占名额与占位角色 | 进出频繁时幽灵名额导致 room_full | 按 AP-001 决策：覆盖 `_refresh_lobby_members` 与 `_on_transport_peer_disconnected`，菜单阶段移除离开者并重同步 | 覆盖方法；高 | F09、F11 | T10、T11 | 核验新增 |

### 2.2 INP：槽位、设备与虚拟输入

| 编号 | 位置 | 现状 | 5～8 人影响 | 接入方案 | 可行性 | 风险 | 用例 | 核验结果 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| INP-01 | `BO/scripts/online_player_slot_manager.gd:7`、`:752`、`:312-313` | `MAX_REMOTE_PLAYERS=3`，失败返回 -1 被忽略 | 放开会话上限后，没有槽位的成员每收到一个包就触发整表重同步 | 覆盖 `_add_remote_steam_id`；同时修正会话侧重同步触发条件；安装时机见 INP-M02 | 覆盖方法；高；需实测 | F01、F02、F18 | T01、T02 | 已纠正（不改 BO 时第 4 名进不了房；补充重同步风暴） |
| INP-02 | `res://singletons/coop_service.gd:156`；`res://main.gd:215-219`；`res://ui/menus/run/character_selection.gd:410-419` | get_max_players=4 同时限制本地加入、远程占位，并决定 UI 节点遍历 | 全局改 8 会访问不存在的节点 | 不全局覆盖；覆盖 `_add_remote_steam_id`；会话容量由 MAX_LOBBY_MEMBERS 与 get_session_member_count 决定 | 覆盖方法；高 | F01、F04 | T01、T02、T04 | 已纠正（get_node 在 main.gd:217；`get_available_remote_slot_count` 无调用者，覆盖无效） |
| INP-03 | `BO/scripts/online_player_slot_manager.gd:14`、`:1182`、`:1271`、`:1282`、`:537-541`、`:567-569` | 占位池 6 个且与实体手柄号重叠；Host 耗尽不建槽；客户端只有耗尽项恰为最后一项才提交少一人的布局，否则整体放弃并被周期守卫写回旧镜像 | 8 人必然不够；7 人时第 6 个占位为 0 | 覆盖三个池方法改用扩展编号池（16 起）；覆盖 `apply_host_selection_layout` 先校验容量再整体拒绝 | 覆盖方法；高 | F01、F02 | T01、T02、T10 | 已纠正（客户端耗尽行为；截断时 RunData 已同步为较小人数） |
| INP-04 | `res://singletons/input_service.gd:252`、`:237` | 设备 0 的动作同时绑定本机键盘（device 0）与物理手柄 0 | 7 人局第 6 名远程用 0，本机输入驱动远程角色 | 扩展池排除 0 以及 1～7 | 覆盖方法；高；需实测 | F02 | T02、T18 | 确认 |
| INP-05 | `res://singletons/input_service.gd:235`、`:321` | 每设备动作只为 0～7 生成（`REMAP_END=8` 只被 `_copy_device_actions` 读取） | 新虚拟号没有动作，移动、瞄准、暂停、菜单查询失效或报错 | 覆盖 `_copy_device_actions`：super 后为扩展虚拟号添加无实体事件的动作并复制 deadzone；不用 device=-1 | 覆盖方法；高；需实测 | F02、F18 | T02、T17、T18 | 确认 |
| INP-06 | `res://singletons/coop_service.gd:367-379`；`res://singletons/input_service.gd:212` | 拔手柄时按设备号删 connected_players；回显合成也按设备号 | 占位 1～5 与实体号重叠，可能被实体手柄驱动或删除 | 虚拟池从 16 起（Godot 3 实体手柄上限 16）；可再覆盖 `_on_Input_joy_connection_changed` 忽略虚拟号 | 覆盖方法；中；需实测 | F03、F11 | T02、T03、T11 | 确认 |
| INP-07 | `BO/scripts/online_input_manager.gd:129`、`:163`；`res://global/entity_spawner.gd:105` | 远程输入每帧 `Input.action_press` 注入；移动 device 出生时缓存 | 锁定期间设备号由快照保持，失配主要来自扩展自己在局中改号 | 设备号按 peer_key 稳定分配（16+稳定槽号）；注入逻辑不改 | 覆盖方法；中；需实测 | F03、F11 | T08、T09、T11 | 已纠正（:1098、:1142 受锁定限制，局中不执行） |
| INP-08 | `res://singletons/utils.gd:657` | FocusEmulator 按名称查找，合作场景只有 1～4 | P5～P8 得到 null，`focus_player_control` 出错 | 在 `_enter_tree` 或用 append_node_in_scene 补 FocusEmulator5～8，`set_script(load(...))` 获得扩展链 | 场景扩展；高 | F04 | T04、T05 | 已纠正（menu_sync:3737 只用于背包弹窗；子类 `_ready` 晚于父类，应在 `_enter_tree` 注入） |
| INP-09 | `res://singletons/coop_service.gd:203`；`res://singletons/coop_service.tscn:66` | player_colors 只有 4 色，get_player_color 无边界检查 | 战斗中 player.gd:902、HUD、炮台、宠物和各菜单都越界；character_panel_ui.gd:159-160 直接下标读 | 运行时把数组补到 8 色（mod_main._ready 或 CoopService 子类 `_ready`），只覆盖方法不够 | 数据补丁；高 | F04 | T04 | 已纠正（影响面扩大到战斗；只覆盖 get_player_color 不够） |
| INP-10 | `res://singletons/utils.gd:814`、`:126` | `_manual_aim_cache` 4 项且每帧重置；BO 联机正常路径不读缓存 | 会话切换或离线 5 人以上时越界 | 链在 BO 之后覆盖 `is_manual_aim`，调用前按需 resize | 覆盖方法；高；需实测 | F09 | T09、T12 | 确认 |
| INP-11 | `BO/scripts/online_player_slot_manager.gd:960` | 本机只接受实体手柄 0～5；物理手柄 7 进入键盘槽 | 一机一人下影响低 | 首版可不改；需要时覆盖 `_get_local_gamepad_entry_for_joypad` | 覆盖方法；中；需实测 | F03 | T03 | 确认 |
| INP-12 | `BO/mod_main.gd:332`；`CF/extensions/focus_emulator.gd:9` | 回调多级调用；focus_emulator.gd、utils.gd 已被多个 Mod 扩展 | 只能覆盖普通方法；链序需要声明 | 依赖 BO，用依赖关系固定与 CoopFix 的顺序；每个覆盖调父方法；启动校验继承链 | 覆盖方法；中；需实测 | F16、F17 | T16、T17 | 已纠正（受 INP-M02 时机约束；BO 自身 manifest 也只声明 ML 6.2.0） |
| INP-M01 | `BO/extensions/entity_spawner_online_player_count_guard.gd:81`、`:88`；`BO/extensions/main_safe_pool_exit.gd:88`；`BO/scripts/menu_sync_manager.gd:8015` | 三处 clamp(…,1,4) 后 `set_player_count(4,false)` | P5～P8 数据永久丢失（F01 的直接触发点） | 覆盖三处计数方法：entity_spawner、main 扩展链在 BO 之后，menu_sync_manager 扩展 | 覆盖方法；高 | F01 | T01、T06 | 核验新增 |
| INP-M02 | `BO/scripts/online_player_slot_manager.gd:15` | `const REMOTE_PLACEHOLDER_PLAYER_TYPE = CoopService.PlayerType.GAMEPAD_XBOX`；在 `_init` 扩展时，排序阶段编译此脚本时 CoopService 尚为 Nil | 槽位管理器可能整体加载失败，联机不可用 | 推迟到 CoopService 实例化后、BO `_ready` 前安装（load_before + 本扩展 `_ready` 中安装），或重设脚本；必须实测 | 覆盖方法；中；需实测 | F16、F17 | T16、T17 | 核验新增 |
| INP-M03 | `BO/scripts/player_identity_registry.gd:29` | 身份表拒绝 >4 人 | 5～8 人继续退回手动认领 | 覆盖 `load_metadata`，或在 manager 扩展中替换（SAVE-M01） | 覆盖方法；中；需实测 | F10、F13 | T10、T13 | 核验新增 |

### 2.3 MENU：菜单同步（Brotato Online）

| 编号 | 位置 | 现状 | 5～8 人影响 | 接入方案 | 可行性 | 风险 | 用例 | 核验结果 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| MENU-01 | `BO/scripts/menu_sync_manager.gd:8015`（经 8028，调用于 2592、2620） | `_get_online_coop_layout_player_count` clamp 到 4，商店开局前 set_player_count 截断 | 每次商店→战斗都丢掉 P5～P8 数据，Host 4 人、客户端 8 人分裂 | 扩展 menu_sync_manager.gd 覆盖该方法，返回 clamp(n,1,扩展上限) | 覆盖方法；高；需实测 | F01、F06 | T01、T06、T17 | 确认（resize 在 run_data.gd:291） |
| MENU-02 | `BO/scripts/menu_sync_manager.gd:2559`；`BO/scripts/session_manager.gd:2400-2402`、`:5015-5027` | 就绪屏障使用多套 roster：RunData、connected_players、session 远端 key（含断线槽）、原版 4 元素数组 | 不一致时提前开局、永不开局或每次等满超时 | 维护单一已提交 roster；覆盖 `_should_sync_shop_game_start`、`_maybe_emit_progression_options_processed_if_complete` 断言一致；session 侧覆盖 `_get_remote_ids_for_host_sync` | 覆盖方法；高；需实测 | F01、F06 | T01、T06、T09 | 已纠正（`_get_run_player_count` 共 18 处调用；重试波屏障同样含断线槽） |
| MENU-03 | `BO/scripts/menu_sync_manager.gd:5992` | `_set_node_array_value` 用写入值填充原版 4 元素数组 | 可伪造全员 Go；`_focused_shop_item` 被复制后 P5～P8 会操作别人的商品 | UI 扩展在 `_init` 把 base_shop 数组扩到 N；覆盖 `_set_node_array_value` 用中性默认值 | 覆盖方法；高；需实测 | F05、F06 | T05、T06 | 确认（存档恢复会整体替换数组，见 UI-M04） |
| MENU-04 | `BO/scripts/menu_sync_manager.gd:9579`、`:8119`、`:9796`、`:11103` | 选人页 `player_index % inventories.size()` | P5～P8 回绕到 P1～P4 的 Inventory，选人串位 | UI 扩展提供 N 个 Inventory；兜底覆盖这 4 个方法，越界即拒绝；原版 base_selection.gd:64、:278 也取模 | 覆盖方法；高；需实测 | F02、F04 | T02、T04 | 确认 |
| MENU-05 | `BO/scripts/menu_sync_manager.gd:7437`；`res://ui/menus/ingame/upgrades_ui.gd:34-36`、`:239-240` | 对 4 元素数组的越界守卫静默跳过 P5～P8 | 客户端在 P1～P4 选完就 emit options_processed；P5+ 收不到 upgrade_state | 扩展 upgrades_ui、base_selection 等：扩数组、覆盖 getter、补节点；menu_sync 覆盖完成判定 | 场景扩展；高；需实测 | F06、F07 | T04、T06、T07 | 已纠正（数组在 34-36；:7492 会继续调用越界 getter；父 `_ready` 不会被子类替换，子类只能幂等补完） |
| MENU-06 | `BO/scripts/menu_sync_manager.gd:7206` | 升级选择 hash 不中时按位置回退，不校验 level、state_key、reroll_count | 快速连点或迟到动作会消费新一轮卡片 | 覆盖 `_get_upgrade_data_from_select_action`、`_apply_progression_reroll_action`、`_apply_progression_item_box_action` | 覆盖方法；中；需实测 | F05、F08 | T05、T08 | 确认 |
| MENU-07 | `BO/scripts/menu_sync_manager.gd:7915`；`BO/scripts/session_manager.gd:232`、`:2643` | 按来源的单调 seq 判陈旧，不随重连重置 | 客户端进程重启后以同一 key 重连，其动作全部被丢弃 | 覆盖 `_is_stale_run_page_action`，或在 `receive_client_content_capability_from_hello` 后幂等清除该来源水位 | 覆盖方法；中；需实测 | F10 | T08、T10 | 已纠正（“分块使后包先到”不成立：菜单通道可靠有序） |
| MENU-08 | `BO/scripts/menu_sync_manager.gd:7875`；`BO/scripts/session_manager.gd:2734` | Host 信任包内 origin_steam_id 与 player_index | 任一客户端可冒充 Host 来源操作任意槽位 | 覆盖 `receive_run_page_action_sync`：强制 origin=from_steam_id 并校验槽映射 | 覆盖方法；高 | F05、F08 | T08 | 确认 |
| MENU-09 | `BO/scripts/menu_sync_manager.gd:6021`（另 2752、2871、3087、6184） | 客户端按任意 player_index 扩容 RunData | 迟到或错误包制造幽灵玩家 | 覆盖这 5 个方法，超出已提交 N 即丢弃 | 覆盖方法；高 | F01、F08 | T08 | 确认 |
| MENU-10 | `BO/scripts/session_manager.gd:5675`、`:82-84` | 开局 ack 1200ms、scene_ready 4500ms 超时后无条件推进 | 慢客户端被甩下；只要存在断线槽，每次开局等满约 5.7s | 覆盖 `_poll_host_game_start_sync`，使用扩展超时与“在线且在已提交 roster 中”的 id 集 | 覆盖方法；高；需实测 | F07、F09 | T07、T09 | 已纠正（等待是并发的，不随断线槽数叠加） |
| MENU-11 | `BO/scripts/menu_sync_manager.gd:8460` | shop/selection 状态没有 phase/wave 代次，只靠时间窗与 screen 比较 | 达不到 T08 旧代次拒绝；残余风险来自墙钟时间窗与跨来源中继 | 覆盖 `build_menu_scene_state`、`receive_menu_scene_state_from_host` 等附加阶段代次（阶段内保持不变，避免改变稳定 key） | 覆盖方法；中；需实测 | F07、F08 | T07、T08 | 已纠正（同一发送方报文可靠有序，“必然被拉回”高估） |
| MENU-12 | `res://global/stats_manager.gd:10-11` | 炮台/宠物重算队列 4 个 | P5～P8 入队越界 | 扩展 stats_manager.gd，在 `_init` 扩容（链在 BO 之后） | 覆盖方法；高；需实测 | F01 | T01 | 确认（BO 显式调用父 `_physics_process`，原版每帧可能执行两次） |
| MENU-13 | `BO/scripts/session_manager.gd:7438` | 发送队列合并 shop_reroll | 连按两次只执行一次，且重随被移到排队的购买之后 | 覆盖 `_get_p2p_send_queue_coalesce_key`，对 shop_reroll 返回空 | 覆盖方法；中；需实测 | F05 | T05、T18 | 确认 |
| MENU-14 | `BO/scripts/menu_sync_manager.gd:7975`、`:6534-6560` | 去重表超过 256 条后线性裁剪；升级状态全员广播 | 8 人同时导航时开销 O(n)，升级报文总量 O(N²) | 覆盖 `_trim_processed_run_page_actions`、`_queue_progression_state_if_changed` | 覆盖方法；中；需实测 | F18 | T18 | 确认 |
| MENU-15 | `BO/scripts/menu_sync_manager.gd:9374`；`BO/scripts/session_manager.gd:6940-6986` | 选人阶段每 250ms 为每个客户端重建 setup，武器目录不缓存 | 构建成本约为客户端数×玩家数 | 覆盖 `_build_host_catalog_for_screen` 为武器页加缓存 | 覆盖方法；低；需实测 | F18 | T18 | 确认 |
| MENU-16 | `BO/mod_main.gd:332` | menu_sync 由 load()+set_script 创建；CoopFix 读其 `_last_state_from_host`，API 调 `_find_progression_ui` | 必须保持私有字段名与结构 | 依赖 BO；启动时 has_method 指纹检查，失败即关闭超四人；只追加字段 | 覆盖方法；高；需实测 | F16、F17 | T16、T17 | 确认 |
| MENU-17 | `BO/scripts/upgrade_runtime_sync.gd:77`、`:134-172` | 按网络数据 load() 资源，index 无上限补 null | 损坏或恶意 Host 可造成大量分配（与人数无关） | 覆盖 `apply_upgrade_effect_state` 过滤 index 与路径前缀（保留 res://dlcs/） | 覆盖方法；中 | F08 | T08 | 确认 |
| MENU-M01 | `BO/scripts/session_manager.gd:7087`、`:7157` | 商店 menu_scene_state 要求每人 shop_items ≥ NB_SHOP_ITEMS 才下发，否则静默 return | P5～P8 商店数据不完整时，所有客户端永远进不了商店 | UI 扩展为 P5～P8 提供 ShopItemsContainer 并扩 `_shop_items`；兜底覆盖 `_is_complete_shop_scene_transition_state` 记录原因并限时提示 | 场景扩展；高；需实测 | F06、F07 | T01、T06、T10 | 核验新增 |
| MENU-M02 | `res://ui/menus/ingame/upgrades_ui.gd:58` | `_ready`、`_process` 等多级调用，子类无法取代原版；原版 upgrades_ui._ready 在 index 4 越界 | 若靠覆盖回调改写原版循环，会重复 connect 或逻辑执行两次 | 覆盖原版循环调用的 getter；`_init` 扩容；子类 `_ready` 幂等补完（connect 前 is_connected） | 覆盖方法；高；需实测 | F04、F06 | T04、T16 | 核验新增 |
| MENU-M03 | `res://singletons/utils.gd:657` | 菜单同步按名称取 FocusEmulator1～4，P5～P8 被静默跳过 | P5～P8 没有菜单输入所有权，Host 看不到其焦点 | UI 扩展在各菜单场景创建 FocusEmulator5～8；自检 `get_focus_emulator(i)` 对 i<N 非空 | 场景扩展；高；需实测 | F02、F04 | T02、T04 | 核验新增 |
| MENU-M04 | `BO/scripts/session_manager.gd:59`、`:7620-7669`、`:7672-7680` | 全局队列每帧 1 块；game_start_prepare 与 commit 都对每个客户端携带完整 run_config | 开局延迟随人数线性增长，易触发 ack/ready 超时 | 整体重写 `_poll_pending_p2p_chunk_sends`，按目标轮转并设字节预算；`_slice_pool_byte_array` 改用 subarray | 覆盖方法；中；需实测 | F07、F18 | T07、T18 | 核验新增 |

### 2.4 BAT：战斗复制、生成与场景守卫

| 编号 | 位置 | 现状 | 5～8 人影响 | 接入方案 | 可行性 | 风险 | 用例 | 核验结果 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| BAT-01 | `BO/extensions/entity_spawner_online_player_count_guard.gd:81`、`:88`、`:101`、`:128-131` | 生成前把在线人数 clamp 到 4，并在原版 init 前后 set_player_count | P5～P8 PlayerRunData 永久删除，只生成 4 名玩家 | 扩展 `res://global/entity_spawner.gd`（链在 BO 之后），覆盖 `_brotato_online_get_authoritative_online_player_count`：先 super 保留快照恢复副作用，再按容量计算且不超过 players_data | 覆盖方法；高；需实测 | F01 | T01 | 确认（快照人数仍受槽位上限约束） |
| BAT-02 | `BO/extensions/main_safe_pool_exit.gd:88`、`:141-165` | players_spawned 时 queue_free 第 5 名起的玩家并再次截断 RunData | 修好 BAT-01 后 P5～P8 节点仍被销毁 | 扩展 `res://main.gd` 覆盖同名计数方法；信号回调本身不必覆盖 | 覆盖方法；高；需实测 | F01 | T01 | 确认 |
| BAT-03 | `res://main.gd:31-32`、`:48`、`:50` | 升级/箱子队列、死亡弹幕缓存、半血状态均为 4 项 | P5～P8 升级与箱子静默丢失，属性重算与死亡弹幕越界 | main 扩展 `_init` 中扩容，并为新增槽逐个赋新的 []、null、false | 覆盖方法；高；需实测 | F05 | T05 | 确认 |
| BAT-04 | `res://main.gd:879-889` | 金币与经验分配用局部 [0,0,0,0]，轮转按 get_player_count | release 下 P5～P8 份额丢失；debug 下整波分配中断 | main 扩展整函数覆盖 `on_gold_picked_up`，保留 BO 客户端清场分支（`BO/extensions/main_safe_pool_exit.gd:405-410`），不再调父方法 | 覆盖方法；高 | F05 | T05、T13 | 确认 |
| BAT-05 | `res://global/entity_spawner.gd:33`、`:40-41`、`:430`、`:556` | lootworms 与建筑/宠物生成队列各 4 个 | P5～P8 的炮台、地雷、宠物、Lootworm 失效 | entity_spawner 扩展 `_init` 扩到 8（BO 清理只清子数组，不改长度） | 覆盖方法；高 | F01 | T13 | 确认（连带问题见 BAT-M01） |
| BAT-06 | `res://global/entity_spawner.gd:93-99` | 出生点只有 2×2 四个位置 | P5～P8 与 P1～P4 重叠（视觉问题） | 覆盖 `spawn_entity`：PLAYER 且 player_index≥4 时改写 args.position | 覆盖方法；高 | F04 | T04、T13 | 确认 |
| BAT-07 | `res://main.gd:1383-1394`、`:215-223`、`:1416` | HUD 按 P1～P4 节点名硬连；died 等信号在同一循环里连接 | P5～P8 没有 HUD；debug 下 :1394 对 null 调用后中断，P5 起信号不连、尾部重置不执行 | main 扩展 `_enter_tree` 复制 P4 的 HUD/容器节点（设 owner 与 unique_name_in_owner），或场景扩展 | 场景扩展；高；需实测 | F04 | T04、T09 | 确认（中断点在 :1394；release 下信号能连上） |
| BAT-08 | `res://main.gd:471`；`res://singletons/run_data.gd:30` | `_players_die_args` 4 项，在判断全灭之前写入 | debug 下 P5～P8 最后阵亡时不进入 clean_up_room | 开局或 roster 确定后 resize，并填 `Utils.default_die_args` | 数据补丁；高；需实测 | F06、F09 | T09、T13 | 确认 |
| BAT-09 | `res://singletons/coop_service.gd:203`（`res://entities/units/player/player.gd:155` 调用） | 角色、炮台、宠物高亮查 4 色表 | P5～P8 高亮颜色缺失并报错，不阻断角色机制初始化 | 运行时追加颜色，时机在 mod_main._ready 或更晚（`_init` 时 CoopService 尚未实例化） | 数据补丁；高 | F04 | T04、T13 | 已纠正（调用在 player.gd:155；错误只中断当前函数） |
| BAT-10 | `res://singletons/debug_service.gd:175`、`:194` | log_run_info 默认参数为 4 元素数组 | 只缺 log 记录并输出错误，不阻断波次结束 | 覆盖 `log_run_info` 补齐参数（优先级低；release 下的崩溃风险见 DATA-M03） | 覆盖方法；高 | F18 | T06、T13 | 已纠正（不是 S1；尾部不执行的真正原因是 BAT-07） |
| BAT-11 | `BO/scripts/session_manager.gd:6316`、`:6324-6342` | 快照逐玩家变长编码，每 120ms 对每个远端单独发送 | 估算 Host 快照上行 4 人约 23 KB/s、8 人约 80 KB/s；停波页单包 10～25 KB | 不改协议；超预算时覆盖 `_build_progression_state_throttled`、`_poll_and_send_host_battle_snapshot` | 覆盖方法；中；需实测 | F18 | T08、T18 | 确认（带宽为估算） |
| BAT-12 | `BO/scripts/session_manager.gd:6245`、`:7636` | 可靠出生事件需全部远端成功才出队 | 实际瓶颈是全局每帧 1 条且可靠条目不过期，开波高峰积压可达秒级 | 覆盖 `_poll_pending_p2p_chunk_sends`；需要时改写 `_poll_and_send_host_battle_snapshot` 按对端排队 | 覆盖方法；中；需实测 | F08、F18 | T08、T18 | 已纠正（失败的可靠消息会入队并返回 true，“整批重发”不是主因） |
| BAT-13 | `BO/scripts/state_snapshot.gd:1396`、`:1424`、`:1696` | Boss/精英击杀与伤害声明优先采用客户端上报的 player_index | 击杀归属可错；越界值让 get_player_effect 越界 | 覆盖三个 apply_* 方法，用发送者映射改写 player_index | 覆盖方法；高 | F08、F10 | T13 | 确认（P5～P8 无映射时 apply_player_state 也信任上报值） |
| BAT-14 | `BO/scripts/battle_replica_manager.gd:4127-4140` | 推断不出自有槽位时回退为最后一名玩家 | 切场景窗口内任一客户端可能自认为 P8 | 覆盖 `_infer_owned_player_index_from_coop_layout` 返回 -1，并在换场景时清 `_cached_owned_player_index` | 覆盖方法；中；需实测 | F07 | T07 | 确认（:4130 写死设备号 7） |
| BAT-15 | `res://singletons/utils.gd:65`；`res://singletons/temp_stats.gd:5-6`；`res://singletons/linked_stats.gd:4`；`res://global/stats_manager.gd:10-11` | 战斗依赖的单例逐玩家数组都是 4 项 | P5～P8 的属性读取、重算、计时器全面越界 | 运行时 resize，并覆盖重建方法（`reset_stat_caches`、`_reset_per_wave_properties`）；StatsManager 在 `_init` 扩容 | 数据补丁；高；需实测 | F01 | T13 | 确认（漏列 tracked_item_effects 等，见 DATA-01） |
| BAT-16 | `BO/extensions/main_safe_pool_exit.gd:13` | Godot 3 回调多级调用；ModLoader 在 `_init` 期统一安装扩展 | 必须依赖 BO 才能排在其后；覆盖回调无法取消父逻辑 | 只覆盖普通方法；早期工作放 `_enter_tree` 或 `_init`；启动打印继承链 | 覆盖方法；高；需实测 | F17 | T17 | 确认（mod_main._init 时 ModLoader 之后的自动加载尚未实例化） |
| BAT-17 | `BO/extensions/jellyshield_safe_owner.gd:7` | 该扩展文件存在但从未安装 | 移除玩家后 Jellyshield 引用已释放的 Player | 扩展 jellyshield.gd：覆盖 init_trajectory；子类 `_physics_process` 先于原版执行，可先清空失效 owner | 覆盖方法；高 | F11 | T11 | 确认 |
| BAT-18 | `res://global/entity_spawner.gd:153`、`:172` | 敌人上限 ×(1+(n-1)/8) 慢于刷怪量 ×(1+0.3(n-1))；Host 剔除不同步 | 8 人剔除更多，客户端看到的敌人比 Host 多 | 必要时覆盖 `on_group_spawn_timing_reached`（只在 Host 生效）；平衡改动需确认 | 覆盖方法；中；需实测 | F18 | T18 | 确认 |
| BAT-19 | `BO/scripts/session_manager.gd:6544` | 客户端不校验快照中的 player_count | 某端被截断时没有任何告警 | 覆盖 `receive_battle_snapshot_from_host` 比较人数，不一致交给流程守卫 | 覆盖方法；高 | F01 | T01 | 确认 |
| BAT-20 | `BO/scripts/state_snapshot.gd:1517`、`:1474`、`:1748`；`BO/scripts/battle_replica_manager.gd:3268` | 按数组位置索引 get_players()，假设位置等于 player_index | 节点离树后 HP、位置、击杀来源错位 | 覆盖这 4 个方法按 player_index 查找 | 覆盖方法；中；需实测 | F11 | T11 | 确认（state_snapshot.gd:1337-1338 同类） |
| BAT-21 | `res://global/entity_spawner.gd:104-105` | 玩家生成要求 connected_players 覆盖全部槽位 | 设备池不足时 init 循环越界 | 在覆盖的计数方法中（super 完成快照恢复后）断言 connected_players≥players_data，并避免收缩 | 覆盖方法；高；需实测 | F01、F02 | T02 | 已纠正（不能在 init 覆盖的 super 之前断言） |
| BAT-22 | `BO/scripts/state_snapshot.gd:1480` | 拾取在各端本地进行，Host 校正经济与队列 | 依赖 BAT-03/04 扩容；客户端代理拾取水果有短暂副作用 | 可不改；需要时覆盖 on_consumable_picked_up 只做表现 | 覆盖方法；中；需实测 | F05 | T05、T13 | 确认 |
| BAT-M01 | `res://global/entity_spawner.gd:556`、`:547`、`:571-572` | StructureTimer 在 P5 越界中断，基础建筑标志永远不置位 | debug 下 P1～P4 的基础建筑每秒重复生成 | 与 BAT-05 相同，在 `_init` 扩容 | 覆盖方法；高；需实测 | F05、F18 | T13 | 核验新增 |
| BAT-M02 | `res://main.gd:539` | 持有死亡弹幕效果的 P5～P8 让 `_on_enemy_died` 越界 | debug 下所有击杀都不掉落 | BAT-03 扩容即可 | 覆盖方法；高；需实测 | F05 | T13 | 核验新增 |
| BAT-M03 | `res://ui/menus/ingame/upgrades_ui.gd:240` | 波末升级 UI 写死 4 个容器，show_options 越界 | debug 下全员升级被跳过；release 下 P5～P8 永远轮不到 | 扩展 upgrades_ui：`_init` 扩数组、`_enter_tree` 复制容器与 StatPopup、覆盖 `_get_player_container`、子类 `_ready` 补连接 | 场景扩展；高；需实测 | F05、F06 | T05、T06 | 核验新增 |
| BAT-M04 | `res://singletons/run_data.gd:268` | DLC 魅惑/计步数组每波重建为 4 | P5～P8 魅惑上限与计步加成失效 | 覆盖 `_reset_per_wave_properties`，super 后补齐 | 覆盖方法；高 | F15 | T13 | 核验新增 |
| BAT-M05 | `BO/scripts/state_snapshot.gd:1491` | Host 判定远端权威依赖槽位管理器字典 | 只追加 connected_players 时 Host 把 P5～P8 当本地玩家结算 | 走 `_add_remote_steam_id` 的字典注册路径并扩设备号（避开 6、7）；开局断言 1..N-1 都是远端 | 覆盖方法；高；需实测 | F02、F10 | T02 | 核验新增 |
| BAT-M06 | `BO/scripts/session_manager.gd:7330`、`:2898` | 每个对端重复 duplicate(true) 与 to_json 同一条消息 | 8 人时 Host 主线程序列化开销为 7 倍 | 覆盖 `_poll_and_send_host_battle_snapshot`，每 tick 只序列化一次，仍走原发送路径 | 覆盖方法；中；需实测 | F18 | T18 | 核验新增 |
| BAT-M07 | `BO/scripts/battle_replica_manager.gd:2107` | 客户端 Boss/精英击杀声明记在上报者名下 | 击杀归属取决于谁的本地模拟先结束 | 覆盖 `_on_host_local_entity_died`、`_send_entity_kill_claim`，按本地击杀者上报 | 覆盖方法；中；需实测 | F05 | T13 | 核验新增 |
| BAT-M08 | `res://main.gd:1363`；`res://global/my_camera.gd:143-157` | 共享镜头要框住全部玩家 | 8 人分散时长期最远缩放，可读性差 | 可选：覆盖 `_on_EntitySpawner_players_spawned` 后改 `_camera.targets`，做成设置项 | 覆盖方法；中；需实测 | F04 | T04 | 核验新增 |
| BAT-M09 | `res://main.gd:1394` | debug 与 release 模板的脚本错误语义不同 | BAT-07/08、BAT-M01～M03 的级联只在 debug 出现，release 多为静默丢数据 | 测试规范：确认模板类型，一律用数据断言 | 未知；高；需实测 | F18 | T01、T18 | 核验新增 |

### 2.5 DATA：局内数据与逐玩家数组

| 编号 | 位置 | 现状 | 5～8 人影响 | 接入方案 | 可行性 | 风险 | 用例 | 核验结果 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| DATA-01 | `res://singletons/run_data.gd:30`、`:148-154`、`:163-164`、`:193` | 11 个逐玩家数组固定 4 项，只有 3 个缓存有长度保护 | release 下越界读得 null、写入丢弃；对 null 调内建方法（如 :465 `.duplicate()`、:2032 `.has()`）可能崩溃 | 扩展 run_data.gd：实现按正确形态补项的容量函数（容器类补项不能是 null）；覆盖 set_player_count | 覆盖方法；高；需实测 | F01 | T01 | 已纠正（摘录在 :153-154；按 release 语义修正后果） |
| DATA-02 | `res://singletons/run_data.gd:268-269`、`:556`、`:606` | `_reset_per_wave_properties`、`reset`、`reset_run_caches` 重写为 4 项字面量 | 只补一次会在每波或每局缩回 | 覆盖这三个方法补齐；TempStats/LinkedStats/Utils 要在 `.reset()` 前补齐；只扩不缩 | 覆盖方法；高；需实测 | F01 | T01、T06 | 确认（reset(true) 内部会调用 add_stat 等） |
| DATA-03 | `res://singletons/run_data.gd:1829`、`:1839`；`res://singletons/progress_data_loader_v3.gd:390`、`:406`、`:603-613` | resume_from_state 采用存档长度；V3 反序列化总是生成 4 项 | 从磁盘继续时商店相关数组一定是 4 项；写入 P5+ 非空项时丢弃或崩溃 | 覆盖 resume_from_state（先按 state 人数补 TempStats 等）；超四人档走 AP-016 独立检查点 | 覆盖方法；高；需实测 | F13、F14 | T01、T13、T14 | 已纠正（V3 总是 4 项；release 下可能崩溃而不是中断保存） |
| DATA-04 | `res://singletons/temp_stats.gd:5-6`；`res://singletons/linked_stats.gd:4`、`:7-9` | 4 项；两个实例各有一份 | P5+ stats_updated 不发出；reset_player 对 null `.clear()` 可能崩溃 | 运行时 append `init_stats()`，在本扩展节点 `_ready` 以及 set_player_count、resume 之前补齐；不扩展 temp_stats.gd | 数据补丁；高；需实测 | F01 | T01、T18 | 已纠正（release 下不刷屏；测试改为断言长度） |
| DATA-05 | `res://singletons/utils.gd:462`、`:65` | `_stat_caches` 4 项，62 处属性读取经过它 | P5+ 时对 null 调 `.get()`，可能崩溃，否则丢失临时属性 | 运行时补到容量；扩展 utils.gd 覆盖 `reset_stat_caches` | 数据补丁；高；需实测 | F01 | T01、T17 | 已纠正（后果修正为可能崩溃） |
| DATA-06 | `res://singletons/utils.gd:126`、`:813` | `_manual_aim_cache` 每帧被重置为 4 项 | BO 在线路径绕开；原版路径在 release 下结果仍正确 | 覆盖 `is_manual_aim` 按需 resize（低优先级） | 覆盖方法；中；需实测 | F09 | T09 | 确认 |
| DATA-07 | `res://singletons/utils.gd:60`、`:653` | `last_elt_selected` 4 项且被 reset 重建 | debug 下结算新开局卡死；release 下丢失焦点记忆 | 覆盖 `reset_last_elt_selected` 生成 8 项，并补现有数组 | 覆盖方法；高 | F04 | T04 | 确认（见 GAP2-01） |
| DATA-08 | `res://singletons/coop_service.gd:203`；`res://singletons/coop_service.tscn:66` | 颜色表 4 色，游戏 18 个文件与 BO 2 个文件使用 | P5+ 颜色缺失 | 在扩展节点 `_ready` 整体替换为 8 色（前 4 色不变），色值按 AP-014 | 数据补丁；高 | F04、F16 | T04 | 确认（release 下越界得到 null 颜色，静默失败） |
| DATA-09 | `res://singletons/coop_service.gd:166-171`；`res://singletons/coop_service.tscn:35-37` | 合作缩放按 (n-1) 线性计算 | 8 人：敌数×3.1、敌 HP×3.1、敌伤害×1.56、人均材料 0.8775；数值安全 | 默认不改；需要时改数据并同步 `_initial_*` | 数据补丁；高；需实测 | F18 | T11、T18 | 已纠正（BO 只在非 main 场景提交移除；人数为 0 的除零窗口基本不存在） |
| DATA-10 | `res://global/entity_spawner.gd:153` | 同屏敌人上限增长慢于刷怪量 | 8 人剔除比例更高且剔除不掉落 | 默认不改；需要时覆盖 `init`，传入改过 max_enemies 的 wave_data 副本 | 覆盖方法；高；需实测 | F18 | T18 | 确认（8.0 是缩放分母，不是人数上限） |
| DATA-11 | `res://entities/units/unit/unit.gd:116`；`res://singletons/entity_service.gd:15`、`:42` | 跨玩家连乘、求和、平均的效果没有 4 人上限 | 8 人同类效果叠加偏离平衡 | 无需修改；如需封顶，评估 sum_all_player_effects 的全局影响 | 覆盖方法；中 | F18 | T15 | 确认（诅咒刷怪概率取平均，只有 HP 加成求和） |
| DATA-12 | `res://main.gd:879-880`、`:138` | 同 BAT-04 | release 下 P5～P8 份额丢失，全队收入少 (n-4)/n | 同 BAT-04；使用前对 `_next_gold_player` 取模 | 覆盖方法；高；需实测 | F05 | T01、T05、T11 | 已纠正（按 release 语义） |
| DATA-13 | `res://singletons/run_data.gd:533`；`res://singletons/entity_service.gd:16`、`:43`、`:69` | player_index 0 承载全局难度与事件效果（另有 item_service.gd:744 等） | 移除或重排槽位 0 会丢失全局难度 | 设计约束：SlotRegistry 规定槽位 0 不可移除 | 数据补丁（规则保证）；高；需实测 | F11 | T11 | 已纠正（行号；漏 item_service.gd:744 等读取；不需要上游改动） |
| DATA-14 | `res://singletons/run_data.gd:282-292` | set_player_count 是唯一扩容入口，resize 截断尾部；BO 以 clamp 值调用 | 8 人被截为 4 | 从源头覆盖 BO 计数方法（BAT-01/02）；set_player_count 覆盖只做补齐与兜底 | 覆盖方法；高；需实测 | F01 | T01 | 确认 |
| DATA-15 | `BO/scripts/player_removal_manager.gd:432` | 客户端 roster 重建时 locked_shop_items 写成 4 项 | 移除后仍≥5 人时，客户端商店越界（release 可能崩溃） | RunData 扩展覆盖 get/lock/unlock_player_shop_item 按需补齐（另见 GAP1-02） | 覆盖方法；高；需实测 | F11 | T11 | 确认 |
| DATA-16 | `res://dlcs/dlc_1/effect_behaviors/player/for_every_step_effect_behavior.gd:56`；`res://dlcs/dlc_1/effect_behaviors/enemy/charm_enemy_effect_behavior.gd:48`、`:79`、`:159` | DLC 计步与魅惑读写 4 项数组 | 计步与 smelly_feet 挑战失效；魅惑上限可能不生效 | 覆盖 `_reset_per_wave_properties`，并在 on_wave_start（main.gd:137）前补齐 | 覆盖方法；高；需实测 | F15 | T15 | 已纠正（release 下不刷屏；魅惑表现需实测） |
| DATA-17 | `res://addons/mod_loader/mod_loader.gd:180` | 扩展机制约束：多级回调、不能重声明父类成员、自动加载顺序、class_name 编译期绑定 | 决定所有数组修补的位置 | 三层方案：覆盖重建方法、扩展节点 `_ready` 首次补齐、高频 getter 按需补齐；依赖 BO | 场景扩展；中；需实测 | F17 | T17 | 确认（reload/take_over_path 在 script_extension.gd:113/:129） |
| DATA-18 | `res://singletons/utils.gd:657` | FocusEmulator 按名称查找，只有 1～4 | P5+ 菜单焦点无效 | 在场景中补 FocusEmulator5～8 | 场景扩展；高；需实测 | F04、F16 | T04 | 确认 |
| DATA-19 | `res://main.gd:31` 等 | 本区以外的逐玩家 4 项数组清单（main、entity_spawner、stats_manager、popup_manager、upgrades_ui、base_selection、base_shop、debug_service、player_gear_container） | 各处 P5+ 越界 | 由各对应区域按统一容量处理 | 数据补丁；高 | F01、F04 | T01、T04 | 已纠正（补漏：debug_service.gd:175、main.gd:777 lootworms、shop_items_by_player） |
| DATA-20 | `res://singletons/item_service.gd:100` 等 | 与人数无关的 3/4/8：物品品阶、商店格数、矩形四角、轮廓槽、`/8.0`、BAN_MAX_TOKEN、难度与事件波次 | 误改会破坏原逻辑 | 不修改；列入禁止误改清单并由检查脚本守护 | 不改；高 | F17 | — | 确认（可补 run_data.gd:663、base_shop.gd:884） |
| DATA-M01 | `res://singletons/utils.gd:462` | exe 中没有 GDScript 调试错误串，推断为 release 模板 | 越界不中断、不写日志；对 null 调内建方法可能崩溃；“日志无越界”的用例恒为真 | 测试改为数据断言；所有补齐在首次访问前完成 | 未知；中；需实测 | F18 | T01、T18 | 核验新增 |
| DATA-M02 | `res://singletons/run_data.gd:578` | reset_wave_caches 按数组长度（4）初始化每波缓存 | P5+ 移速减益与满血消耗品统计失效 | 覆盖 `reset_wave_caches`：先补齐（补 {} 或 []）再 super | 覆盖方法；高；需实测 | F01 | T01、T15 | 核验新增 |
| DATA-M03 | `res://singletons/debug_service.gd:175`、`:194` | log_run_info 在每波开始与结束都按人数访问 4 元素数组（非调试路径） | release 下对 null 调 `.size()` 可能崩溃 | 扩展 debug_service.gd 覆盖 log_run_info，补齐参数后 super，签名保持一致 | 覆盖方法；高；需实测 | F01 | T01 | 核验新增 |
| DATA-M04 | `BO/scripts/menu_sync_manager.gd:4761` | 客户端用 {} 扩容 tracked_item_effects | 追踪键缺失，每次触发 print 一行 | 先用 `init_tracked_effects()` 补齐；已有项缺键时合并，不覆盖 Host 值 | 数据补丁；中；需实测 | F01、F18 | T01 | 核验新增 |

### 2.6 UI：5～8 号玩家的界面

| 编号 | 位置 | 现状 | 5～8 人影响 | 接入方案 | 可行性 | 风险 | 用例 | 核验结果 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| UI-01 | `res://singletons/coop_service.gd:203`、`:39`；`res://singletons/coop_service.tscn:66`；`res://ui/menus/ingame/character_panel_ui.gd:159` | player_colors 4 项（场景值覆盖脚本默认），get_player_color 无边界；角色面板直接下标读 | P5～P8 所有着色缺失或出错 | 在 mod_main._ready（早于 CoopService._ready）幂等补到 8 项 | 数据补丁；高；需实测 | F04 | T04、T16 | 确认 |
| UI-02 | `res://ui/hud/player_ui_elements.gd:40` 等（coop_upgrades_ui_player_container.gd:30、coop_shop_player_container.gd:17、coop_player_label.gd:8） | 多个函数先取色再做功能初始化 | debug 下会连带跳过 HUD 数值、弹窗 player_index、编号文字；release 下只是颜色变黑 | 与 UI-01 一起解决 | 数据补丁；高；需实测 | F04 | T04 | 已纠正（连带跳过只在 debug 模板发生） |
| UI-03 | `res://singletons/coop_service.gd:204`；`res://ui/menus/global/focus_emulator.gd:114` | 颜色先做饱和度+0.5 变换；同控件多焦点叠框宽 4*focus_order | 新颜色须在变换后仍可区分；8 人共焦点最外圈约 28px | 按变换后效果选色并配合编号；`_draw` 多级调用压不掉原版叠框，接受或改用分开的 Inventory | 数据补丁；高；需实测 | F04 | T04 | 确认 |
| UI-04 | `CF/extensions/focus_emulator.gd:9` | `_ready`、`_enter_tree`、`_input`、`_process`、`_draw` 逐级调用，扩展无法屏蔽原版 | 原版回调遇到 index 4 的表现取决于模板 | `_init` 扩容；`_enter_tree` 注入节点并覆盖访问器；子类 `_ready` 补齐；子类回调中不写 `._ready()` | 覆盖方法；中；需实测 | F04 | T04、T17 | 已纠正（中断仅在 debug；base_selection._input 只在 cancel 时越界，逐事件越界的是 base_shop:226、weapon_selection:79） |
| UI-05 | `res://ui/menus/run/base_selection.gd:10-13`、`:48`、`:50`、`:152`、`:158-160` | 成员数组 4 项；`_ready` 用局部 did_set_focus | 未修 UI-06 时 debug 下在 :50 中断，P1～P4 也拿不到默认焦点；:152 越界使 5 人以上永远凑不齐“全员已选” | 扩展 base_selection（或子类）：`_init` 扩容；覆盖 `_get_panels`、`_get_inventory_containers`、`_set_base_ui_player_count` | 覆盖方法；高；需实测 | F04、F06 | T04、T06 | 已纠正（首个越界点 :50；补充 :152 与 UI-M02） |
| UI-06 | `res://ui/menus/run/base_end_run.gd:53-54`；`res://singletons/utils.gd:60`、`:653` | `last_elt_selected` 4 项 | debug 下结算“新开局”、武器与难度页“返回”卡死；release 下只丢上次选择 | 扩展 utils.gd 覆盖 `reset_last_elt_selected`，并在 mod_main._ready 中 resize 现有数组 | 覆盖方法；高；需实测 | F04、F06 | T04、T13 | 已纠正（卡死只在 debug） |
| UI-07 | `res://ui/menus/run/character_selection.gd:411`、`:18-25`、`:399`；`character_selection.tscn:201`、`:698` | 选人 Panel、LockedPanel、CoopJoinPanel、FocusEmulator 只有 1～4，排在一行 | P5～P8 无面板与焦点；面板行运行时可用约 1503px，放不下 8×370 | `_enter_tree` 实例化面板与 FocusEmulator5～8；覆盖 `_get_panels`、`_get_coop_join_panels`、`_get_locked_panels`；改两行；RunOptionsPanel 路径不变 | 覆盖方法；高；需实测 | F04 | T04、T16 | 已纠正（可用宽度约 1503px；需联动 get_max_players，见 UI-13） |
| UI-08 | `res://ui/menus/run/weapon_selection.gd:26`、`:79`；`weapon_selection.tscn:96`、`:171`、`:237` | 武器页 Panel、Inventory、FocusEmulator 1～4；列数=16/人数 | `_input:79` 每个事件越界；8 人每栏只有 2 列 | 注入 Panel5～8（复制 expand_indefinitely=false）、Inventory5～8（复制主题）、FocusEmulator5～8；覆盖访问器；场景与脚本路径保持不变 | 覆盖方法；高；需实测 | F04、F16 | T04、T16 | 已纠正（逐事件越界在 :79；:40-45 只影响无武器槽角色） |
| UI-09 | `res://ui/menus/shop/coop_shop.gd:94-114`、`:21`；`res://ui/menus/shop/base_shop.gd:8-20`、`:48`、`:304` | 商店 4 列各 480px；base_shop 12 个每人数组 4 项 | debug 下 base_shop._ready 在 :48 中断，所有人的商店初始化被跳过；Go 屏障永远不达成 | `_init` 扩容；覆盖 `_find_nodes`（幂等）注入容器、StatPopup、FocusEmulator5～8；覆盖 getter；2×4 布局 | 覆盖方法；高；需实测 | F04、F06 | T04、T05、T06 | 已纠正（首个越界在 :48、:304；存档恢复会撤销扩容，见 UI-M04） |
| UI-10 | `res://ui/menus/ingame/upgrades_ui.gd:15-22`、`:34-36`、`:50`、`:58`、`:240` | 升级/箱子 UI 4 个容器，`_ready` 用局部 stat_popups | debug 下 show_options 返回 null，Main 直接进商店，全员升级被跳过；release 下 P5～P8 被跳过 | `_enter_tree` 在 CoopUpgradesUI 下注入容器、StatPopup、FocusEmulator5～8；`_init` 扩数组；覆盖 `_get_player_container`；用 is_coop_ui 区分单人；main.gd:31-32 同步扩容 | 覆盖方法；高；需实测 | F05、F06 | T04、T05、T11 | 已纠正（结果是跳过升级，不是卡在升级阶段） |
| UI-11 | `res://ui/menus/run/coop_end_run.gd:24-26`、`:34`、`:53-57` | 结算页 PlayerContainer、ItemPopup、StatPopup、FocusEmulator 均为 1～4 | P5～P8 无结算内容；8 列放不下 | `_enter_tree` 注入；子类 `_ready` 追加到 onready 数组并补做 4～7 | 覆盖方法；高；需实测 | F04 | T04 | 确认 |
| UI-12 | `res://main.gd:1379-1421`；`res://main.tscn:307`、`:414`、`:896` | HUD 按名称查找 P1～P4 节点 | BO 先把出生玩家裁到 4（UI-M03）；修复后 debug 下在 :1394 中断 | 覆盖 BO 计数方法；`_enter_tree` 复制 HUD 节点并改名、设 owner；覆盖 `_on_EntitySpawner_players_spawned` 补数组并重排位置 | 覆盖方法；高；需实测 | F01、F04 | T04、T09 | 已纠正（遗漏 BO 截断；get_node 失败本身不中断） |
| UI-13 | `res://main.gd:215`；`res://singletons/coop_service.gd:156` | 若把 get_max_players 提到 8 而不注入节点，main._ready 对 null 调 hide | 战斗无法开始 | 容量扩展与 UI 节点注入同时发布，写入 AP-006/AP-010 接口约定 | 覆盖方法；高；需实测 | F01、F04 | T01、T04 | 确认 |
| UI-14 | `res://main.gd:1379` | `PlayerUIElements.new()` 等 class_name 引用在 main.gd 编译时绑定（排序阶段已编译） | 扩展 PlayerUIElements 预计不生效 | 在 main 扩展中 super 之后直接改 `_players_ui[i].hud_container` | 覆盖方法；中；需实测 | F17 | T04、T17 | 确认 |
| UI-15 | `res://ui/menus/global/carousel.gd:17`；`res://ui/menus/ingame/coop_player_selector.tscn:30-43` | 暂停菜单切换器只有 CoopPlayerLabel1～4，index 被夹到 3 | P5 暂停时标题显示 P4，数据却是 P5；无法切到 5～8 | 扩展 coop_player_selector.gd，在 `_enter_tree` 通过 `%Headings` 注入标签（颜色先扩） | 覆盖方法；高；需实测 | F04 | T04 | 已纠正（越界在 PopupManager 内部，init 循环继续，见 UI-16） |
| UI-16 | `res://ui/menus/global/popup_manager.gd:11-15` | 5 个每人数组 4 项 | P5～P8 物品与属性弹窗不出现 | 扩展 popup_manager.gd，在 `_init` 扩到 8 | 覆盖方法；高 | F04 | T04 | 确认 |
| UI-17 | `res://ui/menus/global/focus_emulator.gd:410`、`:684` | FocusEmulator 本身无人数上限；限制在场景节点数、同父约定、设备动作 0～7 | 新 emulator 必须是 FocusEmulator1 的兄弟并命名为 FocusEmulatorN | 仿 `BO/scripts/pause_focus_alias_manager.gd:118-130`：先设 focus_base_data（新建资源）与 player_index，再 add_child | 覆盖方法；高；需实测 | F02、F04 | T02、T04 | 确认 |
| UI-18 | `CF/mouse_router.gd:151` | CoopFix 联机时吞掉所有不在本机 FocusEmulator base 内的左键点击 | 新增的翻页、详情等控件在联机中点不动 | 新控件放进对应 base 或做成 Popup；必要时扩展 mouse_router.gd 覆盖 `_is_native_lobby_button` | 覆盖方法；高；需实测 | F16、F18 | T16、T18 | 确认 |
| UI-19 | `CF/ui_adapter.gd:57`、`:19` | CoopFix 每 0.15s 把商店锁定/禁用按钮改成 34x34 图标并控制可见性 | 窄列布局会闪动或溢出 | 布局预留两个 34x34 图标；不改这两个按钮；访问器支持 4～7 | 覆盖方法；高；需实测 | F16 | T04、T16 | 确认 |
| UI-20 | `res://addons/mod_loader/internal/script_extension.gd:21` | 同一父脚本的扩展按继承栈与 Mod 加载顺序成链 | 与 CoopFix 的先后决定 P5～P8 焦点与鼠标行为 | manifest：dependencies 写 BO，optional_dependencies 写 CoopFix；每个覆盖调 super；启动校验链序 | 覆盖方法；中；需实测 | F16、F17 | T16、T17 | 确认（importance 为 BO=2、CoopFix=1、扩展=0） |
| UI-21 | `BO/scripts/menu_sync_manager.gd:11321-11329` | BO 按脚本路径、方法名、属性名、固定节点路径访问 UI，越界一律静默跳过 | 改名、改路径或新建场景会让 BO 漏掉 P5～P8 | 只用 install_script_extension（保留 resource_path）；原地扩容；沿用 FocusEmulatorN、PanelN 命名 | 覆盖方法；高；需实测 | F16、F17 | T11、T16、T17 | 确认 |
| UI-22 | `BO/scripts/menu_sync_manager.gd:8015` | 同 MENU-01 | 进入商店或同步开局时截断为 4 | 同 MENU-01 | 覆盖方法；中；需实测 | F01 | T01、T04 | 确认（同类夹紧另见 UI-M03、UI-M09） |
| UI-23 | `BO/scripts/player_list_overlay.gd:667`、`:795` | BO 玩家列表按人数动态生成，8 行约 720px | 8 人可容纳；聊天头像只来自 RunData（选人后备路径固定返回 null） | 无需改 BO；P5～P8 头像依赖 RunData 槽位 | 数据补丁；高；需实测 | F04 | T04 | 已纠正（quick_chat_wheel.gd:478-479 后备返回 null，扩 `_player_characters` 对头像无效） |
| UI-24 | `res://ui/menus/shop/coop_shop_player_container.gd:101` 等 | 布局阈值只针对 2/3/4 人；属性容器最小 400x700，升级容器最小高 780 | 1920x1080 下 8 列或两行都放不下 | 各屏子类 `_ready` 按 AP-014 规则调整尺寸、缩放或分页 | 覆盖方法；高；需实测 | F04 | T04 | 确认 |
| UI-25 | `res://singletons/utils.gd:657` | 与其他 8 人 UI Mod 同时注入同名节点会撞名 | P5～P8 焦点与面板混乱 | 创建前 get_node_or_null 预检；识别已知同类 Mod 并阻止超四人开局 | 覆盖方法；中；需实测 | F16 | T16 | 确认 |
| UI-26 | `res://ui/menus/shop/coop_shop.tscn:24` | FocusEmulatorBaseData 用相对路径；% 唯一名依赖 owner | 为两行布局重新挂父会破坏 base 解析与 BO 的固定路径 | 优先不重挂父，新增第二行容器放 5～8；必须移动时在 `_ready` 之后重设 owner | 场景扩展；中；需实测 | F04、F17 | T04、T17 | 确认 |
| UI-M01 | `res://singletons/coop_service.gd:203` | 越界后果取决于模板：release 不中断，带 nil 继续执行 | 所有“中止→跳过”的推论只适用于 debug | 在原版代码执行前完成扩容与注入；事后补偿幂等；启动日志记录 `OS.is_debug_build()` | 覆盖方法；中；需实测 | F18 | T04、T17 | 核验新增 |
| UI-M02 | `res://ui/menus/run/character_selection.gd:436-438` | `RunData.add_item` 早于越界读 `_player_characters` | debug 下 P5～P8 每移动一次焦点就累加角色道具效果 | 扩展 character_selection.gd，在 `_init` 扩 `_player_characters` | 覆盖方法；高；需实测 | F05 | T04、T05 | 核验新增 |
| UI-M03 | `BO/extensions/main_safe_pool_exit.gd:88`、`:141-165` | BO 在原版之前把出生玩家裁到 4 | P5～P8 HUD 代码永远不执行 | 覆盖 BO 计数方法（与 BAT-02 同一处） | 覆盖方法；高；需实测 | F01 | T01、T04、T09 | 核验新增 |
| UI-M04 | `res://ui/menus/shop/base_shop.gd:106` | 从存档恢复商店时，6 个每人数组被存档中的 4 项数组整体替换 | 5 人以上继续回到商店时越界 | coop_shop 扩展 `_enter_tree` 中先补齐 `ProgressData.saved_run_state` 的这 6 个数组；或由存档模块保证 8 项 | 数据补丁；高；需实测 | F13、F14 | T04、T13、T14 | 核验新增 |
| UI-M05 | `CF/extensions/weapon_selection.gd:7`、`:11` | CoopFix 以 `_player_weapons.size()` 为界读取 `_has_player_selected` | 联机时 P5～P8 进入武器元素即在 CoopFix 层越界 | 在 `_init` 扩 `_has_player_selected` 等（UI-05） | 覆盖方法；高；需实测 | F16 | T04、T16 | 核验新增 |
| UI-M06 | `BO/extensions/coop_resume_player_identity.gd:3` | BO 注释称在 ModLoader 初始化期继承 coop_resume.gd 会让 Godot 3.7 过早解析 RunData | 计划扩展的同类 UI 脚本可能失效 | AP-005 逐个脚本做最小扩展冒烟；失败的改用 node_added 运行时绑定 | 未知；低；需实测 | F17 | T17 | 核验新增 |
| UI-M07 | `res://project.binary`（display/window/size） | 基准 1920x1080，stretch 2d/keep | 宽屏不增加逻辑宽度 | AP-014 布局按 1920x1080 逻辑坐标设计，在 1280x720 验证可读性 | 数据补丁；高 | F04 | T04 | 核验新增 |
| UI-M08 | `CF/extensions/focus_emulator.gd:4` | 在多级回调里显式调用 `._ready()` 会让原版执行两次 | 重复填货、重复 connect、重复注册弹窗 | 规范：多级回调中不调 super；代码审查检查 `._ready(` | 覆盖方法；高 | F06 | T17 | 核验新增 |
| UI-M09 | `BO/scripts/session_manager.gd:5` | 大厅上限常量 4，浏览器显示 n/4 并按 4 判满 | 公开大厅显示满员 | 覆盖全部读取方法（同 CAP-01） | 覆盖方法；中；需实测 | F01、F17 | T01、T04 | 核验新增 |

### 2.7 LIFE：Mod Loader 生命周期与扩展机制

| 编号 | 位置 | 现状 | 5～8 人影响 | 接入方案 | 可行性 | 风险 | 用例 | 核验结果 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| LIFE-01 | `res://addons/mod_loader/mod_loader.gd:235`、`:243`；`res://addons/mod_loader/internal/third_party/steam.gd:46` | Steam 版（profile steam.tres）只加载已订阅工坊条目，本地 mods 目录与 `--mods-path` 无效 | 扩展必须作为工坊条目发布，并在 8 台机器订阅 | 发布未公开工坊条目；握手时比对扩展版本与指纹 | 仅环境；高；需实测 | F15、F17 | T17 | 确认 |
| LIFE-02 | `res://addons/mod_loader/internal/third_party/steam.gd:73`、`:93` | 工坊路径=exe 目录上溯三级+workshop/content/<app_id>，app_id 读 exe 目录的 steam_data.json | 隔离实例布局不对就不加载任何 Mod | 测试目录布局并复制 steam_data.json；用 modloader.log 的工坊路径行核对 | 仅环境；高；需实测 | F15、F17 | T17 | 确认 |
| LIFE-03 | `res://singletons/crash_reporter.gd:57`、`:94` | 上次日志中任一 ERROR 行涉及 mods-unpacked，下次启动禁用全部 Mod（主菜单有提示，见 main_menu.gd:308-320） | 一台机器隔次启动没有 Mod | 扩展零 ERROR，错误消息不带 res://mods-unpacked 路径，提示用 push_warning；测试前清理日志；后续启动补报 | 仅环境；高；需实测 | F16、F17 | T16、T17、T18 | 已纠正（不是静默；被禁用的那次扩展无法自检） |
| LIFE-04 | `res://addons/mod_loader/internal/dependency.gd:108` | 加载顺序只按 importance 降序，排序不稳定 | 依赖 BO 可保证排在 BO 之后，但与 CoopFix 同级时顺序不定 | dependencies 写 BO，optional_dependencies 写 CoopFix；`_init` 自检 BO 在前且 is_active，否则不安装 | 数据补丁；高；需实测 | F16 | T16 | 确认（manifest 校验失败会丢掉依赖，见 LIFE-M-03） |
| LIFE-05 | `res://addons/mod_loader/api/mod.gd:35` | 初始化期 install_script_extension 只入队，所有 `_init` 之后统一排序应用；之后调用立即应用、不排序、不重载子类 | 必须在 `_init` 安装 | `_init` 安装；`_ready` 打印各层（用 extension_script_path 元数据区分） | 覆盖方法；高；需实测 | F17 | T17 | 已纠正（排序按根到父的继承路径字典序，不是深度优先） |
| LIFE-06 | `BO/mod_main.gd:332` | 扩展可以覆盖 BO scripts/ 下的 23 个管理器 | 路线 A 的关键依据 | `_init` 对 BO scripts/*.gd 安装；不要 extends BO 的 extensions/*.gd | 覆盖方法；高；需实测 | F17 | T01、T17 | 确认（host mod 列表在 session_manager.gd:950） |
| LIFE-07 | `BO/scripts/player_identity_manager.gd:3` | `const Registry = preload(...)` 在 manager 编译时绑定 | 同时扩展 manager 时，registry 扩展失效 | 只扩展 registry；或扩展 manager 并改写所有构造 registry 的方法 | 覆盖方法；中；需实测 | F10、F13 | T10 | 确认 |
| LIFE-08 | `BO/extensions/stats_manager_safe_queues.gd:10` | 虚回调在每层自动调用；BO 显式调用父回调使原版执行两次 | 覆盖回调无法屏蔽原版 4 人逻辑 | 覆盖回调内部调用的普通方法；必要时 set_process(false) 自行驱动 | 覆盖方法；中；需实测 | F06 | T17 | 确认 |
| LIFE-09 | `BO/extensions/entity_spawner_online_player_count_guard.gd:88` | 子类改不了父 const；`.method()` 只能调用直接父类 | 取消 BO 截断只能覆盖其辅助方法 | 覆盖 `_brotato_online_get_authoritative_online_player_count`；体内用 `.xxx()` 或 call 访问 BO 成员（见 LIFE-M-01） | 覆盖方法；高；需实测 | F01、F17 | T01、T17 | 确认 |
| LIFE-10 | `res://addons/mod_loader/internal/script_extension.gd:69` | 排序阶段提前编译 class_name 依赖链，`ClassName.new()` 一直指向原版 | 扩展 PlayerUIElements、PlayerRunData 不生效 | 改调用方（main.gd、run_data.gd），不改被创建的 class_name 类 | 覆盖方法；中；需实测 | F01、F17 | T04 | 确认（“约 167 个脚本”为静态估算） |
| LIFE-11 | `res://addons/mod_loader/internal/script_extension.gd:153` | `_reload_vanilla_child_classes_for` 遇到未挂载的 DLC 或 tests 子类时 load 失败并中止 | 已提前编译的子类可能拿不到扩展 | 直接扩展具体子类或调用方；运行时检查子类基类链 | 覆盖方法；中；需实测 | F15、F17 | T17 | 确认 |
| LIFE-12 | `res://singletons/progress_data.gd:451`、`:466-478` | DLC pck 在 ProgressData._ready 时挂载，晚于扩展安装；PC 上 DLC 可用只取决于 exe 旁有无 pck | DLC 脚本不能在 `_init` 扩展；晚装只影响此后加载的资源 | 优先修补基础游戏调用方；或连 ProgressData.ready 后晚装；或在 `_init` 自行 load_resource_pack（需实测） | 包装信号；高；需实测 | F15 | T15 | 已纠正（PC 不查 isDLCInstalled；补充提前挂载方案） |
| LIFE-13 | `res://addons/mod_loader/mod_loader.gd:357` | `_init` 时 ModLoader 之后的自动加载为 null；`_ready` 时它们已入树但未 `_ready` | `_init` 中不能读 CoopService、RunData | `_init` 只做安装与自检；`_ready` 查找 BO 节点与连接信号；存档或 DLC 相关挂 ProgressData.ready 或首帧 | 包装信号；中；需实测 | F17 | T17 | 确认 |
| LIFE-14 | `res://singletons/platforms/platform.gd:8` | CrashReporter、BugReporter、Platform、Keys、ModLoader 早于 Mod 加载，无法扩展 | 超四人存档隔离不能改 Platform | 扩展 progress_data.gd（与 BO 同链） | 仅环境；高 | F13、F14 | T13、T14 | 确认 |
| LIFE-15 | `res://singletons/platforms/steam.gd:37`、`:45-53` | restartAppIfNecessary 可能让进程退出；Steam 初始化失败不退出，但不加载任何工坊 Mod | 隔离实例可能被 Steam 重启，或没有 BO 与扩展 | 环境：steam_appid.txt、Steam 登录并订阅 | 仅环境；高；需实测 | F15、F17 | T17 | 确认 |
| LIFE-16 | `BO/scripts/player_identity_manager.gd:4` | 多实例共享 user:// 会互相覆盖日志、ML 配置与 BO 身份 | 同机 8 实例 installation_id 相同 | 测试框架为每个实例设置不同的 APPDATA（或 XDG_DATA_HOME） | 未知（测试环境）；高；需实测 | F10、F14 | T10、T14 | 确认 |
| LIFE-17 | `res://singletons/coop_service.gd:39`；`res://singletons/coop_service.tscn:66` | 场景保存的导出属性在 `_init` 之后写入，覆盖子脚本默认值 | 在 `_init` 中扩颜色无效 | 在 mod_main._ready 或子类 `_ready` 补齐 | 数据补丁；中；需实测 | F04 | T04 | 确认 |
| LIFE-18 | `res://addons/mod_loader/internal/file.gd:82` | zip 以 replace_files=false 挂载；同一 Mod 两份 zip 报 fatal 并导致下次禁用 | 不能用同路径文件覆盖原版或 BO 资源 | 场景改动在运行时完成（链顶 main.gd 扩展或 node_added）；不在 `_init`/overwrites.gd 预载 PackedScene；发布说明只订阅一个条目 | 场景扩展；高；需实测 | F16 | T16 | 已纠正（原方案会把原版脚本固化在场景里，见 LIFE-M-04） |
| LIFE-19 | `res://addons/mod_loader/resources/mod_manifest.gd:92` | compatible_* 与 incompatibilities 只解析不校验；ML 实为 6.3.0 | ML 不会拒绝版本不符或冲突组合 | 扩展自做版本、指纹、冲突检测（在 `_ready` 读，或读 mod_data 中的 manifest） | 数据补丁；高 | F16、F17 | T16、T17 | 确认 |
| LIFE-20 | `res://addons/mod_loader/internal/dependency.gd:44` | 依赖检查只看 is_loadable，不看用户配置的 is_active | BO 被停用时扩展仍会初始化 | `_init` 检查 BO 的 is_active 与加载位置，否则不安装任何扩展 | 数据补丁；高 | F16 | T16 | 确认 |
| LIFE-21 | `res://addons/mod_loader/resources/mod_manifest.gd:230` | default 配置的重置条件写反 | 只要文件存在，ML default 配置每次启动都被重置 | 扩展设置写自有 user:// 文件或非 default 名称配置 | 数据补丁；中；需实测 | F14 | T14 | 已纠正（不是“第二次起”，而是每次） |
| LIFE-22 | `BO/scripts/online_player_slot_manager.gd:179` | 信号按接收对象的 ObjectID 顺序派发，与 connect 先后无关 | 不能靠调整 connect 时机控制与 BO 的先后 | 控制对象创建时机，或覆盖 BO 处理方法并在 super 前后加逻辑 | 包装信号；中；需实测 | F03 | T02、T03 | 确认 |
| LIFE-23 | `res://addons/mod_loader/api/mod.gd:56` | Mod 脚本的 class_name 不注册；register_global_classes_from_array 会写 exe 目录 override.cfg | 依赖 class_name 会失效，override.cfg 会残留 | 不使用 class_name，按路径 preload/load；禁止调用该 API | 覆盖方法；中；需实测 | F17 | T17 | 确认 |
| LIFE-M-01 | `res://addons/mod_loader/internal/script_extension.gd:69`、`:113`、`:116` | 排序阶段扩展脚本以原版为父类编译；裸标识符访问 BO 新增成员报 Parse Error | 每次启动出 SCRIPT ERROR，CrashReporter 隔次禁用；扩展可能排在 BO 前或未安装 | 在 BO 也扩展的原版路径上只定义同名 func 和用 `.method()`；BO 成员用 get/set/call；签名与 BO 一致 | 覆盖方法；中；需实测 | F16、F17 | T16 | 核验新增 |
| LIFE-M-02 | `res://addons/mod_loader/internal/script_extension.gd:129` | take_over_path 后扩展脚本自身路径移出资源缓存 | 再 load/preload 扩展路径得到新副本；重复安装形成重复层 | 共享常量放在不作为扩展安装的普通脚本；用 extension_script_path 元数据判断；安装前去重 | 覆盖方法；中；需实测 | F06、F16 | T16 | 核验新增 |
| LIFE-M-03 | `res://addons/mod_loader/mod_loader.gd:122` | 打包或 manifest 出错时整机不加载任何 Mod，或依赖被静默清空 | 一台机器没有 BO，或扩展排到 BO 之前 | 发布前校验 zip 结构与 manifest 命名、版本格式；`_init` 检查自身 manifest.dependencies 含 BO | 仅环境；高；需实测 | F15、F17 | T16、T17 | 核验新增 |
| LIFE-M-04 | `res://addons/mod_loader/mod_loader.gd:330`、`:337`、`:351` | 在 overwrites.gd、`_init` 或 mod_main preload 中加载原版场景会固化原版 Script | 主场景脱离 BO 与扩展的继承链 | 场景改动在运行时完成；mod_main 不 preload 原版 PackedScene | 场景扩展；中；需实测 | F01、F04 | T04 | 核验新增 |

### 2.8 SAVE：存档、身份、重连与继续

| 编号 | 位置 | 现状 | 5～8 人影响 | 接入方案 | 可行性 | 风险 | 用例 | 核验结果 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| SAVE-01 | `res://singletons/progress_data_loader_v3.gd:390`、`:406`、`:231` | 读档把 locked_shop_items、shop_items 建成 4 项，再按存档长度写入 | debug 下整局读档失败、继续按钮消失；release 下得到 8 人 players_data 加 4 份商店数据 | 扩展 progress_data.gd 覆盖 `load_game_file`（须幂等，`_use_fallback_save` 会递归调用），用自有 loader 读隔离检查点 | 覆盖方法；高；需实测 | F13 | T13、T14 | 确认 |
| SAVE-02 | `res://singletons/progress_data_loader_v3.gd:603-613` | 写档同样把这两个数组固定为 4 项 | 任何 `ProgressData.save()`（含战斗中完成挑战）都会写坏 run_v3 | 覆盖 `save()`：扩展局先写隔离检查点，再临时换成占位调用 `.save()` 并恢复；复刻原版中止条件；以 has_run_state 为前提 | 覆盖方法；高；需实测 | F13、F14 | T01、T14 | 确认 |
| SAVE-03 | `res://singletons/progress_data.gd:875`、`:600-602` | `ProgressDataLoaderV3` 是 class_name，ProgressData 在扩展排序阶段已编译并绑定原脚本 | 扩展 loader 脚本对存读档无效 | 只扩展 progress_data.gd；子类 preload 自有 loader（以普通 extends 指向原 v3 路径，不作为扩展安装） | 覆盖方法；高；需实测 | F13、F17 | T13、T17 | 确认（置信度可提为高） |
| SAVE-04 | `res://singletons/progress_data_loader_v3.gd:50`；`res://singletons/progress_data.gd:22`、`:588-610` | 局内档只在商店检查点写入，所有路径汇聚到 `ProgressData.save()`（档位操作除外） | 拦截一个汇聚点即可隔离超四人状态 | 覆盖 `save()` 与 `reset_and_save_*`（先调父，保留 BO 重试守卫）；加载期间暂停作废逻辑 | 覆盖方法；高 | F13、F14 | T12、T13、T14 | 确认（备份文件名为 `<basename>_NN.json.bak`；漏 :731、:757、:769 的 save） |
| SAVE-05 | `res://singletons/progress_data.gd:226-258`、`:265-323`、`:1364-1375` | 档位重置、解锁、复制、统计绕过 save() 直接读写 run_v3 | 扩展检查点残留、被错误复制，或档位界面显示无进行中局 | 覆盖这四个方法，同步扩展检查点 | 覆盖方法；高 | F13、F14 | T13、T14 | 已纠正（摘录在 :315） |
| SAVE-06 | `res://singletons/progress_data_loader_v3.gd:518` | 先写 tmp，再 copy 覆盖主文件，不是原子提交；进度档与局内档无共同提交标识 | 中断后状态与身份可能不一致 | 自有提交协议：写 tmp→重读校验→A/B 槽位加代次；状态与身份同文件、同 checkpoint_id | 覆盖方法；高；需实测 | F14 | T12、T14 | 确认 |
| SAVE-07 | `res://singletons/progress_data_loader_v3.gd:204`、`:200` | run_v3 为空时备份回退误走进度档分支 | 坏档路径，与人数无关；无 run 备份时进度不合并 | 扩展检查点不依赖原版恢复链；只记录诊断，不改原版行为 | 覆盖方法；中；需实测 | F14 | T14 | 确认 |
| SAVE-08 | `BO/scripts/player_identity_manager.gd:362` | SAVE_PATH 只按档位 0 计算，身份侧车总绑定 run_v3_0.json | 非 0 档位继续时身份失配 | 扩展 manager 覆盖 `_checkpoint_key`（只对扩展局改 key） | 覆盖方法；高；需实测 | F10 | T10 | 确认 |
| SAVE-09 | `BO/scripts/player_identity_registry.gd:29` | load_metadata 拒绝超过 4 个槽位，退回手动分配 | 5～8 人继续没有身份校验 | 若同时扩展 manager：在 manager 扩展中覆盖 `prepare_resume_if_needed()`，换用自有 registry 子类；否则扩展 registry 的 load_metadata | 覆盖方法；高；需实测 | F10 | T10 | 已纠正（preload 绑定问题，见 SAVE-M01） |
| SAVE-10 | `BO/scripts/player_identity_manager.gd:365` | 身份侧车按 run_v3 文件内容哈希绑定 | 隔离检查点后身份写不出来，或因占位内容相同而串用 | 把身份嵌入同一检查点：覆盖 `load_saved_identity`、`persist_saved_identity`（含 accept_lan_identity、_try_commit 触发的路径）；占位写唯一 checkpoint_id | 覆盖方法；高；需实测 | F10、F14 | T10、T13、T14 | 确认（必须覆盖 persist_saved_identity） |
| SAVE-11 | `BO/scripts/session_manager.gd:791`；`BO/scripts/online_player_slot_manager.gd:14` | 继续流程受 4 人房间与 6 个占位设备号约束 | 8 人档无法完成身份提交 | 扩容由容量与输入区负责；存档侧在进入身份面板前预检容量 | 覆盖方法；高；需实测 | F02、F10 | T09、T10 | 已纠正（硬限制是占位池；MAX_REMOTE_PLAYERS 只限局中加入） |
| SAVE-12 | `BO/extensions/coop_resume_player_identity.gd:41` | 离线继续与原版继续只能由本地设备加入，get_max_players=4 | 8 人档停在继续界面 | manager 扩展覆盖 `_add_offline_button`、`_continue_offline`，人数>4 时禁用并提示 | 覆盖方法；高；需实测 | F09、F13 | T09、T12、T13 | 确认 |
| SAVE-13 | `BO/scripts/player_removal_manager.gd:432` | 客户端应用 roster 时 locked_shop_items 写成 4 项 | 移除后客户端商店越界 | 覆盖 `_apply_client_roster`，super 后按人数补齐 | 覆盖方法；高；需实测 | F11 | T11 | 确认 |
| SAVE-14 | `BO/extensions/main_safe_pool_exit.gd:431` | 每台客户端也写本机局内检查点 | 客户端卸载扩展后点继续会触发 SAVE-01 | 所有机器安装同一 ProgressData 扩展；能力协商拒绝未装扩展者 | 覆盖方法；高 | F13 | T13 | 确认 |
| SAVE-15 | `res://singletons/run_data.gd:1733` | 局内档没有人数或 schema 字段，人数由 players_data 长度推断 | 部分扩容时各数组长度不一致 | 自有 schema 记录 schema_version、扩展与适配版本、容量、人数、roster_revision、run_id；校验长度≥人数 | 覆盖方法；高 | F01、F14 | T01、T14 | 确认 |
| SAVE-16 | `res://singletons/progress_data.gd:536` | 每档位只有一个进行中局；新局第一次进商店前旧档仍被反复写回 | 可能同时出现两份可继续的局，或继续到过期的 8 人局 | run_v3 占位写 checkpoint_id，加载时匹配才有效；覆盖 `reset_and_save_*` 先调父 | 覆盖方法；中；需实测 | F13、F14 | T12、T13 | 确认 |
| SAVE-17 | `BO/scripts/player_identity_manager.gd:389`、`:38`、`:74` | BO 身份文件直接覆盖写，不按账号隔离 | 写入中断后 LAN 原玩家无法自证身份 | 扩展检查点自带身份段；可选对客户端凭据做原子写 | 覆盖方法；高 | F10、F14 | T10、T14 | 确认 |
| SAVE-18 | `res://ui/menus/shop/coop_resume.gd:92` | 继续界面按玩家索引取色 | 原版或离线继续轮到 P5 时越界 | 补 player_colors；超四人离线继续禁用（SAVE-12） | 数据补丁；高 | F04 | T04 | 确认 |
| SAVE-19 | `res://singletons/bug_reporter_input.gd:82-95` | 错误报告上传 SAVE_DIR 顶层 .json、.json.bak、.txt 与日志 | 身份数据若放顶层或嵌入 run_v3 会被上传 | 检查点放子目录且不用 run_v3_/save_v3_ 前缀；run_v3 只写 checkpoint_id；覆盖 get_current_save_object；日志不打印令牌与完整 Steam ID | 覆盖方法；高 | F14 | T14 | 已纠正（current_progress_data.json 不含附加键；8 人时该附件序列化越界） |
| SAVE-M01 | `BO/scripts/player_identity_manager.gd:3`、`:7` | 扩展 manager 会让其 const preload 在排序阶段绑定原版 registry 与 ResumeBridge | registry 扩展静默失效，8 人继续永远走手动 | 在 manager 扩展中覆盖 `prepare_resume_if_needed`、`bind_resume_scene`，改用自有子类（普通 extends，不作为扩展安装） | 覆盖方法；高；需实测 | F10、F17 | T10 | 核验新增 |
| SAVE-M02 | `BO/scripts/online_player_slot_manager.gd:14` | 占位池 6 个号，7 名远端时 apply_resume_identity_layout 返回 false；Steam 大厅以 4 创建 | 8 人继续卡在身份面板 | 容量与输入区覆盖池方法与建房；存档侧预检可用 id 数 | 覆盖方法；高；需实测 | F02、F10 | T02、T10 | 核验新增 |
| SAVE-M03 | `BO/scripts/player_identity_registry.gd:40` | JSON 数字读回为浮点，64 位 Steam ID 会丢精度 | 身份全部对不上或错配 | 自有 schema 中 Steam ID、installation_id、令牌哈希、checkpoint_id 一律存字符串并校验类型 | 覆盖方法；高 | F10、F14 | T01、T14 | 核验新增 |
| SAVE-M04 | `res://singletons/progress_data.gd:808`、`:239-258`、`:731`、`:757`、`:769`；`res://ui/menus/pages/main_menu.gd:93-94` | saved_run_state 会被部分清空、在内存中替换，或在加载完成前被保存 | 若按 players_data 长度判定扩展局，会复活已删局或误删检查点 | 以 has_run_state 为真作为扩展局前提；加载期间只透传父方法 | 覆盖方法；高；需实测 | F13、F14 | T13、T14 | 核验新增 |
| SAVE-M05 | `res://singletons/run_data.gd:1792` | resume_from_state 只恢复存档字段，不调整固定 4 项的缓存 | 继续后进商店或下一波时 P5～P8 越界 | 覆盖 resume_from_state、reset_run_caches、`_reset_per_wave_properties` 补齐 | 覆盖方法；中；需实测 | F01 | T01 | 核验新增 |
| SAVE-M06 | `BO/scripts/player_identity_manager.gd:411` | BO 继续身份面板固定 900x360 | 8 行身份选择时确认与取消按钮可能出屏 | 覆盖 `_build_panel`：super 后把玩家行放进 ScrollContainer 或按行数调整边距 | 覆盖方法；低；需实测 | F04 | T04 | 核验新增 |
| SAVE-M07 | `res://singletons/progress_data.gd:590` | 存档目录为 user://<steam_id>；Steam 云同步范围不在代码中 | 跨机时占位与扩展检查点可能只同步一方 | 保留 checkpoint_id 匹配作为安全网；文档提示 | 未知；低；需实测 | F14 | T14 | 核验新增 |

### 2.9 NET：网络协议、消息类型与 API

| 编号 | 位置 | 现状 | 5～8 人影响 | 接入方案 | 可行性 | 风险 | 用例 | 核验结果 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| NET-01 | `BO/scripts/session_manager.gd:5` | 同 CAP-01（10 个读取方法） | 5～8 人的首个阻断点 | 同 CAP-01；Host 本地第 5 人还受 CoopService 的 get_max_players 限制 | 覆盖方法；高；需实测 | F01 | T01、T13、T16 | 确认 |
| NET-02 | `BO/scripts/lan_transport.gd:9` | 同 CAP-05 | LAN 最多 4 人，客户端看不到 room_full | 覆盖 `start_host`，上限比“容量-1”留余量，准入仍由会话闸门控制 | 覆盖方法；高；需实测 | F01 | T01、T02 | 确认 |
| NET-03 | `BO/scripts/network_heartbeat.gd:164` | 同 CAP-16 | 同时断 4～7 人时客户端漏报 | 同 CAP-16 | 覆盖方法；高 | F09 | T04、T09 | 确认 |
| NET-04 | `BO/scripts/brotato_online_api.gd:144`、`:5` | 公开 API 的 bo_mod_message 可收发自定义消息，有时机、通道与丢弃约束 | 能做加入后的能力协商，但不能早于槽位分配 | 用独有 mod_id/route、可靠发送，超时判定未安装；数值收到后 int()；更早的能力信息走 hello 扩展 | 包装信号；高；需实测 | F08、F16、F17 | T08、T16、T17 | 确认（不可靠消息也可能进入不过期队列；Host 广播含断线槽） |
| NET-05 | `BO/scripts/brotato_online_api.gd:281` | meta 的来源字段取自包内 relay_from_steam_id，可伪造 | 能力协商、Host 身份、槽位归属可被冒充 | 覆盖 `receive_mod_message`：Host 无条件剥离中转字段；客户端只接受 Host 发来的中转 | 覆盖方法；高 | F08、F10 | T08、T10 | 已纠正（只需 relay_from_steam_id 即可伪造；客户端接受任何 Steam 会话） |
| NET-06 | `BO/scripts/session_manager.gd:2734`；`BO/scripts/menu_sync_manager.gd:7873-7887` | run_page_action 信任客户端 origin 与 player_index，不校验 action_id 前缀 | 可操作他人槽位；伪造高序号可永久阻断受害者的动作 | 覆盖 `_handle_run_page_action_sync`：强制 origin=发送者，校验前缀与槽映射（shop_items_resync_request 例外） | 覆盖方法；高 | F05、F08 | T05、T10 | 确认 |
| NET-07 | `BO/scripts/state_snapshot.gd:1396`、`:1424`、`:1696` | 击杀与伤害归属声明优先采用 player_index；遗留 damage_claim_batch 仍可对实体施加伤害 | 归属可伪造 | 覆盖三个 apply_*，或在 `_handle_p2p_message` 前置丢弃无发送方的遗留类型 | 覆盖方法；高 | F08、F10 | T08、T10 | 确认（player_hp_state 会校验映射，不是入口） |
| NET-08 | `BO/scripts/session_manager.gd:7388`、`:7373` | 发往保留但已断线 peer 的可靠消息无限进入应用层队列 | 队列、内存、CPU 随掉线人数和时长增长；重连者先收大量陈旧包 | 覆盖 `_send_p2p_json`：目标在保留列表但无连接时丢弃并返回 true，重连后靠全量同步 | 覆盖方法；中；需实测 | F08、F09、F18 | T09、T10、T18 | 已纠正（LAN 断线同样；纯 LAN 无 Steam 时见 NET-M03） |
| NET-09 | `BO/scripts/session_manager.gd:59`、`:7636` | 应用层发送队列全局每帧只发 1 条 | LAN 8 人大包开局易超时；分块的最新状态包可能饿死 | 覆盖 `_poll_pending_p2p_chunk_sends`，按 (peer, channel) 或字节预算发送，保持 FIFO | 覆盖方法；中；需实测 | F07、F18 | T07、T08、T18 | 确认 |
| NET-10 | `BO/scripts/session_manager.gd:7677` | 分块切片与重组逐字节循环，每个目标重复序列化 | 开局和进商店时主线程卡顿 | 覆盖 `_slice_pool_byte_array` 改用 `subarray(start, end-1)`，重组改 append_array；按轮缓存序列化结果 | 覆盖方法；中；需实测 | F18 | T18 | 确认 |
| NET-11 | `BO/scripts/session_manager.gd:4027` | battle_aim 回发给包括发送者在内的所有人；进度动作附带全员状态逐个广播 | 扇出 O(N²)，R=7 时 battle_aim 约 1470 条/秒 | 覆盖 broadcast_message（只对 battle_aim 排除发送者）；快照只序列化一次 | 覆盖方法；中；需实测 | F18 | T18 | 确认 |
| NET-12 | `BO/scripts/session_manager.gd:6316` | 快照中每人数组随人数增长；停波时完整进度队列走不可靠通道 | 停波包分片丢失概率上升，升级页延迟 | 先测量；必要时覆盖 `_build_progression_state` 只在变化时附带可见选项 | 覆盖方法；中；需实测 | F08、F18 | T08、T18 | 确认 |
| NET-13 | `BO/scripts/session_manager.gd:5349`、`:5428`、`:5675` | 难度与商店开局屏障把断线保留 peer 也算作必须确认的对象 | 有断线时每次开局等满约 5.7s；慢客户端超过 4.5s 被甩开 | 覆盖 `request_synced_shop_game_start`、`_on_host_difficulty_element_pressed`（super 后过滤 remote_ids）、`_commit_host_game_start`（改写截止时间） | 覆盖方法；高；需实测 | F06、F07、F09 | T06、T07、T09 | 已纠正（难度路径在 :5349；重试波确认屏障也含断线槽，见 NET-M02） |
| NET-14 | `BO/scripts/session_manager.gd:35-36` | Steam 接收预算 32/64 条；Host 菜单包解析两次 | 估算远低于预算 | 测出瓶颈再改 | 覆盖方法；中；需实测 | F18 | T18 | 已纠正（LAN 没有预算也不合并焦点，见 NET-M05） |
| NET-15 | `BO/scripts/session_manager.gd:2007`、`:3694-3702` | 协议门控只比 mod_version；Host 在 hello 前按大厅成员分配槽位 | 未装扩展的 BO 客户端可占用 P5+ 槽位 | 加入前：大厅元数据扩展键（容量>4 时可改 mod_version 标记）；hello 追加字段，Host 覆盖 `_accept_client_protocol` 检查 | 覆盖方法；高；需实测 | F17 | T13、T16、T17 | 已纠正（应覆盖 `_accept_client_protocol`；原版客户端进出会留下幽灵槽，见 NET-M04） |
| NET-16 | `BO/scripts/session_manager.gd:3044` | 不在已知列表中的 msg_type 跳过会话校验，在分发中被静默忽略 | 自定义消息类型需要自补校验 | 优先用 bo_mod_message；确需新类型时覆盖 `_is_known_online_message_type`、`_is_host_authoritative_message_type`、`_handle_p2p_message` | 覆盖方法；高 | F08、F16 | T08、T16 | 确认 |
| NET-17 | `BO/scripts/player_identity_manager.gd:34`、`:4-5` | LAN 身份取自 user://mod_data/six666-BrotatoOnline/client_identity.cfg 的 installation_id | 同机多实例共用目录时被拒为 duplicate_identity | 测试环境隔离 user://；或只在测试构建按参数生成 id | 覆盖方法；中；需实测 | F10 | T02、T10 | 已纠正（主文件路径；旧 cfg 只是回退） |
| NET-18 | `BO/scripts/online_player_slot_manager.gd:7`、`:463-476` | API 路由与 meta 依赖 device↔steam_id 映射 | 槽位区扩容前，发往 P5～P8 的 send_to_player 失败 | 由槽位区扩容；协商消息在 payload 中携带 peer key | 覆盖方法；高；需实测 | F02、F10 | T02、T10 | 确认 |
| NET-19 | `BO/mod_main.gd:332` | 网络脚本可被接管的前提：`_init` 安装、只覆盖普通方法 | 在 `_ready` 安装则无效 | 启动读取父类常量与关键方法作为上游指纹，不匹配就关闭超四人 | 覆盖方法；高；需实测 | F16、F17 | T16、T17 | 确认（CoopFix 依赖 API 的 is_online、owns_player、is_host 等成员） |
| NET-M01 | `BO/scripts/session_manager.gd:6993` | 选人阶段每 250ms 为每个远端重建完整 setup 并 to_json 去重；武器目录按人数构建且不缓存 | Host 开销约 O(R×N) | 覆盖 `_send_host_phase_messages_to_all` 共享构建，或覆盖 `_build_host_catalog_for_screen` 加缓存 | 覆盖方法；中；需实测 | F18 | T06、T18 | 核验新增 |
| NET-M02 | `BO/scripts/session_manager.gd:5022` | 重试波确认名单包含断线保留槽 | 每次重试都要等 15s 自动重试 | 覆盖 `_get_retry_wave_expected_ids`，super 后剔除断线远端 | 覆盖方法；高；需实测 | F09 | T06、T09 | 核验新增 |
| NET-M03 | `BO/scripts/session_manager.gd:7323` | 纯 LAN（无 Steam）时，断线 LAN peer 让可靠事件批次永远不被标记已发送 | 其余客户端看不到新敌人和事件 | 与 NET-08 同一处修正 | 覆盖方法；中；需实测 | F08、F09 | T08、T09 | 核验新增 |
| NET-M04 | `BO/scripts/session_manager.gd:2348` | 选人阶段离开 Steam 大厅的成员仍保留槽位 | 幽灵槽提前占满容量 | 覆盖 `_refresh_lobby_members`，仅在选人阶段清理离开且未发 hello 的 key | 覆盖方法；中；需实测 | F09、F11 | T01、T10、T13 | 核验新增 |
| NET-M05 | `BO/scripts/lan_transport.gd:161` | LAN 接收无每帧预算、不合并 menu_focus、每包解析两次 | 卡顿后追赶帧更长 | 先测量；需要时覆盖 `_on_transport_packet_received` 复用解析结果（保留 599-607 的发送者校验） | 覆盖方法；高；需实测 | F18 | T18 | 核验新增 |
| NET-M06 | `CF/mouse_router.gd:297` | CoopFix 依赖 BO API 私有方法与 session 私有字段 | 扩展 API 或 session 时删改成员会破坏 CoopFix | 不改签名、不删成员；T16 组合测试 | 覆盖方法；高；需实测 | F16 | T16 | 核验新增 |

### 2.10 GAP1：局中移除玩家与 roster 重映射（单轮）

| 编号 | 位置 | 现状 | 5～8 人影响 | 接入方案 | 可行性 | 风险 | 用例 | 核验结果 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| GAP1-01 | `BO/scripts/player_removal_manager.gd:164`、`:273-283` | `_select_array(pad=true)` 只补齐到源数组长度 | 源数组仍是原版 4 项时，8 人局移除后新索引 4～6 越界 | 首选 RunData 扩展先扩容；兜底覆盖 `_select_array` 补到容量并用合法默认值（init_tracked_effects、default_die_args） | 覆盖方法；高 | F11 | T01、T11 | 单轮 |
| GAP1-02 | `BO/scripts/player_removal_manager.gd:432` | 客户端 `_apply_client_roster` 把 locked_shop_items 写成 4 项 | ≥5 人时客户端商店 `_ready` 在 index 4 越界 | 覆盖 `_apply_client_roster`，super 后补齐（新场景 `_ready` 是延迟执行的） | 覆盖方法；高；需实测 | F11 | T04、T11 | 单轮 |
| GAP1-03 | `BO/scripts/menu_sync_manager.gd:4737`、`:4755-4767` | 客户端不按 kept 左移 RUN_ARRAYS 与 start_wave_state；tracked_item_effects 只按持有物合并 | 新 P3 的非持有键残留原 P3 计数 | 覆盖 `_apply_client_roster` 后重建 tracked_item_effects，或由 Host 附带 old→new 映射 | 覆盖方法；中；需实测 | F11 | T11 | 单轮 |
| GAP1-04 | `BO/scripts/player_removal_manager.gd:131` | `ui._get_player_container(index)` 没有越界保护 | 在升级界面移除 P5～P8 时每 100ms 报错，Host 不推进 | UI-10 扩展 8 个容器；覆盖 `_disable_removed_actors_and_rewards` 加长度保护 | 覆盖方法；高；需实测 | F09、F11 | T09、T11 | 单轮 |
| GAP1-05 | `BO/scripts/online_player_slot_manager.gd:14`、`:567-569`、`:1344-1367` | 占位池 6 个；客户端重建 roster 时不检查布局是否成功仍 set_player_count | 8 人局必然分配失败，设备与索引错位 | 覆盖三个池方法改用扩展编号；在 `_apply_client_roster` 覆盖中断言 connected_players 数量 | 覆盖方法；高；需实测 | F02、F11 | T02、T03 | 单轮 |
| GAP1-06 | `BO/scripts/player_identity_registry.gd:29`、`:79-87` | load_metadata 拒绝 >4；compact 遇到越界索引时静默清空全部槽位 | 持久化的超四人身份下次继续必被拒；身份表可能被清空 | 覆盖 load_metadata 与 compact（越界时保留原表并报告）；注意 preload 绑定时机 | 覆盖方法；高；需实测 | F10、F11 | T10、T14 | 单轮 |
| GAP1-07 | `BO/scripts/player_removal_manager.gd:69`、`:206-211` | Host 建房后 `_online_flow_started` 即为真，开局前踢人也会裁剪 saved_run_state | 无关的旧本地存档被删人并绑定错误身份 | 覆盖 `filter_saved_state`，只对带本局标识的检查点生效 | 覆盖方法；中；需实测 | F14 | T13、T14 | 单轮 |
| GAP1-08 | `BO/scripts/session_manager.gd:9694` | player_roster_commit 只广播一次没有确认；客户端应用时清空分块缓冲 | 连续移除两人时部分客户端永久停在旧 revision | 覆盖 `reset_after_player_roster_change` 保留 commit 分块；加扩展确认与重发 | 覆盖方法；中；需实测 | F08、F11 | T08、T11、T18 | 单轮 |
| GAP1-09 | `BO/scripts/player_removal_manager.gd:326` | `_finish_host_removal` 按数组位置而不是 player_index 重排商店状态 | 中间某玩家状态缺失时后续玩家错位 | 覆盖 `_finish_host_removal`，按 state.player_index 建映射 | 覆盖方法；中；需实测 | F11 | T11 | 单轮 |
| GAP1-10 | `res://singletons/run_data.gd:606` | RUN_ARRAYS 之外的单例逐玩家容器只 reset 或不处理 | duplicate_items_cache 回到 4 项；last_elt_selected 不左移 | 覆盖 reset_run_caches 与 Utils/TempStats/LinkedStats 的重建方法；Host 侧用 kept 左移 last_elt_selected | 覆盖方法；高 | F11 | T11 | 单轮 |
| GAP1-11 | `BO/scripts/player_removal_manager.gd:55` | can_kick_peer 不限场景；踢人是局内释放“离开后仍占名额”的唯一途径，释放的名额局内不能复用 | 断线保留与踢人之间没有自动超时 | 覆盖 `can_kick_peer` 按阶段收紧，并加断线超时提示 | 覆盖方法；高 | F09、F11 | T09、T11 | 单轮 |
| GAP1-12 | `res://main.gd:716`、`:879-889` | main 中已移除但尚未压缩期间，被移除者仍参与消耗品与金币分配 | 本波剩余收益约 1/8 流失 | main 扩展的分配函数跳过 is_player_removed 的索引（需先定产品规则） | 覆盖方法；中；需实测 | F05、F11 | T11 | 单轮 |
| GAP1-13 | `BO/scripts/player_removal_manager.gd:6` | RUN_ARRAYS、SAVE_ARRAYS 是 const，被父方法直接读取 | 扩展自有的逐玩家表无法纳入同一映射 | 覆盖 `_commit_host_removal` 记录 kept；在 `_reset_indexed_caches` 覆盖中左移自有表；覆盖 filter_saved_state 处理自有键 | 覆盖方法；高 | F11、F17 | T11、T17 | 单轮 |

### 2.11 GAP2：失败、重试波、胜利、结算与结算后新开一局（单轮）

| 编号 | 位置 | 现状 | 5～8 人影响 | 接入方案 | 可行性 | 风险 | 用例 | 核验结果 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| GAP2-01 | `res://ui/menus/run/base_end_run.gd:52-54` | “新开一局”先置 `_button_pressed` 闩锁，再写 `Utils.last_elt_selected[4]` | 5 人起 debug 下 Host 卡死在结算页；BO 的“返回大厅”也受同一闩锁 | 扩展 coop_end_run.gd 覆盖 `_on_NewRunButton_pressed` 先补数组；或 Utils 扩展；兜底覆盖 `_on_online_end_run_exit_pressed` | 覆盖方法；高；需实测 | F06、F12 | T06、T12 | 单轮 |
| GAP2-02 | `res://main.gd:471-472`、`:1416`；`BO/extensions/main_safe_pool_exit.gd:455` | 最后倒下的是 P5～P8 时，Host 原版 `_on_player_died` 与客户端 BO 分支都越界中止 | 不立即全灭结算，要等 WaveTimer；died 信号可能根本没连 | 运行时把 `_players_die_args` 补到 8；HUD 节点覆盖 P5～P8 | 数据补丁；高；需实测 | F06、F07 | T06、T07、T09 | 单轮 |
| GAP2-03 | `BO/extensions/entity_spawner_online_player_count_guard.gd:88` | 重试波不经过 MENU-01，但重载 main.tscn 时被战斗入口 clamp；start_wave_state 快照拍在截断之前 | 8 人重试后被截成 4，多次重试人数来回变化 | 覆盖两处 BO 计数方法与 menu_sync 计数方法 | 覆盖方法；高；需实测 | F01、F06 | T01、T06 | 单轮 |
| GAP2-04 | `BO/scripts/session_manager.gd:5022` | 重试确认名单取自 `_session_remote_peer_keys`（含断线保留槽） | 有人断线时全员确认永远不成立，固定等 15s 自动重试 | 覆盖 `_get_retry_wave_expected_ids` 剔除断线者 | 覆盖方法；高；需实测 | F06、F09 | T06、T07、T09 | 单轮 |
| GAP2-05 | `BO/scripts/online_player_slot_manager.gd:1098` | 新开一局后由每 500ms 的周期恢复重建已映射远端，不做容量检查；新成员仍受 4/3/6 限制；LAN 不强制同步 | 顺序可能与上一局不同；断线 key 被重建成占位 | 覆盖 `_handle_online_character_selection_restage_after_new_run`，按已提交顺序校正，清理断线 key，LAN 主动同步 | 覆盖方法；中；需实测 | F01、F09 | T06、T09 | 单轮 |
| GAP2-06 | `res://ui/menus/pages/menu_restart.gd:29`；`res://ui/menus/pages/menu_end_run.gd:29` | 暂停菜单“重新开始”与“结束本局”没有被 BO 拦截或同步 | 任一机器可单方面重开或结束，Host 会绕过开局屏障 | 扩展 ingame_main_menu.gd 覆盖 init，联机时隐藏或禁用这两个按钮（或只允许 Host） | 覆盖方法；高；需实测 | F06、F12 | T06、T09、T12 | 单轮 |
| GAP2-07 | `res://singletons/run_data.gd:556`、`:606`、`:264-270` | reset 与每波重置把逐玩家数组重建为 4 项 | 新开一局后第一次商店锁定越界 | 覆盖 reset、reset_run_caches、`_reset_per_wave_properties`、set_player_count 补齐（与 DATA-02 合并实现） | 覆盖方法；高 | F01 | T01、T06、T11 | 单轮 |
| GAP2-08 | `res://singletons/run_data.gd:1923` | 胜利时每台机器对全部角色执行 apply_run_won；带诅咒时读 `_stat_caches` 越界 | 中止后跳过 reset_and_save_new_run_state，胜利局仍可继续 | 补 Utils._stat_caches（DATA-05）；可选合并写盘 | 覆盖方法；中；需实测 | F14 | T06、T18 | 单轮 |
| GAP2-09 | `BO/scripts/session_manager.gd:5020` | 重试提示期间每次取确认名单都调用 `_refresh_lobby_members` | 15s 窗口内大量 Steam API 调用 | 覆盖 `_get_retry_wave_expected_ids` 在同一轮询内缓存 | 覆盖方法；中；需实测 | F18 | T18 | 单轮 |
| GAP2-10 | `res://main.gd:1071` | 胜利演出 yield 依赖 `_players` 与 RunData 人数一致 | 不一致只丢演出，结算计时器照常切场景 | 保证二者人数一致（GAP2-03） | 场景扩展；高 | F01 | T06 | 单轮 |

### 2.12 GAP3：二级菜单——难度/区域、暂停与选项、重试界面、加入提示（单轮）

| 编号 | 位置 | 现状 | 5～8 人影响 | 接入方案 | 可行性 | 风险 | 用例 | 核验结果 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| GAP3-01 | `res://ui/menus/run/difficulty_selection/difficulty_selection.gd:133` | 难度页只由 P1/Host 操作（enable_coop_panels=false，只有 FocusEmulator1），原版与 BO 都不会送入 4～7 | 只有扩展自己注入节点或让 `_get_panels` 返回 null 时才越界 | 不向难度页注入 P5～P8 节点；base_selection 扩展覆盖 `_get_panels` 时过滤 null，或只在 enable_coop_panels 时追加 | 覆盖方法；高；需实测 | F04 | T04 | 单轮 |
| GAP3-02 | `res://ui/menus/run/difficulty_selection/difficulty_selection.gd:62`、`:70` | 返回时逐人写 last_elt_selected[4..7] | debug 下 Host 卡在难度页；release 下 P5～P8 丢失上次选择 | Utils 扩展（DATA-07、UI-06） | 覆盖方法；高；需实测 | F04、F06 | T04 | 单轮 |
| GAP3-03 | `res://ui/menus/run/base_selection.gd:62-68` | 难度页为 P5～P8 安排初始焦点，对不存在的 FocusEmulator 调 set_deferred | debug 下父 `_ready` 中断并跳过 reset_last_elt_selected | 不注入节点；在 difficulty_selection 子类 `_ready` 补调 reset | 覆盖方法；中；需实测 | F04 | T04 | 单轮 |
| GAP3-04 | `res://ui/menus/run/difficulty_selection/difficulty_selection.gd:109` | effect.apply(0) 等读写与人数无关，或已按人数动态处理 | 5～8 人正确；不能把 apply(0) 改成逐人应用 | 无需覆盖 | 不改；高 | F01 | T04 | 单轮 |
| GAP3-05 | `res://ui/menus/ingame/pause_menu.gd:46` | 暂停所有者按 get_player_count 动态遍历，按设备动作判断 | 设备号唯一且动作已注册时，本机 P5～P8 能正确成为所有者 | 不需覆盖；保证设备号唯一（F02） | 数据补丁；高；需实测 | F02 | T04、T16 | 单轮 |
| GAP3-06 | `res://ui/menus/global/carousel.gd:17` | init(4..7) 时切换器被夹到索引 3 | 标题与数据不一致，切走后回不到 P5～P8 | 同 UI-15 | 覆盖方法；高；需实测 | F04 | T04 | 单轮 |
| GAP3-07 | `res://ui/menus/ingame/ingame_main_menu.gd:68` | 暂停菜单把同一弹窗注册到 0..N-1，PopupManager 只有 4 项 | P5～P8 暂停时看不到弹窗 | 同 UI-16 | 覆盖方法；高；需实测 | F04 | T04 | 单轮 |
| GAP3-08 | `res://ui/menus/global/focus_emulator.gd:386` | P5～P8 暂停时，暂停菜单与 BO 别名的焦点框按 4 色表取色 | 焦点框没有颜色 | 补 player_colors（UI-01） | 数据补丁；高；需实测 | F04 | T04 | 单轮 |
| GAP3-09 | `BO/scripts/pause_focus_alias_manager.gd:118` | BO 在战斗场景根下创建 FocusEmulator1 别名，player_index 为 -1 或暂停者 | 扩展若在 main 根下创建 FocusEmulator1，会让 BO 停止创建别名，选项页返回焦点出错 | 只在原版已有 1～4 的场景注入 5～8，同父同命名；按名查找时跳过带 brotato_online_pause_alias 元数据的节点 | 场景扩展；高；需实测 | F16 | T16 | 单轮 |
| GAP3-10 | `res://ui/menus/pages/menu_options.gd:110` | 选项页固定读 `Utils.get_focus_emulator(0)` | 战斗中依赖 BO 别名可正确显示；商店中按 P1 显示（原版同样） | 一般不改；可选覆盖 init 修正 LB/RB 图标 | 覆盖方法；高；需实测 | F04 | T04 | 单轮 |
| GAP3-11 | `res://ui/menus/ingame/retry_wave.tscn:33` | 重试波界面只有一个 FocusEmulator（P1），死因固定显示 P1 | 可用；焦点框颜色与死因都是 P1 的 | 不需覆盖；可选在 show 中显示本机死因 | 覆盖方法；高 | F04 | T04 | 单轮 |
| GAP3-12 | `res://ui/menus/run/character_selection.gd:540` | RunOptionsPanel 只在 FocusEmulator1 的 base 中，并断言只有 P1 能聚焦 | 若以 FocusEmulator1 为模板复制，P5～P8 可以改合作、无尽、区域等全局设置 | 新 FocusEmulator 的 base 只含 Inventory1（照 FocusEmulator2 的参数新建资源） | 场景扩展；高 | F04 | T04 | 单轮 |
| GAP3-13 | `res://ui/menus/run/coop_join_panel.gd:45` | CoopJoinPanel 在 `_ready` 时就按 player_index 取色 | 颜色未扩时注入面板即越界 | 先在 mod 初始化时补颜色，再实例化面板 | 数据补丁；高 | F04 | T04 | 单轮 |
| GAP3-14 | `res://ui/menus/run/coop_show_character_hint.gd:27`；`res://ui/menus/shop/coop_item_popup.gd:27` | 提示按人数读 connected_players；物品弹窗只为 2 人设横排 | connected_players 少于人数时越界；窄列下提示可能被裁切 | 保证 connected_players 与 RunData 同步；必要时在子类 `_ready` 替换提示容器 | 数据补丁；中；需实测 | F04 | T04 | 单轮 |
| GAP3-15 | `res://ui/menus/run/zone_selection_button.gd:6` | 区域选择相关脚本没有逐玩家数据，只有 P1/Host 能改区域 | 无影响 | 无需修改 | 不改；高 | — | — | 单轮 |
| GAP3-16 | `res://singletons/coop_service.gd:246` | 与人数无关的数字：input_style 4/5（Switch 握持）、Switch 人数 2、设备号 6/7、REMAP_END=8、调试设备 8～11、边框 4*focus_order 等 | 当作人数替换会破坏图标、设备映射或视觉 | 不覆盖、不替换 | 不改；高 | F17 | — | 单轮 |

### 2.13 GAP4：共享全局上限、放大效应与跨端一致性（单轮）

| 编号 | 位置 | 现状 | 5～8 人影响 | 接入方案 | 可行性 | 风险 | 用例 | 核验结果 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| GAP4-01 | `res://global/entity_spawner.gd:302`、`:18` | 建筑共享上限 MAX_STRUCTURES=100，超出后跨玩家随机拆除 | 8 人更早、更频繁触发，归属统计偏差 | 默认不改；若批准公平策略，覆盖 `spawn_entity_birth`（链在 BO 之后，只在 Host） | 覆盖方法；高；需实测 | F18 | T18 | 单轮 |
| GAP4-02 | `BO/scripts/state_snapshot.gd:193`、`:23` | Host 因上限拆除的建筑不下发，客户端也不执行上限 | 各端建筑集合发散，客户端建筑数无上限 | 方案 A：Host 记录拆除并用扩展消息下发（依赖 BO net_id 内部结构）；方案 B：客户端本地裁剪 | 覆盖方法；高；需实测 | F08、F18 | T08、T17、T18 | 单轮 |
| GAP4-03 | `res://main.gd:741`、`:22` | 金币共享上限 MAX_GOLDS=50，超出后并入随机一枚 | 总价值不变，但按拾取次数触发的效果变少 | 默认不改；加调试计数 | 覆盖方法；高；需实测 | F18 | T08、T18 | 单轮 |
| GAP4-04 | `res://main.gd:879` | 同 BAT-04 | 5 人起必然越界 | 同 BAT-04 | 覆盖方法；高 | F05 | T01、T05、T18 | 单轮 |
| GAP4-05 | `res://main.gd:716`、`:719-724` | share_coop_loot 是本机设置，用全局 randi；Host 停波整队校正只覆盖前 4 槽 | P5～P8 箱子队列越界且不被校正 | main `_ready` 后把 `_consumables_to_process`、`_upgrades_to_process` 扩到人数；可选同步该设置 | 数据补丁；高；需实测 | F05 | T01、T05、T08 | 单轮 |
| GAP4-06 | `BO/scripts/menu_sync_manager.gd:8927` | enemy_scaling 不在 run_config，客户端用本机设置计算敌人投射物伤害与速度 | 各玩家实际难度不同 | Host 下发该值，客户端在 main.gd:248 reset_cache 前写入；或开局前比对并阻止 | 数据补丁；高；需实测 | F15 | T01、T08、T15 | 单轮 |
| GAP4-07 | `res://singletons/sound_manager_parent.gd:6`、`:8` | 声音队列 16、播放器 12、每帧最多启动 1 个，全部共享 | 本机射击和受击声被远端声音挤掉 | 扩展武器射击行为或覆盖 sound_manager.play 让本机优先；不提高播放器数 | 覆盖方法；中；需实测 | F18 | T18 | 单轮 |
| GAP4-08 | `res://global/effects_manager.gd:85`、`:14` | 特效上限 100 由命中特效与拾取粒子共用；MAX_PICK_UP_EFFECTS 未被使用 | 饱和后本机反馈丢失 | 覆盖 `_on_unit_took_damage`，接近上限时优先保留本机特效 | 覆盖方法；高；需实测 | F18 | T18 | 单轮 |
| GAP4-09 | `res://entities/entity.gd:129`；`res://entities/entity.tscn:16-19` | 轮廓只有 4 个 shader 槽，assert 有一位偏差且 release 不执行 | 单个实体的轮廓数与人数无关 | 不改槽数；P5～P8 新颜色避开 BOOST/CURSE/CHARM/HIGHLIGHT/易伤色 | 场景扩展；高；需实测 | F04 | T04、T18 | 单轮 |
| GAP4-10 | `res://singletons/coop_service.gd:203`；`res://entities/structures/turret/turret.gd:27`、`:192` | 炮塔、宠物、玩家在 `_ready` 中必定查 4 色表 | P5～P8 一生成就越界 | 把 player_colors 补到 8 | 数据补丁；高 | F04 | T01、T04 | 单轮 |
| GAP4-11 | `res://visual_effects/fog_viewport.gd:68` | 雾波要求 players_data、get_player_count、main._players 三者等长 | 只放开一处 BO clamp 时每帧越界 | 两处 BO 计数方法用同一容量规则覆盖；可再覆盖 `_process` 做防御 | 覆盖方法；高；需实测 | F01、F18 | T01、T18 | 单轮 |
| GAP4-12 | `res://entities/units/unit/unit.gd:628` | 燃烧来源失效时随机选一名玩家作为归属，各端 RNG 独立 | 只造成本地统计差异，不影响 Host 经济 | 建议不改 | 未知；中；需实测 | F08 | T08 | 单轮 |
| GAP4-13 | `res://global/entity_spawner.gd:141`、`:20-21` | 敌人生成吞吐（每 3 帧 1～2 个）全局共享，不随人数缩放 | 8 人队列更长，敌人出场更晚 | 默认不改，先测量；:126 只遍历 4 个队列需按人数处理 | 覆盖方法；高；需实测 | F18 | T18 | 单轮 |
| GAP4-14 | `BO/scripts/session_manager.gd:6234`；`BO/scripts/state_snapshot.gd:2091` | 每个对端分别序列化；待发 birth 队列超过 384 时丢最旧，birth-only 实体没有补发 | 一个慢对端可能让所有客户端永久缺少实体 | 先测量；确认 BO 脚本可扩展后，评估按对端确认或在 8 人时设容量保护 | 未知；中；需实测 | F08、F18 | T08、T09、T18 | 单轮 |

## 3. 关键问题答复

每个答复后注明核验状态：确认、已纠正（括号内为纠正内容，答复已采用纠正后的事实），或单轮（缺口审计未独立核验）。

### 3.1 CAP

**Q1 哪些函数读取 `MAX_LOBBY_MEMBERS`、`MAX_CLIENTS`、`MAX_REMOTE_PLAYERS` 或 `CoopService.get_max_players()`，能否被子脚本覆盖？**

- `MAX_LOBBY_MEMBERS`（`BO/scripts/session_manager.gd:5`）只在 session_manager.gd 的 10 个实例方法中读取：`_sync_host_local_join_listening_state`:499、`_handle_transport_identity`:652（仅展示）、`_remote_connection_rejection_reason`:791、`get_lan_discovery_info`:1134/1142、`_publish_session_metadata`:1151/1155、`create_session`:1346/1349、`set_public_lobby_enabled`:1748、`_prepare_friends_only_lobby_for_invite`:1758、`_setup_lobby_data`:2230/2247、`_get_lobby_status_text`:8569。都能覆盖；常量不可重声明，必须整函数覆盖或 super 后修补。
- `MAX_CLIENTS` 只由 `BO/scripts/lan_transport.gd:43` 的 `start_host` 读取；`MAX_REMOTE_PLAYERS` 只由 `BO/scripts/online_player_slot_manager.gd:752` 的 `_add_remote_steam_id` 读取。
- `get_max_players()` 调用方：`res://singletons/coop_service.gd:356`、`res://main.gd:215`、`res://ui/menus/run/character_selection.gd:61/234/304/306/399/412/418/566`、`res://ui/menus/shop/coop_resume.gd:25`、`BO/scripts/online_player_slot_manager.gd:755/877`。DLC 与 CoopFix 不调用。它可被 CoopService 子脚本覆盖，但在 UI 节点就绪前不宜全局改成 8（main._ready 会访问不存在的节点）。
- 核验：确认（`_sync_host_local_join_listening_state` 的调用点是 484 与 2394；`_publish_session_metadata` 也可改为拦截 `_set_lobby_metadata_if_changed`，joinable 再逐个调用方处理）。

**Q2 `get_max_players()` 如何计算，谁调用它？**

- Switch 上返回 2，否则硬编码 4（`res://singletons/coop_service.gd:156-158`），无缓存，是普通实例方法。调用方见 Q1。另有独立口径 `UI_MAX_PLAYER_COUNT=4`（`res://singletons/coop_service.gd:53`），由 upgrades_ui.gd:47、base_selection.gd:112、coop_end_run.gd:34/53、coop_shop.gd:21 直接读取。
- 核验：确认（PS 分支的 ps_device_colors 也只有 4 项，只影响 PlayStation）。

**Q3 握手中有哪些协议/版本字段，能否加入扩展能力字段而不破坏原版客户端？**

- `NETWORK_PROTOCOL_VERSION="5.0.0"`（`BO/scripts/session_manager.gd:7`，浏览器副本 `BO/scripts/public_lobby_browser.gd:8`）在元数据 2239、加入前 2006-2007、hello 3281 与 3694-3702、LAN 发现 1136、浏览器 1169/1224、LAN 握手各消息中精确比较；`LAN_PROTOCOL_VERSION=3`（:10）；LAN 发现 `PROTOCOL_VERSION=1`（`BO/scripts/lan_discovery.gd:6`、:118）。另有独立可选格式：HOST_MODS/BLOCKLIST 格式 "1"（:11-18）、`content_capability.version=3`（`BO/scripts/menu_sync_manager.gd:9131`）、hello 的 `player_list_enabled`（:3770-3772）、`API_VERSION=1`（`BO/scripts/brotato_online_api.gd:7`、:222）。
- 可行：在 Steam 元数据、LAN 发现应答、hello、transport_identity 中追加可选键，或握手后用 bo_mod_message；`host_mods_payload` 已让客户端在加入前知道主机装了哪些 Mod。不可行：修改任何线上版本值，或新增 msg_type。
- 核验：确认（补充：被会话闸门拒绝的 Steam 成员，其 hello 在 `_handle_raw_p2p_packet:3483` 经 `_should_drop_p2p_message_for_session:3060` 就被丢弃，准入阶段读能力须覆盖丢弃函数；resume 待分配期间 bo_mod_message 被丢弃（:3713）；未知 msg_type 会跳过会话过滤（:3044-3045））。

### 3.2 INP

**Q1 远程玩家如何表示为输入设备，动作如何注入？**

- 每台机器把远程玩家记为 `CoopService.connected_players` 中的 `[device, GAMEPAD_XBOX]`，device 从 `[1,2,3,4,5,0]` 取第一个可用号（`BO/scripts/online_player_slot_manager.gd:14`、:762-765），客户端由 `apply_host_selection_layout` 按 Host 广播重建（:557-582）。只有 Host 注入战斗移动与瞄准：每个物理帧对 `button_move_*_<device>`、`analog_move_*_<device>`、`rjoy_*_<device>` 调用 `Input.action_press`（`BO/scripts/online_input_manager.gd:134-163`），不产生 InputEvent，300ms 无输入归零（:12、:125-127）。菜单操作由 menu_sync 直接设焦点并按 Host 结果回放（`BO/scripts/menu_sync_manager.gd:5651`），非本机 FocusEmulator 被关闭输入（:8108）。
- 核验：确认（`emit_signal("pressed")` 只用于背包弹窗按钮，menu_sync_manager.gd:3728-3737）。

**Q2 游戏接受什么范围的设备号？**

- 存储层任意 int 都可以（`res://singletons/coop_service.gd:317-322`）。约束来自 InputMap：每设备动作只为 0～7 生成（`res://singletons/input_service.gd:235-253`，`REMAP_END=8` 见 coop_service.gd:47）；0 与 7 和键盘共享；8～11 只在调试开关下有少量 ui 动作。多处查询没有 `has_action` 保护（如 `res://singletons/utils.gd:716`、`res://ui/menus/global/focus_emulator.gd:210`）。
- 核验：已纠正（没接物理手柄 0 时 6 号也“干净”，干净的号是 1～6 中当前未接对应物理手柄的那些；对不存在动作 `event.is_action_*` 在 Godot 3 中一定报错，`Input.get_vector` 是否报错需在本构建实测）。

**Q3 保留本机设备时能同时存在多少个远程虚拟设备？**

- 现有池最多 6 个，干净的只有 1～5，且本机每接一个 1～5 号手柄就少一个。Host 用键盘时：远程 1～5 干净，第 6 名用 0 会串位，第 7 名分不到。客户端同样需要 N-1 个占位。可行方案：虚拟号从 16 起（Godot 3 实体手柄上限 16），通过覆盖 `InputService._copy_device_actions` 注册无实体事件的完整动作集，覆盖槽位管理器的三个池方法与 `_add_remote_steam_id`，保持 vanilla 的本地加入上限。
- 核验：已纠正（客户端耗尽时只有耗尽项恰为最后一项才提交少一人的布局，否则整体放弃；不会在 entity_spawner.gd:105 越界，因为 RunData 已同步为较小人数；另需处理 INP-M01 的三处 clamp 与 INP-M02 的安装时机）。

**Q4 每玩家动作名如何构造，player_index≥4 时是否存在？**

- 动作名为基础动作加 `"_"+str(device)`（`res://singletons/input_service.gd:321`），按设备号而不是 player_index。按 player_index 定长、≥4 即失效的是：FocusEmulator1～4 节点名（`res://singletons/utils.gd:657`）、player_colors 4 色（coop_service.gd:203）、`Utils._manual_aim_cache`（utils.gd:66）。
- 核验：确认（补充：`Utils.last_elt_selected`、`_stat_caches`、main.gd 的 HUD 容器 1～4、BO 的 clamp(…,1,4) 也按 4 定长）。

### 3.3 MENU

**Q1 菜单层限制或截断人数的位置及调用方？**

- 唯一硬上限：`_get_online_coop_layout_player_count()` 返回 clamp(…,1,4)（`BO/scripts/menu_sync_manager.gd:8015`），经 `_force_run_player_count_to_online_coop_layout`（:8018-8031）调用 `RunData.set_player_count`，调用点在商店开局路径 :2592 与 :2620。隐式截断：多处对原版 4 元素数组的越界守卫（:7437、:7295、:7414、:10380-10384 等）与 4 处取模（:8119、:9579、:9796、:11103）。`max(4, n)` 只是最小填充；`set_player_count(player_index+1)` 在 5 处无上限扩容（:2752、:2871、:3087、:6021、:6184）。与人数无关：TierData 下标、诊断阈值、商店格数、P2P 通道号等。
- 核验：确认（补充：session 在商店场景状态下发前要求每人商品格完整，`BO/scripts/session_manager.gd:7087-7100`，见 MENU-M01）。

**Q2 各菜单动作由谁决定、是否去重、重复时如何处理？**

- 商店与升级动作统一为 `run_page_action_sync`，session 写入 origin 并把 action_id 设为“自身 id:进程内单调序号”（`BO/scripts/session_manager.gd:2641-2643`）；接收方先精确去重（`BO/scripts/menu_sync_manager.gd:766`），再按来源序号判陈旧（:767、:7904-7918）。购买由 Host 按 hash 优先校验后执行，失败私发全量纠正；Go 与锁定是期望状态语义，天然幂等（:2531、:2653）；升级选择 hash 不中时按位置回退（:7206）；角色与武器选择客户端 2000ms 去重、Host 按发送者槽映射（:616-642）；难度只由 Host 决定（:639-640）。
- 核验：确认（`_build_shop_action_delta_state` 返回全量的位置在 :2778-2785；shop_reroll 合并还会改变其与购买的先后，见 MENU-13）。

**Q3 就绪屏障按哪个 roster 判定全员就绪？**

- 角色/武器：Host 原版 BaseSelection 遍历 RunData 人数并检查 4 元素 `_has_player_selected`（`res://ui/menus/run/base_selection.gd:11`、:151-170）。商店 Go：`_should_sync_shop_game_start` 按 RunData 人数（`BO/scripts/menu_sync_manager.gd:2550-2564`），开局握手按 `_session_remote_peer_keys`（含断线保留槽，`BO/scripts/session_manager.gd:5646-5679`）。客户端升级完成：RunData 人数与 4 元素 `_player_is_choosing` 取交集（menu_sync_manager.gd:7427-7443）。布局 clamp 按 connected_players。5～8 人必须统一为一个已提交 roster。
- 核验：确认（补充：重试波屏障同样基于含断线槽的 key，session_manager.gd:5015-5027；商店入场还有完整性门槛 7087-7100）。

**Q4 场景/阶段切换如何发信号，是否有代次防旧包？**

- 角色/武器页由 Host 周期发送 host_character_setup / host_weapon_setup；难度、商店、战斗靠 menu_scene_state；进入战斗走 game_start_prepare → time_ack → commit → client_game_scene_ready，用 start_id 去重（`BO/scripts/session_manager.gd:5294-5460`、:5599-5915、:2683-2690）。会话级有 session_lobby_id 与 roster_revision（:2895-2912，`BO/scripts/player_removal_manager.gd:463-476`）。菜单阶段没有 run/phase/wave 代次，只靠固定时间窗（`BO/scripts/menu_sync_manager.gd:11-12` 等）与 screen 比较。
- 核验：已纠正（所有菜单报文以可靠方式走同一通道，非 latest_state 报文排在已排队报文之后（session_manager.gd:7360、:7848-7853），同一发送方的旧包不会越过新包；开局 pending 期间 Host 会抑制非 game 场景状态（:7121）；残余风险来自墙钟时间窗与跨来源中继）。

### 3.4 BAT

**Q1 战斗扩展中的人数钳制及其调用路径，能否覆盖？**

- 只有两处方法把人数夹到 4，都叫 `_brotato_online_get_authoritative_online_player_count`：`BO/extensions/entity_spawner_online_player_count_guard.gd:81/:88`（经 init 前后的 `_brotato_online_force_run_player_count` 调用 `RunData.set_player_count`，:101、:128-131）与 `BO/extensions/main_safe_pool_exit.gd:88`（players_spawned 时裁剪玩家节点并修 RunData，:141-165）。通过 self 动态派发，本扩展链在 BO 之后覆盖即可生效。与人数无关的数字（插值 clamp、掉落坐标、`res://entities/entity.gd:129` 的轮廓槽、entity_spawner.gd:153 的 `/8.0`、battle_replica_manager.gd:4130 的设备号 7）不要改。
- 核验：确认（补充：快照人数还受槽位管理器上限约束）。

**Q2 快照如何编码玩家，8 人负载增长多少？**

- 快照全部按玩家变长：p 每人 9 个整数（`BO/scripts/session_manager.gd:6324-6342`），ec 每人 8 个字段（:6400-6420），pr 每人一个字典（`BO/scripts/state_snapshot.gd:1110-1140`）。每 120ms 对每个远端分别发送（session_manager.gd:70、:6222-6244）。估算 Host 快照上行 4 人约 23 KB/s、8 人约 80 KB/s；停波升级页 8 人单包约 10～25 KB。数值需实测。
- 核验：已纠正（可靠消息发送失败时会入队并返回 true，主要瓶颈是全局每帧只发 1 条且可靠条目不过期（:59、:7636、:7572-7577）；每个对端都要 duplicate 并 to_json 一次（:2898、:7328-7330））。

**Q3 玩家在哪生成、生成多少，出生点是否按 4 人设计？**

- 唯一生成点是 `EntitySpawner.init`（`res://global/entity_spawner.gd:91-114`，由 `res://main.gd:240` 调用），数量为 `RunData.get_player_count()`。每台机器在本地生成全部 N 名玩家。出生点是 2×2 公式（:93-99），索引 4～7 与 0～3 重合。逐玩家固定 4 的结构有 lootworms 与建筑/宠物队列（:33、:40-41）以及 main.gd 的数组。wave_manager 按人数动态循环。
- 核验：确认。

**Q4 战斗归属：伤害来源、拾取物、炮台/宠物的 owner？**

- 普通敌人只在出生时同步，各端本地模拟。Boss/精英的击杀与伤害声明优先采用客户端上报的 player_index（`BO/scripts/state_snapshot.gd:1396-1398`、:1424-1426）。掉落由 Host 预掷，拾取在各端本地，Host 用经济与进度快照校正（`BO/scripts/battle_replica_manager.gd:2803-2838`、:2894-2961）。炮台/宠物的 owner 就是实体的 player_index，Host 按 owner 入队（`res://global/entity_spawner.gd:531-572`），客户端按 Host 出生事件回放。
- 核验：已纠正（`apply_player_state` 只在映射存在时校验（state_snapshot.gd:1491），P5～P8 无映射时信任上报值；Host 是否把代理当客户端权威取决于槽位管理器字典（online_player_slot_manager.gd:455-460）；客户端击杀声明用的是上报者自己的槽位（battle_replica_manager.gd:2107），不是本地实际击杀者）。

### 3.5 DATA

**Q1 RunData 如何存储玩家，有哪些 ≤4 的假设？**

- `players_data` 是动态数组，`get_player_count()` 就是其长度；`set_player_count` 是唯一扩容入口并会截断尾部（`res://singletons/run_data.gd:282-292`）。与之平行的 11 个数组固定 4 项（:30、:148-154、:163-164、:193），并在 `_reset_per_wave_properties`（:268-269）、`reset`（:556）、`reset_run_caches`（:606）中被重写为 4 项字面量。TempStats、LinkedStats、Utils 的逐玩家数组也是 4 项。没有 range(4)、按 0～3 的 match 或 "p1" 字符串键。player_index 0 承载全局难度与事件效果。
- 核验：已纠正（从磁盘经 V3 加载时 locked_shop_items 与 shop_items 一定是 4 项，只有内存中的 start_wave_state 保留当前长度；漏列 `reset_wave_caches`（:577-596）、`log_run_info` 的 4 元素默认参数（`res://singletons/debug_service.gd:175`）以及 BO 用 {} 补 tracked_item_effects（`BO/scripts/menu_sync_manager.gd:4761-4762`）；release 模板下越界不中断，对 null 调方法可能崩溃）。

**Q2 合作缩放公式如何随人数变化，8 人是否数值安全？**

- 敌数系数 0.3、敌 HP 系数 0.3、敌伤害系数 0.08（`res://singletons/coop_service.tscn:35-37`），材料因子 0.8（`res://singletons/coop_service.gd:154`），全部按 (n-1) 线性，n=1 时提前返回，没有除零。8 人时敌数×3.1、敌 HP×3.1、敌伤害×1.56、同屏上限×1.875、每次掉落×2.265、总材料约为单人 7.02 倍、人均 0.8775（4 人为 0.895）。数值安全，但属于 4 人曲线外推，平衡需 OWNER 确认；同屏上限增长慢于刷怪量，被剔除的敌人不掉落。
- 核验：确认（附带风险降级：BO 只在非 main 场景提交移除，不会让本波系数缓存失效；人数为 0 的除零窗口基本不存在）。

**Q3 是否有按 player_index 索引的查找表？**

- 颜色表 `player_colors` 4 色（`res://singletons/coop_service.gd:39-44`、:202-206；场景值见 coop_service.tscn:66），游戏 18 个文件与 BO 2 个文件使用，`res://ui/menus/ingame/character_panel_ui.gd:159-160` 直接下标读。PS 手柄颜色 4 色只在 PlayStation 生效。名称 `COOP_PLAYER` 无上限。`_default_weapon_columns[人数-1]` 是按人数索引的 4 项表（`res://ui/menus/shop/player_gear_container.gd:10`、:44）。其余见 DATA-19 清单。
- 核验：已纠正（漏项：`log_run_info` 的 upgrades/consumables 默认参数（debug_service.gd:175、:194-195）、`shop_items_by_player[p_player_index]`、`res://main.gd:777` 的 `lootworms[player.player_index]`；`OS_Seaven.get_controller_style` 对 ≥4 的返回值待实测）。

### 3.6 UI

**Q1 哪些界面写死 4 个玩家面板，哪些动态生成？**

- 写死：角色选择（Panel/LockedPanel/CoopJoinPanel 1～4、FocusEmulator1～4，`res://ui/menus/run/character_selection.tscn:201`、:698）、武器选择（Panel/Inventory/FocusEmulator 1～4，`weapon_selection.tscn:96`、:171、:237）、合作商店（CoopShopPlayerContainer、StatPopup、FocusEmulator 1～4，`coop_shop.tscn:118-231`）、升级/箱子 UI（`coop_upgrades_ui.tscn:80-146`）、合作结算（`coop_end_run.tscn:158`、:233、:277）、战斗 HUD（`res://main.tscn:307`、:414、:896）、暂停菜单切换器（`coop_player_selector.tscn:30-43`）。难度页只有 FocusEmulator1，由 Host 操作。暂停菜单、重试波、继续界面用单个 FocusEmulator 或逐人轮流；BO 玩家列表与快捷聊天按人数动态生成。与人数无关的 4：每列 ShopItem1～4（商店格数）、升级选项数、焦点框矩形四角、强制商品数。
- 核验：确认（角色选择单行运行时可用宽度约 1503px，不是 1856px）。

**Q2 player_colors 的使用方与 index≥4 时的后果？**

- 使用方见 DATA Q3 与 UI-02。后果取决于模板：debug 下越界中止当前函数，调用方拿到 null 后常再次中止，会连带跳过 HUD 数值、弹窗归属、编号文字等初始化；release 下越界读到 nil，传给 Color 后变成黑色，函数继续执行，功能初始化正常完成。修复方式是在 mod_main._ready 幂等补到 8 色。
- 核验：已纠正（原答复把 debug 语义当成通用后果）。

**Q3 OnlineMouseUI 覆盖了什么，会不会与 8 人 UI 冲突？**

- CoopFix 扩展三个脚本（`CF/mod_main.gd:8-10`）：focus_emulator.gd（`_ready` 加组、`_handle_input`、`_is_coop_ui_action`、`_on_focus_changed`）、inventory.gd（`on_element_hovered`/`on_element_unhovered`）、weapon_selection.gd（`_on_element_focused`）。另由 MouseRouter 吞掉 base 之外的点击（`CF/mouse_router.gd:151`），ui_adapter 每 0.15s 改写商店锁定/禁用按钮（`CF/ui_adapter.gd:57`）。它本身没有 4 人常量。只要原地注入 FocusEmulator5～8、PanelN（同名、同父），访问器支持 4～7，场景与脚本路径不变，每个覆盖调 super，就不会硬冲突。冲突条件：base 外的新控件、改动锁定按钮、替换武器选择场景路径、链序错误、访问器不支持 4～7。
- 核验：已纠正（`_on_focus_changed` 的门控是“本机拥有且派发对象为空或等于自身”的与关系，CF/extensions/focus_emulator.gd:31-35；CoopFix 的 weapon_selection 扩展只用 `_player_weapons.size()` 做边界，`_has_player_selected` 必须同步扩容，见 UI-M05）。

**Q4 FocusEmulator 是否限于 4 人？**

- 本身不限：player_index 是导出变量，设备取 connected_players（`res://ui/menus/global/focus_emulator.gd:410-417`），按名称查找无上限（`res://singletons/utils.gd:656-657`）。实际限制是场景只有 1～4 个节点、跨玩家过滤只看同一父节点下的 emulator（focus_emulator.gd:363-368、:683-708）、设备动作只有 0～7、共享 Inventory 时叠框变宽。按 `BO/scripts/pause_focus_alias_manager.gd:118-130` 的方式创建 FocusEmulator5～8 即可。
- 核验：确认（容器类脚本按场景根下的 `FocusEmulator%s` 名称查找，命名与父节点位置都是硬约定）。

### 3.7 LIFE

**Q1 Mod 从哪里发现，CLI 参数是否有效，Steam 版用哪个 options profile？**

- Steam 版生效 profile 为 steam.tres（options.tres 的 feature_override_options 中 steam 键；project.binary 的 `_custom_features=steam`），`steam_workshop_enabled=true`、log_level=INFO。只走工坊分支：工坊目录由 exe 目录上溯三级再拼 `workshop/content/<app_id>`（`res://addons/mod_loader/internal/third_party/steam.gd:64-81`），只挂载已订阅条目的顶层 zip/pck（:46）。exe 目录的 mods/ 不读取。CLI：`--disable-mods`、`--configs-path`、日志级别参数有效；`--mods-path` 与 `--enable-mods` 在 Steam 版无效（`res://addons/mod_loader/mod_loader_store.gd:205-237`）。
- 核验：确认。

**Q2 加载顺序如何决定，依赖 BO 能否保证在 BO 之后？**

- 没有字母序排序。被依赖一次 importance+1，按 importance 降序做不稳定排序（`res://addons/mod_loader/internal/dependency.gd:24-65`、:108、:125-131），决定 `_init`、扩展链次序与 `_ready` 顺序。依赖 BO 通常能保证 BO 在前；与 CoopFix 同级时顺序不定，建议把 CoopFix 写进 optional_dependencies，顺序固定为 BO、CoopFix、扩展；BO 被用户配置停用时依赖检查不拦截。需要在 `_init` 自检。
- 核验：确认（补充：manifest 的 name、namespace 不合规或 version_number 不是 x.y.z 时，依赖会被静默清空，见 LIFE-M-03）。

**Q3 脚本扩展何时生效、如何成链，能否扩展 BO 的脚本，BO 管理器如何创建？**

- 初始化期调用只入队，所有 mod_main `_init` 后统一处理：排序、`child.reload()`（extends 解析到当前缓存，从而成链）、`take_over_path`（`res://addons/mod_loader/internal/script_extension.gd:94-131`）。可以扩展 BO 的 `scripts/*.gd`：BO 在 `_ready` 中按顺序用 load()+set_script 创建 23 个管理器（I18n、VersionAdapter、SessionManager、SteamTransport、LanTransport、NetworkHeartbeat、LanDiscovery、LobbyBrowser、OnlinePlayerSlotManager、PlayerIdentityManager、UpgradeRuntimeSync、MenuSyncManager、QuickChatWheel、OnlineInputManager、RuntimeLocator、ModSettingsManager、NetIdRegistry、StateSnapshot、BattleReplicaManager、API、PlayerRemovalManager、PlayerListOverlay、PauseFocusAliasManager，`BO/mod_main.gd:121-146`、:321-343），拿到的是链顶子脚本。BO 在 `_init` 中登记 12 个原版脚本扩展（:9-22）。
- 核验：已纠正（排序按根到父的继承路径数组做字典序比较，不是深度优先；`_reload_vanilla_child_classes_for` 遇到 DLC 或 tests 子类即中止；另见 LIFE-M-01 排序阶段以原版为父编译、LIFE-M-02 扩展自身路径移出缓存）。

**Q4 Steam restartAppIfNecessary、初始化失败、隔离实例、DLC pck 位置？**

- Platform 在 `_init` 中调用 `restartAppIfNecessary(1942280)`，为真时在进入场景树时退出；steamInitEx 失败不退出，但 `get_subscribed_mods` 返回空，不加载任何工坊 Mod（`res://singletons/platforms/steam.gd:33-63`、:146-150）。DLC pck 在 ProgressData._ready 从 exe 目录挂载（`res://singletons/progress_data.gd:447-457`）。隔离实例需要：正确目录深度、steam_data.json、BrotatoAbyssalTerrors.pck、steam_appid.txt、Steam 登录与订阅、每实例不同的 APPDATA。
- 核验：已纠正（PC 上 DLC 可用只取决于 exe 旁有无 pck，不查 isDLCInstalled（progress_data.gd:466-478）；restartAppIfNecessary 为真时 ModLoader._init 仍会执行）。

**Q5 Mod Loader 把日志和配置写到哪里？**

- user:// 为 %APPDATA%/Brotato。日志 `user://logs/modloader.log`（`res://addons/mod_loader/api/log.gd:6`）；用户配置 `user://mod_user_profiles.json`（api/profile.gd:9）；缓存 `user://mod_loader_cache.json`（internal/cache.gd:7）；Mod 配置 `user://configs/<mod_id>/`（internal/path.gd:9，不是 user://mod_configs）；只有 register_global_classes_from_array 会写 exe 目录 override.cfg。
- 核验：确认（default 配置的重置条件见 LIFE-21：只要文件存在就每次重置）。

### 3.8 SAVE

**Q1 游戏写哪些文件、何时写、每名玩家保存什么？**

- SAVE_DIR = `user://<Platform.get_user_id()>`（`res://singletons/progress_data.gd:588-603`），含 settings.json、save_v3_<p>.json、run_v3_<p>.json、.json.tmp、仅 Windows 的 `<basename>_NN.json.bak`（最多 5 个）、log.txt。BO 另有 `user://mod_data/six666-BrotatoOnline/client_identity.cfg` 与 `saved_identities.cfg`。局内状态只在商店检查点写入（`res://ui/menus/shop/base_shop.gd:201`、:265、:319），失败、胜利、重开时写空。每人保存 PlayerRunData.serialize（无身份字段），以及 6 个来自 BaseShop、2 个来自 RunData 的固定 4 项旁路数组；局内档没有 schema 版本和人数字段。
- 核验：已纠正（备份文件名应为 `<basename>_NN.json.bak`；`get_state` 的 play_mode 恒为 SOLO，继续时由 is_coop_run 推出 COOP；漏列 load_game_file 内部在 :731、:757、:769 的 save）。

**Q2 原版读取超过 4 人的存档会怎样（F13）？**

- players_data 不受限，但 `deserialize_run_state` 把 locked_shop_items 与 shop_items 固定为 4 项（`res://singletons/progress_data_loader_v3.gd:390`、:406）：debug 下整局读档失败、继续按钮消失；release 下得到 8 人加 4 份商店数据的混合状态。继续后 get_max_players=4 让 P5 以后无法加入。之后任何 save() 都会把截断或空状态写回 run_v3。写入方向同样固定 4 项（:603-613）。结论：超四人状态绝不能进入 run_v3。
- 核验：已纠正（有 BO 时的阻断原因除 `MAX_LOBBY_MEMBERS=4`（Steam 大厅也以此创建，session_manager.gd:1346/1349）外，主要是占位设备池只有 6 个号（online_player_slot_manager.gd:14），`MAX_REMOTE_PLAYERS=3` 只限局中加入）。

**Q3 BO 在继续/重连时如何把身份映射到槽位，持久化什么，移除时如何重映射？**

- Steam 成员的 owner 是 steam_id，LAN 成员是 `"lan:"+installation_id` 加每局令牌哈希；`slots[i]` 的下标就是 players_data 的 player_index（`BO/scripts/player_identity_registry.gd:23-101`）。房主每次 save 后把元数据写入以 run_v3 文件哈希为键的侧车（`BO/scripts/player_identity_manager.gd:342-396`）。继续时校验成功就只接纳原身份并自动提交，失败则手动分配（:114-180、:582-647）。移除时按保留位置重排 SAVE_ARRAYS 与 RUN_ARRAYS、压缩槽位与身份表、revision 加一并广播 commit（`BO/scripts/player_removal_manager.gd:158-211`、:250-353）。
- 核验：确认（补充：Host 最终落盘的商店检查点不带 bo_roster_* 键，因为写盘时 `_removed` 已清空）。

**Q4 有没有原子写存档？**

- 没有。v3 先写 tmp，再用 `Directory.copy` 覆盖主文件（`res://singletons/progress_data_loader_v3.gd:518`），恢复只依赖 Windows 下的 5 个 .bak（:434-454），从不使用 tmp；进度档与局内档分两次写入。settings.json 直接覆盖（progress_data.gd:645-661）。BO 的身份与设置文件也直接覆盖写，只靠文件哈希发现不同步。
- 核验：确认（补充：save() 唯一的中止条件 *_NO_STEAM/*_NO_EPIC 在本版本从未被赋值；读取 _01.bak 失败时主文件不更新、tmp 残留）。

**Q5 在哪里隔离超四人检查点，需要覆盖哪些方法？**

- 只扩展 `res://singletons/progress_data.gd`，排在 BO 的 progress_data_removed_players.gd 之后：覆盖 `save()`、`load_game_file()`、`reset_and_save_run_state()`、`reset_and_save_new_run_state()`、`reset_save_profile()`、`unlock_all_save_profile()`、`copy_save_profile()`、`get_profile_stats()`、`get_current_save_object()`。检查点放在 SAVE_DIR 子目录（或 `user://mod_data/<mod>/<steam_id>/`），不用 .json 与 run_v3_/save_v3_ 前缀。BO 侧：身份校验、checkpoint key、离线继续按钮、客户端 roster 补齐分别覆盖。所有机器都要安装，用能力协商拒绝未装扩展者；1～4 人局走原版路径。
- 核验：已纠正（只要扩展了 player_identity_manager.gd，其 preload 就在排序阶段绑定原版 registry，放宽上限必须改为在 manager 扩展中覆盖 `prepare_resume_if_needed()`；必须覆盖 `persist_saved_identity`；判定扩展局以 has_run_state 为前提，加载期间不得作废检查点）。

### 3.9 NET

**Q1 所有 msg_type 与处理函数（按阶段）？**

- LAN 传输握手（会话过滤前处理，`BO/scripts/session_manager.gd:583-597`）：transport_identity_request、transport_identity、transport_welcome、transport_session_id。大厅浏览：lobby_ping_request/response（通道 2）。分块：p2p_json_chunk。控制：hello、heartbeat、bo_mod_message、quick_chat、player_kicked/player_removed/player_roster_commit（`BO/scripts/player_removal_manager.gd:356-389`）。选人：menu_focus、select_character、select_weapon、host_character_setup、host_weapon_setup、selection_state、menu_scene_state。开局：game_start_prepare、game_start_time_ack、game_start_commit、client_game_scene_ready。商店/升级/箱子：run_page_action_sync（多种 action_type）。战斗：battle_input、battle_aim、battle_snapshot、battle_reliable_events、battle_terminal_state、player_state、entity_kill_claim、boss_damage_report、battle_entity_resync_request；遗留且无发送方：damage_claim_batch、player_hp_state、pickup_claim、request_selection_state、select_difficulty、select_zone。重试波：retry_wave_confirm/decline/state/end。分发前依次经过会话过滤（:3042-3068）、hello 门（:3710）、身份恢复门（:3713）、移除过滤（:3715-3720）、战斗代次围栏（:3755）。
- 核验：确认（select 动作还会触发全目标阶段消息重建与强制 selection_state 广播，:3842-3843，见 NET-M01）。

**Q2 API 是否允许第三方 Mod 收发自定义消息，能否用于能力协商？**

- 可以：`send_to_host`、`send_to_player`、`broadcast` 与信号 `mod_message_received`（`BO/scripts/brotato_online_api.gd:5`、:144、:158、:184）。约束：mod_id/route 非空、payload 为 Dictionary、走菜单通道、Host 在 hello 前与身份恢复期间丢弃、roster 过渡中丢弃、JSON 传输数字变浮点、没有 ACK。可用于加入后协商（未装扩展的对端不回复，用超时判定），但不能阻止槽位分配，因为 Host 在 hello 前就分配槽位（`BO/scripts/session_manager.gd:2338-2343`）。需要三层：大厅元数据、hello 扩展字段、加入后 bo_mod_message。
- 核验：已纠正（非可靠消息在该 peer 已有排队时也会进入不过期队列；伪造 meta 只需包内 relay_from_steam_id；Host 侧门控应覆盖 `_accept_client_protocol`；Host 的 broadcast 目标含断线保留槽；改写 mod_version 拦截原版客户端会留下幽灵槽）。

**Q3 包大小限制、分块，以及随人数增长的部分？**

- Steam 超过 400 KB 预分块，每块 44000 字节；LAN 超过 32000 字节就预分块；应用层队列全局每帧只成功发 1 条（`BO/scripts/session_manager.gd:53-59`、:7636），失败 100ms 后重试，只有 latest_state 会过期。随人数增长：快照 p/ec/pr、终局状态、选人状态、setup、商店 menu_scene_state、game_start_commit、roster commit，并按目标逐份序列化发送。O(N²) 部分：battle_aim 转发、进度动作附带全员状态、commit 的全量 run_config。
- 核验：已纠正（32/64 条接收预算只适用于 Steam，LAN 一帧取完且每包解析两次；选人阶段每 250ms 按目标重建 setup；纯 LAN 无 Steam 时断线保留槽会让可靠战斗批次停滞）。

**Q4 Host 如何校验发送者拥有某个槽位？**

- 传输层身份由 Steam 或 LAN 令牌握手保证（`BO/scripts/session_manager.gd:3520-3531`、:599-607）。按发送者校验的：battle_input（`BO/scripts/online_input_manager.gd:61-71`）、menu_focus 与 select_*（`BO/scripts/menu_sync_manager.gd:619-628`）、重试与开局确认。可被伪造的：run_page_action_sync（origin 与 player_index，menu_sync_manager.gd:7873-7887）、quick_chat 的 origin、entity_kill_claim/boss_damage_report/damage_claim_batch 的 player_index（`BO/scripts/state_snapshot.gd:1396`、:1424、:1696）、API meta（`BO/scripts/brotato_online_api.gd:281`）。扩展应在 Host 端覆盖这些入口，按传输发送者映射槽位。
- 核验：已纠正（player_hp_state 委托 apply_player_state 会校验，不是入口；伪造高序号还能永久阻断受害者动作（menu_sync_manager.gd:7904-7918）；客户端接受任何 Steam 会话（session_manager.gd:7856-7860））。

### 3.10 GAP1（单轮）

1. **RUN_ARRAYS/SAVE_ARRAYS 与已知逐玩家容器比对，8 人移除 P3 后是否整体左移？** Host 侧 players_data、11 个 RUN_ARRAYS、start_wave_state、saved_run_state、商店 6 个存档数组、connected_players、身份表、`_connections` 按同一 kept 左移（`BO/scripts/player_removal_manager.gd:273-298`）；duplicate_items_cache 被重置回 4 项，`Utils.last_elt_selected` 不左移，扩展自有表没有插入点。任何源数组仍为 4 项时新索引 4～6 越界。客户端不左移 RUN_ARRAYS，locked_shop_items 写成 4 项（:432），占位池不足（GAP1-05）。目前无法保证 8 人局整体一致左移。单轮。
2. **`_select_array(pad=true)` 的结果长度？** 恒等于源长度（:161-164）：源为 4 项时结果为 4 项，源已扩到 8 时为 8 项并正确左移；players_data 不补位。补位类型取自第一个元素，`_players_die_args` 补 null、tracked_item_effects 补 {}。单轮。
3. **客户端 `_apply_client_roster` 的其他 4 人假设与防重放？** 4 人假设：reset_run_caches 重写 duplicate_items_cache、TempStats/LinkedStats 只有 4 项、占位池 6 个、:432。发送者校验存在（:361-364）；commit 要求 revision 严格增大（:381-388），旧包与重放被忽略，但没有确认与重发，应用时清空分块缓冲（`BO/scripts/session_manager.gd:9693-9694`）。7 人 commit 估计 0.2～0.45 MB（未实测）。单轮。
4. **移除后占位设备如何回收，身份表在 >4 时是否失效？** Host 降序删除映射并释放设备号，其余人不重新编号（`BO/scripts/online_player_slot_manager.gd:1350-1361`）；客户端从池中重新分配全部占位。>4 人的拒绝只在继续时生效（`BO/scripts/player_identity_registry.gd:29`）；compact 的真正失效方式是遇到越界索引时把身份表整体清空（:79-87）。单轮。
5. **can_kick_peer 允许哪些阶段？** 不限场景，只要求 Host、非过渡、在会话 key 中、远程、未移除、无待完成开局（`BO/scripts/player_removal_manager.gd:45-55`）。踢人是局内释放断线名额的唯一途径，但局内新玩家仍因冻结被拒（`BO/scripts/session_manager.gd:791`）。在升级界面移除 P5～P8 时 :131 无越界保护。单轮。
6. **要满足 F11 需覆盖哪些方法？** player_removal_manager.gd 的 `_select_array`、`_commit_host_removal`、`_reset_indexed_caches`、`_apply_client_roster`、`_finish_host_removal`、`_disable_removed_actors_and_rewards`、`filter_saved_state`、`can_kick_peer`（均需保持原名，多处通过 call_deferred 字符串或节点路径调用）；槽位管理器三个池方法；身份表 load_metadata 与 compact；session 的 reset_after_player_roster_change；RunData、Utils、TempStats、LinkedStats、UpgradesUI、Main 的相关方法。单轮。

### 3.11 GAP2（单轮）

1. **重试波确认名单来自哪套 roster，超时走哪条路？** 来自含断线保留槽的 session key（`BO/scripts/session_manager.gd:5015-5027`、:2400-2402）。P5～P8 能确认，但断线者永远不确认，只能等 15s 后以 allow_unconfirmed 自动重试（:93、:4765-4804），随后经过 1200ms ACK 与 4500ms 就绪屏障；任一玩家点“否”全队结束。单轮。
2. **start_wave_state 能否完整保存 8 人数组，重试是否经过 MENU-01？** get_state 只保存 players_data、locked_shop_items、tracked_item_effects（`res://singletons/run_data.gd:1727-1767`），resume 按快照长度恢复；快照在 _reset_per_wave_properties 之后拍。重试 run_config 不经过 MENU-01，但重载 main.tscn 时被战斗入口的两处 clamp 截断，且快照早于截断（GAP2-03）。单轮。
3. **胜利时每台机器为全部角色解锁挑战与写盘是否既有语义？** 是，BO 不拦截 apply_run_won（`res://singletons/run_data.gd:1881-1937`）。唯一条件越界是 P5～P8 带诅咒时读 4 项 `_stat_caches`；yield 不会卡住流程（`res://main.gd:971`、:1143-1145）。单轮。
4. **结算后新开一局时 P5～P8 会丢弃还是错位？** 先会在 `res://ui/menus/run/base_end_run.gd:54` 卡死（GAP2-01）。修复后，已映射的远端由周期恢复重建且不做容量检查，不会丢弃，但顺序可能与上一局不同；新成员仍受 4/3/6 限制；断线 key 被重建成占位。单轮。
5. **P5～P8 先死时客户端全灭判定与 Host 是否一致？** 判定口径一致，但最后倒下者是 P5～P8 时 Host 在 `res://main.gd:471` 中止、客户端在 `BO/extensions/main_safe_pool_exit.gd:455` 中止，需等 WaveTimer；died 只连接一次，原版函数体不会执行两次。单轮。
6. **暂停菜单的重新开始与结束本局是否被同步？** 没有，BO 与 CoopFix 都没有拦截（`res://ui/menus/pages/menu_restart.gd:24-35`、`res://ui/menus/pages/menu_end_run.gd:24-29`）。Host 重开会绕过开局屏障，客户端结束本局会单独离开战斗。单轮。

### 3.12 GAP3（单轮）

1. **联机 8 人时难度页由谁操作，会不会越界？** 只有 Host（P1）：`enable_coop_panels=false`、只有 FocusEmulator1（`difficulty_selection.tscn:51`、:53-56），BO 把难度页定为 Host-only（`BO/scripts/menu_sync_manager.gd:354-357`）。原版与 BO 不会把 4～7 送进 `_on_element_focused`；越界只会由扩展自己注入节点或返回 null 面板造成。返回路径写 `last_elt_selected[4..7]`：debug 下卡在难度页，release 下丢失上次选择。单轮。
2. **本机为 P5～P8 时暂停菜单的表现？** 暂停所有者按人数动态确定，能成为所有者（`res://ui/menus/ingame/pause_menu.gd:46-50`）；数据按 4～7 加载，但切换器被夹到 3（carousel.gd:17）、弹窗注册越界（popup_manager.gd:11-19）、焦点框取色越界；选项页在战斗中依赖 BO 别名可正确返回。BO 别名只占 FocusEmulator1 且 player_index 不等于 0，扩展不能在 main 根下创建 FocusEmulator1～8。单轮。
3. **各页面的逐玩家数据、FocusEmulator 依赖、需新增节点与覆盖方法？** 难度页无需新增节点，只需 Utils 扩展与 `_get_panels` 过滤；区域选择无逐玩家数据；暂停菜单需补 CoopPlayerLabel5～8、扩 PopupManager；重试波无需新增；加入面板需先扩颜色；新建 FocusEmulator 的 base 只含 Inventory1。BO 与 CoopFix 都没有扩展 difficulty_selection、base_selection、ingame_main_menu、coop_player_selector、popup_manager、menu_options。单轮。
4. **与人数无关、不能改的数字？** 见 GAP3-16 与 DATA-20：Switch 握持样式 4/5、Switch 人数 2、设备号 6/7、REMAP_END=8、调试设备 8～11、边框 4*focus_order、难度阈值、按钮数组、effect.apply(0)、BO 的 range(8) 设备动作后缀。单轮。

### 3.13 GAP4（单轮）

1. **共享上限在 8 人下是否更早触发，会不会造成偏差？** 会。敌数系数 4 人 1.9、8 人 3.1，材料单位数约为 4 人的 1.96 倍（推算未计同屏上限）。建筑超过 100 时跨玩家随机拆除（`res://global/entity_spawner.gd:302-315`），归属统计有偏差；Host 拆除不下发、客户端不执行上限，各端建筑集合发散（GAP4-02）。金币合并不改变总价值，金币仍轮转平分，但按拾取次数触发的效果变少。经济以 Host 为准。单轮。
2. **声音与特效上限在 8 人下的影响？** 声音队列 16、播放器 12、每帧启动 1 个，特效 100 个名额共用；8 人时更早饱和，本机反馈被远端挤掉。建议默认不提高上限，先测量，再做本机优先。单轮。
3. **Entity 轮廓槽在 8 人下是否更易满？** 不会；单个实体最多 BOOST、CURSE、CHARM、易伤 4 种颜色，高亮只用所有者一人的颜色，且颜色相同会去重（`res://entities/entity.gd:121-133`）。release 下 assert 不执行，第 5 个颜色不显示。真正的风险是颜色表只有 4 色。单轮。
4. **share_coop_loot、lock_coop_camera、retry_wave、enemy_scaling 各机是否一致？** retry_wave 由 Host 下发并临时覆盖；share_coop_loot 只在 Host 生效，箱子队列在停波时被 Host 校正，但只校正前 4 槽；lock_coop_camera 只影响本机镜头；enemy_scaling 不同步，客户端用本机设置计算敌人投射物伤害（`BO/scripts/menu_sync_manager.gd:8927`），会造成各玩家难度不同。单轮。
5. **雾波在 BO 裁剪人数或扩容后会不会越界？** 仅装 BO 时三者等长不越界；扩展只放开一处 clamp 时 `res://visual_effects/fog_viewport.gd:68` 每帧越界。单轮。
6. **与人数无关、禁止改动的数字？** entity_spawner 的距离与生成节奏常量、`/8.0`、MAX_STRUCTURES；main.gd 的边距、MAX_GOLDS、掉落概率、调试时速键；金币单价与尺寸；声音元组下标与播放器数；特效与飘字上限；轮廓与武器品质的 4 个 shader 槽；雾波参数；合作平衡系数；BO 的网络节奏与预算常量；Steam 发送标志 5/8；EntityType 枚举值。需要按人数定向修改的是：entity_spawner 的逐人队列与出生格、main.gd 的逐人数组、player_colors、get_max_players 与 BO 的 clamp。单轮。

## 4. 参考 Mod 审计

| Mod | 状态 | 依据 | 对本项目的结论 |
| --- | --- | --- | --- |
| Extended Coop（工坊 3629226509） | 尚无源码（未安装，未取得实现） | 仅公开页面描述（见 `docs/plan/BACKGROUND.md:70`）：8 人合作；前四人锁定角色后再加入后四人；单独存档路径；页面注明超四人继续对局有问题 | 分组选人与独立存档路径可作参考；“超四人继续”问题已对应到本审计的 SAVE-01/02/09、SAVE-M01/M02 与 T10、T13、T14。若与本扩展同时安装，属 F16 危险组合（同名 FocusEmulator/Panel 注入、颜色表、扩展同一批脚本，见 UI-25），需在 AP-019 识别并阻止 |
| Extended Coop - 8 players local + remote（工坊 3792682639） | 尚无源码（未安装，未取得实现） | 仅公开页面描述（`docs/plan/BACKGROUND.md:71`）：选人、商店、升级、结算用 2×4 布局；新增玩家颜色；超四人局内存档分离；四人以内保留原界面 | 2×4 布局与“四人以内保留原界面”可作 AP-014 样例参考，需按 1920x1080 逻辑画布核算（UI-24、UI-M07）。冲突风险：若它在战斗场景根下创建 FocusEmulator1，会关闭 BO 的暂停焦点别名（GAP3-09）；与本扩展同时注入 5～8 号节点会撞名（UI-25） |
| CoopFix-OnlineMouseUI 1.0.1（工坊 3803857989） | 已审计（只读源码） | 扩展 focus_emulator.gd、inventory.gd、weapon_selection.gd（`CF/mod_main.gd:8-10`）；MouseRouter 由 `load().new()` 创建（`CF/mod_main.gd:13-17`）；manifest 依赖 BO，声明 ML 6.2.0；本身无 4 人常量 | 冲突结论：联机时吞掉 FE base 之外的点击（UI-18）；每 0.15s 改写商店锁定/禁用按钮（UI-19）；与本扩展对同一脚本的链序需固定（UI-20、LIFE-04）；以 `_player_weapons.size()` 为界读 `_has_player_selected`，需同步扩容（UI-M05）；依赖 BO API 私有方法与 session 私有字段（NET-M06）；读取 menu_sync 的 `_last_state_from_host`（MENU-16）。建议 manifest 把它列入 optional_dependencies，并在 T16 测试装与不装两种组合 |

许可：

- Brotato Online：工坊 zip 内没有 LICENSE 文件（`mods-unpacked/six666-BrotatoOnline` 下检索无结果）。计划文档引用的 GitHub 快照为 GPL-3.0（`docs/plan/BACKGROUND.md:247`、`:284`）。工坊版本的实际许可需要 OWNER 确认。本扩展只通过脚本扩展覆盖其方法，不复制其文件；如需复制或改编其代码，按 GPL-3.0 处理。
- CoopFix-OnlineMouseUI：包内有 LICENSE，为 MIT 许可（`CF/LICENSE:1`）。本扩展不复用其代码。
- 两个 Extended Coop：无源码、无许可信息，只按公开行为描述自行实现，不复用任何实现。

## 5. 每条发现的去向

下表把全部 280 条发现映射到一个主工作项。一条发现涉及多个工作项时，按“谁先需要它”选主项，其余工作项在实现时引用同一编号。

| 工作项 | 范围 | 发现编号 |
| --- | --- | --- |
| AP-005 验证脚本扩展生命周期 | 加载时机、继承链、多级回调、编译期绑定、日志与 CrashReporter、模板类型 | CAP-19、INP-12、INP-M02、MENU-M02、BAT-16、BAT-M09、DATA-17、DATA-M01、UI-04、UI-14、UI-M01、UI-M06、UI-M08、LIFE-01、LIFE-02、LIFE-03、LIFE-05、LIFE-06、LIFE-07、LIFE-08、LIFE-09、LIFE-10、LIFE-11、LIFE-13、LIFE-15、LIFE-16、LIFE-23、LIFE-M-01、LIFE-M-02、LIFE-M-04、NET-19 |
| AP-006 容量与输入原型 | 会话容量、Steam/LAN 传输上限、远程槽位、虚拟设备与动作、BO 的 4 人截断 | CAP-01、CAP-02、CAP-03、CAP-04、CAP-05、CAP-06、CAP-07、CAP-08、CAP-09、CAP-10、CAP-M02、INP-01、INP-02、INP-03、INP-04、INP-05、INP-M01、MENU-01、BAT-01、BAT-02、BAT-21、DATA-14、UI-13、UI-22、UI-M03、UI-M09、NET-01、NET-02、NET-17、GAP2-03 |
| AP-009 版本适配与能力协商 | 协议字段、能力门控、指纹、manifest 自检、禁止误改清单、设置同步 | CAP-12、CAP-13、MENU-16、DATA-20、LIFE-19、LIFE-20、LIFE-M-03、NET-04、NET-15、NET-16、GAP3-16、GAP4-06 |
| AP-010 稳定槽位与输入 | 逐玩家数据初始化、在线/在局/容量区分、设备拔插、第九人拒绝 | CAP-14、CAP-M03、INP-06、INP-07、INP-10、INP-11、BAT-03、BAT-15、BAT-M05、DATA-01、DATA-02、DATA-04、DATA-05、DATA-06、DATA-19、DATA-M02、DATA-M03、DATA-M04、LIFE-22、NET-18、GAP2-07、GAP3-05 |
| AP-011 菜单操作提交 | 发送者归属、去重、陈旧判定、合并、远程数据边界 | MENU-03、MENU-06、MENU-07、MENU-08、MENU-09、MENU-13、MENU-17、BAT-13、NET-05、NET-06、NET-07 |
| AP-012 场景与阶段守卫 | 就绪屏障、超时、阶段代次、终局与重试、结算后新局、暂停菜单重开/结束 | CAP-15、MENU-02、MENU-05、MENU-10、MENU-11、MENU-M01、BAT-08、BAT-14、BAT-19、NET-13、NET-M02、GAP2-01、GAP2-02、GAP2-04、GAP2-05、GAP2-06、GAP2-10 |
| AP-013 战斗与合作机制 | 逐玩家战斗数组、金币分配、出生点、建筑/宠物队列、合作缩放、共享上限 | MENU-12、BAT-04、BAT-05、BAT-06、BAT-10、BAT-18、BAT-22、BAT-M01、BAT-M02、BAT-M04、BAT-M07、DATA-09、DATA-10、DATA-11、DATA-12、GAP1-12、GAP2-08、GAP3-04、GAP4-01、GAP4-02、GAP4-03、GAP4-04、GAP4-05、GAP4-11、GAP4-12 |
| AP-014 原风格 UI 样例 | 颜色可辨性、布局阈值、逻辑分辨率、镜头 | BAT-M08、UI-03、UI-24、UI-M07 |
| AP-015 全部扩展 UI | 选人、武器、难度、升级、商店、HUD、暂停、结算、继续界面、颜色表、FocusEmulator | CAP-11、INP-08、INP-09、MENU-04、MENU-M03、BAT-07、BAT-09、BAT-M03、DATA-07、DATA-08、DATA-18、UI-01、UI-02、UI-05、UI-06、UI-07、UI-08、UI-09、UI-10、UI-11、UI-12、UI-15、UI-16、UI-17、UI-21、UI-23、UI-26、UI-M02、LIFE-17、SAVE-18、SAVE-M06、GAP3-01、GAP3-02、GAP3-03、GAP3-06、GAP3-07、GAP3-08、GAP3-10、GAP3-11、GAP3-12、GAP3-13、GAP3-14、GAP3-15、GAP4-09、GAP4-10 |
| AP-016 隔离检查点 | 存读档入口、schema、提交协议、档位操作、错误报告脱敏 | DATA-03、UI-M04、LIFE-14、LIFE-21、SAVE-01、SAVE-02、SAVE-03、SAVE-04、SAVE-05、SAVE-06、SAVE-07、SAVE-10、SAVE-14、SAVE-15、SAVE-16、SAVE-19、SAVE-M03、SAVE-M04、SAVE-M07、GAP1-07 |
| AP-017 断线/继续/移除 | 身份校验、重连、保留槽、继续提交、移除重映射 | CAP-16、CAP-17、CAP-M01、CAP-M04、INP-M03、BAT-17、BAT-20、DATA-13、DATA-15、SAVE-08、SAVE-09、SAVE-11、SAVE-12、SAVE-13、SAVE-17、SAVE-M01、SAVE-M02、SAVE-M05、NET-03、NET-08、NET-M03、NET-M04、GAP1-01、GAP1-02、GAP1-03、GAP1-04、GAP1-05、GAP1-06、GAP1-08、GAP1-09、GAP1-10、GAP1-11、GAP1-13 |
| AP-019 内容与 Mod 组合 | DLC、CoopFix 与同类 Mod 组合、加载顺序、发布结构 | DATA-16、UI-18、UI-19、UI-20、UI-25、UI-M05、LIFE-04、LIFE-12、LIFE-18、NET-M06、GAP3-09 |
| AP-020 八人性能 | 发送队列、分块、序列化、扇出、快照大小、生成吞吐、声音与特效上限 | CAP-18、MENU-14、MENU-15、MENU-M04、BAT-11、BAT-12、BAT-M06、NET-09、NET-10、NET-11、NET-12、NET-14、NET-M01、NET-M05、GAP2-09、GAP4-07、GAP4-08、GAP4-13、GAP4-14 |

## 6. 被驳回的发现

核验阶段没有驳回任何发现（0 条 refuted）。

- 54 条发现被“已纠正”：结论保留，部分事实（行号、触发条件、后果严重度、接入时机）被修正，表 2 已采用修正后的事实。影响较大的纠正：BAT-10 由“阻断波次结束”降为“只丢日志”；BAT-12 的瓶颈改为全局每帧 1 条的发送队列；MENU-07、MENU-11 中“乱序导致旧包覆盖”的推论不成立；SAVE-09、SAVE-11 的接入方案与阻断原因改写；UI-02、UI-04、UI-06、DATA-01、DATA-04 等按 release 模板语义修正后果。
- 关键问题答复中有 17 条被“已纠正”，没有被驳回的答复。
- GAP1～GAP4 的 53 条发现只经过一轮审计，没有核验结论，使用时按“未独立核验”对待。

## 7. 未覆盖范围与待运行时验证清单

### 7.1 未覆盖范围

- `BO/scripts/session_manager.gd`（约 9706 行）与 `BO/scripts/menu_sync_manager.gd`（约 11452 行）没有逐行通读：大厅 UI、Host 断线冻结与退出（session_manager.gd 约 1447-1550）、重试波 UI 细节、菜单同步中 PlayerRunData 压缩与 hash、商店焦点解析等段落只做了模式检索。
- `BO/scripts/battle_replica_manager.gd`、`BO/scripts/state_snapshot.gd` 的出生标记、弹幕阶段同步、quiescence 细节只浏览或检索；客户端是否对远程代理运行原版移动与开火未完整追踪。
- `BO/scripts/public_lobby_browser.gd`、`quick_chat_wheel.gd`、`upgrade_runtime_sync.gd`、`pause_focus_alias_manager.gd`、`player_identity_*` 的完整逻辑只读了相关片段；`BO/extensions/coop_resume_player_identity.gd` 的身份守卫细节未逐行核对。
- 原版 UI：单人 shop.gd、end_run.gd、menu_options.gd 的大部分、codex、title_screen、inventory.gd、shop_items_container.gd、player_gear_container.gd、shop_item.gd 没有通读；各合作场景中每玩家容器的完整布局属性只核对了节点数量。
- `effects/`、`items/` 中约 58 个脚本与 DLC 敌人、投射物脚本只做了检索；DLC 的胜负流程扩展未审计。
- ProgressData 与各版本 loader 的完整迁移逻辑（v1/v2/beta）只确认了路径与固定数组。
- Mod Loader 的 config.gd、mod_config.gd 的 JSON Schema 校验与 setup_log.gd 未通读。
- 两个 Extended Coop 参考 Mod 没有源码，冲突点无法核实。
- Godot 3.7 自定义构建的引擎源码不可得：多级回调、信号派发顺序、编译期 class_name 解析、InputMap 设备匹配、FileAccess safe-save、Directory.rename 语义、JOYPADS_MAX 都依据 Godot 3.x 通用行为推断。
- 所有性能数字（快照大小、带宽、帧耗）都是代码结构估算，没有实测。

### 7.2 待运行时验证清单

按建议执行顺序排列，括号内为相关编号。

1. 导出模板：打印 `OS.is_debug_build()`；用最小探针确认越界读写、对 null 调用内建方法（如 `null.size()`）的后果（BAT-M09、DATA-M01、UI-M01）。
2. 扩展生效与链序：对 SessionManager、LanTransport、SteamTransport、OnlinePlayerSlotManager、NetworkHeartbeat、MenuSyncManager、StateSnapshot、CoopService、InputService、RunData、Utils、ProgressData、main、EntitySpawner、FocusEmulator 打印 `get_script().resource_path`、`extension_script_path` 元数据与 `get_base_script()` 链，确认 `_ready` 只运行一次（CAP-19、LIFE-05、LIFE-06、UI-20）。
3. `online_player_slot_manager.gd` 扩展在 `_init` 安装时能否编译（第 15 行常量依赖 CoopService），失败时 load_before + `_ready` 安装的替代方案（INP-M02）。
4. 排序阶段编译：在 BO 也扩展的路径上，确认扩展脚本没有 Parse Error，启动日志中涉及 mods-unpacked 的 SCRIPT ERROR 为 0，连续三次启动都没有“Mods are currently disabled”（LIFE-M-01、LIFE-03）。
5. 多级回调与信号顺序：三层链（原版→BO→扩展）在 `_ready`、`_enter_tree`、`_process`、`_input`、`_draw` 的调用次数与顺序；joy_connection_changed 与 connected_players_updated 的回调顺序（LIFE-08、LIFE-22、UI-M08）。
6. 编译期绑定：`ProgressDataLoaderV3.new()`、`PlayerUIElements.new()`、`player_identity_manager.gd` 中 Registry 与 ResumeBridge 实际使用的脚本（SAVE-03、UI-14、LIFE-07、SAVE-M01）；`_enter_tree` 注入节点能否通过 % 唯一名访问（UI-07、UI-12、GAP3-06）；`_reload_vanilla_child_classes_for` 对 BaseSelection 子类的效果（UI-05）。
7. Steam 能力：GodotSteam 是否提供 `setLobbyMemberLimit`、`setLobbyMemberData`、`getLobbyMemberData`；主机建房时 lobby_created 与 lobby_joined 的先后（CAP-03、CAP-13）。
8. 输入：本构建中 InputMap 设备匹配、对不存在动作的报错行为、`Input.action_press` 是否设置 raw strength；Windows 加 Steam Input 时物理手柄 id 是否会落在 6～15（INP-04、INP-05、INP-06、INP-11）。
9. LAN：ENet 断线 peer 超时时长与 `create_server` 余量；客户端重连的 duplicate_identity 竞态（CAP-05、CAP-M01）。
10. 隔离实例：exe 复制后的工坊路径、steam_data.json、steam_appid.txt、restartAppIfNecessary 行为；每实例 APPDATA 隔离后 installation_id 是否各不相同（LIFE-02、LIFE-15、LIFE-16、CAP-M02、NET-17）。
11. 性能：8 人时 host_character_setup、商店 menu_scene_state、game_start_commit、停波 battle_snapshot、player_roster_commit 的实际字节数与分块数；发送队列峰值；Host 帧时间均值与 P95；声音丢弃数与特效饱和率（BAT-11、BAT-12、NET-09、MENU-M04、GAP1-08、GAP4-07、GAP4-08、GAP4-14）。
12. 存档：FileAccess 在导出版是否启用 safe-save；Windows 上 `Directory.rename` 覆盖已存在目标的语义；Steam 云同步范围（SAVE-06、SAVE-M07）。
13. 战斗一致性：远程代理在每台机器上是否实际开火并产生声音与特效；8 名工程师类角色时 Host 建筑数达到 100 的时间与客户端未拆除建筑的累积（GAP4-01、GAP4-02）。
14. DLC：在 `_init` 中提前 `load_resource_pack` DLC pck 是否安全；魅惑上限在 release 下的实际表现（LIFE-12、DATA-16）。

### 7.3 需要 OWNER 或 AP-001 决策的问题

- 5～8 人的平衡目标：沿用线性外推（8 人敌数与 HP×3.1、人均材料 0.8775），还是设新上限或系数（DATA-09、DATA-10、BAT-18、GAP4-01）。
- 容量 >4 时是否禁止主机本地多人，坚持每机一人（CAP-07、CAP-14、CAP-09）。
- 扩展主机建立的 ≤4 人房间是否允许原版客户端加入；>4 人房间是否一律要求全员装扩展；容量是否在建房时固定（CAP-13、NET-15）。
- Steam 侧拒绝时的通知方式：复用 `player_kicked`（原版客户端显示“被踢”），还是只对扩展客户端发专用消息（CAP-02、CAP-M03）。
- 菜单阶段离开的成员是否自动释放名额（CAP-M04、NET-M04）；断线保留与踢人之间是否加自动超时（GAP1-11）。
- 被移除但尚未压缩的玩家是否继续参与当前波的收益分配（GAP1-12）。
- 逐玩家数组容量取 max(4, 人数) 还是固定 8（影响 1～4 人存档是否与基线逐字节一致，DATA-01）。
- 是否允许客户端在本地以房主身份继续一份超四人档；复制档位时是否连同扩展检查点与身份一起复制（SAVE-05、SAVE-14）。
- BO 身份侧车按档位 0 路径求哈希（SAVE-08）是否视为上游缺陷，修正 key 会让已有侧车记录失配。
- 暂停菜单“重新开始/结束本局”在联机中是隐藏、禁用还是只允许 Host（GAP2-06）。
- 每台机器为他人角色解锁成就与难度（apply_run_won）在 8 人时是否保持不变（GAP2-08）。
- 新增 4 种玩家颜色的色值（需避开 BOOST、CURSE、CHARM、HIGHLIGHT 与易伤色，UI-03、GAP4-09）。

