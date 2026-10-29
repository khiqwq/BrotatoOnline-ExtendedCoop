# ADR-005：房间类型与超四人能力校验

日期：2026-10-28。状态：已实现，尚未联机实测。关联：D-008、D-009、R01、R03、R07、R08、AP-009、CAP-01～CAP-13、[ADR-001](ADR-001-extension-loading.md)。

## 背景

- D-008：房主建房时选择**标准房间**或**扩展房间**，本局固定。
  - 标准房间：容量 4，未装本扩展的玩家可以加入，行为与原版一致。
  - 扩展房间：容量 5～8，所有成员必须装有能力版本一致的本扩展，进入正式流程前校验，不合格者被明确拒绝。
- 之前的原型只有一个全局开关：运行时闸门验证通过后，所有会话一律按 8 人处理。
- Brotato Online（BO）没有会话信号，版本一律精确比较（CAP-12）。
  - Steam 成员在发 hello 之前就已入座（CAP-13）。
  - 未装扩展的客户端只认识 BO 自己的提示文本。

## 选择

1. **房间容量是闸门的一部分**（`scripts/compatibility/runtime_gate.gd`）。
   - `set_room_capacity(n)`：本机开房或入房时设置。之后 `capacity()` 取房间容量，且不超过本机验证通过的容量；离开房间时 `clear_room()`。
   - 标准房间容量为 4，所以 `is_extended()` 为假，所有扩展在整个房间期间都走父类方法（R08），各扩展无需再判断房间类型。
   - 不在房间里（离线）时沿用原来的判定。
   - `verified_capacity()`：本机支持的容量。
   - `capability_version()`：来自 compatibility.json 的 `network_capability_version`。
2. **房主偏好与房间规则**（`scripts/core/room_policy.gd`，纯规则，有单元测试）。
   - 偏好按电脑保存在 `user://coopplus_settings.cfg`，默认扩展房间 8 人。
   - `host_room`：本机未验证超四人时只能开标准房间。
   - `to_metadata` / `from_metadata`：缺少或读不到房间数据时视为标准房间（与未装扩展的房主相同）。
   - `join_room`：扩展房间要求本机已验证、容量足够、能力版本相同。
3. **选择入口**：角色选择的运行选项里有一个下拉框，标准房间（4 人，原版兼容）/ 扩展房间 5～8 人（`character_selection_ext.gd`）。
   - 只在本机已验证超四人时出现；房间开着时锁定。
   - 主菜单“创建大厅”、邀请按钮、继续游戏时自动开房，都读同一偏好。
4. **房主开房**（`extensions/bo/session_manager_ext.gd`）。
   - `create_session`：在 BO 建 Steam 大厅 / LAN 主机之前定下房间，所以 `steam_transport_ext`、`lan_transport_ext` 已按房间容量创建。
   - 继续一局 5～8 人的存档时（BO 在继续界面自动开房），无论偏好如何，都开不少于该局人数的扩展房间。
   - `leave_lobby` 清除房间；创建失败也清除。
5. **广告**。扩展房间在 Steam 大厅数据（`_setup_lobby_data` 建房时同步写入、`_publish_session_metadata`）和 LAN 发现信息中：
   - 发布 `coopplus_room`、`coopplus_capacity`、`coopplus_capability`；
   - 把 `mod_version` 写成标记 `5.0.0+coopplus`。

   未装扩展的 BO 会精确比较 `mod_version`：
   - 好友邀请或直连时，它们在入座前就自行退出，提示“房主的协议或模组版本不兼容”；
   - 公开大厅列表把房间显示为版本不符、不能加入。

   标准房间什么都不改。
6. **本扩展的客户端**。
   - Steam：`_on_lobby_joined` 先读房间数据。本机参加不了的扩展房间，直接离开并给出具体原因（未启用/版本不同）；否则取房间容量（标准房间为 4）。`_is_lobby_protocol_compatible` 接受标记，房主进自己的大厅时也一样。
   - LAN：客户端在身份凭据之前发送 `coopplus_capability_hello`（同一可靠通道，先到）。房主在扩展房间里对缺失或不符的连接回复带标记版本的拒绝 `transport_welcome`，并附 `coopplus_reason`：未装扩展的客户端显示“协议或模组版本不兼容”，本扩展客户端显示具体原因。被接受的客户端随后收到 `coopplus_room`，没收到就按标准房间。
   - 公开大厅列表（`extensions/bo/public_lobby_browser_ext.gd`）：本机能加入的扩展房间显示为可加入。
7. **第二道检查**：本扩展客户端的 hello 在 `content_capability.coopplus` 里带能力版本。房主在扩展房间里拒绝缺失或不符的 hello，做法与 BO 拒绝协议不符相同（`_accept_client_protocol`）。日志不记录对方的标识（Steam ID）。

## 后果

- 标准房间里，装了本扩展的房主和客户端都与原版行为一致。
- 扩展房间里：
  - 未装扩展的玩家看到的是 BO 自己的“版本不兼容”提示；
  - 本扩展玩家看到具体原因；
  - 1～4 人时有 D-009 列出的差异。
- 房间类型在房间开着时不能改；要换类型，先关闭大厅。
- 未实测：真实 Steam / LAN 会话中的建房、加入、拒绝提示（需要多台机器，M1）。单机同时开多个实例走 LAN 理论上可行，但隐藏实例监听端口可能在桌面弹出 Windows 防火墙提示，所以没有做。
