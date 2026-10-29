# Txx 用例模板

实例编号：`Txx-<人数>-<后端>-<场景>-<序号>`，例如 `T05-8-LAN-shop-01`。复制本模板为 `tests/scenarios/Txx-....md`，执行后在 `evidence/index.md` 登记。

## 元数据

| 字段 | 值 |
| ---- | -- |
| 用例实例 | |
| 关联 | 任务 AP-xxx / 需求 Rxx / 风险 Fxx / 缺陷 BUG-xxx |
| 提交与安装包 | commit `<sha>`；package SHA-256 `<sha256>`（未打包写“源码目录”） |
| 锁定环境 | project.lock.json 版本；游戏/上游指纹是否与锁一致 |
| 人数 / 后端 | 例：8 / LAN（8 个隔离实例） |
| 输入 / DLC / Mod 组合 | 例：全键鼠；Abyssal Terrors；无其他 Mod |
| 随机种子 / 事件序列 | |
| 超时界限 | 引用 docs/requirements.md 第 5 节对应条目，不得临时放宽 |

## 步骤

1. 触发步骤（精确到菜单/按键/注入命令）。
2. ……

## 预期

- 观测值与通过断言（引用 ACTION_PLAN 第 6 节对应 Fxx 的断言）。

## 实际

- 观测值：
- 恢复结果：
- 结果：PASS / FAIL / SKIPPED（SKIPPED 必须写原因，不计通过）

## 证据

- 日志：`evidence/raw/...`（脱敏，不含凭据或重连令牌）
- 录像/截图：
