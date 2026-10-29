# 超四人联机合作扩展（BrotatoOnline-ExtendedCoop）

独立扩展 Mod `CoopPlus-OnlineExtendedCoop`（中文名「超四人联机合作扩展」）：配合**未经修改**的工坊版 Brotato Online（`six666-BrotatoOnline` 6.6.6），让《土豆兄弟》联机合作支持每机一人、最多 8 人。

当前状态：M0/M1 之间。容量与虚拟输入原型（AP-006）已在单个隔离实例中验证：容量 8、1 本地 + 7 名模拟远程玩家各自独立输入、第 9 人被拒、移除后恢复。单机本地模拟（模拟控制器）中，5～8 人可以连续多波完成战斗、升级、商店与结算：战斗 HUD、升级、商店、结算界面支持 P5～P8，5～8 人时每台电脑只放大显示本机玩家的面板、其余玩家收进状态条（显示武器；在商店和结算界面可用手柄或鼠标选择某人，展开其面板与本机面板平分左侧，鼠标需 CoopFix-OnlineMouseUI 1.0.1，现可与超四人共存），也可按 V / 手柄 Back 键切换为原版式的四人视图并左右逐个切换玩家；打开存档时 5～8 人局写入独立检查点，不写坏原版存档。角色、武器、难度选择界面也支持 5～8 人（本地模拟可从选人一路进入战斗）。尚未用真实客户端联机测试；房间类型、退出后继续 5～8 人局仍未完成，**还不能安装给玩家使用**。执行计划见 [docs/plan/ACTION_PLAN.md](docs/plan/ACTION_PLAN.md)，任务状态见 [docs/tasks.md](docs/tasks.md)。

## 目录

| 路径 | 内容 |
| ---- | ---- |
| `mods-unpacked/CoopPlus-OnlineExtendedCoop/` | Mod 本体（manifest、入口、规则模块、扩展、UI） |
| `mods-unpacked/.../debug/` | 测试专用故障注入，打包时排除 |
| `tests/unit/` | 纯规则测试，只需引擎即可运行 |
| `tests/integration/` | 依赖还原游戏工程与上游 Mod 的契约测试 |
| `tests/scenarios/` | 实机用例 Txx 与证据模板 |
| `tools/` | setup / check / test 入口；`tools/recovery/` 为本机审计用的脚本还原工具 |
| `docs/` | 需求、兼容记录、限制审计、ADR、runbook |
| `evidence/` | 证据索引（原始日志/录像放 `evidence/raw/`，不入库） |
| `.local/` | 本机忽略目录：引擎副本、还原的游戏脚本、隔离用户数据、报告 |

## 开发环境

需要：Windows、PowerShell 7.4+、已安装的 Brotato 1.1.15.4（含工坊订阅 Brotato Online）、Python 3.12（仅 setup 的脚本还原步骤使用；没有 Python 时集成测试标记为 SKIPPED）。不需要单独安装 Godot：测试使用复制到 `.local/engine/` 的游戏自带引擎，版本与目标完全一致（见 [ADR-000](docs/adr/ADR-000-test-runtime.md)）。

```powershell
pwsh ./tools/setup.ps1 -GamePath "<Steam 库>\steamapps\common\Brotato"
pwsh ./tools/check.ps1
pwsh ./tools/test.ps1 -Suite Unit
pwsh ./tools/test.ps1 -Suite Integration -GamePath "<Steam 库>\steamapps\common\Brotato"
```

- `setup.ps1` 只读取游戏与工坊目录，核对 [project.lock.json](project.lock.json) 中的哈希和规范化指纹，把引擎副本、上游 Mod 解包和还原的游戏工程放进 `.local/`。它不会写入游戏目录，也不会安装或替换任何 Mod。
- `check.ps1` 检查 manifest、`compatibility.json` 与锁文件一致、打包白名单、GDScript 源码规则，并编译纯规则模块。`-UpdateCompatibility` 在审核锁文件变更后重新生成 `compatibility.json`。
- `test.ps1` 运行时把 `APPDATA` 指向 `.local/userdata/` 下的独立目录，测试不会读写玩家的真实存档。`-Suite RunnerSelfTest` 证明运行器会把失败用例报告为失败。
- 所有入口出错时返回非零退出码；条件不具备的检查记为 SKIPPED 并写明原因，不算通过。

打包（`package.ps1`/`verify-package.ps1`）在 AP-022 实现。

## 不入库的内容

游戏文件、还原出的游戏脚本和资源、测试存档、Steam 数据、重连令牌、缓存都只在 `.local/`，由 `.gitignore` 排除，打包使用白名单。

## 许可

GPL-3.0，见 [LICENSE](LICENSE) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
