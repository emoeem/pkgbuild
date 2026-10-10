# build-plan / build-dag 独立审查（②）

审查对象（你未提交的 WIP）：`scripts/build-planner.py`(392 行)、`scripts/build-dag.py`(325 行)、
`scripts/lib/pkgbuild_lib.py`(431 行)、`scripts/build-timing.py`、`scripts/wait-for-build-dependencies.sh`、
`tests/test_build_planner.py`(175 行)、`.github/workflows/build.yml` 的 select/build/repair 接线。
方法：读代码 + 在 `/tmp/planner-probe*.{1,2,3}` 造探针仓库跑真脚本（不改你的仓库代码），
并把缺失的测试补成 `tests/test_build_dag.py`（新文件，未跟踪）。

**一句话结论**：DAG 内核（波次、环降级、装箱、权重、前置查询）经 13 项新测试验证是正确的；
问题出在**接线**——选点从 `select-packages.py` 换成 `build-planner.py` 后，两条真实的决策输入被丢掉：
`.rebuild-on` 声明边（F1）与已发布 ABI manifest（F2）；另有「波次有序 ≠ 产物可用」（F3）。

---

## 0 结论摘要

| # | 严重度 | 问题 | 证据 |
|---|---|---|---|
| F1 | **阻断** | `.rebuild-on` 声明的重建边在 build 选择路径上完全丢失，planner 与 select-packages 对同一改动给出不同答案 | probe3：planner `rebuild=['toolchain']`（consumer 进了 `skipped`）vs select-packages `["consumer","toolchain"]` |
| F2 | 高 | `--repository-manifest` 能力齐全但 CI 从不传 → 已发布 ABI 驱动的重建决策在 CI 永远不生效 | `build.yml:87-93` 无该参数；`docs/build-platform.md:17` 却写了用法；probe：传入时 `manifest_checked=true`，不传即 `false` |
| F3 | 高 | 「Wait for in-repo build prerequisites」只让 job 结束时间有序，依赖的新产物从未 staging 进 build job | `wait-for-build-dependencies.sh:40`（且注释自承 fail-open）+ `build.yml:266-268/284-285` 用的是 release 里的**已发布**包 |
| F4 | 中 | DAG 波次/环/装箱/前置零测试 | 我补的 `tests/test_build_dag.py` 13 例全绿（本节交付） |
| F5 | 中 | 依赖环被静默合并成最后一波，无告警、不列出参与环的包 | probe：A↔B → 1 波，输出里没有任何警告 |
| F6 | 低 | 三处文档/帮助与代码漂移 | `docs/architecture-audit.md:17`、`docs/build-pipeline.md:7` 仍称选点是 select-packages.py；`build-dag.py:207` 帮助写 `build-plan.json`，`build.yml:100` 实传 `build-plan/plan.json` |
| F7 | 低 | 代码卫生 | `build-dag.py` 的 `make_jobs` 死变量、`__import__("os")` 内联、`from errorrules import load_yaml`（YAML 解析住在错误分类模块里） |
| F8 | 中 | 你 WIP 新增的 `tests/test_build_planner.py` 有 GIT_* 泄漏隐患（与本会话修过的事故同类，会污染真实仓库） | `setUp` 用 `subprocess.run(["git","init","-q",...])` + `git -C` 且未清 `GIT_*`；本会话实测该模式在 pre-commit 钩子下把夹具提交写进真实仓库 |

**落地状态（F1+F5+F8 已随 a4e0638 并入 main 并推送；§6 是当时的落地记录，真跑后的补充见 §7）**

| 项 | 状态 |
|---|---|
| F1 声明边下沉进 `pkgbuild_lib` | ✅ 已落地（`graph_consumers` + `in_repo_dependencies` 双路消费；planner/select/DAG 一次对齐） |
| F4 DAG 测试 | ✅ 已交付并扩到 19 例（新增环报告断言与 3 条 `.rebuild-on` 断言） |
| F5 环告警 | ✅ 已落地（`build_waves` 返回 `(waves, cycles)`；JSON `cycles`；text WARNING + 环路路径） |
| F8 测试 `git_environment()` | ✅ 已落地（两个测试文件 + `pkgbuild_lib` 内部 git 调用一并清 `GIT_*`） |
| F2 / F3 / F6 / F7 | ⏳ 待你拍板（F2/F3 要动 CI 接线，F6/F7 是文档与代码卫生） |

---

## 1 交付物：`tests/test_build_dag.py`（新文件，未跟踪）

`python3 -m unittest tests.test_build_dag -v` → **13 passed, OK (0.6s)**。零 git 依赖，可在
pre-commit 钩子环境里安全运行（正因如此它不受 F8 那类污染影响）。覆盖：

- 链式依赖 → 3 波且 `topological_order` 递增（`toolchain → lib → app`）
- 菱形（a,b,d 独立；c→a,b；e→d）→ 恰好 2 波 `[[a,b,d],[c,e]]`（装箱正确）
- **环** → 1 波、`counts.waves == 1`、`timeout=60` 兜住「环上死转」回归
- `--prerequisites-for app` → `["lib"]`（只列直接 in-repo 前置，跨波由传递性保证）；叶子 → `[]`
- 装箱：`--max-parallel-jobs 1` → 每槽 ≤1；8 CPU/16 GiB → `parallel_jobs_per_slot=2`、`ram_slots=4`
- `--plan` 限定集合；空 plan → `waves==[]`、`counts.packages==0`
- 权重：`state/timing-history.jsonl` 里 `{"package":"heavy","total_seconds":4000,"resources":{"cpu_seconds":3600,"memory_peak_bytes":16GiB}}` → `source=measured`、`cpu=3`、`ram=3`、makespan > 0；无历史 → `declared`、makespan 0
- 未知包名**报错而非静默忽略**

（额外人工验证并**通过**：`--before` 传空 / 全零 / 不存在的 ref 都不崩——`pkgbuild_lib.changed_files`
先 `git cat-file -e <before>^{commit}` 再回退 `git diff-tree --root`，健壮性没问题。）

---

## 2 发现明细

### F1（阻断）`.rebuild-on` 声明的边在 build 路径上丢失

`pkgbuild_lib.py` 全库没有任何 `.rebuild-on` / `list-rebuild-triggers` 引用，`build.yml` 的 select
job 又已经不用 `select-packages.py` 了，所以「不是依赖但必须跟着重建」的声明只剩 check 路径认识。

复现（`/tmp/planner-probe3`：`consumer/.rebuild-on = package toolchain`，consumer 的 `.SRCINFO` **不**依赖 toolchain）：

```
$ python3 scripts/build-planner.py --root . --selection changed --before HEAD~1 --after HEAD --format json
changed: ['toolchain']  affected: []  rebuild: ['toolchain']  skipped: ['consumer']
reason: {"toolchain": ["direct: packages/toolchain/PKGBUILD"]}

$ python3 scripts/select-packages.py --root . --selection changed --before HEAD~1 --after HEAD
["consumer","toolchain"]
```

**影响**：①a/①b 在 origin/main 上刚建立的语义（改 provider → 声明它的包必须重建）会在 build 侧静默失效；
同一个改动 check 会说「该重建 consumer」而 build 不会。`soname <so> <provider>` 声明同理。

**补丁（推荐，一处修好两条路径）**：把声明边下沉进 `pkgbuild_lib.py`，而不是塞进 planner：

```python
# scripts/lib/pkgbuild_lib.py
def declared_dependencies(root: Path) -> dict[str, set[str]]:
    """package dir -> packages named by packages/<dir>/.rebuild-on.

    Delegates to scripts/list-rebuild-triggers.sh (the single parser), so the
    planner, the DAG and select-packages.py cannot drift apart.
    """
    helper = root / "scripts" / "list-rebuild-triggers.sh"
    if not helper.is_file():
        return {}
    completed = subprocess.run(["bash", str(helper), str(root / "packages")],
                               text=True, capture_output=True)
    if completed.returncode != 0:
        raise SourceInfoError(completed.stderr.strip() or "list-rebuild-triggers.sh failed")
    declared: dict[str, set[str]] = {}
    for line in completed.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) < 3 or fields[0] not in ("package", "soname"):
            raise SourceInfoError(f"malformed rebuild trigger: {line!r}")
        declared.setdefault(fields[1], set()).add(fields[2] if fields[0] == "package" else fields[3])
    return declared
# 然后 dependency_graph():  depends |= declared.get(directory.name, set())
```

`select-packages.py` 与 `build-planner.py` 都经过 `pkgbuild_lib` 的图函数，因此两条路径
一次对齐；`tests/test_select_packages.py` 里我已给 main 的等价实现配了 4 个用例，可照搬。

**最终落地形态（与上面的草图有两处差异，代码见 §6）**：声明不直接作为图上的键，而是先经
`declaration_providers()` 解析成**仓内 base 名**，再在 `graph_consumers()`（消费方向）与
`in_repo_dependencies()`（排序方向）里各加一次边——这样同一个 SONAME 的两种拼写
（`.SRCINFO` 的 `libfoo.so=2-64` 与声明的 `libfoo.so.2`）不会各算各的。另外：声明存在但
`scripts/list-rebuild-triggers.sh` 不在（例如只拷了数据文件）时会**报错退出**，不允许静默忽略。

### F2（高）`--repository-manifest` 在 CI 从未传入

`build-planner.py:363` 定义、`:82` 消费、`docs/build-platform.md:17` 示范用法，但 `build.yml:87-93`
的调用只有 `--selection/--before/--after/--builder-generation/--out/--github-output`。

```
$ python3 scripts/build-planner.py --root . --selection chain-a --format json
repository: {"manifest_checked": false, "drift": []}
$ python3 scripts/build-planner.py --root . --selection chain-a --format json --repository-manifest abi.txt
repository: {"manifest_checked": true, "drift": []}
```

**影响**：已发布仓库里的 ABI 漂移（NEEDED 变了但 `.SRCINFO` 没变）在 CI 里永远不会触发重建——
又是一个「能力齐全、没人喂」的静默空转（与我这次修的 drift 检测器同一类病）。

**补丁**：select job 先取资产再传参（manifest 由 `scripts/generate-abi-manifest.sh` 在 publish job 生成并随 release 发布）：

```yaml
      - name: Fetch published ABI manifest
        shell: bash
        run: |
          set -Eeuo pipefail
          mkdir -p published/x86_64
          gh release download repo --repo "$GITHUB_REPOSITORY" \
            --pattern "*-abi-manifest.txt" --dir published/x86_64 --clobber || true
      # Build plan 步骤里追加：
      #   --repository-manifest published/x86_64/emoeem-abi-manifest.txt
```
（资产不存在时 planner 会自己退回 `manifest_checked=false`，不会让 job 变红。）

### F3（高）波次有序 ≠ 产物可用

`wait-for-build-dependencies.sh` 的 docstring 已经把危险说清楚（ffmpeg-full 会链到本轮正在重建的
mpeghdec/quirc/svt-jpeg 的旧版本），但它只做两件事：查 `--prerequisites-for`、按 job 名 `Build <pkg>`
轮询 `gh api`，**读不到 API 就跳过**（fail-open）。等待结束后，consumer 的容器里仍然是
`build.yml:266-268` 从 **release** 下载的已发布包（`localrepo/x86_64` → `/localrepo`）。
同一 run 里前置包的新产物只存在于它自己的 artifact（`built-<pkg>-<run_id>`，`build.yml:382`），
从未进入 consumer 的 localrepo。

**影响**：波次只在「job 结束时间」上有序，在「产物可用性」上无序——对 `soname` 变化的依赖，consumer
照样会用旧库链接（然后被 ①a 的 stale 检查或 verify 步骤抓出来，或者悄悄产出错误产物）。

**补丁**：在「Wait for in-repo build prerequisites」之后、容器构建之前，按前置清单取兄弟 job 的产物：

```yaml
      - name: Stage in-repo prerequisites
        if: matrix.package != ''
        shell: bash
        env:
          PACKAGE_NAME: ${{ matrix.package }}
        run: |
          set -Eeuo pipefail
          mapfile -t deps < <(python3 scripts/build-dag.py --prerequisites-for "$PACKAGE_NAME" |
            python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)))')
          for dep in "${deps[@]}"; do
            gh run download "$GITHUB_RUN_ID" --repo "$GITHUB_REPOSITORY" \
              --name "built-${dep}-${GITHUB_RUN_ID}" --dir staging || true
            if [[ -f "staging/${dep}.tar" ]]; then
              tar --extract --file "staging/${dep}.tar" --directory localrepo/x86_64
            fi
          done
          ls -1 localrepo/x86_64 | tail -5
```

要点：`wait` 步骤提供**顺序**，这一步提供**内容**，两者缺一不可；产物已在 upload 步骤生成，接口是现成的。
只取直接前置（不要 `built-*` 通配）可以避免让包意外链到与本轮无关的兄弟包。

### F4（中）DAG 零测试 → 已补 `tests/test_build_dag.py`

见第 1 节。建议把它作为 ② 首个提交（纯新增文件，零冲突面），再动 F1/F2/F3。

### F5（中）环的降级是静默的

`build_waves` 对检测到的环把剩余包合成最后一波并 `break`（不空转，这点是对的），但输出里没有任何
提示；被合并的包会**在同一波里并行**，等于放弃了它们之间的顺序。真实仓库里一个意外的环（例如
`.SRCINFO` 里写反了 `depends`）会表现为「莫名其妙地并发构建」，很难排查。

**补丁（已落地）**：`build_waves` 返回 `(waves, cycles)`，`cycles` 是**环路路径**（如
`["mutual-a","mutual-b","mutual-a"]`），由新增的 `cycle_path()` DFS 求出（一个环一个条目）；
JSON 增 `"cycles"`，text 输出首行打
`WARNING: dependency cycle(s) cannot be ordered; merged into one wave:` 并列出
`a -> b -> a`。测试断言 `document["cycles"] == [["mutual-a","mutual-b","mutual-a"]]` 且 text 含该警告。

### F6（低）文档/帮助漂移

- `docs/architecture-audit.md:17`「选择 | `build.yml:select` | … | `scripts/select-packages.py`」→ 现在是 `build-planner.py`
- `docs/build-pipeline.md:7` 同；`:93` 说「select-packages.py 现在同时把 depends/makedepends/checkdepends 纳入」→ 图语义已搬进 `pkgbuild_lib.py`
- `build-dag.py:207` `--plan` 帮助写 `build-plan.json`，实际是 `build-plan/plan.json`

### F7（低）代码卫生

- `build-dag.py`：`make_jobs` 算完从没用过（读 `cpus` 的那段），`__import__("os").cpu_count()` 内联，
  `from errorrules import load_yaml` 让「读 YAML」这件事住在错误分类模块里——建议 `scripts/lib/resources.py`
  或直接把 `load_yaml` 提到一个中性模块。

### F8（中）`tests/test_build_planner.py` 的 GIT_* 泄漏隐患

它的 `setUp`/`commit` 用 `subprocess.run(["git", "-C", str(self.root), ...])`，但不清理环境里的
`GIT_DIR`/`GIT_WORK_TREE`。本会话实测：git 会把这两个变量导出给 `pre-commit` 钩子进程，于是夹具里的
`git init/add/commit` 绕过 `-C` 作用到**真实仓库**上（当时把主仓库变成了 bare、把测试身份写进
`user.name/email`、把分支写成夹具提交）。修法（我在 main 的 18baad8 里已经用过）：

```python
def git_environment() -> dict[str, str]:
    return {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
# subprocess.run([...], env=git_environment())
```
另外 `scripts/run-static-checks.sh`（单一入口）已经会 `unset GIT_*`，但**只在入口生效**——
直接跑单个测试文件仍然会中招，所以测试文件自己也要清。

**已落地**：两个测试文件都加了 `git_environment()` 并传给每一次 `git` 调用；同时
`pkgbuild_lib.changed_files()` 内部的两处 git 调用也改用 `pkgbuild_lib.git_environment()`——
planner 是在**库内部**跑 git 的，只清测试自己的调用挡不住 `GIT_DIR` 抢优先级。
实测：`GIT_DIR=<真实仓库>/.git GIT_WORK_TREE=<真实仓库>` 下跑 37 个 Python 用例仍全绿，
真实仓库 HEAD 与工作树条目数不变。

---

## 3 与 origin/main 的合流风险（动手前必看）

你的 WIP 基于 `58e7c75`，而 origin/main 已经领先 3 个提交：

```
origin/main = 18baad8 fix(drift): 让依赖漂移检测真正工作，并认领 .rebuild-on 声明
              a1df87c feat(maintenance): 外部 SONAME 白名单改成逐包 .rebuild-on 声明
              d0b4418 feat(ci): 静态检查收成单一入口，pre-commit 与 CI 共用
宿主 HEAD   = 58e7c75（是 a1df87c 的祖先）
```

两边**同时改过**这 5 个文件：`scripts/select-packages.py`（你的 WIP 把它重写成 103 行的
`pkgbuild_lib` 薄 CLI，删了约 100 行）、`scripts/check-dependency-drift.sh`（你 +35 行，
第 35 行仍是坏的 `awk -F ': +' '$1 == "Version"'`；我的版本重写了它并修好静默空跑）、
`tests/test_select_packages.py`、`README.md`、`docs/build-pipeline.md`。
建议合流时**以你的 WIP 结构为准、把我的语义补进去**（F1 的补丁正好就是这件事），不要直接 `git pull` 硬碰。

---

## 4 建议落地顺序

~~1. `tests/test_build_dag.py`（已交付，13 例全绿）→ 先独立提交，锁住现有行为~~
~~2. F5 环告警 + 对应断言（小改动，先把可观测性补上）~~
~~3. F1 声明边下沉 `pkgbuild_lib`，并让 planner/DAG 的测试各加一条「.rebuild-on 消费者必须入选且排在后一波」~~
4. F2 select job 取 ABI manifest 并传参；补一条「manifest 存在时 `manifest_checked=true`」的测试
5. F3 staging 步骤（这一步最好在真 runner 上跑一次 `workflow_dispatch` 验证，与 ①a 的端到端验证同法）
6. F6/F7 收尾（F8 已随本轮一起修完）
7. 提交前建议先把 WIP `git add` 进库再跑 `bash tests/run-all.sh --fast`：本树的唯一失败
   `tests/test_workflow_references.py::test_every_referenced_script_is_tracked` 正是「脚本被引用但未跟踪」
   （21 条），与本次改动无关，`git add` 后即消失

1–3 与 F8 已在本轮改在你的 WIP 上（见 §6），未提交也未推送；2/4/5/6 的顺序仍建议照上表走。

---

## 5 复现附录

```
# 探针（不碰你的仓库）
/tmp/planner-probe3   # F1：.rebuild-on 分歧
/tmp/planner-probe2   # DAG 波次/环/装箱/前置/权重
# 关键命令
python3 scripts/build-planner.py --root /tmp/planner-probe3 --selection changed --before HEAD~1 --after HEAD --format json
python3 scripts/select-packages.py --root /tmp/planner-probe3 --selection changed --before HEAD~1 --after HEAD
python3 scripts/build-dag.py --root /tmp/planner-probe2 --packages chain-a,chain-b,chain-c --cpus 8 --memory-gb 16
python3 -m unittest tests.test_build_dag -v
```

**本轮的边界**：§6 之外没有动你的代码；所有改动都在工作树里，**没有 `git add`、没有 commit、没有推送**。

---

## 6 落地记录（F1 + F5 + F8，已改在你 WIP 的工作树上）

### 6.1 改了哪些文件

| 文件 | 改动 |
|---|---|
| `scripts/lib/pkgbuild_lib.py` | ① 新增 `git_environment()`，`changed_files()` 里两处 git 调用（`cat-file -e` / `diff`）改用干净环境；② 新增常量 `REBUILD_ON_FILENAME`、`REBUILD_TRIGGER_HELPER` 与 `declared_dependencies(root)`（委托 `scripts/list-rebuild-triggers.sh`，**有声明但缺解析器时报错**）；③ `PackageMetadata` 增 `rebuild_on: tuple[str, ...]`，`load_packages()` 用 `dataclasses.replace` 把声明挂到对应包上；④ 新增 `declaration_providers()`（trigger → 仓内 base 名）；⑤ `graph_consumers()` 加消费边、`in_repo_dependencies()` 加排序边 |
| `scripts/build-dag.py` | `build_waves()` 返回 `(waves, cycles)`；新增 `cycle_path()`（DFS 求一条具体环路）；`main` 解包、JSON 增 `"cycles"`、text 首行打 WARNING 与 `a -> b -> a` 路径 |
| `tests/test_build_dag.py` | 13 → **19 例**：环被报告（JSON + 文本断言）、无环时 `cycles == []`、`package` 声明把声明者排到后一波且 `--prerequisites-for` 认它、`soname` 声明跨拼写解析到 provider、声明指向未入选包时不串行、有声明但缺解析器必须非零退出 |
| `tests/test_build_planner.py` | 新增 `git_environment()`，`setUp`/`commit` 的 6 处 git 调用全部带 `env=` |
| `tests/test_select_packages.py` | 同上（`setUp` 3 处 + `commit` 3 处） |
| `scripts/list-rebuild-triggers.sh` | **新增未跟踪文件**（从 origin/main 的 ①a 拷来，0755）。宿主树 `58e7c75` 还没有它，而 F1 的唯一解析器就是它；rebase 到 origin/main 后内容一致，不会冲突 |

### 6.2 验证证据

真实 13 包数据、真实解析器、`git` 输入完全相同的 A/B（`/tmp/rebuild-on-demo`：只在 `packages/xclip-git/.rebuild-on` 写 `package ffmpeg-full`，diff 只有 `packages/ffmpeg-full/PKGBUILD` 一个文件）：

```
planner  --selection changed   带声明: rebuild ['ffmpeg-full','xclip-git']   移走声明: ['ffmpeg-full']
select-packages.py             带声明: ['ffmpeg-full','xclip-git']           移走声明: ['ffmpeg-full']   ← 两条路径终于一致
build-dag --packages f,x       带声明: [[ffmpeg-full],[xclip-git]]           移走声明: [[ffmpeg-full,xclip-git]]
```

- `python3 -m unittest tests.test_build_dag tests.test_build_planner tests.test_select_packages` → **37 例全绿**；
  再以 `GIT_DIR=<真实仓库>/.git GIT_WORK_TREE=<真实仓库>` 重跑仍 37 例全绿，且真实仓库 HEAD/工作树条目数不变（F8 回归）。
- `bash tests/run-all.sh --fast`：Syntax / shellcheck / actionlint / py_compile 与各 Python、Behaviour 用例全绿，
  唯一失败是**既存**的 `tests/test_workflow_references.py::test_every_referenced_script_is_tracked`
  （`build-planner.py`、`build-dag.py`、`wait-for-build-dependencies.sh` 等 21 个 WIP 脚本尚未 `git add`），与本轮改动无关。
- （当时的记录）未提交、未推送；`git status` 里就是你这棵 WIP 上的进一步修改。
  这些改动随后随 a4e0638「并入构建平台」一起进了 main 并推送，真跑后的补充见 §7。

### 6.3 留给你的两个提醒

- 宿主树里目前**没有** `.rebuild-on` 数据文件（①a 的 `packages/ffmpeg-full/.rebuild-on` 在 origin/main；
  宿主版 `scripts/check-repository-sonames.sh` 也还 grep 不到 `rebuild-on`）。把 ①a 那部分合过来后，
  图这边会**自动**开始消费这些声明；你现在就可以挑一个包写 `.rebuild-on` 试效果。
- F2/F3 需要你拍板（都要动 `build.yml` 接线：前者把 ABI manifest 取来传给 select job，后者把已构建产物
  staging 进 build job）。F6/F7 是文档与代码卫生，随时可做。

---

## 7 真跑补充（并入 main 之后，2026-10-10）

a4e0638 落地后的第一次**真跑**（不是空跑：planner 有意让构建脚本变化不触发重建）暴露了 4 个只有真跑
才会出现的缺陷，全部已修并推送。这条也顺带把 F3 说得更明白：波次有序 ≠ 产物可用，真正卡住流水线的
往往是「等谁」和「怎么验证」这两端。

| # | 真实日志里的症状 | 根因 | 修复（提交） |
|---|---|---|---|
| R1 | 每个 build job 刚起步就退出：`/workspace/scripts/lib/timing.sh: line 57: local: source_cache_dir: readonly variable` | `timing.sh:57` 的 `local source_cache_dir="$3"` 与 `build-in-arch.sh:12` 顶层 `readonly source_cache_dir=...` 重名；`local` 在只读变量上返回非零，`set -e` 直接结束该包的构建 | 改名为 `sources_dir`；`tests/test-build-regressions.sh` 加 4/5 回归（在 `readonly source_cache_dir` 下调用 `timing_resources`）。提交 183df01 |
| R2 | 所有 SONAME 正确的库都被判错：`FAIL: vapoursynth-plugin-mlrt-ncnn-runtime: libvsncnn.so declares [libvsncnn.so]`；quirc 更怪：`FAIL: quirc: soname-mismatch: /usr/lib/libquirc.so declares libquirc.so.1` | ① `runtime-verify.sh` 去方括号的正则 `gsub(/[][\\[\\]]/, "", $NF)` 永不匹配，`declared` 一直带着 `[ ]`；② `check_elf` 会读到链接器别名（`libquirc.so -> libquirc.so.1`），`readelf` 顺链读出目标的 SONAME 再拿它和别名自己的名字比 | 正则改 `gsub(/[][]/, "", $NF)`；判定改为「跳过符号链接 + 真实文件无 SONAME 且文件名带版本 → missing-soname + 有 SONAME 时必须能在 payload 里解析（自身同名，或存在同名条目，覆盖 `libavcodec.so.61.19.100` 真文件 + `libavcodec.so.61` 符号链接的发行版惯例）」；`tests/test_runtime_verify.sh` 补两种合法形状（`libok.so.1`+`libok.so`、`libfull.so.2.1.0`+`libfull.so.2`+`libfull.so`），修复前会以 CI 里一模一样的消息失败。提交 d123eca |
| R3 | ffmpeg-full 一直 `Still waiting for: mpeghdec, svt-jpeg-xs-git`，45 分钟后超时——这两个包根本不在本次矩阵里 | `wait-for-build-dependencies.sh:63-88` 把 jobs API 的 `status=missing` 当成 pending | 新增 `missing)` 分支归入 absent（不在本次 run 里 = 用已发布的版本，无需等待）并打印一行说明；`tests/test-build-regressions.sh` 加 5/5 回归。提交 183df01 |
| R4 | `FAIL: quirc: missing-soname: /usr/lib/libquirc.so.1.2 has a versioned name but no SONAME` | `packages/quirc/PKGBUILD` 沿用上游 Makefile 的链接规则，从不传 `-Wl,-soname` | PKGBUILD 里 `CFLAGS+=" -fPIC" LDFLAGS+=" -Wl,-soname,libquirc.so.1"` 构建、`package()` 装成 `/usr/lib/libquirc.so.1` 并保留 `libquirc.so` 别名；pkgrel 4→5、`.SRCINFO` 用 `makepkg --printsrcinfo` 重生成。提交 183df01（R2 修好后 quirc 才能真正编过） |

真跑验证（`workflow_dispatch`，`packages=quirc`，run 38037955697）：

- select 的 plan 里出现 `quirc selection: explicitly requested` 与
  `ffmpeg-full dependency: quirc (provided by quirc)` —— F1 的声明边在 CI 里真的驱动了「重建依赖者」。
- `Build quirc` **success**：日志里 `cc -shared -o libquirc.so.1.2 ... -Wl,-soname,libquirc.so.1`，
  打包清单里是 `usr/lib/libquirc.so.1`，运行期门禁 `Runtime verification checked 3 ELF object(s); 0 failure(s).`
  + `Runtime verification passed.`（R2 修好后同一条检查不再误报）。

一条运维经验：`gh api`/`gh run view` 取不到作业日志，必须
`curl -sS -L -H "Authorization: Bearer $(gh auth token)" https://api.github.com/repos/<owner>/<repo>/actions/jobs/<id>/logs`
（先存文件再 grep）。

