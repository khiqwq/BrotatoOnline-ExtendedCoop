# Changelog

格式参考 Keep a Changelog；扩展版本使用 SemVer。网络能力版本与存档 schema 版本独立记录在 `project.lock.json` 的 `extension` 段。

## [Unreleased]

### Changed
- 运行时门控：CoopFix-OnlineMouseUI 1.0.1 由“超四人阻止”改为可选共存（R07、D-011）。文件指纹与锁定一致时超四人照常，其他版本仍阻止超四人开局；compatibility.json 新增角色 `optional`。

### Added
- 5～8 人时商店、升级、结算界面采用“本机面板放大”布局（D-010）：本机玩家的面板加宽，其余玩家收进状态条（玩家色、角色、P 编号与状态）；隐藏玩家的道具/属性弹窗不再显示。1～4 人或本机多名本地玩家时保持原版整行。`ui/local_focus_layout.gd`、`ui/player_status_strip.gd`。
- 5～8 人面板界面新增“四人视图”（D-012）：和原版一样显示四个面板，右摇杆、←/→ 或十字键左右逐个切换玩家（←/→ 与十字键只在光标到边时切换），两端标出未显示的玩家；V 键 / 手柄 Back 键在“本机放大”和“四人视图”间切换，每台电脑记住选择，默认本机放大。`ui/panel_view_controller.gd`。
- 状态条显示每名玩家的武器（原版品质底色）；商店与结算界面可用手柄/键盘或鼠标（需 CoopFix-OnlineMouseUI）选择一名玩家，展开其原版面板查看商店、武器与道具，与本机面板平分左侧，再次选择收起（D-011）。
- 5～8 人局内存档隔离（AP-016 写入部分）：5 人以上的局内状态写入独立检查点 `coopplus_runs/profile_<档位>/`，原版存档只写“无进行中局”的占位，不再写坏原版存档。暂不支持退出后继续这类局。`extensions/vanilla/progress_data_ext.gd`、`scripts/persistence/extended_run_state.gd`。
- 中文名「超四人联机合作扩展」；许可证 GPL-3.0（LICENSE 全文）。
- AP-001 范围与需求草案（`docs/requirements.md`），含决策、性能与超时提议值。
- AP-002 仓库结构、锁文件、`tools/setup.ps1`、`tools/check.ps1`、`tools/test.ps1`、最小 Godot 3 测试运行器。
- 本机审计用的 GDScript 字节码还原工具（`tools/recovery/`）。
- 容量规则 `scripts/core/capacity_policy.gd` 与单元测试。
- 隔离游戏实例工具 `tools/instance.ps1` 与 runbook；AP-005 生命周期探针（`debug/`，正式包排除）与 ADR-001。
- 纯规则模块与单元测试：槽位/设备池、阶段守卫/就绪屏障、操作去重/载荷校验、能力协商、隔离检查点、诊断脱敏；可重放事件与应用层故障注入（共 381 个单元用例）。
- AP-004 限制审计 `docs/limits-audit.md`（280 条发现）；上游契约测试覆盖全部被覆盖的上游方法。
- 合作商店与合作结算界面支持 P5～P8（面板、属性/道具弹窗、焦点、商店 12 个逐玩家数组）；5～8 人本地模拟可连续多波、走完阵亡→结算。共用面板克隆 `ui/extra_player_panels.gd`。
- `check.ps1` 新规则：禁止脚本预加载 `extensions/` 下的扩展（运行时会变成继承自己）。
- 战斗 HUD 支持 P5～P8（世界血条、角落 HUD 块、待处理图标），P5～P8 出生点不再与 P1～P4 重叠，每波运行日志支持 5～8 人；5/8 人本地模拟可完整打完一波并完成升级选择。
- 修复 5～8 人的前两处阻塞：逐玩家数组按 max(4, 人数) 扩容（RunData/TempStats/LinkedStats/Utils/弹窗管理器），合作升级界面补建 P5～P8 面板、属性弹窗与焦点；1～4 人保持原版数组。
- 单机 N 人本地模拟（`debug/local_sim_probe.gd`，模拟控制器，正式包排除）与 runbook；4 人本地流程走通至商店，5 人的前两个阻塞点已定位。
- 决策 D-006～D-009（复制原版代码须重写、沿用原版平衡、房间类型、扩展房间 1～4 人差异）。
- 运行时上游指纹计算 `scripts/compatibility/upstream_fingerprint.gd`（与锁文件算法一致，已实测相等）。

- AP-006 容量与输入原型：运行时开关 `scripts/compatibility/runtime_gate.gd`（容量 8/4、虚拟设备 16..22；版本、Brotato Online 指纹或 `compatibility.json` 不符时不安装扩展；`--coopplus-vanilla` 或检测到 CoopFix-OnlineMouseUI 时容量 4）；`mod_main.gd` 按固定顺序安装 11 个扩展（会话/传输/心跳人数上限、远程槽位与虚拟设备、按设备动作、玩家颜色、战斗与菜单人数守卫）；开发用容量探针 `debug/capacity_probe.gd`（含 BO 输入注入矩阵与 `--coopplus-probe-observe` 被动模式）。
- `THIRD_PARTY_NOTICES.md` 逐文件登记 Brotato Online 片段。

### Not verified
- 只在单个隔离实例中、无联机会话的情况下验证了槽位、设备与输入（EV-0008～EV-0012）；真实 Steam/LAN 会话的准入、人数上限、满员通知与重连均未实测。
- 5～8 人尚不能进入角色选择与战斗（BAT-07、DATA-04/05、DATA-01/02 等未实现，AP-013～015）。
- `extensions/vanilla/main_ext.gd` 含游戏代码改写，发布前需 OWNER 决定许可处理。
