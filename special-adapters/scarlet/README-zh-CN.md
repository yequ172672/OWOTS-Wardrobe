# Scarlet 专用衣橱适配器

这是对 `Scarlet-Model-1.1.0` 的人工迁移候选。它只能在衣橱运行时确认以下两个完整选择时启用：

- `scarlet_hat_static`
- `scarlet_no_hat_static`

适配器通过 `owots_appearance_lab.get_scarlet_adapter_snapshot()` 读取衣橱的只读快照。快照必须同时确认 BODY、HEAD、HAIR 的私有 PFB/catalog、catalog 行、当前 supporter 和 player entity。普通衣橱、切换中的模型、菜单暂停、旧 actor 或恢复未完成时，所有回调都会被门控。

## 文件与来源

- `src/scarlet_manual_adapter.lua`：由 `tools/derive_lua.py` 从审计过的原始 Lua 派生；不会加载原始 Lua 或 DLL。
- `src/scarlet_gate.lua`：选择、身份变化、重入和恢复失败隔离门。
- `manifest/runtime-path-map.json`：两个变体各 120 条完整 source→private target 路由，路径不使用开发机绝对路径。
- `manifest/actor-contract.json`：264 个 actor joints、577 个 body joints、11 个阶段和 actor 组件要求。
- `src/Scarlet*.cs`：独立的 .NET 10 生命周期、布料/髋部数学和资源契约，可供 OWOTS runtime 整合。

原作者为 **Little1113**。原 `scarlet_native_adapter.lua` SHA-256 为 `B280101CDEC954F73EACE41527379500E6367504644F775B72291FC2A160A272`。

## 已迁移行为

适配器保留了原算法的边界和回调顺序：11 个 native constraint 阶段、7 个连贯布料根（默认响应比例 `0.05`）、髋部 `.35/.55` 平滑门、延迟 sheath IK、左臂握刀修正、刀鞘释放、动态 motion/chain/weapon/visual/sheath/AAA 私有资源隔离，以及按 actor 所有权恢复。

武器和刀鞘逻辑只接受适配器自己持有的 Scarlet actor、motbank、USER 和 mesh。它不会改公共武器 ID、存档或其他 MOD 的对象；发现外部写入时保留外部值并停止释放该 lease。

HEAD/HAIR 已有静态衣橱 catalog 时，原动态 parts router 会完全停用，避免重复占用 ID 或覆盖其他衣橱。动态资源仍由同一衣橱 ID 的私有路径选择。

## Actor 合约是硬前提

Scarlet 的 whole-player `player.pfb.18` 比 stock player 多 110 个 RSZ 实例；前 261 个实例逐项一致，新增部分包括：

| 组件 | Scarlet 独有数量 |
| --- | ---: |
| `via.motion.ConstraintJoints` | 4 |
| `via.motion.ConstraintParent` | 36 |
| `via.motion.ConstraintTargetJoint` | 62 |
| `via.motion.JointConstraints` | 3 |
| `via.motion.JointConstraintsLayer` | 8 |

静态衣橱 PFB 不会创建这些 actor 级组件，当前候选也不会替换全局 player PFB。运行时缺少这些组件、正确的 264/577 joints、正确的所有权或两个仍未补齐的设置类时，适配器必须报告 `actor_contract_missing`/`unresolved_actor_setting_template` 并保持禁用。不能把静态衣橱包宣称为完整动态等价实现。

需要补齐的设置类已在 `manifest/actor-contract.json` 中记录：

- `0x072c4ea0` — `app.CharacterTimelineEventActorPlayer.cVirtualGroundHeightOffsetSetting`
- `0xdd674fdf` — `app.CharacterTimelineEventActorPlayer.cOverwriteSpecificWeaponDrawSetting`

这两类不能通过猜字段布局解决。应在专用 actor 实例或已验证的现有 actor 合约中提供；不得把整个原 Scarlet PFB 覆盖到所有玩家。

追加组件之外还存在一个版本化解析边界：`via.dynamics.Ragdoll` 在 Scarlet
whole-player PFB 中是 v10、偏移 `0x5DF0`，stock/game PFB 对应为 v12、偏移
`0x56B0`。现有解析器无法证明这两个布局可以安全重写，因此 110 个追加
actor 实例的创建和 Ragdoll 迁移仍未实现。这个状态记录在
`manifest/actor-contract.json` 和 `manifest/runtime-path-map.json`；不能只补齐
上面的两个设置类就宣称 actor 合约完成。

### 重置与线程边界

`re.on_script_reset` 只写入 `restart_required`/`restart_reason` 标量，不调用
`close()`、native getter/setter 或恢复处理器，因为 ScriptRunner 可能从
UI/render 线程派发 reset。BeginRendering、UpdateMotion 和其他 native hook 的
门控拒绝也只停止本次回调并把恢复标记排队；注册的恢复处理器只由已知游戏线程
的 `UpdateConstraintsEnd` 调用 `scarlet_gate.flush_restore()`；处理器覆盖私有部件
路由、Prop lease、刀鞘释放和动态隔离。actor 只读预检的 `read_only` 标志会穿过
resolver 装饰器，不能在 render/UI 线程退休 native source lease。恢复失败会保持
`restore_pending`/quarantine，直到所有自有 lease 通过所有权检查恢复。

## 离线验证

在仓库根目录运行：

```powershell
dotnet build re-engine-mcp-CN\special-adapters\scarlet\src\Scarlet.Adapter.csproj --configuration Release --nologo
dotnet run --project re-engine-mcp-CN\special-adapters\scarlet\tests\Scarlet.Adapter.Tests.csproj --configuration Release
python re-engine-mcp-CN\special-adapters\scarlet\tools\derive_lua.py
```

离线测试覆盖衣橱 ID/私有路径、路径穿越、11 阶段顺序、7 根布料、髋部曲线、重复帧、选择切换、actor generation 变化、动态依赖缺失和恢复失败隔离。Lua 派生工具只做受限文本变换和路径校验，不执行 Lua。

## 游戏线程验收步骤

当前工作区没有执行真实游戏验收，`runtimeGameTested=false`。在隔离的测试配置中由整合方完成：

1. 准备带衣橱 bridge 的 OWOTS REFramework runtime，并确认 bridge 的快照字段来自当前生效的 BODY/HEAD/HAIR，而非保存的意图状态。
2. 先准备单独验证过的 Scarlet whole-player actor 合约：必须提供 264/577 joints、11 个角色组件、追加的 110 个 RSZ 实例、两个设置类和已验证的 Ragdoll 版本布局。当前静态衣橱包没有这部分，因此在现有工作区直接安装静态包时，预期结果就是 `actor_contract_missing`、`blocked_actor_contract`，gate 保持禁用，不会进入 rig、weapon、cloth 或 native 阶段；不要继续观察阶段输出来推断迁移成功。
3. 只有在上述 actor 合约已经由整合方提供并完成只读结构验证后，才安装一个静态变体及其对应动态资源；一次只启用一个 `scarlet_*_static` ID。
4. 进入有 player actor 的场景，确认预检先通过，再等待 `ready=true`、`catalogRowsVerified=true` 和 supporter/entity 地址非零。
5. 观察 `scarlet_gate.status()` 和 `_G.scarlet_manual_adapter.status()`：应看到 11 个阶段按序运行、布料没有 scale 写入、动态资源路径都带当前衣橱 ID。
6. 在 hat↔no-hat、Scarlet↔普通衣橱、场景重建/角色替换、菜单暂停和外部武器 MOD 变化之间切换。每次都应先恢复自有写入；恢复失败必须保持 quarantine 并重试，不能重新启用。
7. 若出现 `actor_contract_missing`、资源/类型 CRC 不匹配、路径不一致、`restart_required` 或 `restore_pending`，停止测试并保留诊断 JSON。不要用原始 DLL/Lua 绕过门控。

验收通过前只能称为“人工迁移候选”；静态外观包和动态算法的离线测试结果不代表游戏内视觉或 native 回调已经通过。
