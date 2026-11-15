# Phase 2 验收报告 — dsh-desktop-linux 依赖与打包修复（2026-11-15）

对应计划 Phase 2.1 / 2.2 / 2.3 / 2.4；问题定位见 [dsh-audit.md](dsh-audit.md)。未执行任何 git commit / push。

## 1. 变更文件清单

| 文件 | 变更 |
|---|---|
| `packages/dsh-desktop-linux/PKGBUILD` | depends 删除 `'libxss'`（11 项，与 rc3 资产 .PKGINFO 逐项一致）；注释说明上游 rc2 删除史；**build() 新增依赖双向对账** |
| `packages/dsh-desktop-linux/.SRCINFO` | 同步删除 `depends = libxss`；`makepkg --printsrcinfo` 比对一致 |
| `scripts/data/smoke-tests.yaml` | dsh 段新增 `.desktop` 存在断言（`test -f /usr/share/applications/deepseek-harness.desktop`） |
| `tests/test-dsh-desktop-linux.sh` | **新增**。三组断言：元数据一致性、build() 对账正/反两方向、打包外围自洽 |

## 2. 修复前后对比

### 2.1 过时依赖（2.1）

```text
修复前: depends=( gtk3 nss libnotify libxss libxtst xdg-utils at-spi2-core
                  libsecret alsa-lib dbus libxcrypt-compat libdbusmenu-glib )   # 12 项
        上游 rc2（0.2.2rc2）release note: "去掉安装包里冗余的 XScreenSaver 依赖…Arch 包
        不再要求安装 libxss"；rc3 资产 .PKGINFO depend = 11 项（无 libxss）

修复后: depends 11 项，与 rc3 资产 .PKGINFO 逐项 diff = 空（Phase 0 复现命令 `9d8 < libxss` 消除）
        .SRCINFO 同步；客户端不再被强制安装一个 Electron 既不链接也不加载的库
```

### 2.2 根因（更新器永不同步 depends）——build() 对账闸门

选型依据（审计 §2 方案 2）：零工作流改动、每次构建都验、不把"依赖语义要不要跟"的判断交给无人值守更新器。对账是**集合双向**比较（`local -A`）：

```text
资产多声明 → "Dependency reconciliation failed: the upstream asset declares dependencies
              this PKGBUILD does not: <name>" → 构建失败
本地多声明 → "…this PKGBUILD depends on <name>, but the upstream asset does not declare it."
              → 构建失败
一致       → 放行
```

上游 makedepend（nodejs/pnpm/python）字段名不同，不进入对账——本地无 makedepends，属上游构建细节，语义正确。

### 2.3 pkgrel 策略（2.3）

`.pkgrel-floor-skip` 保留，语义与适用范围已由 Phase 1 落实为**全入口**：E1/E2（pkgrel-floor）原有，E3（prepare-build-source）/E4（auto-repair）本阶段起生效（见 [phase1-pkgrel-report.md](phase1-pkgrel-report.md) §2）。上游版本变化 → 更新器重置 `pkgrel=1`（资产内嵌 `-1`，版本前进靠 pkgver）保持不变。repack 包不被无意义 dispatch 的部分属 Phase 3/5。

### 2.4 验证矩阵（2.4）实测结果

| 检查项 | 结果 |
|---|---|
| PKGBUILD 解析 / .SRCINFO 一致性 | ✅ `bash -n` + `makepkg --printsrcinfo` diff 为空（本机 makepkg 7.1.0 实测） |
| 上游下载 + SHA256 | ✅ 完整 357,204,579 字节下载，sha256 `e6f46a40…b640bd` 与 pin 一致 |
| .PKGINFO 字段（pkgname/pkgver/arch） | ✅ 真实资产 build() PASS |
| 依赖关系（新增） | ✅ 真实资产 PASS；合成资产正/反两方向失败且指名道姓（test-dsh §2） |
| 包内文件列表 | ✅ 真实资产 .MTREE（33,130 项）核对：顶层点文件恰 4 个（.BUILDINFO/.INSTALL/.MTREE/.PKGINFO，与 package() 排除清单一致）；payload 含 etc/ opt/ usr/ |
| 安装/卸载行为 | ✅ 发布闸门 repository-install-test 照旧（未改动） |
| AppArmor 逻辑 | ✅ 资产含 `/etc/apparmor.d/deepseek-harness`，install 脚本路径一致，optdepends 在 |
| 桌面启动文件 | ✅ 资产含 `/usr/share/applications/deepseek-harness.desktop`；package() 实解包断言 PASS；smoke-tests.yaml 新增安装后断言 |
| 应用启动动态库 | ✅ runtime-verify + 3 条已论证豁免照旧 |

端到端命令（真实资产）：`build()` PASS → `package()` PASS → desktop/apparmor/chrome-sandbox 三断言 PASS（见 §5 复现）。

## 3. 测试报告

| 套件 | Phase 1 | 本次 |
|---|---|---|
| `./tests/run-all.sh --fast` | 129 / 0 | **131 / 0 / 2 skip**（+test-dsh-desktop-linux.sh） |
| `./scripts/run-static-checks.sh` | 14/14 | **14/14** |
| `bash tests/test-dsh-desktop-linux.sh` | — | 6 断言全绿 |

新测试的三个合成资产用例（匹配放行 / 资产多 depend 拒绝 / 本地多 depend 拒绝）不联网、秒级完成，进 `--fast` 套件，CI 的 run-all（builder 内）自动覆盖。

## 4. 剩余风险

1. **对账为构建期闸门，非更新期**：上游改依赖时，下一次 dsh 更新的候选构建会红（不是静默发布），但修复靠人改 depends 数组——这是有意设计（依赖语义需要人判断）。更新器未来可选增强：对账失败时在失败 issue 里附 diff（Phase 5/7 可做）。
2. **depends 元素若引入版本约束**（如 `gtk3>=3.24`）：对账按原样字符串比较，两边必须同步加，否则构建失败——过严但安全，当前均为裸名。
3. **`.desktop` 断言硬编码路径**：上游改名会红（指名道姓的失败，可接受）。
4. **CI 全链路**：本机已用完整真实资产验证；下一次上游 release 的候选构建将首次在 CI 中走过新对账闸门（当前 pin 与资产一致，预期绿）。
5. 计划 2.2 的既有校验（tag/asset/digest/候选构建/runtime 验证）全部保留未动。

## 5. 复现命令与预期回显

```bash
cd /media/emo/code/pkgbuild

# 1. 依赖集合与 rc3 资产逐项一致（Phase 0 的证据命令，现在差异为空）：
tmp=$(mktemp -d); for i in 1 2 3; do curl -sL --retry 3 --retry-all-errors -r 0-8388607 \
  "https://github.com/ffyfox/dsh-desktop-linux/releases/download/v0.2.2rc3/dsh-desktop-linux-0.2.2rc3-1-x86_64.pkg.tar.zst" \
  -o "$tmp/head.zst" && break || sleep 5; done
diff <(sed -n 's/^\tdepends = //p' packages/dsh-desktop-linux/.SRCINFO | sort) \
     <(zstd -dc "$tmp/head.zst" 2>/dev/null | head -c 6291456 | strings | sed -n 's/^depend = //p' | sort)
# 预期: （无输出，exit 0）—— Phase 0 时是 "9d8 < libxss"
rm -rf "$tmp"

# 2. 离线测试（对账两方向 + 元数据一致性）：
bash tests/test-dsh-desktop-linux.sh
# 预期: ok: 11 depends agree in PKGBUILD and .SRCINFO (no libxss)
#       ok: a matching asset passes the reconciliation
#       ok: an asset-only dependency fails loudly and names it
#       ok: a locally declared dependency absent from the asset fails loudly and names it
#       all dsh-desktop-linux cases passed

# 3. 回归：
./tests/run-all.sh --fast 2>&1 | tail -2
# 预期: passed 131, failed 0, skipped 2 / All local checks passed.
```

**阶段验收结论**：2.1（libxss 移除 + 无其他过时依赖，逐项核对 rc3 资产）✅；2.2（现有完整性校验全保留，新增 depend 对账）✅；2.3（skip 标记语义与全入口生效，Phase 1 已交付）✅；2.4（矩阵逐项实测，含完整真实资产端到端）✅。DSH 包可正常构建、安装，依赖定义与当前上游资产一致。可进入 Phase 3（构建策略分类）。
