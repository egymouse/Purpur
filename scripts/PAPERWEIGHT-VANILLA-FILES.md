# 修改「原版类」（只在 mc-dev-sources 缓存里的文件）并提交成 patch

针对本仓库的 paperweight 配置（`io.papermc.paperweight.patcher` **1.7.3**）。
目标：**任何文件都能改、都能提交成 patch，且 `applyPatches` 不冲突**。

> 现状：已接入构建，**不需要再手动做什么**。直接改文件 → commit →
> `./gradlew rebuildPatches`（会自动把 new-file 补丁转成修改型）→ `applyPatches`。

---

## 1. 机制（源码在 `paperweight-patcher-1.7.3-sources.jar`）

`applyPatches` 的真实流程（`tasks/ApplyPaperPatches.kt:112-172` / 本仓库实际用的
`patcher/tasks/PatcherApplyGitPatches.kt:110-167`）：

```
克隆 upstream → （拷贝 remapped 源码）→ McDev.importMcDev(patches=...)
→ git commit "Initial" → git tag base → git am --3way 全部 patch
→ makeMcDevSrc() 重建缓存
```

### 1.1 导入是「按补丁里出现的路径」驱动的

`util/McDev.kt:173-194` 扫描每个 patch 的 `+++ b/src/main/java/...` 行；
`McDev.kt:77-108` 对每个「反编译 jar 里有、目标目录还没有」的路径，先把**原版**文件拷进工作树。

| 补丁形态 | 结果 |
|---|---|
| **新增文件型**（`new file mode`） | 原版先被导入 → `git am` 两边都新增 → `both added` **冲突** |
| **修改型**（`--- a/` + `+++ b/`） | 原版先被导入 → 干净应用 **正确** |
| 真新文件（反编译 jar 里没有，如 `org/purpurmc/...`） | 不导入 → 新增型也能用 |

### 1.2 缓存每次 applyPatches 都会被删掉重建

`util/MakeMcDevSrc.kt:40-56`：先 `ensureDeleted`，再按「反编译 jar 减去工作树」重拷。

- 手改 `.gradle/caches/.../mc-dev-sources/**` **无效**，下次 `applyPatches` 就没了；
- 缓存的正确身份 = 工作树的补集，**不要提交、不要手改**；
- 脚本取原版内容的顺序因此是：**缓存 → `base` 提交 → 反编译 jar**（两者内容一致，
  缓存只是快，jar 才是权威）。

### 1.3 工作树也会被清空

`tasks/ApplyGitPatches.kt:192-211`：`reset --hard upstream/...` + `clean -fxd`。
未 commit 的改动、未跟踪文件（`.serena/`、`*.dat` 等）都会消失。

### 1.4 为什么改动能稳定复现

`RebuildGitPatches.kt:96-103` 用 `git format-patch base..HEAD`，而 `base` 里已经包含
被导入的原版文件。所以**文件一旦进过 `base`，之后的 diff 天然是修改型**。
唯一的问题是「第一次」：文件对树来说是新文件，format-patch 会输出整文件新增。

### 1.5 那 Paper / Purpur 自己怎么办？

它们不需要任何脚本，因为它们面对的 `base` 和这里不一样，或者踩一次坑就自愈：

1. **Paper 本体**用的是 `tasks/ApplyPaperPatches.kt`，第 131-138 行会先把
   **完整的 remapped 源码树**拷进 `src/main/java`，然后才应用补丁。于是 `base`
   里存在所有原版类，改任何 vanilla 类都是普通「修改」，根本不会出现 new-file。
2. **下游 fork**（本仓库；Purpur 也走这条路）用的是 `PatcherApplyGitPatches`，
   `base` = upstream 树 + 被补丁引用到的原版文件。第一次改某个没动过的原版类时
   必然产生 new-file 补丁，于是 `applyPatches` 冲突一次：
   ```
   CONFLICT (add/add): Merge conflict in src/main/java/...
   ***   Please review above details and finish the apply then
   ***   save the changes with `./gradlew rebuildPatches`
   ```
   按提示处理：解决冲突（保留你的版本）→ `git add` → `git am --continue`
   → `./gradlew rebuildPatches`。此时 `base` 里已经有了导入的原版文件，
   `format-patch` 直接把它重写成**修改型**补丁，之后永久正常。

   实测（本仓库）：
   | 步骤 | 结果 |
   |---|---|
   | 原生 `rebuildPatches` | `new file mode`，17618 字节 |
   | `applyPatches` | `CONFLICT (add/add)` + 上面的提示 |
   | 解决 + `git am --continue` | `base` 里是**原版**内容 |
   | 再 `rebuildPatches` | 变成 `--- a/ +++ b/`，970 字节 |
   | 再 `applyPatches` | `308 patches applied cleanly` |

   指纹证据：本仓库当前被导入的 **62 个原版类，全部出现在「修改型」补丁里，
   0 个位于 new-file 补丁**——正是这条「冲突一次 → rebuild 自愈」流程留下的痕迹。

所以 Paper/Purpur 的共同答案是：**要么 base 里本来就有全量原版类（Paper），
要么容忍一次冲突、修完再 `rebuildPatches`（下游 fork）**。本文的自动化只是把
这个一次性步骤做成了自动的。


---

## 2. 自动化：new-file → 修改型（已接入构建）

`build.gradle.kts` 末尾（`// Prism start - make "new file" patches ...`）：

```kotlin
tasks.named("rebuildServerPatches") { finalizedBy(prismNormalizeServerPatches) }
```

`scripts/pw-normalize-patches.ps1` 在 `rebuildServerPatches` 之后运行：

- 对每个 `new file mode` 且路径在 `src/main/java/` 下的补丁；
- 取原版内容（缓存 → `base` → 反编译 jar），与补丁里的新内容做 diff；
- 把整文件新增改写为 `--- a/... / +++ b/...` 的修改型补丁（`--full-index`）；
- 反编译 jar 里没有的类（`org/purpurmc/...`、`gg/pufferfish/...`）**原样保留**。

于是标准工作流变成：

```bash
# 1. 改文件（无论它在树里还是只存在于缓存）
# 2. 一个 commit = 一个 patch
git -C Purpur-Server commit -am "My change"
# 3. 重新生成补丁（自动规范化）
./gradlew rebuildPatches
# 4. 应用验证
./gradlew applyPatches          # N patches applied cleanly
# 5. 提交补丁
git add patches && git commit -m "My change"
```

只有第一次会走「转换」；一旦 `applyPatches` 成功，`base` 里就有了该文件，
后续 `rebuildPatches` 直接产出修改型补丁，规范化任务变 no-op。

### 2.1 手动兜底（不经过 rebuildPatches 时）

```powershell
./scripts/pw-add-vanilla-patch.ps1 `
    -Path net/minecraft/world/effect/MobEffects.java `
    -ModifiedFile .dsh-work/MobEffects.java `
    -Subject "Custom weakness tuning"
```

它为单个文件直接生成修改型补丁（原版 pre-image 来自缓存/base/jar），追加到补丁序列末尾。

---

## 3. 另一个选择：直接改插件（更彻底，但要 fork）

理论上最干净的改法是让 `importMcDev` **跳过「被补丁新增」的路径**，这样 new-file
补丁对原版类也能直接应用，连规范化都不需要。改动只有几行（`util/McDev.kt`）：

```kotlin
// 在 readPatchLines 旁边新增：收集 "new file mode" 的路径
private fun readNewFilePaths(patches: Iterable<Path>): Set<String> = buildSet {
    for (patch in patches) {
        val lines = patch.readLines()
        for (i in 0 until lines.size - 1) {
            val m = Regex("^diff --git a/\\S+ b/(\\S+)$").find(lines[i]) ?: continue
            if (lines[i + 1].startsWith("new file mode")) add(m.groupValues[1].removePrefix("src/main/java/"))
        }
    }
}

// importMcDev 里过滤掉
val newFiles = readNewFilePaths(patches)
val exactJavaImports = javaPatchLines
    .filterNot { newFiles.contains(it) }          // <-- 唯一的行为改动
    .filter { decompSourceFiles.contains(it) }
    .map { targetDir.resolve(it) }
```

代价与风险：

- 需要 fork `paperweight-patcher`、本地构建并发布（`mavenLocal` + `pluginManagement` 加仓库），
  本机当前**离线不可行**（Gradle 发行版/依赖下载超时）；
- 以后升级 paperweight 要重新 rebase 这几行；
- 语义变化：工作树里的原版类不再「先导入再做 diff」，你的补丁会**整文件拥有**该文件，
  上游（Paper/Purpur）对它的后续改动不会自动合并进来，需要你手动同步。

所以默认采用「生成时规范化」：不 fork 插件、不改变 apply 语义、补丁仍是精简的 diff，
上游改动仍可合并。

---

## 4. 验证清单

```bash
./gradlew applyPatches            # "N patches applied cleanly"
./gradlew :purpur-server:compileJava
git -C Purpur-Server show base:src/main/java/<path> | head   # base 里应是原版
```

- `Importing N classes from vanilla` 比上次 +1 → 说明新文件被正确导入；
- `git status` 干净（applyPatches 是重建，不是增量）；
- 树 + 缓存 ≈ 4053（互斥补集）。

---

## 5. 常见坑

| 现象 | 原因 | 处理 |
|---|---|---|
| `both added` 冲突 | 对原版类用了 new-file 补丁 | 跑一次 `./gradlew rebuildPatches`（自动规范化），或用手动脚本 |
| 改了缓存，`applyPatches` 后没了 | 缓存每次重建 | 永远别改缓存 |
| 未提交改动消失 | `clean -fxd` + `reset --hard` | 先 commit，或先复制出来 |
| `rebuildPatches` 重排整套补丁 / 多出 `0001-Initial.patch` | 提交数与补丁数不匹配（漏补丁或多 commit） | 保持「除 `base` 外每个 commit 对应一个 patch」 |
| `Unsupported class file major version 69` | Gradle 8.8 不支持 JDK 25 | `JAVA_HOME` 指向 JDK 21 |
| 脚本报「字符串缺少终止符」 | PowerShell 5.1 按 ANSI 读 `.ps1` | `.ps1` 保持纯 ASCII |
| `FileAlreadyExistsException`（缓存路径） | 缓存与工作树重叠 | 缓存中与树重名的文件删掉（会自动重建） |

---

## 6. 关键源码位置（1.7.3）

| 文件 | 作用 |
|---|---|
| `patcher/tasks/PatcherApplyGitPatches.kt:110-167` | 本仓库实际使用：导入、`commit Initial`、`tag base`、应用补丁 |
| `tasks/ApplyPaperPatches.kt:112-172` | 上游版本同类逻辑（含 remapped 源码拷贝） |
| `util/McDev.kt:173-194` | 从 patch 的 `+++ b/src/main/java/` 行收集导入路径 |
| `util/McDev.kt:77-108` | 过滤「jar 里有、目标没有」的文件并导入 |
| `tasks/ApplyGitPatches.kt:164` | `git am --3way --ignore-whitespace` |
| `tasks/ApplyGitPatches.kt:192-211` | `reset --hard upstream` / `clean -fxd` |
| `tasks/RebuildGitPatches.kt:96-103` | `format-patch base..HEAD` |
| `util/MakeMcDevSrc.kt:40-56` | 缓存 = 反编译 jar 减去工作树（每次重建） |
