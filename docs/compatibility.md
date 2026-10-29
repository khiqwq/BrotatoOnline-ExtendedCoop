# 兼容记录

`mods-unpacked/CoopPlus-OnlineExtendedCoop/compatibility.json` 由 `project.lock.json` 生成（`tools/check.ps1 -UpdateCompatibility`），运行时只读取它；本页是人工可读的支持记录。只有实测通过的组合才能标为“已支持”；未来版本不自动继承支持状态。

| 组合 | 游戏 | Mod Loader | Brotato Online | 扩展 | DLC | 其他 Mod | 状态 | 证据 |
| ---- | ---- | ---------- | -------------- | ---- | --- | -------- | ---- | ---- |
| C-01 | 1.1.15.4（build 23429717） | 6.3.0（内置） | 6.6.6，指纹 `17443875…b819` | 0.1.0 | Abyssal Terrors | 无 | 未验证 | — |
| C-02 | 同上 | 同上 | 同上 | 0.1.0 | 无 | 无 | 未验证 | — |
| C-03 | 同上 | 同上 | 同上 | 0.1.0 | 任意 | CoopFix-OnlineMouseUI 1.0.1（指纹 `811ebfa7…ee54`） | 未验证；允许共存（R07 由 D-011 改为可选共存）：指纹一致时超四人可用，其他版本超四人阻止。本地模拟中门控放行、点击经它的命中检测选中状态条（EV-0028）；联机未测 | EV-0028 |

状态取值：已支持 / 冲突（已阻止）/ 未验证。
