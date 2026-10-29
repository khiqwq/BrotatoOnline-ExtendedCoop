# Runbook：单机 N 人本地模拟（模拟控制器）

用途：在一台电脑上不联网、不装虚拟手柄驱动，就能跑 1～8 名玩家的对局代码路径，用来开发和回归 AP-013～AP-015（战斗数据、HUD、升级/商店界面）。它**不能代替** M1/AP-021 的真实多机联机验收（不经过 Brotato Online 网络同步），也不是支持的玩法（R02 每机一人）。

实现：`mods-unpacked/CoopPlus-OnlineExtendedCoop/debug/local_sim_probe.gd`（`debug/` 不进正式包）。

## 原理

| 环节 | 做法 |
| ---- | ---- |
| 控制器 | 不模拟操作系统级手柄。P1 用键盘设备 7，P2～PN 用运行时闸门分配的虚拟设备 16～22；这些设备的每设备动作由 `extensions/vanilla/input_service_ext.gd` 注册且没有实体事件，因此不会和真实键盘/手柄串位 |
| 入座 | `CoopService.clear()` 后按设备逐个 `_add_player` |
| 开局 | 跳过菜单，按角色/武器/难度选择界面的写法组装 RunData（每人不同角色及其第一把起始武器），再切到 `main.tscn` |
| 操作 | 战斗中每 0.3 s 用固定种子随机方向 `Input.action_press("button_move_<方向>_<设备>")`；波次计时结束后改为每 0.6 s 为每个设备发送 `ui_accept_<设备>` 输入事件，让升级/箱子界面全员确认。5～8 人时 P1 之外的面板按 D-010 隐藏，FocusEmulator 不响应隐藏控件上的确认（`focus_emulator.gd:146`），探针改为像 Brotato Online 应用远程选择那样直接调用面板方法（`_on_choose_button_pressed` / `_on_TakeButton_pressed`），事件 `accept_round.direct` 记录为哪些玩家代选 |
| 安全 | `RunData.invulnerable`、`DebugService.custom_wave_duration`、`DebugService.disable_saving`；隔离实例（见 isolated-game-instance.md），真实存档不受影响 |
| 结果 | `user://coopplus_probe/local_sim.json`（每秒采样：场景、每个角色位置/设备、HUD 条目数、RunData 人数）与逐步落盘的 `events.log`（崩溃后仍保留，用于定位） |

## 操作

```powershell
pwsh ./tools/instance.ps1 -Action New -Name sim -Mods "BrotatoOnline,Extension" -WithDlc -DevBuild
pwsh ./tools/instance.ps1 -Action Start -Name sim -StopAfterSec 150 -ExtraArgs "--audio-driver,Dummy,--coopplus-local-sim=5,--coopplus-local-sim-seconds=20,--coopplus-probe-quit"
```

参数：`--coopplus-local-sim=<1..8>` 人数；`--coopplus-local-sim-save` 打开存档（默认关闭；只在隔离实例中用，见 ADR-004）；`--coopplus-local-sim-seconds=<秒>` 波次时长；`--coopplus-local-sim-seed=<整数>` 机器人输入种子；`--coopplus-local-sim-pad` 仅用于探路，每帧把原版固定 4 格的逐玩家数组补到 8 格，以便找到它们之后的下一个阻塞点（**不是修复**，正式修复在 AP-013）。每次运行前删除 `.local/userdata/instance-sim`；改代码后重新 `-Action New`。退出码 -1073741819 表示引擎崩溃，看 `events.log` 最后一条定位。

想看画面时加 `-ShowWindow`。需要人手操作时，游戏自带的调试开关 `DebugService.coop_multiple_keyboard_inputs` 可让一个键盘分成多名本地玩家（WASD / TFGH / IJKL / 方向键，设备 8～11），但原版本地合作仍限制 4 人。

## 2026-10-28 结果（证据 EV-0013～EV-0015）

| 运行 | 结果 |
| ---- | ---- |
| 4 人 | 通过：4 人生成、4 人各自移动（各自设备 7/16/17/18）、20 s 波次结束、升级界面全员确认、进入合作商店，0 个脚本错误 |
| 5 人 | 崩溃于开局前：为 P5 调用 `RunData.add_character` 时写入只有 4 格的逐玩家缓存（`run_data.gd:148-164` 等，DATA-01） |
| 5 人 + 探路填充 | 越过上一处后，切入战斗场景时崩溃于子节点 `ui/menus/ingame/upgrades_ui.gd:39` 的 `_ready`：按实际人数遍历只有 4 个的玩家面板与 4 元素 `stat_popups`（UI-10、BAT-M03）；此时 `main._ready` 尚未执行 |

结论：单机 5～8 人本地模拟**可行并已可用**，而且已经定位出前两个按顺序出现的阻塞点；继续修复 AP-013/AP-015 时用同一命令复测，直到 5/8 人都能走到商店并完成多波。

### 修复前两处后（证据 EV-0016～EV-0018）

| 运行 | 结果 |
| ---- | ---- |
| 4 人 | 不变：走到合作商店，0 个脚本错误（R08 回归） |
| 5 人 / 8 人（不加填充） | 数据设置通过；战斗场景子节点与 `main._ready` 前半通过；生成全部玩家；随后崩溃于 `main.gd` `_on_EntitySpawner_players_spawned` 查找 `%LifeContainerP5`、`%UIXPBarP5`、`%UIGoldP5` 等 HUD 节点（只有 P1～P4，BAT-07/UI-12）。这是下一处阻塞点 |

### 修复战斗 HUD 后（证据 EV-0019、EV-0020）

| 运行 | 结果 |
| ---- | ---- |
| 4 人 | 不变：走到合作商店 |
| 5 人 / 8 人 | 全部生成且各自移动（P5～P8 出生在 P1～P4 右侧两列，不再与 P1～P4 重叠）；HUD 每人一块；整波打完；本波升级的玩家（含 P5～P8）在升级界面完成选择；随后切入合作商店时崩溃：商店只有 `CoopShopPlayerContainer1..4`（UI-09），这是下一处阻塞点 |

本轮修复：`ui/extra_player_hud.gd`（克隆 P1～P4 的世界血条、角落 HUD 块与待处理图标容器给 P5～P8，并注册为战斗场景的唯一名称；P1 块中全队共用的额外金币与帧率标签不克隆）、`main_ext.gd`（在生成回调前补齐待处理容器，回调后把 P5～P8 放到对应角落）、`entity_spawner_ext.gd`（P5～P8 出生点右移两列，BAT-06）、`debug_service_ext.gd`（每波开始的运行日志默认 4 元素数组，BAT-10）。

### 修复商店与结算后（证据 EV-0021～EV-0024）

| 运行 | 结果 |
| ---- | ---- |
| 4/5/6/7/8 人 × 3 波（无敌） | 全部完成：战斗 → 升级 → 商店 → 出发 → 下一波，每人数据独立 |
| 8 人 × 10 波（无敌） | 完成，停在商店 |
| 4/5/8 人（可阵亡） | 全员阵亡后经“重试本波”对话框进入合作结算界面 |
| 布局 | 8 人时商店与结算面板排成一行超出屏幕（P7/P8 被裁切），后按 D-010 改为“本机面板放大”，见下节 |

新增参数：`--coopplus-local-sim-waves=<W>`（多波，商店中每人按“出发”）、`--coopplus-local-sim-mortal`（角色可阵亡）、`--coopplus-local-sim-on-loss=end|retry`（阵亡后进入结算或重打本波）。报告含每人角色/金币/等级/经验/道具/武器（`player_data_by_shop_visit`），第一次进商店和最终界面各截一张图。

### “本机面板放大”布局与存档隔离（证据 EV-0025～EV-0027）

| 运行 | 结果 |
| ---- | ---- |
| 4/5/8 人 × 3 波（无敌） | 全部完成；P2～P8 面板隐藏后，探针按远程路径直接代选（`accept_round.direct`） |
| 8 人可阵亡 × 最多 12 波 | 第 6 波全员阵亡 → 合作结算界面；结算界面只显示 P1 的弹窗 |
| 5 人带存档（修复前） | 进入第一个商店时崩溃（EV-0026） |
| 5/8 人带存档 × 3 波（修复后） | 完成；原版存档只有占位，检查点完整（EV-0027）；用该存档重启进入主菜单正常 |
| 4 人带存档 × 2 波 | 原版存档为完整 4 人局，不产生检查点（R08） |
| 8 人可阵亡带存档 | 第 5 波阵亡进入结算，检查点随局结束删除，原版存档回到无进行中局 |

检查存档：隔离实例的存档在 `.local/userdata/instance-sim/Brotato/<平台用户 ID>/`，`run_v3_0.json` 的 `current_run_state` 应为 `has_run_state: false` 加 `coopplus_extended_run` 标记，检查点在同目录 `coopplus_runs/profile_0/{current,previous}/`。用户 ID 是 Steam ID，不要写进证据。

### 状态条武器与查看他人面板（D-011，证据 EV-0028、EV-0029）

第一个商店和结算界面里，探针按 `VIEW_STEPS` 每 0.8 s 走一步并记录 `local_sim.view.*`（P1 焦点所在、当前展开的玩家）：

- 商店：截图 → 手柄右 → 下 → 确认（展开第二行的玩家）→ 截图 → 点击最后一行（切换）→ 截图 → 再点一次（收起）。
- 结算：点击第一行 → 截图 → 再点一次。
- “点击”：加载了 CoopFix-OnlineMouseUI 时调用它的 `_hit_test`、`_focus`、`_activate`（离线时它的路由器不处理原生鼠标事件）；没装时直接“聚焦 + ui_accept”，与它的 `_activate` 相同。

带 CoopFix 的实例：`tools/instance.ps1 -Action New -Name simm -Mods "BrotatoOnline,Extension,MouseUI" -WithDlc -DevBuild`。门控只在 CoopFix 文件与锁定指纹一致时放行超四人（R07 改为可选共存）；godot.log 的 `runtime gate:` 行与 `capacity.json` 的 `optional_running` 显示结果。

| 运行 | 结果 |
| ---- | ---- |
| 8 人 × 3 波，带 CoopFix | 手柄与 CoopFix 点击都能展开/切换/收起，0 个脚本错误 |
| 8 人可阵亡，带 CoopFix | 第 5 波进入结算，点击展开 P2 的库存、再点收起 |
| 4/5/8 人 × 2 波，无 CoopFix | 5/8 人同上；4 人无状态条（R08） |
| 容量探针，带 CoopFix | extended、容量 8，37/37（EV-0029） |

### 两种显示模式（D-012，证据 EV-0030）

第一个升级界面、第一个商店和结算界面在上面的检查之后再走一遍四人视图：`key_v`（切换）→ 截图 → `stick_right`（右摇杆推到底再回中）→ 截图 → `stick_left` → `key_v`。商店另加 `pad_right`、`pad_left` 检查“光标到边才滑动”。每步记录 `mode`（focus/pages）与 `start`（窗口起点）。升级界面的检查在第一次接受之前进行（第一次接受就会结束整个升级界面）。选择保存在实例用户目录的 `coopplus_view.cfg`；`run_sims.ps1` 每轮删除用户目录，所以每轮从默认的本机放大开始。

| 运行 | 结果 |
| ---- | ---- |
| 8 人可阵亡，带 CoopFix | 三个界面两种模式往返；商店边缘规则 0→1→2→1→0；第 5 波进入结算 |
| 4/5/8 人 × 2 波，无 CoopFix | 5 人窗口 0↔1、到端不动；8 人同上；4 人不启用 |

### 走完选人菜单（证据 EV-0031）

`--coopplus-local-sim-menus`：玩家入座后，以“从武器页返回”的方式（`RunData.menu_selection_back`，保留已入座的玩家）进入角色选择，而不是直接构造一局。每个界面先截图，再走显示模式检查（角色、武器页与上面相同的 `key_v`/`stick_*` 步骤），然后所有玩家每 0.6 s 按一次确认：角色与武器都选“随机”，P1 确认难度后进入战斗，之后与普通模拟相同。卡在菜单超过 90 s 记为 `stuck_in_menus:<界面>`。

| 运行 | 结果 |
| ---- | ---- |
| 5 人，去掉三个选人扩展（基线） | 卡在角色选择：P5 没有 FocusEmulator，没有光标，无法选择 |
| 4/5/8 人 × 2 波（无 CoopFix） | 三个选人界面 → 战斗 → 升级 → 商店，0 个脚本错误；4 人与原版相同 |
| 8 人可阵亡（带 CoopFix） | 选人 → 第 3 波阵亡进入结算，0 个脚本错误 |

### 退出后继续（证据 EV-0033、EV-0034）

`--coopplus-local-sim-continue`：不入座、不开新局，等标题界面出现后记录 `local_sim.continue.title`（“继续”是否可见、存档里的人数与商店数），再按“继续”。到 BO 的继续界面时，探针以离线继续的方式（管理器的 `_offline_resume`，会话管理器暂停）按存档人数入座，进入商店后记录 `local_sim.continue.shop`（每人数据与商店商品）。与 `--coopplus-local-sim-save` 一起用，两段共用同一份用户数据：

```powershell
pwsh ./tools/instance.ps1 -Action Start -Name sim -StopAfterSec 200 -ExtraArgs "--audio-driver,Dummy,--coopplus-local-sim=8,--coopplus-local-sim-seconds=20,--coopplus-local-sim-save,--coopplus-probe-quit,--coopplus-local-sim-waves=2"
pwsh ./tools/instance.ps1 -Action Start -Name sim -StopAfterSec 240 -ExtraArgs "--audio-driver,Dummy,--coopplus-local-sim=8,--coopplus-local-sim-seconds=20,--coopplus-local-sim-save,--coopplus-probe-quit,--coopplus-local-sim-waves=3,--coopplus-local-sim-continue"
```

第二段之前不要删除 `.local/userdata/instance-sim`。比较第一段的 `local_sim.final_shop` 与第二段的 `local_sim.continue.shop`：每人的商店、材料、经验、等级、武器与道具应完全相同。

| 运行 | 结果 |
| ---- | ---- |
| 8 人，扩展 BO 身份管理器的版本 | BO 的管理器无法编译（相对路径预加载，EV-0033），改为运行时调整 |
| 8 人 | 检查点 `00000005` 恢复，“继续”可见，8 人逐项相同，再打 1 波（EV-0034） |
| 4 人（原版路径） | 逐项相同（R08） |

本地模拟里没有 BO 会话，继续界面的身份为空，身份面板与 5～8 槽登记表的路径要在联机中验证（M1）。

### 战斗 HUD 位置（证据 EV-0035）

每次模拟在第一波结束后 0.4 s 和 1.5 s 各截一张战斗画面（`wave_end_1/2_<N>p.png`），同时记录 `local_sim.hud_layout`：每名玩家 HUD 块与待处理图标容器的屏幕矩形、材料袋的矩形与所在块、材料飞向的屏幕坐标。检查：P5～P8 的块与 P1～P4 不重叠；每人的图标容器与自己的块顶边（上方角落）或底边（下方角落）对齐；5 人以上材料袋在 `LifeContainerP5`，4 人在 `LifeContainerP1`。

实例窗口：`tools/instance.ps1` 默认加 `--no-window --coopplus-no-fullscreen --resolution 1920x1080`。新档默认全屏，以前启动时游戏会把隐藏窗口切成全屏、盖住桌面；现在扩展遇到 `--coopplus-no-fullscreen` 就跳过这一步（引擎会吞掉 `--no-window`，脚本看不到它），窗口一直隐藏，截图为 1920x1080。需要看窗口时用 `-ShowWindow`。

测试环境注意：实例窗口隐藏时，桌面上任何焦点切换都会让游戏收到“失去焦点”并打开暂停菜单（`input_service.gd:91-96`），波次停止。战斗场景和合作商店（`coop_shop.gd:38`）各自连接这个信号，商店里打开的暂停会带进下一波。探针在两处都断开连接，并在采样中记录 `paused`；看到全体同时静止时先查这个字段。模拟运行期间不要再启动其他游戏实例（新窗口会抢焦点）。

修复内容：`scripts/core/per_player_arrays.gd`（按 max(4, 人数) 只增不减地扩容）、`extensions/vanilla/run_data_ext.gd`（RunData/TempStats/LinkedStats/Utils 数组，含 RunData 三个重置函数之后）、`utils_ext.gd`（Utils 两个重置函数之后）、`popup_manager_ext.gd`（弹窗管理器五个数组）、`upgrades_ui_ext.gd`（合作升级界面补建 P5～P8 面板、属性弹窗、FocusEmulator 与界面数组；5～8 人的最终布局待 AP-014 样例确认）。
