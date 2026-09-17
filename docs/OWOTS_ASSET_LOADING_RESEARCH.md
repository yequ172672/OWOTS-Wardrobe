# OWOTS 额外外观资源加载调查

调查日期：2026-09-14  
范围：只读检查本地 `REFramework-cn` 源码、OWOTS 已部署 C# 示例和外观系统需求。没有连接正在运行的游戏，没有修改 `REFramework-cn`，也没有做骨骼验证或重定向。

主代理后续实测补充：独立路径的 `.user` 与 `.pfb` 已成功加载，Prefab Ready=true、Valid=true，见 OWOTS_APPEARANCE_RUNTIME_RESEARCH.md。以下正文保留最初只读调查的证据边界；纹理专用映射不能代表通用 LooseFileLoader 的格式范围，不能据此推断只有纹理可加载。

## 结论先行

1. **OWOTS 的版本门槛满足现有松散资源路径。** `GameIdentity` 将 `onimushawots` 和 demo 映射为 `ONIMUSHA_WOTS`（`REFramework-cn/shared/sdk/GameIdentity.cpp:113-116`），并把该游戏的 TDB 设为 82（同文件 `:359-366`）。因此 TDB>=81 的 `LooseFileLoader` 和 `LooseTextureLoader` 路径适用。
2. **独立纹理路径在源码设计上可行，但必须先被请求。** 纹理加载器只在资源路径哈希函数看到 `.tex` 路径时检查磁盘；它不会扫描目录或自动注册一个未被游戏请求的文件。C# `CreateResource(typeName, resourcePath)` 可主动发起资源请求，再通过 holder 绑定到组件；这使“独立路径 + 主动引用”成为可行方案。这里关于“自定义 loose `.tex` 经 `CreateResource` 可用”的结论是源码推断，本次没有运行时验证。
3. **独立路径不覆盖原生资产的条件是路径唯一且使用正确的资源根。** 当前实现按解析后的完整路径调用 `std::filesystem::exists`；它不把所有资源重映射到一个全局替换文件。因此可使用 `natives/STM/<mod-id>/...` 这类唯一命名空间（或 native path resolver 实际返回的等价路径），并在资源 API 中传入与游戏资源命名一致的相对路径。若使用与原生资源相同的规范路径，行为就是同路径 loose override，多个 MOD 也会发生冲突。
4. **纹理专用附加处理只明确列出纹理；不能据此否定通用 loose 加载其它格式。** `ResourceType` 虽有 `Mesh`、`Material` 枚举值，但 `ResourceTypeInfoMap` 只有 `.tex` / `via.render.TextureResource` 条目（`REFramework-cn/src/mods/LooseTextureLoader.hpp:33-50`）。没有在本地源码中找到 mesh、material、skeleton 或 physics 的独立路径映射和绑定示例。通用 `ResourceManager` API 理论上可以接受其它有效 `via.typeinfo.TypeInfo`，但这不等于 OWOTS 已经具备这些类型的 loose DStorage 加载或组件绑定。
5. **骨骼/物理只应作为资源引用和生命周期问题处理。** `Resource::create_holder` 只检查目标类型是否属于 `via.ResourceHolder`，创建 holder，并把资源指针写入 holder（`REFramework-cn/shared/sdk/ResourceManager.cpp:43-63`）；源码没有骨名、层级、绑定关系、动画兼容性检查，也没有修复、转换或动画重定向。这符合 `OWOTS_APPEARANCE_SYSTEM_REQUIREMENTS.md:44-51`：MOD 自行保证资产可用，系统只负责引用、应用、解绑和释放。

## 1. 运行时门槛和加载链

### 1.1 OWOTS 版本与初始化

- OWOTS 可执行文件名被识别为 `ONIMUSHA_WOTS`（`REFramework-cn/shared/sdk/GameIdentity.cpp:113-116`），运行时 TDB 为 82，并启用 packed/AT 标志（同文件 `:359-366`）。
- `LooseFileLoader::early_initialize` 只在 TDB>=81 时安装 path-to-hash hook，并初始化纹理加载器（`REFramework-cn/src/mods/LooseFileLoader.cpp:488-493`）。
- `LooseFileLoader` 的主开关由 `ModToggle::create(generate_name("Enabled"))` 创建（`REFramework-cn/src/mods/LooseFileLoader.hpp:70-74`）；`ModToggle::create` 的默认参数为 `false`（`REFramework-cn/src/Mod.hpp:85-95`）。所以部署后必须确认 LooseFileLoader 主开关实际启用，不能只依赖 LooseTextureLoader 的默认开关。
- 纹理加载器自身的 `m_enabled` 默认值是 `true`，强制重载开关默认值是 `false`（`REFramework-cn/src/mods/LooseTextureLoader.hpp:111-129`）。初始化会安装 DStorage 路径检查、上传链、资源路径哈希和 native path resolver hook（同文件实现 `REFramework-cn/src/mods/LooseTextureLoader.cpp:124-134`）。这些 hook 任一关键扫描失败时，独立路径能力不能视为成立；源码只记录错误，没有通用回退。

### 1.2 LooseFileLoader 的实际判断

`handle_path` 的核心条件是：路径非空，主开关启用，然后对**传入的规范路径**使用 `std::filesystem::exists`（`REFramework-cn/src/mods/LooseFileLoader.cpp:326-348`、`:350-437`）。找到文件后返回 `true`；path-to-hash hook 随后返回特殊 loose sentinel `4294967296`，旧调用约定返回 `0xFFFFFFFF`（同文件 `:439-458`）。

这条链有两个直接含义：

- 资源必须经过游戏的 path-to-hash/资源创建流程；loader 没有目录枚举、MOD 注册表或“看到新文件就加载”的逻辑。
- “独立路径”只改变被请求资源的名字和文件位置；它不会替换其它名字的原生资源。相同名字/相同规范路径则会进入同一个 loose 判断，因而是覆盖或冲突场景。

`can_loosely_load_file` 在 TDB>67 时确保 hook 存在，调用原始 hash 后再次走 `handle_path`（`REFramework-cn/src/mods/LooseFileLoader.cpp:461-486`）。这是纹理加载器检查候选文件的入口，也意味着 hook 未成功时不会误报“可加载”。

### 1.3 纹理路径的规范化与 DStorage

`LooseTextureLoader::handle_resource_hash_path` 只接受 `ResourceTypeInfoMap` 能识别的后缀；当前唯一条目是 `.tex`，其它路径从纹理专用处理直接返回（`REFramework-cn/src/mods/LooseTextureLoader.cpp:704-734`，类型表见 `REFramework-cn/src/mods/LooseTextureLoader.hpp:33-50`）。

对 `.tex` 路径，它会：

1. 去掉可选的 `@` 前缀，并把它转成 `localize` 参数（`REFramework-cn/src/mods/LooseTextureLoader.cpp:736-743`）。
2. 优先调用游戏 native path resolver，失败时回退为 `natives/STM/` + 资源相对路径（同文件 `:745-766`）。
3. 把这个解析结果交给 `LooseFileLoader::can_loosely_load_file`；文件不存在就退出，不改资源 hash（同文件 `:768-771`）。
4. 正常模式下只记录计数而保留原 hash（同文件 `:773-793`）；只有启用 `DisableTextureCache` 才把计数追加到 hash path（同文件 `:795-802`）。

为使 loose `.tex` 走 DirectStorage 上传，代码会把包含 `.tex` 的检查路径改成 `.tex.`（`REFramework-cn/src/mods/LooseTextureLoader.cpp:603-614`），并为没有 PAK entry 的流临时借用 fake entry（同文件 `:656-675`、`:677-701`）。这证明代码针对“磁盘上的 loose 纹理流”提供了额外上传处理。它不证明 mesh/material/skeleton/physics 需要同一处理：通用 LooseFileLoader 不按该映射表限制扩展名，应另做实测。

## 2. C# 资源创建、holder 绑定和生命周期

### 2.1 API 的类型和名字

C# API 的文档明确区分两种名字：`ResourceManager.CreateResource` 的 `typeName` 是 `via.typeinfo.TypeInfo` 名称，`name` 是 PAK/资源路径；失败返回 `null`（`REFramework-cn/csharp-api/REFrameworkNET/ResourceManager.hpp:13-29`）。实现把字符串传给 native resource manager，并在 native 返回空时返回 null（`REFramework-cn/csharp-api/REFrameworkNET/ResourceManager.cpp:10-22`）。C ABI 也注明 `create_resource` 的第二个参数是资源类型、第三个是 PAK 路径（`REFramework-cn/include/reframework/API.h:322-332`）。

插件 ABI 通过 `reframework::get_types()->get(type_name)` 查找 TypeInfo，再调用 `ResourceManager::create_resource`（`REFramework-cn/src/mods/PluginLoader.cpp:456-488`）；这不是 `TypeDefinition`。相反，`Resource::CreateHolder` 接受 TypeDefinition 名称（`REFramework-cn/csharp-api/REFrameworkNET/Resource.hpp:22-30`），底层通过 `find_type_definition` 创建 holder（`REFramework-cn/src/mods/PluginLoader.cpp:490-507`）。因此外观系统至少需要分别确认：资源创建的 TypeInfo 名称、组件所需 holder 的 TypeDefinition 名称、以及组件属性/方法。

### 2.2 holder 的实际语义

底层 `Resource::create_holder` 的实现只做以下事情：检查目标类型非空且 `is_a(via.ResourceHolder)`，调用 `create_instance_full`，增加资源引用计数，并把资源指针写入 holder（`REFramework-cn/shared/sdk/ResourceManager.cpp:43-63`）。这是一种通用的资源持有/绑定机制，不是骨骼兼容性验证器。`AddRef`、`Release` 和 `CreateHolder` 的 C# 转发也只是调用相应 native 函数并包装返回对象（`REFramework-cn/csharp-api/REFrameworkNET/Resource.cpp:9-30`）。

`API.GetResourceManager()` 要求 REFramework.NET API 已初始化；manager 不存在时返回 null（`REFramework-cn/csharp-api/REFrameworkNET/API.cpp:214-224`）。插件应在合适的游戏生命周期回调中调用，并对 null 和对象存活状态做检查。

### 2.3 OWOTS 本地示例（源码证据，不是本次实测）

已部署的 `D:\gametest\steamapps\common\OnimushaWotS\reframework\plugins\source\Minimap.cs` 证明 OWOTS 侧的 API 链可以被实际插件使用，但它引用的是已知原生资源路径：

- GUI：`via.gui.GUIResource` + `GUI/Minimap/MinimapEnemies.gui`，创建 `via.gui.GUIResourceHolder`，再赋给 GUI 的 `Asset`（`Minimap.cs:1987-2010`）。
- 纹理：按 `via.render.TextureResource` + `definition.ResourcePath` 创建，生成 `via.render.TextureResourceHolder`，调用 `texture.setTexture(holder)`（`Minimap.cs:2356-2392`）。纹理路径由原生 GUI 数据推导为 `GUI/ui_texture/tex_map/tex_{name}_IMLM3.tex`（`Minimap.cs:2588-2608`），并非独立 MOD 资源。
- 生命周期：helper 调用 `API.GetResourceManager().CreateResource` 后显式 `AddRef`；切换/回滚时 `Release`（`Minimap.cs:4238-4266`），解绑纹理时调用 `setTexture(null)`（`Minimap.cs:4276-4289`）。

因此这个示例支持“创建资源 → 创建 holder → 设置组件 → 持有引用 → 解绑/释放”的生命周期模型，但没有证明自定义 loose `.tex`、mesh、骨骼或物理文件已经在 OWOTS 中成功加载。

## 3. 独立路径、不覆盖原生资产的可行条件

| 条件 | 源码依据 | 结论 |
| --- | --- | --- |
| OWOTS TDB 版本和 loader hook 可用 | `GameIdentity.cpp:113-116,359-366`；`LooseFileLoader.cpp:488-493` | OWOTS 满足 TDB>=81；需确认 path-to-hash、DStorage 和资源 hash hook 都成功。 |
| 主开关已启用 | `LooseFileLoader.hpp:70-74`；`Mod.hpp:85-95` | LooseFileLoader 默认关闭；没有它，纹理 loader 的文件存在判断会失败。 |
| 资源真的被请求 | `LooseFileLoader.cpp:439-458`；`LooseTextureLoader.cpp:704-734` | 仅在游戏/插件调用资源创建或其它引擎路径请求时生效；放文件本身不会加载。 |
| 当前实现支持的后缀 | `LooseTextureLoader.hpp:33-50`；`LooseTextureLoader.cpp:723-734` | 纹理专用附加映射只有 `.tex`；其它格式仍应单独测试通用 LooseFileLoader。 |
| 文件放到解析后的实际路径 | `LooseTextureLoader.cpp:745-771`；`LooseFileLoader.cpp:328-330` | 优先以 native resolver 返回值为准；fallback 是 `<游戏根>/natives/STM/<相对路径>`。 |
| 资源类型、holder 类型、组件属性匹配 | `ResourceManager.hpp:19-23`；`Resource.hpp:28-30`；`ResourceManager.cpp:43-63` | 需要分别提供 TypeInfo、ResourceHolder TypeDefinition 和组件赋值逻辑；API 不会自动绑定。 |
| MOD 之间不冲突 | `LooseFileLoader.cpp:350-437` | 使用稳定且唯一的 `mods/<作者或ID>/...` 资源路径；不要复用原生路径或其它 MOD 的路径。 |
| 常规切换不产生重复实例 | `LooseTextureLoader.cpp:80-89,791-802` | 保持 `DisableTextureCache=false`；强制重载只适合编辑阶段，会创建重复纹理实例并增加内存。 |

推荐的纹理命名形态是资源 API 使用的相对路径，例如 `mods/<mod-id>/outfit_a/body.tex`，磁盘 fallback 对应 `natives/STM/mods/<mod-id>/outfit_a/body.tex`。这条具体目录映射是根据源码 fallback 的推断；如果 OWOTS native resolver 对该类型返回其它绝对/相对路径，应以 resolver 和 loader 日志中的实际规范路径为准。路径唯一时，原生资源仍由自己的路径请求；相同规范路径则会故意进入 loose override，不能称为独立资产。

## 4. mesh、材质、骨骼和物理

- **mesh/material：未得到当前实现的独立加载证据。** 枚举中有 `Mesh`、`Material`，但 `ResourceTypeInfoMap` 没有对应扩展名、TypeInfo 或 holder；因此 `handle_resource_hash_path` 看到非 `.tex` 路径会直接返回。通用 `LooseFileLoader` 仍可能观察到某些普通 path-to-hash 调用，但源码没有为这些资源提供 TDB82 DStorage 上传和解析链，不能把它当作已支持。
- **骨骼/物理资源：没有自动绑定支持证据。** `ResourceManager` 的 `create_resource` 是通用的，理论上可尝试有效的 OWOTS TypeInfo；但必须知道该资源的真实类型名、资源路径、holder 类型，以及服装/武器组件接受它的属性或方法。当前本地源码没有这些骨骼/物理 TypeInfo、holder 和赋值流程。
- **没有兼容性检查。** holder 创建只验证 `via.ResourceHolder` 继承关系并写入资源指针（`ResourceManager.cpp:43-63`），不会检查骨名、层级、绑定关系或动画兼容性，也不会重定向动画。实现阶段应保持“引用、切换、解绑、释放”范围，不把骨骼验证器加成注册前置条件。
- **FaultyFileDetector 只记录失败。** 在 TDB>=81 时初始化（`REFramework-cn/src/mods/FaultyFileDetector.cpp:662-672`）；它调用原始 `create_resource`，若返回 null 就记录 MissingFile 后原样返回（同文件 `:365-375`），所以不能用它补救错误路径，也不能据此证明资源已加载。

## 5. 本次验证边界

### 源码推断

- OWOTS TDB82 可进入 TDB>=81 loader 路径。
- 以唯一资源路径主动 `CreateResource`，并创建合适 holder，是独立纹理资源的预期调用链。
- 文件必须存在于 loader 解析后的规范路径；不请求就不会加载；同路径会与原生或其它 MOD 冲突。
- 当前 `LooseTextureLoader` 只明确处理 `.tex`。

### 本地示例证据

- OWOTS 的 `Minimap.cs` 已包含 native GUI/texture 的 `CreateResource`、`CreateHolder`、组件赋值、引用保留和释放代码（见上面的行号）。这证明 REFramework.NET 资源 API 在该部署环境有实际使用样例，但路径均为原生资源路径。

### 本次未做的实测

- 没有向正在运行的游戏发送请求，也没有通过 live session 创建独立 `.tex`、mesh、material、skeleton 或 physics 资源。
- 没有验证自定义 loose `.tex` 能否被 OWOTS 的 `CreateResource` 解析、上传和显示；也没有验证资源切换后的缓存行为。
- 没有进行骨骼检查、修复、转换、动画重定向或物理兼容性验证。

后续若要在主代理的独占游戏会话中验证，最小安全实验应使用唯一的 `mods/<mod-id>/...tex` 路径、保留原生资源引用作为对照，并只验证资源创建/holder 绑定/解绑/Release；不要把实验文件放到原生资源规范路径。

