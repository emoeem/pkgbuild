# 优化评估 — pkgbuild-source（2026-10-03）

评估方式：逐文件阅读 + 工具实测（`actionlint` 1.7.12、`shellcheck` 0.11.0、`shfmt`、`makepkg --printsrcinfo`、本地测试套件、`gh run view` 真实 CI 日志、最小 `repo-add` 复现）。
**没有修改任何文件。** 标注说明：`[实测]` = 我在本机/真实 CI 日志里复现过；`[推断]` = 代码阅读结论，未复现。

工具基线（都是好消息，说明基础很稳）：

- `actionlint` 对 9 个 workflow：**0 条**。
- `shellcheck -x -S style` 对 34 个 shell 文件：仅 16 条 info/style，**0 warning/error**。
- `bash -n` 全部通过；本地测试套件全部通过（见 §7）。
- 13 个 `.SRCINFO` 与 `makepkg --printsrcinfo` **逐字节一致**，无漂移。
- `scripts/overlays/ffmpeg-full.sh` 幂等、锚点计数、会失败即报错，质量很高。

---

## 0. 摘要：最值得先做的 8 件事

| # | 问题 | 影响 |
|---|---|---|
| 1 | `removals/daed-emo` 与在用的 `packages/daed-emo` 冲突 | 改 `remove.yml`/`create-repository.sh` 时会把在维护的包从仓库删掉 |
| 2 | `verify-repository.sh` 的"数据库引用了不存在的资产"校验是**死代码** | 发布管线最关键完整性闸门形同虚设（CI 日志已有 13 条 WARN） |
| 3 | `quirc` / `vapoursynth-...` 的 `.aur-url`、`.aur-commit` **没被 git 跟踪** | CI 永远不同步这两个 AUR 包，且新文件会被 `.gitignore` 静默吞掉 |
| 4 | README 教的 `emoeem-update` + systemd timer **已被删除** | 文档承诺的能力不存在 |
| 5 | sing-box 运维脚本有**三份副本且已分叉** | 最近 4 个修复没跑在真正执行的命令上 |
| 6 | build 缓存把整个发布仓库打进去，命中后又 `rm -rf` 重下 | 每个 matrix job 重复下载全仓（ffmpeg-full 很大） |
| 7 | lint 放在 per-package matrix 里：重复 N 次，且 `scripts/**` 单独变更时**完全不跑** | 又慢又漏 |
| 8 | `client/install.sh` 任何 key 下载失败就静默降级 `SigLevel = Never` | 校验被无声关掉 |

---

## 1. 正确性缺陷（会静默出错）

### 1.1 `removals/daed-emo` 与在用的 `packages/daed-emo` 冲突 — P0
`removals/daed-emo`（48d61af 移除）在 53704a3 恢复 `packages/daed-emo` 时没有一起删掉。
`.github/workflows/remove.yml:68-72` 在 `scripts/create-repository.sh` / `remove.yml` 自身变化（或 before-sha 全零）时，会把 `removals/` 下**所有**记录重放给 `/remove-packages`。

后果：只要动一次 `create-repository.sh`，仍在构建发布的 `daed-emo` 会被从 `emoeem.db` 删除。
建议：`git rm removals/daed-emo`；并在 `remove.yml` 里跳过存在 `packages/<name>/.SRCINFO` 的名字（防御性双保险）。

### 1.2 `verify-repository.sh` 的缺资产校验是死代码 — P0 `[实测]`
`scripts/verify-repository.sh:19` 用 `awk -F ' = ' '$1 == "%FILENAME%"'` 解析 repo-add 数据库。
本机用 `repo-add` 7.1.0 复现：`.db` 的 `desc` 条目是 `%FILENAME%` 单独一行、值在**下一行**，根本没有 ` = `，因此永远匹配不到 → 走 `WARN ... continue`。

真实 CI 日志（run 37084091619）里该步骤打印了 **13 条** `WARN: database entry has no %FILENAME% field`，然后 `Repository integrity verification passed`。
建议：`awk '/^%FILENAME%$/{getline; print; exit}'`（已在本机验证可正确取到文件名），并补一个"删掉资产后期望 verify 失败"的测试。

### 1.3 AUR 同步对两个包完全失效 — P0 `[实测]`
`packages/quirc/.gitignore` 和 `packages/vapoursynth-plugin-mlrt-ncnn-runtime/.gitignore` 是 `*` + 白名单，但白名单里没有 `.aur-url`/`.aur-commit`。
`git ls-files` 实测：这两个包的 `.aur-url`、`.aur-commit` 是 **UNTRACKED**（其余 7 个包都跟踪了）。`scripts/sync-aur-packages.sh:9` 用 `find … -name .aur-url` 发现包 → CI 里这两个包永远不会被同步，也永远不会触发重建。同一个坑还会静默吞掉将来加进这两个目录的 patch/`.install`。
建议：白名单加 `!.aur-url`、`!.aur-commit`（或改用 `ffmpeg-full/.gitignore` 那种窄写法），把 4 个文件 `git add`。

### 1.4 `select-packages.py` 的"全零 before"兜底实际选中 0 个包 — P1
`scripts/select-packages.py:82-83` 在 `before` 为空/全零时返回 `["scripts/"]`，看起来是想表达"diff 不可知 → 重建全部"；但 `affected_packages`（:107-121）只把 `config/` 当作 infrastructure，`scripts/` 什么都不会命中 → 返回空集。
对比 `remove.yml:60-61` 对全零 before 的处理是 `infrastructure_changed=true`，两者语义不一致。
建议：全零 before 直接 `return set(available)`，并加测试。

### 1.5 `daed-emo` 的 `pkgver` 是占位值 + 构建期浮动输入 — P1
`packages/daed-emo/PKGBUILD:3` `pkgver=1.27.0.r0.gunknown`（`.SRCINFO` 同步写着 `gunknown`；任何 `git describe` 都不会产生这个值）。
`prepare():34-41` 在构建时 `git fetch --depth=1 origin main` + `checkout --detach FETCH_HEAD`（不锁 commit），再用 `go mod edit`/`go mod tidy` 改依赖图 —— 网络 + 浮动版本 + 无校验和，与 `sing-box-ebpf` 锁定 `_commit` 的做法相反。
注：实测发布仓库里的 daed-emo 是 `1.27.0.r19.gb3043aa-1`，说明 makepkg 会重算 pkgver，功能上没坏；但源码树的记录是错的，且构建不可复现。
建议：写入真实 pkgver；子模块锁 commit；把 `go mod` 改动落到打包补丁里。

### 1.6 `sync-dae-release.sh` 先写 marker 再验证 — P1
`scripts/sync-dae-release.sh:36` 先写 `state/dae-upstream-release` 并退出 0；`sync-dae-release.yml` 靠这次 push 触发构建。如果 daed-emo 构建失败，marker 已经提交，下一次运行在 `:31` 早退（"nothing to do"）→ 这次上游更新被静默丢失，直到上游再发新版。
建议：marker 在构建/发布成功后再提交，或把已应用 tag 记进构建产物。

### 1.7 `pipefail` + 提前退出的消费者会翻转判断结果 — P2（潜在）`[实测]`
形状：`if producer | grep -q PATTERN; then …`。`grep -q` 命中即退出，producer 若在 64 KiB 之后仍要写，会因 EPIPE 以非 0 退出，`pipefail` 让整条管线变成失败。

- 实测复现（合成 producer，输出 >64 KiB）：`(printf 'not found\n'; seq 1 50000) | grep -q 'not found'` → 管线状态 **1**，`if` 分支被判为 false → **掩盖**。
  对应真实代码：`scripts/runtime-smoke-test.sh:19`（`ldd | grep -q 'not found'` 决定是否报缺库）、`scripts/validate-build-policy.sh:15`。
  目前是潜在问题：`ldd` 输出通常远小于 64 KiB，所以还没触发。
- 反向（误报失败）在 `verify-repository.sh:37` / `configure-build-repo.sh:29`：我实测 `bsdtar -tf`（166 KB 列表、`grep -q` 提前退出）退出码是 **0**，所以这两处**没有**被这个坑打中，不要按"误报"去改。

建议：把 `grep -q` 换成会读完输入的写法（`grep … >/dev/null`）或先把输出收进变量，消除对 producer 缓冲行为的隐含依赖。

### 1.8 其它小缺陷
- `manage.sh:807` 的 `'审计全部软件包')` 分支在 `select_one` 菜单列表（:757-776）里没有对应条目 → `audit_all_packages()` 从 TUI **不可达**；而 `README.md:352` 宣称"TUI 增加「审计全部软件包」"。`[实测]`
- `scripts/refresh-rule-sets.sh:15` 只识别 `--check`：`--help`/拼错参数都会继续跑下去并改写 `PKGBUILD`/`.SRCINFO`。建议加 case 解析 + `*) exit 2`。
- `run-namcap.sh:5` 的 trap 用 `;` 串联恢复与删除：恢复失败也会删掉备份且无声。改用 `&&`。
- `scripts/check-dependency-drift.sh:15,39`、`refresh-rule-sets.sh:88`、`check-repository-sonames.sh:156`、`verify-repository-elf.sh:78,112` 有未注册到 EXIT trap 的临时目录/文件（`check-dependency-drift.sh` 每次运行泄漏一整份仓库副本）。

---

## 2. 文档与现实不一致（会误导操作）

### 2.1 文档教的客户端更新器不存在 — P0（文档）
`README.md:167,293,304,310` 与 `docs/package-management.md:93` 描述 `./client/install.sh` 会创建 `emoeem-update` 命令和六小时一次的 `emoeem-repo-update.timer`（读 GitHub 凭据、强同步单提交 `repo` 快照、GC reflog、校验 SHA256、只刷新 db/files）。
实测：`client/` 下只有 `install.sh` 和 `host/rebuild-detector.hook`；`emoeem-update`/`repo-update` 在全仓只有这 4 处文档命中，没有任何代码。这两个文件在 11d8cde 被删除。真实行为是：root 身份、**匿名** HTTPS 预检、导入 key、往 `/etc/pacman.conf` 写 `Server =` HTTPS 段落。
建议：重写 §自动更新客户端 使其与 `install.sh` 一致，或恢复被删的脚本+timer。

### 2.2 README 包清单过期 — P1
- `README.md:6`、`:349` 与 `docs/build-pipeline.md:125` 都写"12 个 package base"，实际 `packages/` 有 **13** 个（`./scripts/audit-packages.sh` 实测输出 `Audited 13 package directories`）。
- `README.md:20-36` 表格 15 行里，`ggml-cuda-git`、`llama.cpp-cuda`、`llama.cpp-cuda-git`、`whisper-cpp-cuda-git` 4 个已下架；`daed-emo`、`linuxqq-wayland-fix-git` 2 个在用但缺失。
- `README.md:24` 仍把 `linuxqq-clipsync-git` 描述成剪贴板修复，实际它的 `package()` 是空的过渡元包。
建议：从 `packages/*/.SRCINFO` 重新生成表格，改掉两处计数。

### 2.3 其它文档漂移
- `docs/performance-profile.md:18,32` 说 ffmpeg-full 是 "Zen3 + O3 + full LTO / GCC 16"，而 `packages/ffmpeg-full/PKGBUILD:241-245` 强制 `-march=x86-64-v3 -mtune=generic -O2`、`:252` 是 `--enable-lto`，且 `docs/build-pipeline.md:104` 写的是 gcc15。
- `README.md:71-85` 只列了 3 个自动化 workflow，实际有 5 个 cron：漏了 `sync-dae-release.yml`（`17 2 * * *`，每日重建 daed-emo，写 `state/dae-upstream-release`）与 `dependency-drift.yml`（只在 :275 提过一句）。
- `README.md:82-83` 与 `refresh-rule-sets.sh:2` 说"三个上游源"，`packages/sing-box-rule-sets/PKGBUILD:35-41` 已经是四个（多了 217heidai 的 adblockfilters），脚本也已按四个处理。
- `README.md:12` 说传播只走 "pkgname/provides 图"，`docs/build-pipeline.md:83` 的说法含 depends/makedepends/checkdepends。

---

## 3. 单一事实来源与重复代码

### 3.1 sing-box 运维脚本三处副本且已分叉 — P1（含未上线修复）
同一批脚本存在三份：

| 仓库内 | 本机已安装（`~/.local/bin`） | 另一仓库 `~/code/toolbox-hub/scripts/sing-box/` |
|---|---|---|
| `scripts/apply-audit-fixes.sh` | `sing-box-audit` | `sing-box-audit` |
| `scripts/switch-to-ebpf.sh` | `sing-box-switch-ebpf` | `sing-box-switch-ebpf` |
| `scripts/switch-to-tun.sh` | `sing-box-switch-tun` | `sing-box-switch-tun` |
| `scripts/enable-container-proxy.sh` | `sing-box-container-proxy` | `sing-box-container-proxy` |
| `scripts/sing-box-status` | `sing-box-status` | 同 |
| `scripts/sing-box-why` | `sing-box-why` | 同 |

实测：`~/.local/bin/*` 与 toolbox-hub 版本**完全一致**（10月2日 20:58 安装），与仓库内版本**不一致**；而仓库版本更新 —— `scripts/switch-to-ebpf.sh` 有 `--shared-plane`（canonical 0 处）、`scripts/apply-audit-fixes.sh` 有 `adblockfilters`（canonical 0 处），对应 git log 里 10月2日 21:16–21:38 的提交。
也就是说：**最近这几个修复只落在仓库副本里，实际在机器上执行的命令没有这些修复**；README §sing-box 运维脚本 又让人跑 `scripts/` 下的版本，第三条路径。
建议：选一个事实来源（建议 toolbox-hub canonical → `install.sh` → `~/.local/bin`，仓库只做引用），或让仓库成为唯一来源并让 toolbox-hub 从它同步；无论哪种，都在 README 里写清"跑的是哪个命令、源码在哪"。

### 3.2 sing-box 脚本内部重复约 270 行 — P1
- `say/warn/die` 逐字节相同 ×5：`apply-audit-fixes.sh:58-60`、`switch-to-ebpf.sh:46-48`、`switch-to-tun.sh:31-33`、`enable-container-proxy.sh:41-43`、`test-shared-interception.sh:34-36`。
- 前置样板（CONF/BIN/SERVICE/BACKUP_DIR + `mktemp -d` + trap + root 检查）约 25 行 ×5。
- "备份 → 原子替换 → 重启" ×4（8 行/处）、"回滚" ×4、`systemctl is-active` 轮询 ×4。
- 端到端健康检查（出口直连 vs 代理、国内直连、DNS 随机子域重试）在 `switch-to-ebpf.sh:260-291` 与 `switch-to-tun.sh:131-158` 近乎逐字重复。
建议：`scripts/lib/singbox-pipeline.sh` 提供 `sb_init/sb_backup_replace/sb_restart_wait/sb_rollback/sb_health_egress/sb_health_dns`，可去掉约 250 行，并顺带统一目前已经分叉的回滚分支。（若采纳 3.1 的单一来源，则改在 canonical 侧做。）

### 3.3 跨脚本小工具重复 — P2
`fail()`+计数器 ×3（`audit-packages.sh:23`、`verify-repository.sh:13`、`verify-repository-elf.sh:18`）；ELF magic `head -c 4 | od …` ×4；`.SRCINFO` 手写 awk 解析散在 6 个文件（`manage.sh:123-130,:149-156` 就有 8 份近似拷贝）；`pacman.conf` 段落改写 + 固定 `/tmp/emo-repo.conf` ×2。建议合并进 `scripts/lib/common.sh`。

### 3.4 发布管线在 build.yml 与 remove.yml 重复且已漂移 — P0（CI 正确性）
`build.yml:293-361` 与 `remove.yml:126-166` 的"准备签名 key / 取仓库状态 / 跑 `create-repository.sh` / `publish-release.sh`"几乎相同，但 `verify-repository.sh`、`verify-publish-inputs.sh` 只出现在 build.yml（2 处），**remove.yml 一次都没有** —— 删除包后重建数据库是不做完整性校验的。
建议：抽 `.github/actions/publish-repository/action.yml`（或 `workflow_call`），把两个 verify 变成无条件步骤。

---

## 4. CI 成本与可靠性

### 4.1 缓存把整个发布仓库卷进去，命中后立刻删掉重下 — P1（最大 CI 浪费）
`build.yml:131-135` 缓存 `path: .cache/pkgbuild`；`:160-170` 却把**所有** `*.pkg.tar.zst` release 资产下到 `.cache/pkgbuild/repo/x86_64`，`:185` 又把该目录挂成 `/localrepo`；`:166` 每次先 `rm -rf` 该目录。
结果：① 每个 matrix job 的缓存保存都打包整个滚动仓库（数 GB）；② 缓存命中的内容 100% 被立刻删除重下；③ key 对所有包相同（`…-<flavor>-<hash>`），miss 时多个 job 抢同一个 key；④ 没有 `restore-keys`，改一次 Dockerfile 全部冷启动。
建议：只缓存真正的缓存目录（pacman/VCS source/cargo），把本地仓库挪到 `.cache` 之外；补 `restore-keys`。

### 4.2 lint 的位置既重复又漏跑 — P1 `[实测]`
`check.yml:115-116` 的 `shellcheck manage.sh scripts/*.sh client/*.sh tests/*.sh` 与两次 `py_compile` 不依赖 `matrix.package`，却在 per-package matrix 里 → 有几个包就跑几遍；`check.yml:108` 的 `test-cachyos-environment.sh builder` 同理。
而 `check` job 有 `if: needs.select.outputs.packages != '[]'`（:87），`select-packages.py` 对 `scripts/**` 单独变更返回 `[]`（`tests/test_select_packages.py:87-94` 就是这么断言的）→ **只改脚本的 PR 一行 shellcheck 都不跑**。
建议：把 shellcheck/py_compile/env 测试移到无条件的 `integration` job（:57-82），matrix 里只留 `check-package.sh` + `namcap`。

### 4.3 触发与并发
- `check.yml:10` 的 `pull_request:` 没有 `paths:`，且全文件没有 `concurrency:` → 纯文档 PR 也会拉起两个容器 job，同一 PR 每次 push 都叠加一整套运行。
- `dependency-drift.yml` 没有 `concurrency:`，schedule 与手动 dispatch 可能同时触发两次 build。
- `refresh-rule-sets.yml`、`sync.yml`、`sync-dae-release.yml` 各自 `git push main`、并发组互不相同、也没有 rebase 重试 → non-fast-forward 失败（`sync-dae-release` 02:17 起最长 90 分钟，正好可能压到 `sync.yml` 的 03:17）。
建议：`check` 加 `concurrency: {group: check-${{ github.ref }}, cancel-in-progress: true}` 与 PR `paths:`；三个 push-main 的 workflow 共用一个并发组 + `git pull --rebase` 重试。

### 4.4 `tests/test-build-regressions.sh` 从未被 CI 执行 — P1
9 个 workflow 里没有任何一处引用它；它守的 git source-cache 冲突回归因此无人把门。建议加进 `integration` job。

### 4.5 其它 CI 项
- `dependency-drift.yml:35` 的 `hashFiles(...)` 守卫 + `:49` 的 `> drift/report.txt || true`：干净运行时 detector 本来就不输出任何东西（`check-dependency-drift.sh` 只在有漂移时打印），所以**崩溃与"无漂移"在日志上完全无法区分**，且 detector 依赖 `pacman -Si` 有已同步数据库，数据库缺失时 `current_version` 为空 → 同样静默"无漂移"（`[实测]` drift run 日志里确实出现过 `database file for 'cachyos-*' does not exist` 警告）。建议去掉 `|| true`、崩溃即报错，并断言"至少比较过 N 个依赖"。
- `builder.yml:44-51` 无 `cache-from/cache-to`，每次改 Dockerfile 都从 `pacman -Syu` 重来；`context: .` 而 Dockerfile 只 `COPY config/emo-native-flags.conf`，又没有 `.dockerignore` → 每次上传约 400 MB 上下文（`.git` 14 MB + `packages/` 含 214 MB 的 ffmpeg src）。
- `.github/builder/Dockerfile` 不可复现：`FROM cachyos-v3:latest` 浮动、`pacman -Syu`、`git clone --depth 1 yay-bin` 无 pin、chaotic keyring/mirrorlist 无 hash 校验、`DisableSandboxNetwork` 削弱 pacman 沙箱、`PATH="/opt/cuda/bin:…"` 也作用于非 CUDA 变体。
- `dispatch-stale-rebuilds.sh:44` 的 `gh api …/runs?per_page=20` 在 per-package 循环里重复发（最多 20×N 次调用）。
- `check.yml` 及其它 workflow 对包名/输入的正确写法已有（`build.yml:67,122,141,175` 用 `env:`），但 `check.yml:45` 把 `${{ inputs.packages }}` 直接插进 `run:`（真注入点，需 dispatch 权限），`build.yml:104` 把 `${{ matrix.package }}` 直接插进 `run:`（同模式；目前只因 `select-packages.py:157` 校验了包名才不可利用）。
- action 引用不统一：`docker/login-action@v3`（`build.yml:112`，浮动 tag）vs `builder.yml:38` 的 pin SHA v4.6.0；`dependency-drift.yml:21`、`maintenance.yml:68`、`refresh-rule-sets.yml:27`、`sync-dae-release.yml:24` 的 `actions/checkout@v6` 未 pin；仓库里没有 `.github/dependabot.yml`。
- `build.yml:339` 通过 `docker run --env` 传 GPG passphrase（宿主机 `ps` 可见）。
- `build.yml:90` 有 `timeout-minutes: 360`，但 `publish`（:241-361）与 `remove.yml` 的发布 job 都没有超时，而它们持有仓库级 `pacman-repository-release` 锁。
- `.github/builder/**` 变化只触发 `builder.yml`（发布新镜像），不触发 `build.yml` 重建；但 `build.yml:135` 的缓存 key 又把该 Dockerfile 计入失效条件 —— 语义不一致，值得明确一下"builder 变了要不要重建全部包"。
- `sync-dae-release.yml:21` 的 `timeout-minutes: 90` < 它等待的 `build.yml` 的 360；`:76-99` 找 run 的条件（`event=workflow_dispatch` + `created_at >= STARTED` + `head -n1`）会误配到同一时间窗内的任何 build dispatch。

---

## 5. 安全与供应链

1. **live sing-box 配置被强制 `chmod 644`** — `apply-audit-fixes.sh:287`、`switch-to-ebpf.sh:230`、`switch-to-tun.sh:112`、`enable-container-proxy.sh:193`。该文件含 `clash_api.secret`（`switch-to-ebpf.sh:243-248` 会读回）和代理凭据；若原为 0600，替换后变全局可读。同时 `"$CONF.new"` 是固定可预测名字。建议 `install -m "$(stat -c %a "$CONF")"` + 同目录 `mktemp` + `mv`。
2. **`client/install.sh:77-92` 静默降级**：任何 key 下载失败（`curl -f` 对 5xx/超时也失败）都会把 `SigLevel` 降成 `Never`；`:88` 正是下载成功时的 `Required DatabaseRequired`。建议只在 HTTP 404 时降级，其余直接失败。`:94` 的 `cp` 每次覆盖 `${pacman_conf}.emoeem-backup`（第二次运行备份的是已被改过的文件），建议 `cp -n` 或带时间戳。
3. **9 处 `sha256sums=('SKIP')` 用在非 VCS 的本地文件上**：`sing-box-panel/PKGBUILD:43-51`（6 个仓库内文件）、`sing-box-rule-sets/PKGBUILD:46-54`（3 个）。本地文件恰恰是唯一可验证的输入，改坏/截断会直接进包。`SKIP` 只应留给 `git+` 源。
4. **`arch` 声明与实际指令集不符**：`daed-emo:50`（`GOAMD64=v3`）、`sing-box-ebpf:99`（`GOAMD64=v3`，pkgdesc 自己都写 x86-64-v3）、`ffmpeg-full:241`（`-march=x86-64-v3`）都声明 `arch=('x86_64')` → 在不支持 v3 的 CPU 上会 SIGILL 而不是被依赖拦下。可考虑 `arch=('x86_64_v3')`（构建容器已接受该架构）。
5. **`sync-aur-packages.sh:30`** `git clone --depth 1 "$aur_url"` 的 `$aur_url` 来自 `.aur-url`（`add-aur-package.sh:68` 由用户输入写入）且没有 `--` → `--upload-pack=…` 之类会被当选项解析。`install-built-package.sh:41,44` 同样缺 `--`。
6. Dockerfile 的信任链问题见 §4.5（keyserver TOFU、chaotic keyring 无 hash、浮动 base/yay、`DisableSandboxNetwork`）。

---

## 6. 局部卫生与工具链

- **本地残留 214 MB**：`packages/ffmpeg-full/src/`（ffmpeg 114 M、whisper.cpp 42 M、build 29 M、staging 19 M、lensfun 12 M）+ `packages/ffmpeg-full/pkg/`（权限 `d--x--x--x`，`ls/du/find/grep -r` 全部报"权限不够"）。两者都被忽略、未被 git 跟踪，不影响 CI，只费磁盘并让递归工具失效。`manage.sh` 目前没有清理入口 —— 可以加一个"清理构建树"动作。
- **没有统一入口**：没有 `Makefile`/`justfile`/`tests/run-all.sh`；`README.md:354-362` 手写 6 条命令，漏了 `tests/test_elf_soname.sh` 与 `tests/test-cachyos-environment.sh`（而 `test-*.sh` 通配还会漏掉下划线命名的 `test_elf_soname.sh`）。
- **缺少约定文件**：`.editorconfig`、`.shellcheckrc`、`.dockerignore`、`.gitattributes`、`.github/dependabot.yml` 都不存在。本地 `shellcheck` 默认 style 全跑（16 条 info），CI 用 `--severity=warning`，两边基线不一致。
- **格式不统一**：`shfmt -d -i 2 -ci` 在 33/34 个文件上提出 5081 行差异（约 16 个 4 空格、7 个 2 空格、9 个内部混用），且没有 CI 格式门。
- **文件权限不一致**：7 个带 shebang 的脚本是 0644（`check-dependency-drift.sh`、`configure-build-repo.sh`、`fetch-repository-state.sh`、`run-namcap.sh`、`validate-build-policy.sh`、`verify-build-dependencies.sh`、`verify-publish-inputs.sh`，现在只因调用方都写 `bash <path>` 才没事，`refresh-rule-sets.yml:36`/`sync-dae-release.yml:35` 还专门 `chmod +x` 兜底）；`check-repository-sonames.sh`、`setup-container-repos.sh`、`scripts/data/external-sonames.txt` 是 0600；`switch-to-tun.sh`、`test-shared-interception.sh` 是 0711。
- **`.gitignore` 缺 `.cache/`**（`docs/build-pipeline.md:93` 就在用 `.cache/pkgbuild`），目前只是被 `*.pkg.tar.*` 巧合遮住；另有未跟踪的 `packages/quirc/.nvchecker.toml`（活着但没人用）、`scripts/__pycache__`、`tests/__pycache__`。
- **网络调用缺超时**：`client/install.sh:79`（`--retry 3` 但无 `--max-time`，而同文件 `:65` 有）、`build-in-arch.sh:157`（有 `--connect-timeout` 无 `--max-time`）；`fetch-repository-state.sh:21-43`、`sync-aur-packages.sh:30`、`manage.sh:450-519` 的 `gh`/`git` 调用没有 `timeout` 包裹。
- **`pacman -Sy` 不带 `-u`**：`manage.sh:408`、`client/install.sh:120`、`build-in-arch.sh:191`、`setup-container-repos.sh:110,115`（同文件 `:68` 却是 `-Syu`）—— Arch 文档里的部分升级隐患，建议统一 `-Syu`。
- **性能**：ELF 判定每个文件 fork 两个进程（`check-elf-needed.sh:48` 等）+ 每文件 `readelf`；`verify-repository-elf.sh` 把每个包解两遍（:68-105 与 :109-133）。可直接在 bash 里读 4 字节 magic，并复用一次解包。
- **`select-packages.py`**：`affected_packages` 的不动点循环每轮重新打开/解析 `.SRCINFO`（`dependency_graph` 已有映射）；`changed_paths` 的 `check=True` 失败时抛裸 traceback；argparse 没有 `choices`/`--` 保护。

---

## 7. 测试覆盖

现状（我本机全部跑过，均通过）：`test_select_packages.py`(6) / `test-package-audit.sh` / `test-build-regressions.sh` / `test_elf_soname.sh` / `test_repository.sh` / `test-cachyos-environment.sh base`；`bash -n` 全通过；`shellcheck --severity=warning`（CI 原命令）全通过。

缺口（按风险排序）：

1. **签名路径完全没测**：没有任何测试设置 `REPOSITORY_KEY`，`create-repository.sh:148-176,208-249`（gpg 导入、逐包 `.sig`、db/files `.sig`、导出公钥、`SigLevel = Required DatabaseRequired`）从未执行过 —— 而 `client/install.sh:88` 一旦拿到 key 就切到这个 SigLevel。建议加一个一次性 GPG key 的 fixture 测试。
2. `test-build-regressions.sh` 里 11 条 `grep -Fq` 是"改文本就过"的 change-detector（`:33-55`，其中一条还在 grep 另一个测试文件），`build-in-arch.sh` 从未真正执行。
3. `audit-packages.sh` 只测了合法输入 + 重复 provider；`.SRCINFO` 过期（:48）、pkgbase 不匹配（:54）、缺 arch（:58）、`.aur-url`/`.aur-commit`（:60-65）、自依赖（:113-125）都没测。
4. `verify-repository-elf.sh` 只测了"互斥替代品允许重复 SONAME"，拒绝分支（:86-88）没测。
5. `test_elf_soname.sh:45-51` 的 locale 回归在没装对应 locale 时静默跳过，而且 `check-elf-needed.sh:7` 已经写死 `LC_ALL=C`，即使跑到也无法失败 —— 属于空转断言。
6. `client/host/rebuild-detector.hook:17` 只有 `Operation = Upgrade`：全新 `pacman -S emoeem/<pkg>` 不会触发重建扫描（README:259 的表述是"每次事务结束"）。
7. 完全没测的高风险脚本：`refresh-rule-sets.sh`（用正则改 PKGBUILD 的 sha256sums + SKIP 计数启发式 + 下载 4 个 URL，写错就发布坏 PKGBUILD）、`sync-aur-packages.sh`（`rm -rf "$package_dir"` 后 `mv`）、`remove-package.sh`。
8. `test_select_packages.py` 只调 `select()`，没测 CLI（`--selection` CSV、未知/非法包名退出码、`--root`、JSON 输出、`--before` 缺失时的 `diff-tree` 回退）。
9. 命名/一致性：`tests/test_repository.sh` 权限 0644（只能 `bash` 跑）；`check.yml:46,53,64,116` 用 `python` 而 README:360 写 `python3`。

---

## 8. 各包 PKGBUILD 的小问题

| 包 | 问题 |
|---|---|
| `quirc` | `:1` `# Maintainer:` 为空；`:11` `arch=('i686' 'x86_64')`（Arch 已无 i686，本仓库只发 x86_64）；`:13-17` 的 `libjpeg-turbo`/`sdl12-compat`/`sdl_gfx` 是 `build()` 需要的，却在 `depends` 且没有任何 `makedepends` |
| `scx-scheds-git` | `:33-39` `_backports=()`/`_reverts=()` 为空 → `:44-63` 整套 cherry-pick/revert/patch 机制永远不可能执行（约 25 行死代码） |
| `vapoursynth-plugin-mlrt-ncnn-runtime` | `:5` `pkgver=v15.14` 保留前导 `v`；`:13` `optdepends=()` 空数组；`:41` `for i in $(find models* -type f)` 未加引号 |
| `mpeghdec` | `:9` `license=('LicenseRef-Custom')` 应为 `custom:`；`:33` 未加引号的 glob；`:35` 用 `mv` 把 `usr/share/pkgconfig` 挪进 `usr/lib`（应在安装时指定路径） |
| `sing-box-panel` | 6 个本地源 `SKIP`（见 §5.3）；`package()` 用 `cp -a` 拷贝 `dist/`，但没有 pin zashboard 之外的其它输入 |
| `daed-emo` | `pkgver` 占位 + 浮动子模块（见 §1.5） |
| `ffmpeg-full` | `pkgrel=2.6`（overlay 管理，幂等，属预期）；`:86,98,112` 依赖本仓库的 `mpeghdec`/`quirc`/`svt-jpeg-xs-git`，任何小库改动都会把最贵的构建拖下水（设计取舍，可考虑 ABI 稳定性豁免） |

---

## 9. 建议的推进顺序

**第 1 批（正确性，改动小、风险低）**
`git rm removals/daed-emo` + remove.yml 防御；补跟踪 4 个 `.aur-url`/`.aur-commit`；修 `verify-repository.sh:19` 的 awk 并补测试；修 `select-packages.py` 全零 before；把 `'审计全部软件包'` 加回菜单；修 README 计数/表格/`emoeem-update`。

**第 2 批（CI 成本与可靠性）**
lint 移出 matrix 并覆盖 `scripts/**`-only 变更；缓存只留真正的缓存目录；接入 `test-build-regressions.sh`；补 `concurrency`/PR `paths`；抽 publish 复用并在 remove.yml 补两个 verify；统一 action pin + 加 dependabot；`dependency-drift` 去掉 `|| true`。

**第 3 批（可维护性）**
`scripts/lib/common.sh`；sing-box 脚本单一事实来源（配合 3.1 决定方向）；`Makefile`/`tests/run-all.sh`；`.editorconfig` + `shfmt -w` + CI 格式门；统一文件权限；补 `.cache/` 忽略。

**第 4 批（安全）**
两处 `${{ }}` 注入改 `env:`；`install.sh` 只对 404 降级 + 备份不覆盖；sing-box 配置保留原权限；Dockerfile pin base/yay 并校验 keyring hash。

---

### 附：本次"已经很好、不要动"的部分

- `actionlint` 全绿、`shellcheck` 无 warning/error；多行 `run:` 一律 `set -Eeuo pipefail`，用户输入普遍走 `env:`，三个 matrix 都 `fail-fast: false`。
- 发布串行化与幂等做得对：`build.yml:252-254` 与 `remove.yml:32-34` 共用 `pacman-repository-release` 组，`publish-release.sh:112-139` 用 sha256 比对后再上传，`--clobber` 不是盲写。
- 解析型脚本统一 `export LC_ALL=C` 并写明了"本地化标签会把检查变成 no-op"的原因；`create-repository.sh` 的 GitHub 资产名净化（epoch 冒号 → `1.2.0`）考虑周全且有端到端测试。
- `scripts/overlays/ffmpeg-full.sh` 幂等、锚点计数、CI 里没有 makepkg 时降级为文本修补 `.SRCINFO`；两个手写 scriptlet（`sing-box-ebpf.install`、panel 的 0600 token + `/var/lib` 状态）都是安全且幂等的。
