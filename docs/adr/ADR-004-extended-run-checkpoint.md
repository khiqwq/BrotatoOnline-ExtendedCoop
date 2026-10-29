# ADR-004：5～8 人局内存档的隔离检查点

日期：2026-10-28。状态：已采用（写入路径）；继续游戏（读档恢复）在 AP-016/AP-017 完成身份合并后补充。关联：AP-016、R12、R13、F13、F14、[limits-audit](../limits-audit.md) SAVE-01～SAVE-16、[ADR-001](ADR-001-extension-loading.md)、证据 EV-0026、EV-0027。

## 背景

- 原版 v3 读写器在序列化和反序列化局内状态时，把 `shop_items`、`locked_shop_items` 固定建成 4 项（`progress_data_loader_v3.gd:390`、`:406`、`:603-613`）。
- 5 人以上在商店按“出发”时，调用链是 `save_run_state` → `ProgressData.save()` → `serialize_run_state`，写第 5 人的商店条目时越界。release 引擎上越界读取得到 null，接着对 null 调用方法，进程直接退出（EV-0026）。
- 读档时会丢掉第 5 人起的商店数据（SAVE-01）。
- 所有局内存档都汇聚到 `ProgressData.save()`（SAVE-04），包括：
  - 商店出发；
  - Brotato Online 的重试守卫与移除玩家；
  - RunData 的“重试本波”（`reset_and_save_run_state`）。
- Brotato Online 的 `extensions/progress_data_removed_players.gd` 已经扩展了 `save()`、`reset_and_save_new_run_state()` 与 `get_run_state()`。

## 选择

1. 扩展 `res://singletons/progress_data.gd`（`extensions/vanilla/progress_data_ext.gd`，在 `mod_main._init` 安装）。它叠加在 Brotato Online 的扩展之上（ADR-001 规则 3），调用父方法时 Brotato Online 的逻辑照常执行。
2. `save()`：
   - 状态不超过 4 人，或没有进行中的局：原样交给父类（R08）。
   - 超过 4 人：
     1. 序列化：原版序列化器处理前四人的商店条目和其余全部字段，第 5 人起的商店条目按原版同一形状 `[item.serialize(), 值]` 追加（`scripts/persistence/extended_run_state.gd`）。不复制原版代码（D-006）。
     2. 写入隔离检查点 `<SAVE_DIR>/coopplus_runs/profile_<档位>/`（`scripts/persistence/checkpoint_store.gd`：暂存 → 回读校验 → 提交记录 → 保留上一副本；中断任一阶段仍可读上一有效检查点）。载荷记录 schema、人数，以及游戏、Brotato Online 与本扩展的版本。
     3. 原版存档写入占位：`has_run_state = false`，加标记 `coopplus_extended_run = {run_id, checkpoint_id, players, reason}`。原版和未装本扩展的游戏读到的是有效存档、无进行中局；永久进度与设置照常写入。
     4. 内存中的完整状态立即恢复，游戏继续使用它。
   - `DebugService.disable_saving`，或存档已损坏（`CORRUPTED_ALL_SAVES_NO_*`）：与原版一样，什么都不写。
3. 一个档位只有一局进行中（与原版一致，SAVE-16）。档位换成别的局内状态时删除检查点，包括：
   - `reset_and_save_run_state` 传入不超过 4 人的状态（局结束、新局、重开）；
   - 1～4 人的局在商店存档。

   “重试本波”（`RunData.reset_to_start_wave_state`）和 Brotato Online 的重试守卫保存的仍是 5～8 人状态，所以检查点保留并更新。
4. Bug reporter 的存档副本（`get_current_save_object` → `_get_current_run_state`）同样会序列化实时状态，5～8 人时返回占位。
5. Brotato Online 的身份侧车在保存期间看到的是占位（无进行中局），不为这一局写身份。5～8 人的身份与检查点合并留到 AP-016/AP-017（SAVE-08～SAVE-12）。

## 后果

- 5～8 人局可以正常推进多波，存档不会崩溃，也不会写坏原版存档；1～4 人的存档与原版相同；局结束时检查点随之删除（均见 EV-0027）。
- 退出游戏后暂时不能继续这一局：标题界面没有“继续”，检查点保留在磁盘上，等恢复路径实现后可用。
- 卸载本扩展后：原版读档得到完整进度、无进行中局；`coopplus_runs/` 目录残留，不影响原版。
- 每次 `save()`（包括战斗中完成挑战）都会重写检查点，当前副本轮换为上一副本。检查点只有几十 KB，可以接受。

## 未决

- 读档恢复：标题界面的继续入口、反序列化（第 5 人起商店条目的反向处理）、schema 与版本校验、明确拒绝不支持的检查点。
- 身份与状态同一检查点提交（SAVE-10），以及 Brotato Online 继续流程的人数上限（SAVE-11、SAVE-12）。
- 客户端各自的局内检查点（SAVE-14）：所有机器必须安装同一扩展，由能力协商（AP-009）保证。
