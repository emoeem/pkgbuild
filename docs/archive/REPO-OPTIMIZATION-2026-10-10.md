# 我对你的仓库做了什么、怎么优化的、优化完有什么用

日期：2026-10-10 　范围：`e9e6b5b` → `c00fcb2`（**18 个提交，131 个文件，+11673 / −811**，全部已推到 `origin/main`）

- 你的宿主工作树 `/home/emo/pkgbuild-source`（75 项 WIP、HEAD `58e7c75`）**全程没动**。
- 所有落地都在干净 worktree `/tmp/wip-land`（分支 `feat/build-platform`，基线 = `origin/main`）里做，改完 `git push origin HEAD:main`。
- 当前 `origin/main = c00fcb2f2c44c5e21e56736ebff7e7dbe8b7b65a`。

一句话：**先把「检测本身是坏的」修好（原来很多门禁看着绿、其实没在检查），再把检查收成一个本地也能跑的入口，最后把你未提交的构建平台 WIP 并入 main、并用真跑把它暴露的缺陷逐个修掉。**

---

## 0 总账

| 类别 | 提交 | 规模 |
|---|---|---|
| 检测修复（soname / 漂移 / 运行时校验） | `e9e6b5b` `a1df87c` `18baad8` `183df01` `d123eca` | 5 提交 |
| 静态策略与门禁（manifest 门禁、`.rebuild-on`、静态检查单一入口） | `654dd6f` `857b799` `d0b4418` | 3 提交 |
| 构建平台并入 main | `a4e0638` | 99 文件 +9066/−505 |
| CI/镜像/容器套件修复 | `39b92cb` `0b74b60` `1105518` | 3 提交 |
| 两包退役（daed-emo、linuxqq-clipsync-git）及退役前修复 | `e7b39bf` `8fd3908` `e1edae1` `3a8e5d6` `2679446` | 5 提交 |
| 文档（审查记录、真跑复盘） | `c00fcb2` | 1 提交 |

验证基线：`bash scripts/run-static-checks.sh` **11/11**；`./tests/run-all.sh --fast` **78 passed / 0 failed**；`actionlint` 对 8 个 workflow **0 条**。

---

## 1 先修「门禁是坏的」——这类 bug 的特征是：CI 全绿，但什么都没检查

### 1.1 定时 soname 检测被 Docker Hub 匿名限速（`e9e6b5b`）
- **做了什么**：`scripts/setup-container-repos.sh` 等 7 个文件，把定时 soname 检测从 Docker Hub 拉镜像改成用 GHCR builder 镜像；新增 `tests/test_workflow_images.py`（60 行）钉住 workflow 里用的镜像来源。
- **为什么**：匿名拉取会 429，检测偶尔整轮跑不起来 → 漂移无人发现。
- **有什么用**：检测不再依赖会被限速的镜像源；有人改回 Docker Hub 会被测试直接拦下。

### 1.2 依赖漂移检测其实一直在空跑（`18baad8`，9 文件 +399/−23）
三个真 bug：
1. `scripts/check-dependency-drift.sh` 取 `Version` 的 awk 永远取不到值（静默空跑）→ 修成 `awk -F ': +'` 并对 key 做 trim。
2. `recorded_version` 匹配太松：`nss` 会命中 `nss-mdns` → 现在要求候选能拆成 `<version>-<pkgrel>-<arch>`。
3. `scripts/verify-build-dependencies.sh:34` 解析 `Repository` 同族 bug 一并修。
- 另加：`scripts/select-packages.py` 新增 `declared_dependencies(root)`，把 `package` / `soname` 两类声明边并入重建图。
- **有什么用**：上游 soname 升级现在真的会触发依赖包重建——这是这个仓库最核心的自动化，之前它是「打印一行然后通过」。

### 1.3 运行时校验的正则永远匹配不上（`183df01`）
`scripts/runtime-verify.sh` 里剥离方括号的正则 `/[][\[\]]/` 永不匹配，后果是**正常的库被判成 soname-mismatch，真没 SONAME 的库反而看不出来**。改成 `/[][]/`，并在 `tests/test_runtime_verify.sh` 补两个方向的夹具（正常 `libok.so.1` 必须通过；版本化文件名却没有 SONAME 必须报 `missing-soname`）。

### 1.4 真跑里 quirc 暴露的两个假警报/真缺陷（`d123eca`）
- **假警报**：`libquirc.so → libquirc.so.1` 这类链接器别名会被 `readelf` 顺链读到目标的 SONAME，再与别名自身的名字比较 → 永远「不一致」。现在：循环里 `[[ -L "$target$file" ]] && continue` 跳过别名，SONAME 只要求「文件名一致」或「payload 里存在同名条目」，于是 ffmpeg 那种 `libavcodec.so.61.19.100` + `libavcodec.so.61` 的惯例布局判为合法，而「SONAME 在包里根本不存在」仍然报错。
- **证据**：`git stash` 回退该脚本后，同一夹具立刻复现 CI 里那条 `FAIL: okfixture: soname-mismatch: /usr/lib/libok.so declares libok.so.1`。

---

## 2 把检查收成「一条命令」（`d0b4418`，8 文件 +463/−18）

**做了什么**：
- 新增 `scripts/run-static-checks.sh`：11 项检查，不需要容器、makepkg 或网络，笔记本上约 10 秒。

  ```
  package-manifest-policy  package-manifest-tests  select-packages  elf-soname
  rebuild-triggers         workflow-images         aur-dependency-fallback
  build-regressions        shell-syntax            shellcheck       python-syntax
  ```
- 新增 `.githooks/pre-commit` + `scripts/install-git-hooks.sh` + `.pre-commit-config.yaml`，`.github/workflows/check.yml` 的静态部分缩成一行 `bash scripts/run-static-checks.sh`。
- 新增 `tests/test-static-checks.sh`（177 行）钉住「检查清单」本身：往清单里加检查而不更新测试，测试就失败。
- **顺手修了一个真实事故**：git 钩子会把 `GIT_DIR` / `GIT_WORK_TREE` / `GIT_INDEX_FILE` 导出给子进程，而套件里多个检查会用 `git init` 造一次性仓库——`git -C <夹具>` 因此忽略参数、作用到**你自己的仓库**上：一次 pre-commit 把开发者 checkout 的 `core.bare` 设成了 true、覆盖了共享的 user.name/email、还把分支指针移到了夹具提交上。现在入口脚本开头 `unset` 这些变量，一处防护覆盖所有检查（`tests/test_select_packages.py` 与 `test_package_manifests.py` 里各自的 git 调用也配了干净环境）。

**有什么用**：本地绿 == CI 绿，是**构造上**成立而不是靠同步；`scripts/**` 单独变更时再也不会漏跑检查；提交时就能挡住低级错误，而不是等 40 分钟 CI。

---

## 3 静态策略：包的「更新来源」和「重建触发」都变成显式声明

| 提交 | 做了什么 | 有什么用 |
|---|---|---|
| `654dd6f` | 新增 `scripts/check-package-manifests.py`（369 行）+ `tests/test_package_manifests.py`（317 行）：每个包必须声明更新来源 | 挡住「包在仓库里但永远不会被同步/更新」这一类静默失效（本仓库历史上真的发生过） |
| `a1df87c` | 把 `scripts/data/external-sonames.txt` 那种中央白名单改成逐包 `packages/<包>/.rebuild-on` 声明（如 `soname libshine.so.3 shine`、`package foo`） | 重建触发规则和被触发的包放在一起，改包的人就看得见；中央表不再需要人工对齐 |
| `857b799` | 更新来源登记表（`scripts/data/**`）自身变化不再触发全量重建 | 以前动一次登记表要把 11 个包全部重编，现在触发 0 个包 |

---

## 4 把你未提交的构建平台并入 main（`a4e0638`，99 文件 +9066/−505）

按你的拍板：**不另起炉灶、不往 main 推重叠代码**，而是独立审查你 WIP 的那份，补加固、并到 main。

### 4.1 并入的东西
- `scripts/build-planner.py`：把 git diff 变成**显式重建决策**（`plan.json` / `plan.txt` / GitHub 输出），是唯一的决策点。
- `scripts/build-dag.py`：波次构建（`build_waves`）、资源权重装箱、环降级。
- `scripts/lib/pkgbuild_lib.py`：统一的 `.SRCINFO` 解析 + 依赖图（`graph_consumers` / `in_repo_dependencies` / `transitive_closure`）。
- `scripts/lib/timing.sh` + `scripts/build-timing.py`：分阶段构建时序（`timings.json`、`timings.phases.jsonl`、`resources.txt`、ccache 统计）。
- `scripts/runtime-verify.sh`：产物体检——符号链接、SONAME、缺失依赖、权限、smoke，两种模式（已安装 / 从包文件提取）。
- `scripts/wait-for-build-dependencies.sh`：按本次 matrix 等前置。
- `scripts/analyze-build-failure.py` + `scripts/lib/errorrules.py` + `scripts/data/build-errors/*.yaml`（20 类：compiler / linker / cuda / ffmpeg / network / soname / …）。
- `scripts/auto-repair.sh` + `scripts/repair-budget.sh`：失败分类 → 有限预算自愈。
- `scripts/doctor.sh`、`parallel-build.sh`、`repository-install-test.sh`、`generate-abi-manifest.sh`、`write-back-pkgrel.sh`、`tests/run-all.sh`。

### 4.2 我补的加固（F1/F5/F8，编号见 `BUILD-DAG-REVIEW.md`）
- **F1（阻断级）**：`.rebuild-on` 声明的重建边在 planner 路径上完全丢失——planner 对同一次改动只重建 `['toolchain']`，而 `select-packages.py` 选 `['consumer','toolchain']`。修法是把声明骑到 `PackageMetadata` 上（`declared_dependencies` 委托 `scripts/list-rebuild-triggers.sh` 这一个解析器），planner / select / DAG 三个调用者自动对齐。失败一律抛 `SourceInfoError`，不再静默。
- **F5**：依赖环原来被静默合并成最后一波。现在 `build_waves` 返回 `(waves, cycles)`，JSON 里带 `cycles`，文本输出打 WARNING + 环路路径。
- **F8**：你 WIP 的 `tests/test_build_planner.py` 有和 §2 同一类 `GIT_*` 泄漏隐患，已加固。
- **F4**：新交付 `tests/test_build_dag.py`（13 → 19 例）覆盖链式/菱形/环/装箱/权重/未知包必须报错。

### 4.3 有什么用
- 一次提交**只重建真正受影响的包**，而且顺序由依赖图决定（波次），不是靠 job 结束时间碰运气。
- 「声明式重建边」「登记表不触发重建」「构建脚本不触发重建」这些策略现在从三处逻辑收敛到一处，不会再出现两套选点给出不同答案。
- 失败不再只是红一个 job：有错误分类、有自愈预算（dry run）、有运行期体检结论。

---

## 5 真跑暴露的缺陷：只有真跑才能发现的那 5 个

第一次真跑（run `38036057599`，4 个包全失败）逐条读日志后修掉 4 个（`183df01` + `d123eca`，记录在 `BUILD-DAG-REVIEW.md` §7）：

| # | 症状 | 根因 | 状态 |
|---|---|---|---|
| R1 | 正常的 `libok.so.1` 被判 soname-mismatch | SONAME 方括号正则永不匹配 | ✅ 已修 + 双向夹具 |
| R2 | 每个构建任务刚起步就退出 | `timing.sh` 的 `local source_cache_dir` 与 `build-in-arch.sh` 顶层 `readonly source_cache_dir` 撞名，`set -e` 下直接死 | ✅ 已修 + 回归测试 |
| R3 | ffmpeg-full 白等 45 分钟 | `wait-for-build-dependencies.sh` 把 `status=missing`（前置不在本次 matrix）当成 pending | ✅ 已修：missing 视为「不重建、按已发布版本链接」并打印说明 |
| R4 | quirc 装出来的库运行期无法解析 | 上游链接规则不带 SONAME，包却把文件装成 `libquirc.so.1.2` | ✅ 已修：`LDFLAGS+=" -Wl,-soname,libquirc.so.1"`、按 SONAME 安装 `libquirc.so.1` + 保留 `libquirc.so` 别名、pkgrel 4 → 5 |
| R5 | ffmpeg-full 编译成功、最后一步失败，且验证脚本**没有任何输出**就死 | ①`pacman --noconfirm` 对 `ffmpeg-full` 与 `ffmpeg` 的冲突问句默认答「否」→ 装不上；②`runtime-verify.sh` 的 `list_payload` 在包没装上时非零，`pipefail` + `set -e` 让赋值直接终止，既没打 `FAIL:` 也没打结尾统计 | ⏳ **待修（等你一句话）** |

R5 的修法已经定好（未落地）：编译后、verify 前**真的把产物装上**——先 `pacman -U --noconfirm`；失败则按 `.SRCINFO` 的 `conflicts`（去版本约束、trim 行首 tab）用 `pacman -Qq` 找命中的已装包并 `pacman -Rdd` 卸掉再装（一次性镜像，等价于用户答 y）；**不**拿 `provides` 里的 `.so=版本` 当移除依据。同时让 `runtime-verify.sh` 的 `list_payload` 失败落到既有的 `not-installed` 结论（跑不动必须响，这是平台自己写的原则）。

真跑的好消息：quirc job **success**，日志里 `Runtime verification checked 3 ELF object(s); 0 failure(s).` —— 说明计划→波次→构建→时序→运行期校验这条链真的跑通了。

---

## 6 优化之后，具体有什么用

| 优化前 | 优化后 |
|---|---|
| 静态检查散在 CI 各处，本地没入口；`scripts/**` 变更时漏跑 | 一条 `scripts/run-static-checks.sh`（11 项、约 10 秒），pre-commit 与 CI 是同一份清单，构造上不会漂移 |
| 多个门禁有解析 bug，永远是「WARN…PASS」 | 全部修复并配回归测试，真会失败；`--fast` 套件 78 passed / 0 failed |
| 新包可以「存在但永不更新」 | manifest 门禁在 CI 前挡住 |
| 改一次更新来源登记表 = 全量重建 11 个包 | 触发 0 个包 |
| 重建规则藏在中央白名单 | 就近声明在 `packages/<包>/.rebuild-on` |
| 漂移检测静默空跑，`nss` 会命中 `nss-mdns` | 版本必须能拆成 `<version>-<pkgrel>-<arch>`，声明的 package/soname 边真进重建图 |
| planner 与 select 对同一改动给出不同答案 | 唯一决策点 + 声明边下沉，三个调用者自动对齐 |
| 构建顺序靠 job 排序；前置等待会 fail-open 或白等超时 | DAG 波次 + `missing` 视为按已发布版本链接 + 环有 WARNING 和路径 |
| 构建产物没人检查 SONAME / 符号链接 / 权限 | `runtime-verify.sh` 逐条检查，真跑已证明（quirc 3 ELF / 0 失败） |
| 失败只能人工翻日志 | 20 类错误规则分类 + 有限预算自愈（dry run）+ 可选的自动修复 |
| 本地「绿」和 CI「绿」是两回事 | `tests/run-all.sh` 先复制再跑、以 builder 用户跑、失败会自己说出原因（`39b92cb` `0b74b60` `1105518`） |

---

## 7 还没做的（诚实清单）

1. **R5 修复**（上面的冲突安装 + 静默中止）——要动 `scripts/build-in-arch.sh` 与 `scripts/runtime-verify.sh`，改完需要重跑 `workflow_dispatch packages=quirc` 才能把发布补上。
2. **F2**：`build.yml:87-93` 从不给 planner 传 `--repository-manifest`，于是「已发布 ABI 驱动重建」在 CI 永远不生效（文档里却写了用法）。
3. **F3**：`wait-for-build-dependencies.sh` 只让 job 结束时间有序，依赖的新产物从未 staging 进 build job——build job 里 `localrepo` 用的是 release 里的**已发布**包。
4. F6/F7：三处文档与代码漂移、`build-dag.py` 的 `make_jobs` 死变量与内联 `__import__("os")`。
5. 发布现状：**quirc 仍是 `1.2-4`、ffmpeg-full 仍是 `9.0.2-2.6`**。上一次 dispatch（run `38037955697`）quirc 构建成功，但 ffmpeg-full 失败，发布是 all-or-nothing（`allow_partial_publish=false`），所以两个都没发出去。

## 8 你怎么自己验收

```bash
# 1) 静态检查：应当 11/11
bash scripts/run-static-checks.sh

# 2) 全量本地套件（跳过需要容器/root 的）：应当 78 passed / 0 failed
./tests/run-all.sh --fast

# 3) 干净 worktree 复算这次并入的结果
git worktree add /tmp/verify origin/main && cd /tmp/verify && ./tests/run-all.sh --fast
```

## 9 相关文档

- `BUILD-DAG-REVIEW.md`（在 main 上）：② 的独立审查，F1–F8 的问题、证据、落地状态，含 R1–R4 真跑复盘。
- `LANDING-STATUS-2026-10-10.md`（你工作树里，未跟踪）：本轮「已做 / 在做 / 未做」的状态页。
- `OPTIMIZATION-REVIEW.md`（2026-10-03 的审计，未跟踪）：更早那轮只读评估，不是本次改动。
