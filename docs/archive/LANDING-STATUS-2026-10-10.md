# ② 构建平台落地：已做 / 在做 / 未做

时间：2026-10-10 17:05（Asia/Shanghai）。`main` = `c00fcb2`；你给我的指令是 m02613「推送」。
**这份文档本身没有提交**，放在你宿主树里只是给你看。

---

## 0 一句话

你未提交的构建平台 WIP 已经**并入 main 并推送**（`a4e0638` … `c00fcb2`，7 个提交），静态检查
11/11、`Check Arch packages` 绿；第一次**真跑**（不是空跑）暴露的 4 个缺陷已修好。
随后用 `workflow_dispatch` 真重建 **quirc + ffmpeg-full**：quirc 全绿，ffmpeg-full **在最后一个环节
（把产物装上再验证）失败**，又暴露第 5 个平台缺陷——**包还没发布出去**（发布是 all-or-nothing）。

---

## 1 已经做完的（都在 main 上，逐条可查）

| 提交 | 内容 | 验证 |
|---|---|---|
| `a4e0638` | **并入构建平台**：56 个新文件 + 44 个修改（build-planner / build-dag / pkgbuild_lib / timing / runtime-verify / wait-for-build-dependencies / 测试 / workflow 接线）；保留 ①a 依赖漂移、①b soname 检测、③ 静态检查单一入口、两包退役的结果；不复活已删除的 `sync-dae-release.yml` | `run-static-checks` 11/11；`tests/run-all.sh --fast` 78 passed / 0 failed；`git diff origin/main` = 56 A + 44 M + 0 D |
| `a4e0638` | **F1 声明边下沉**：`.rebuild-on` 的 package/soname 声明骑在 `PackageMetadata` 上，planner / select / DAG 一个答案 | CI 真跑 plan 里出现 `ffmpeg-full dependency: quirc (provided by quirc)` |
| `a4e0638` | **F5 环报告**：`build_waves()` 返回 `(waves, cycles)`，JSON 增 `cycles`，text 打 WARNING + 环路路径 | `tests/test_build_dag.py` 19 例 |
| `a4e0638` | **F8 测试污染**：两个测试文件的 git 调用全部清 `GIT_*`（与本会话早先那起「pre-commit 把夹具提交写进真实仓库」同类） | 以 `GIT_DIR=<真实仓库>` 跑仍全绿且真实仓库未动 |
| `39b92cb` | builder 镜像发布挂掉：`cache-to: type=registry,mode=max` 在默认 docker driver 上不支持 → 加 `docker/setup-buildx-action`（docker-container driver）；dependabot 的 docker 目录写成 `/github/builder` → 改 `/.github/builder` | `Publish CI builders` 与 `Dependabot Updates` 转绿 |
| `0b74b60` | 容器套件改「先 `cp -a /workspace /tmp/ws` 再跑」；`tests/run-all.sh` 在 `set -Eeuo pipefail` 下第一个失败就终止、`report $?` 永不执行（它自己的契约从没生效过） | 注入 `sys.exit(3)` 的临时用例 → 正确报 `failed 1` + 名字 + exit 1 |
| `1105518` | 容器里改以 `--user builder` 跑（root 下 makepkg 直接拒绝；root 复制会保留 uid 1001 属主 → git `dubious ownership`）；`run-all.sh` 失败时原样回显子进程输出 | `Check Arch packages` 38037205094 转绿 |
| `183df01` | **真跑暴露的 4 个缺陷**：R1 `timing.sh:57` 的 `local source_cache_dir` 与 `build-in-arch.sh:12` 的 `readonly source_cache_dir` 撞名 → `set -e` 下每个 build job 刚起步就退出；R2 `runtime-verify.sh` 去方括号正则 `gsub(/[][\\[\\]]/,"")` 永不匹配 → 所有 SONAME 正确的库都被误判；R3 wait 步把 jobs API 的 `status=missing` 当 pending → ffmpeg-full 白等到 45 分钟超时；R4 `quirc` 从不传 `-Wl,-soname`（pkgrel 4→5） | 每个修复都带「修复前失败 / 修复后通过」的回归用例；`run-static-checks` 11/11 |
| `d123eca` | **SONAME 判定按加载器语义重写**：跳过链接器别名（`libquirc.so → libquirc.so.1`，readelf 会顺链读到目标 SONAME）、真实文件无 SONAME 且带版本 → missing-soname、有 SONAME 时要求能在 payload 里解析 | 修复前会以 CI 里一模一样的消息 `soname-mismatch: /usr/lib/libok.so declares libok.so.1` 失败 |
| `c00fcb2` | `BUILD-DAG-REVIEW.md` 增 §7，记录 R1–R4 与真跑证据；顺手改对 §0「未提交、未推送」的过期说法 | 文档改动，不触发 build/check |

---

## 2 这轮真重建（run 38037955697，`workflow_dispatch packages=quirc`）的结果

| 作业 | 结果 | 关键证据 |
|---|---|---|
| Select packages | ✅ success | `quirc selection: explicitly requested`、`ffmpeg-full dependency: quirc (provided by quirc)` —— F1 的声明边在 CI 里真的驱动了「重建依赖者」 |
| Build quirc | ✅ success（08:30:59，约 3 分钟） | `cc -shared -o libquirc.so.1.2 … -Wl,-soname,libquirc.so.1`、清单含 `usr/lib/libquirc.so.1`、`Runtime verification checked 3 ELF object(s); 0 failure(s).` + `Runtime verification passed.` |
| Build ffmpeg-full | ❌ **failure**（08:50:47，约 23 分钟） | **编译本身是成功的**（`Finished making: ffmpeg-full 9.0.2-2.6`，08:49:42），失败发生在最后一个环节「把产物装上再做运行期验证」 |
| Auto-repair failed builds | ✅（dry run） | 只报告，没有向 main 推任何东西（`origin/main` 仍 = `c00fcb2`） |
| Publish pacman repository release | ⏭️ **skipped** | 发布是 all-or-nothing（`allow_partial_publish` 默认 false）→ **quirc-1.2-5 与新的 ffmpeg-full 都没发出去** |

### ffmpeg-full 失败的两个根因（第 5 个平台缺陷 = R5）

1. **冲突包装不上**（真实日志）：
   ```
   :: ffmpeg-full-9.0.2-2.6 and ffmpeg-2:9.0.2-2.1 are in conflict. Remove ffmpeg? [y/N]
   error: failed to prepare transaction (conflicting dependencies)
   -> error installing: [/build/ffmpeg-full/ffmpeg-full-9.0.2-2.6-x86_64.pkg.tar.zst] - exit status 1
   yay exited with status 1 after producing the target package; continuing without installing it.
   ```
   builder 镜像自带 `ffmpeg`，而 `packages/ffmpeg-full/PKGBUILD:165` 有 `conflicts=('ffmpeg')`。
   `yay -Bi --noconfirm` 走到 pacman 的冲突问句时，**`--noconfirm` 取默认答案（否）**，于是产物
   编出来了却没装上（脚本本身容忍这一点，继续往下走）。
2. **运行期验证因此静默死亡**：`runtime-verify.sh` 的 installed 模式第一步是 `pacman -Ql <pkg>`
   （`list_payload`）。包没装上 → 命令失败 → 脚本是 `set -Eeuo pipefail`，`listing="$(…)"` 直接
   终止脚本，**连它本来准备好的 `FAIL: …: not-installed` 都没打出来**，日志里只剩一行
   `Running installed-package runtime verification...` 然后 job 失败。这正好违背平台自己写在
   dependency-drift 里的原则：跑不动就必须响。

---

## 3 还没做的

1. **R5（代码修复已落地；真实发布待 CI 验证）**：`build-in-arch.sh` 在编译后显式安装产物；
   只有 `pacman -U` 失败时，才按 `.SRCINFO` 的 `conflict` 字段查找实际已安装冲突包，并在一次性构建容器
   内用 `pacman -Rdd` 移除后重装。`provides` 不参与移除判断。`runtime-verify.sh` 也会把 `pacman -Ql`
   失败记录为 `not-installed`，不再被 `set -e` 静默终止。需在 GitHub Actions 中重跑 `quirc + ffmpeg-full`
   并确认 runtime verification 与发布闸门结果，不能在本地声称已经发布。
2. **F2（代码接线已落地；需 CI 运行验证）**：build select 步骤尝试下载 `emoeem-abi-manifest.txt`，存在时传给 planner 的 `--repository-manifest`；新仓库无清单时明确告警并继续。
3. **F3（代码接线已落地；需 CI 运行验证）**：等待直接前置结束后，build job 下载每个前置的 `built-<dep>-<run_id>` artifact，将新构建包放入本地仓库目录；缺失 artifact 或包文件会硬失败，不再静默使用旧版本。`configure-build-repo.sh` 在构建容器中重建本地仓库数据库。
4. **F6 文档漂移（已修复主要位置）**：架构审计与构建管线文档改为 planner/shared graph；`build-dag.py --plan` 帮助已与 `build-plan/plan.json` 对齐。
5. **F7 代码卫生（已修复）**：移除 `make_jobs` 死变量和内联 `__import__("os")`；YAML 子集解析器抽到中性的 `scripts/lib/resources.py`。
6. **自愈链路未真跑验证**：ABI watch（`dependency-drift.yml`，每 2 小时 / 可手动）会在发布后自己发现
   `ffmpeg-full → quirc` 的版本漂移并派重建；这条「漂移→自动重建」目前只是接线完成，还没在真跑里跑通过。
7. **附带（已修复，需在目标机器谨慎使用）**：`scripts/install-built-package.sh` 安装失败时，仅在包元数据声明了冲突且对应包确实已安装的情况下移除冲突包后重试；未找到匹配冲突时拒绝盲目卸载。
8. 本轮修改直接发生在 `/home/emo/pkgbuild-source` 的既有 WIP 工作树中；未执行 git add、commit、push、reset、clean、stash 或 rebase。

---

## 4 你怎么自己验收

```bash
# 这轮的结论
gh api repos/emoeem/pkgbuild/actions/runs/38037955697/jobs \
  --jq '.jobs[] | "\(.name)|\(.status)|\(.conclusion)"'

# 发布结果（现在是：quirc 还停在 1.2-4，ffmpeg-full 9.0.2-2.6）
gh release view repo --json assets --jq '.assets[] | select(.name|test("quirc|ffmpeg")) | .name'

# 本地复算（干净 worktree）
cd /tmp/wip-land && bash scripts/run-static-checks.sh      # 11/11
cd /tmp/wip-land && ./tests/run-all.sh --fast              # 78 passed / 0 failed / 2 skipped

# 取作业日志（gh api/gh run view 取不到，必须走 API + token）
curl -sS -L -H "Authorization: Bearer $(gh auth token)" \
  https://api.github.com/repos/emoeem/pkgbuild/actions/jobs/<job_id>/logs | tail -50
```

---

## 5 我的建议

先修 R5 再重跑（让 quirc-1.2-5 真的发出去——现在仓库里 quirc 还停在没有 SONAME 的 1.2-4，而
ffmpeg-full 的 FFmpeg 本体没问题，只是没法在这个镜像里装上验证）；F3 次之（否则「依赖者重建」
永远链上一版）；F2 再往后。凡是动 `build.yml` 接线的（F2/F3），照上次的规矩等你拍板。
