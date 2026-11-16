# Navicat for Mac — V2.1（安全维护版）

V2.1 在原有 `navicat-v2.sh` 上增加 **SHA-256 备份清单校验、只读 `doctor` 诊断、恢复冲突归档、异常回滚日志、隔离自动化测试**。原版脚本保留以便参考，不需要修改或打补丁到 Navicat 应用。

## 兼容与限制

| 功能 | Navicat 16.x、17.0–17.3.6 | Navicat 17.3.7+、18.x |
|---|---|---|
| 版本与本地环境检测 | 支持 | 支持 |
| Dry Run / doctor | 支持 | 支持 |
| 配置备份与恢复 | 支持 | 支持 |
| 旧版本地记录清理 (`reset`) | **仅匹配已知旧结构时开放** | **主动阻止** |
| Keychain 读写 | 不涉及 | 不涉及 |

**注意：** 匹配到 32 位字符串只是格式匹配，不意味着已证明这些记录对应试用授权。V2.1 没有在真实 Navicat 18 上验证重置，不会因检测到相似记录就解锁执行。脚本不提供许可证，也不保证新的试用资格；应遵守软件许可条款。

## 使用方法

系统要求：macOS、自带 Bash、`PlistBuddy`、`plutil`、`defaults`、`shasum`。**不要使用 sudo 或 chmod 777。** 修改/恢复前务必关闭 Navicat 并独立导出重要数据库连接。

```bash
bash -n navicat-v2.sh
bash navicat-v2.sh inspect           # 只读，输出环境和匹配数量
bash navicat-v2.sh doctor            # 只读，附带扫描现有备份健康度
bash navicat-v2.sh audit-18          # 仅 Navicat 18：只读指纹审计，不重置试用期
bash navicat-v2.sh dry-run           # 只读，预览重置是否会被策略阻止
bash navicat-v2.sh backup            # 生成带 SHA-256 清单的备份
bash navicat-v2.sh backups           # 列出备份 ID
bash navicat-v2.sh verify-backup ID  # 校验备份 SHA-256 清单和文件清单
bash navicat-v2.sh restore ID --confirm RESTORE  # 未修改或缺失目标时的恢复
```

### Navicat 18 实验分支只读审计

`audit-18` 在 18.x 中报告偏好文件和符合旧格式的隐藏文件的大小及 SHA-256 指纹，以便在不删除任何记录的条件下比较环境快照。不会打印 plist 键值或文件内容，不读取 Keychain，不创建日志或备份，也不启用试用重置。对非 18 版本会明确拒绝。

**注意：** 指纹变化只能说明文件字节发生改变，不能证明字段属于授权或试用状态。本实验分支仍然阻止 Navicat 18 执行 `reset`。

`restore` 遇到现有内容和备份内容不一致时**默认拒绝覆盖**。明确希望保留当前文件并恢复备份时，可执行：

```bash
bash navicat-v2.sh restore ID --confirm RESTORE --on-conflict archive
```

这会先将现有目标文件存入私有恢复日志目录 `recovery/`，再恢复备份；发生可捕获的中断/写入异常时尝试自动回滚。**这不是数据库级 ACID 事务**：断电、SIGKILL 或文件系统损坏时必须人工检查 `recovery/` 下的日志和快照；`doctor` 会提示未完成或需检查的恢复事务。

已知旧版本的受控重置命令仍保留：

```bash
bash navicat-v2.sh reset --confirm RESET
```

此命令**不会**在 Navicat 17.3.7+ 或 Navicat 18 上执行，会先备份后修改已知旧版的本地记录；不触碰 Keychain，不保证获得新的软件试用资格。

## V2.0 备份兼容

V2.0 生成的备份（例如 `20261116-115423-17219`）没有 SHA-256 清单。V2.1 **保留这些文件，不会自动重写**，`doctor` 将它们显示为 `legacy_unverified`。

如确实需要恢复一个 V2.0 备份，须审查备份目录及来源后显式确认：

```bash
bash navicat-v2.sh restore 20261116-115423-17219 --confirm RESTORE --allow-legacy-backup
```

这只能做文件结构与 plist 校验，**不能追溯验证原有备份未曾被篡改**。因此优先建议先使用 V2.1 创建一个新的、带 SHA-256 清单的备份。旧备份可以另外使用 `verify-backup ID --allow-legacy-backup` 检查基本结构。

## 文件组织与安全

```
~/Library/Application Support/NavicatTrialV2/
├── backups/
│   └── YYYYMMDD-HHMMSS-PID/
│       ├── prefs.plist          # 仅当配置存在时
│       ├── hidden/             # 仅匹配格式的常规隐藏文件
│       ├── version
│       └── manifest.sha256     # SHA-256 完整性清单
├── logs/run.log
└── recovery/                  # 恢复操作前的原始目标文件与状态标记
```

备份目录使用私有权限。日志只记版本、数量与状态，不主动记录连接密钥、备份内容或 Keychain 数据。`inspect`、`doctor`、`dry-run` 和 `verify-backup` **不会写日志或修改文件**。SHA-256 校验旨在发现意外损坏，并不能防范有权同时改写文件和清单的恶意程序。

## 开发与测试

```bash
bash -n navicat-v2.sh
python3 -m unittest discover -s tests -v
```

测试显式使用独立临时目录的模拟 plist/应用元数据，**不会读取或修改真实 Navicat 数据**，也可在 Linux 上运行。测试模拟16/17旧版本和18版本限制、备份篡改、目录冲突、旧备份兼容、恢复中断与回滚。自动化测试**不等于**已在 macOS 上完成实际集成测试：在真实机器上仍应从只读检测、备份和同内容恢复开始。

### 已知事项

- 仍通过旧版格式规则筛选 32 位键，不能证明它们的功能。
- Keychain 没有纳入备份或回滚，因此恢复仅限这里列出的本地文件。
- 所有修改均针对当前登录用户，不支持多账号批量操作。
- V2.1 默认拒绝跨应用版本恢复，降低配置不兼容风险。
- GitHub Actions 中的 Linux 模拟测试用于防止脚本回归；真实 macOS 行为需另行验证。