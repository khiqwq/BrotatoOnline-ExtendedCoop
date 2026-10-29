# 任务状态表（唯一状态来源）

工作流：TODO → READY → IN_PROGRESS → REVIEW → VERIFY → DONE；受阻为 BLOCKED（写明阻塞条件、已尝试方法、可继续事项）。没有日志/测试证据的工作不能标为 DONE。证据编号见 [evidence/index.md](../evidence/index.md)。

| 编号 | 工作 | 负责 | 状态 | 证据 / 说明 |
| ---- | ---- | ---- | ---- | ----------- |
| AP-001 | 固定范围 | OWNER/DEV | REVIEW | [requirements.md](requirements.md) 已写默认值、Rxx、预算提议值；待 OWNER 确认第 7 节清单 |
| AP-002 | 初始化仓库与工具链 | DEV | VERIFY | 结构、锁文件、setup/check/test、测试运行器与自检；EV-0002、EV-0003。待：干净目录按 README 重建的复核（QA） |
| AP-003 | 建立对照基线 | DEV/QA | IN_PROGRESS | 已完成：版本锁与指纹、隔离用户数据验证（EV-0004）、Txx 模板、证据索引、上游原有错误记录。**BLOCKED 部分**：1～4 人联机基线需要 2～4 个 Steam 账号/客户端（本机仅 1 个） |
| AP-004 | 审计限制和参考实现 | DEV | VERIFY | [limits-audit.md](limits-audit.md) 与 `docs/audit/findings.json`：9 个领域 227 条经独立核验（确认 123、纠正 54、核验新增 50、驳回 0），4 个缺口审计 53 条为单轮；每条已映射到工作项。两个参考 Mod 无源码，按公开页面标注。待：QA 抽查单轮条目；第 7.3 节 OWNER 决策 |
| AP-005 | 验证脚本扩展生命周期 | DEV | VERIFY | [ADR-001](adr/ADR-001-extension-loading.md)；EV-0005、EV-0006：扩展作用于 BO Manager 与 CoopService，叠加顺序正确，回调各 1 次，上游指纹未变。待：对局内实例的初始化/清理次数（M1） |
| AP-006 | 容量与输入原型 | DEV | VERIFY | 运行时开关 `scripts/compatibility/runtime_gate.gd`、11 个扩展（`extensions/`）、容量探针 `debug/capacity_probe.gd`。隔离实例验证 EV-0008～EV-0012：容量 8，1 本地 + 7 远程在虚拟设备 16..22，第 9 人被拒，7 个远程输入通道经 BO 注入路径互不串扰，移除后回到 1 人；`--coopplus-vanilla` 与 CoopFix-OnlineMouseUI 时容量 4（R07）；标题画面无新增错误。**BLOCKED 部分（需真实客户端）**：真实 Steam/LAN 会话的准入与人数上限（CAP-02、大厅 `member_limit`、LAN `create_server`）、满员通知（CAP-M03）、LAN 旧连接释放（CAP-M01）、真实 `battle_input` 包、第 5 人进入角色选择/战斗（AP-007）。已知未实现、会阻断 5+ 人对局：BAT-07 HUD、DATA-04/05 Utils 缓存、DATA-01/02 RunData 数组（AP-013～015）。待 OWNER：`main_ext.gd` 含游戏代码改写的许可（THIRD_PARTY_NOTICES）；继续游戏时按快照截断玩家（BAT-21，AP-012/017） |
| AP-007 | 执行 M1 验证 | DEV/QA | TODO | 需要 5 个真实客户端；8 实例 LAN 受同账号身份冲突限制（见 runbook） |
| AP-008 | 建状态测试与故障入口 | DEV | VERIFY | 可重放事件格式与回放 `tests/support/event_replay.gd`、应用层故障注入 `debug/fault_injection.gd`（正式包排除）、诊断/脱敏 `scripts/diagnostics/`；固定种子同摘要，重复/旧代次/伪造归属均被检出（26 个回放用例，变异测试 21/21 检出）。传输层丢包不在此模拟 |
| AP-009 | 固化版本适配与能力协商 | DEV | VERIFY | 运行时闸门 `runtime_gate.gd`、能力协商规则 `capability.gd`；房间类型（D-008，ADR-005）：房间容量进入闸门、运行选项下拉框、扩展房间的 mod_version 标记（CAP-13 方案 C）、LAN 能力消息与拒绝、hello 能力字段、公开大厅列表适配。待：真实 Steam/LAN 会话实测（M1） |
| AP-010 | 实现稳定槽位与输入 | DEV | IN_PROGRESS | 规则模块 `slot_registry`/`virtual_device_pool` 完成（55 个用例，复核修复 7 个缺陷）；AP-006 的槽位扩展已使用设备池。待：身份↔槽位映射接入 BO 身份管理器、ADR-002 |
| AP-011 | 实现菜单操作提交 | DEV | IN_PROGRESS | 规则模块 `action_ledger`/`payload_guard` 完成；待接入 BO 菜单同步 |
| AP-012 | 实现场景与阶段守卫 | DEV | IN_PROGRESS | 规则模块 `flow_guard`/`ready_barrier` 完成；待接入场景切换与就绪屏障 |
| AP-013 | 补齐战斗与合作机制 | DEV | IN_PROGRESS | 已修：P5～P8 出生点（BAT-06）、每波运行日志（BAT-10）、RunData/TempStats/LinkedStats/Utils 固定 4 格的逐玩家数组（`run_data_ext.gd`、`utils_ext.gd`、`per_player_arrays.gd`；EV-0017 中 5/8 人数据设置通过）。待：存档加载路径的数组（AP-016）、战斗内归属等；D-006 已解决：金币拾取不再复述游戏代码（EV-0032）。复测见 [local-simulation.md](runbooks/local-simulation.md) |
| AP-014 | 制作原风格 UI 样例 | DEV/OWNER | DONE | 布局已定（D-010“本机面板放大”），OWNER 补充 D-011：状态条显示武器，商店/结算可选择玩家展开其面板、平分左侧。8 人截图见 EV-0025、EV-0028（另含战斗 HUD：EV-0020）；OWNER 已确认 D-011 截图（2026-10-28） |
| AP-015 | 完成全部扩展 UI | DEV | IN_PROGRESS | 升级界面、战斗 HUD、合作商店、合作结算界面支持 P5～P8，并按 D-010 排布（`ui/local_focus_layout.gd`、`ui/player_status_strip.gd`），可切换为 D-012 四人视图（`ui/panel_view_controller.gd`，EV-0030）；5～8 人可连续多波并走完阵亡→结算（EV-0019～0025）。角色/武器/难度选择界面支持 P5～P8（UI-05/07/08、UI-M02/M05、MENU-M03），角色与武器页同样两种显示模式（`ui/selection_view_controller.gd`）；本地模拟可从角色选择一路走进战斗（EV-0031）。角色选择的运行选项里有房间类型（D-008，ADR-005） |
| AP-016 | 实现隔离检查点 | DEV | IN_PROGRESS | 写入路径完成（[ADR-004](adr/ADR-004-extended-run-checkpoint.md)）：`extensions/vanilla/progress_data_ext.gd` 把 5～8 人局内状态写入 `checkpoint_store`（`coopplus_runs/profile_<档位>/`），原版存档只写无进行中局的占位。修复前打开存档时 5 人进入第一个商店即崩溃（EV-0026），修复后 5/8 人带存档连续多波通过（EV-0027）。继续游戏已实现：读检查点、校验与明确拒绝、反序列化（含第 5 人起商店）、身份存入同一检查点（EV-0034）。待：联机继续实测 |
| AP-017 | 完成断线/继续/移除 | DEV | VERIFY | 继续：BO 身份管理器在继续界面运行时调整（超过 4 槽的登记表、面板加高、4 人以上禁用离线继续，`scripts/bo/resume_identity_patch.gd`）。移除：客户端重建名单后补齐逐玩家数组（GAP1-02、SAVE-13、DATA-15，`extensions/bo/player_removal_manager_ext.gd`）；房主端压缩保持数组长度、身份表 compact 支持任意人数，单机重放 8→7、6→5 通过（EV-0037）。断线重连：沿用 BO 保留断线者槽位与身份校验（R11）；与人数有关的部分已处理——准入只对新成员按房间容量限制（`_remote_connection_rejection_reason`）、客户端显示全部断线者（CAP-16）、LAN 留重连余量（CAP-05）、回来的玩家拿回原虚拟设备（F03）。BO 自身与人数无关的行为未改：开局/重试屏障等待断线者（NET-13、GAP2-04）、LAN 新连接与旧连接并存时判 duplicate_identity（CAP-M01）、移除后客户端 tracked_item_effects 不左移（GAP1-03）。待：多机联机实测（M1） |
| AP-018 | 跑完 18 类故障 | QA | TODO | |
| AP-019 | 验证内容与 Mod 组合 | QA | TODO | |
| AP-020 | 分析八人性能 | DEV | TODO | |
| AP-021 | 完整验收与长测 | QA | TODO | |
| AP-022 | 完成可复现打包与 CI | DEV | TODO | 确定性 zip 与白名单函数已在 `tools/lib/Common.psm1`（开发实例使用） |
| AP-023 | 冻结 RC 并交付 | QA/OWNER | TODO | |
| AP-024 | 建立更新响应流程 | DEV | TODO | |
