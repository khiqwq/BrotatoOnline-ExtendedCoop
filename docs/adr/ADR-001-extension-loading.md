# ADR-001：独立补丁的加载与覆盖方式

日期：2026-10-28。状态：已采用（M0 证据）；M1 在对局场景内复核后更新。关联：AP-005、R03、D-002、[limits-audit](../limits-audit.md)、证据 EV-0005、EV-0006。

## 背景

路线 A 要求不修改工坊版 Brotato Online（`six666-BrotatoOnline` 6.6.6）就改变人数、槽位与场景保护逻辑。未知点（BACKGROUND 第 5 节）：扩展注册时机、能否作用于 Brotato Online 用 `load()`/`set_script()` 创建的 Manager、父类常量、重复回调。

## 选择

1. 扩展只通过游戏内置 Mod Loader 6.3.0 的 `ModLoaderMod.install_script_extension()` 安装，分两个时机：
   - **`mod_main._init()`**（Mod Loader 初始化中，排队、所有 Mod 初始化后统一应用）：原版自动加载脚本、原版场景脚本，以及常量表达式只用字面量的 Brotato Online 脚本。
   - **`mod_main._enter_tree()`**（Mod Loader 已结束初始化，调用立即生效）：常量表达式引用自动加载的父脚本，例如 Brotato Online 的 `scripts/online_player_slot_manager.gd`（`const REMOTE_PLACEHOLDER_PLAYER_TYPE = CoopService.PlayerType.GAMEPAD_XBOX`）。此时所有自动加载都已实例化，而 Godot 先为整棵子树执行 enter_tree 再执行 ready，所以仍早于 Brotato Online 的 `mod_main._ready()` 创建 Manager。
2. `manifest.json` 声明依赖 `six666-BrotatoOnline`，保证加载顺序在其后（实测 `mod_load_order -> 1) six666-BrotatoOnline, 2) CoopPlus-OnlineExtendedCoop`）。
3. 同一路径的扩展按加载顺序叠加：本 Mod 的扩展继承 Brotato Online 已安装的扩展，而不是替换它。
4. 可以扩展的目标：
   - Brotato Online 自己的脚本（如 `scripts/session_manager.gd`、`scripts/menu_sync_manager.gd`）。
   - 自动加载顺序排在 `ModLoader` 之后的原版单例（Utils、MenuData、ProgressData、ItemService、RunData、InputService、CoopService、UIService 等）。
   - 运行中才实例化的原版脚本（如 `global/entity_spawner.gd`、`main.gd`）。
5. 不能扩展：排在 `ModLoader` 之前的自动加载（CrashReporter、BugReporter、Platform、Keys、ModLoaderStore）、通过 `class_name` 静态调用的函数、已经实例化的对象。
6. 调试/探针代码只放在 `debug/`（打包排除），并且只在命令行带 `--coopplus-probe` 时安装。

## 实测时间线（EV-0006，隔离实例，2026-10-28）

| 时刻 (ms) | 事件 |
| --------- | ---- |
| 528 | 本 Mod `mod_main._init`；此时 `Engine.get_main_loop()` 为 null，Brotato Online 与 CoopService 脚本都尚未加载进缓存 |
| 529–531 | 4 个探针扩展排队 |
| （约 1 s 后） | Mod Loader 在所有 Mod 初始化之后统一安装扩展（日志 `Installing script extension ...`） |
| 3088 | CoopService 自动加载实例创建，使用本 Mod 扩展后的脚本 |
| 3163–3209 | Brotato Online 的 `mod_main._ready` 用 `load()+set_script()` 创建 SessionManager、MenuSyncManager，实例使用本 Mod 扩展后的脚本 |
| 3270 | 本 Mod `mod_main._ready` |
| 4299 | CoopService `_ready` |

继承链（按源码哈希识别每一层）：

- `res://global/entity_spawner.gd`：本 Mod 探针 → Brotato Online `entity_spawner_online_player_count_guard.gd` → 原版字节码。
- `res://singletons/coop_service.gd`：本 Mod 探针 → 原版字节码。
- `scripts/session_manager.gd`：本 Mod 探针 → Brotato Online 原文件。

计数：每个被扩展对象的 `_init`、`_ready` 各 1 次；SessionManager 父类 `_ready` 里 `call_deferred` 的 `_bind_transports` 1 次，说明父类 `_ready` 没有被重复执行。运行时计算的 Brotato Online 规范化指纹 = 锁文件值 `17443875…b819`（42 个文件），上游文件未被改动。

## 编写扩展的规则（违反会造成 F01/F06 类问题）

1. **不要在覆盖的 `_init/_ready/_process/_physics_process/_input/_enter_tree/_exit_tree/_notification` 中调用父类同名方法**：Godot 3 会自动逐层调用这些回调，手动 `._ready()` 会让上游逻辑执行两次。普通方法覆盖需要上游行为时用 `.method()`。
2. **子脚本不能重新声明父脚本的常量或变量**（引擎报 `The member "MAX_LOBBY_MEMBERS" already exists in a parent class`，EV-0005）。`MAX_LOBBY_MEMBERS`、`MAX_CLIENTS`、`MAX_REMOTE_PLAYERS` 这类常量只能通过覆盖**每一个读取它的方法**来改变；方法清单见 limits-audit。
3. **`mod_main._init()` 中不得访问 `Engine.get_main_loop()`、`get_tree()` 或绝对节点路径**：此时主循环尚未设置，访问 `.root` 会让引擎直接崩溃（0xC0000005，不是脚本错误）。需要场景树的工作放到 `_ready()` 或之后。
4. 覆盖方法必须保持与父方法相同的参数个数；父方法声明了返回类型时子方法必须一致。
5. 父脚本的常量表达式引用自动加载时（如 `CoopService.PlayerType`），**不能在 `_init()` 安装**：Mod Loader 会在自动加载实例化之前编译父脚本，报 `invalid index 'PlayerType' in constant expression`，扩展失效（EV-0007 前半）。改在 `_enter_tree()` 安装（EV-0007 后半：常量解析为 1，实例使用扩展脚本，0 个脚本错误）。
6. **不得 preload/load 任何扩展脚本**（`extensions/`、`debug/probe_extensions/`）：扩展安装后接管了父脚本路径，再加载扩展就会让它在运行时“继承自己”，报 `member already exists in a parent class`，该扩展失效；离线编译查不出（编译环境里没有安装扩展）。共享常量放到 `scripts/`。`check.ps1` 静态检查此规则（EV-0023）。
7. 正式版引擎不打印 GDScript 运行时错误；对 null 调用方法会直接空指针崩溃（0xC0000005）。验证一律依靠数据断言与逐步落盘的事件记录，不能以“没有脚本错误”作为通过依据。
8. 依赖 Brotato Online 节点时使用其实际路径 `/root/ModLoader/six666-BrotatoOnline/<NodeName>`，并在找不到时安全降级、记录诊断，不假设存在。

## 代价与风险

- 依赖 Mod Loader 6.3.0 “所有 Mod 初始化后统一安装扩展”的行为；Mod Loader 或 Brotato Online 更新必须重跑本 ADR 的探针（AP-024）。
- 覆盖“所有读取常量的方法”会让适配面变大，必须由 compatibility 层集中管理并用指纹门控（F17）。
- Steam 版 Mod Loader 只加载已订阅的工坊条目；开发版通过隔离实例侧载（[runbook](../runbooks/isolated-game-instance.md)），正式交付必须作为独立工坊条目或由用户手动放置，交付方式待 AP-022 决定。

## 尚未验证（M1 更新本 ADR）

- 对局内实例（EntitySpawner、Main、Player）的初始化/清理次数，以及退出再进入对局时是否只初始化一次。
- 扩展覆盖后五人以上实际人数路径是否生效（AP-006/AP-007）。
- 本版本不支持与 CoopFix-OnlineMouseUI 同时运行（R07），只需验证检测与阻止。（2026-10-28 更新：D-011 需要它提供鼠标操作，R07 改为锁定版本可选共存，门控角色 `optional`；本扩展不扩展 `focus_emulator.gd`，与它的扩展链无先后依赖。）
