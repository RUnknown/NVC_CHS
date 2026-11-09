# NVC_CHS

![Platform](https://img.shields.io/badge/platform-Windows-blue)
![Runtime](https://img.shields.io/badge/.NET%20Framework-4.x-blueviolet)
![Shell](https://img.shields.io/badge/shell-Windows%20PowerShell%205.1-lightgrey)

给 [NVCleanstall](https://www.techpowerup.com/download/techpowerup-nvcleanstall/) 加简体中文界面的非侵入式补丁。
通过 .NET 的 `AppDomainManager` 机制在程序入口之前加载，再用反射遍历 WPF 界面树替换文本；
**不修改、不重打包 `NVCleanstall.exe`**，原程序签名保持不变，随时可完整回退。

## 功能特性

- **非侵入**：只新增配置与补丁 DLL，删掉即恢复原状。
- **低开销**：订阅 `LayoutUpdated`，界面有变化才扫描（10 ms 唤醒、1 s 定时兜底），空闲时零遍历。
- **零足迹**：正常运行时不在安装目录写任何文件、也不创建子目录；只有出错才生成 `NVC_CHS\error.log`，
  修好后下次启动会自动清理。
- **热重载**：`zh-CN.txt` 每秒检查时间戳，改完保存即生效，无需重启程序；文件被编辑器短暂锁住时保留旧词典并在下次重试。
- **两种匹配**：精确匹配与 `*prefix=` 前缀匹配（最长优先），动态数值等后缀原样保留。
- **自带回归测试**：`build.ps1` 编译后自动运行回归检查（词典解析、WPF 遍历、发布包完整性）。

## 目录

- [NVC\_CHS](#nvc_chs)
  - [功能特性](#功能特性)
  - [目录](#目录)
  - [背景](#背景)
  - [快速开始](#快速开始)
    - [方式一：下载 Release（无需编译）](#方式一下载-release无需编译)
    - [方式二：从源码构建](#方式二从源码构建)
  - [使用说明](#使用说明)
  - [词典格式](#词典格式)
  - [补全词条](#补全词条)
  - [目录结构](#目录结构)
  - [隐私与分享前检查](#隐私与分享前检查)
  - [常见问题](#常见问题)
  - [第三方内容与商标](#第三方内容与商标)
  - [致谢](#致谢)

## 背景

NVCleanstall 是 TechPowerUp 出品的 NVIDIA 驱动精简安装工具，官方没有中文界面。
本仓库为它做了一个个人本地化补丁。词典按 **v1.19.0** 的界面文本编写；上游更新后按「补全词条」
流程增量维护即可。

## 快速开始

### 方式一：下载 Release（无需编译）

从 [Releases](https://github.com/RUnknown/NVC_CHS/releases) 下载 `NvcChs.zip`，
**全部解压到 NVCleanstall 安装目录**（即 exe 所在目录）。解压后：

```text
NVCleanstall.exe             原有文件，不会被改动
NvcChs.dll                   解压得到
NVCleanstall.exe.config      解压得到
install.cmd                  解压得到；便携版改名时才需要
zh-CN.txt                    解压得到；词典
NVC_CHS\                     仅出错、或你把词典放在此处时出现
```

启动 NVCleanstall 即可看到中文。

**`<exe名>.config` 与 `NvcChs.dll` 必须同时存在。** 只删 DLL 而留下配置，NVCleanstall
会**无法启动**（CLR 找不到注入的程序集，报 `TypeLoadException`）。

**如果 exe 改了名**（便携版如 `NVCleanstall_1.19.0.exe`）：Windows 只认与可执行文件
**文件名完全一致**的 `<exe名>.config`，所以这时需双击一次 `install.cmd`，它会为目录里每个
`NVCleanstall*.exe` 生成对应配置。多个版本并排放时，每版各有一份配置，互不影响；上游更新换了
文件名后，旧配置不会跟着改名，重跑一次 `install.cmd` 即可。

要回退，删除 `NvcChs.dll`、`NVCleanstall*.exe.config`、`zh-CN.txt` 与 `NVC_CHS` 目录即可。

### 方式二：从源码构建

环境要求：

- Windows x64 与 .NET Framework 4.x（编译使用系统自带的 `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`）；
- `powershell.exe`（Windows PowerShell 5.1）；`test.ps1` 需要 WPF 与 STA，`pwsh` 7 不支持；
- 已安装 NVCleanstall，且**本仓库目录需位于其安装目录内**（脚本依赖这个位置关系）；
- 安装目录在 `C:\Program Files` 下时，构建与部署需要管理员权限。

```powershell
git clone <仓库地址> NVC_CHS   # 放进 NVCleanstall 安装目录
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1    # 编译 + 回归测试
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1   # 启用汉化
```

## 使用说明

| 命令 | 作用 |
| --- | --- |
| `.\build.ps1` | 编译 `NvcChs.dll` 到上一级（exe 同级），并自动运行 `test.ps1` |
| `.\build.ps1 -Diagnostics` | 额外编译诊断版：持续写 `seen/missing/status.txt`，供补全词条使用 |
| `.\package.ps1` | 打出发布用 `NvcChs.zip`（依赖 `build.ps1` 的产物）；CI 与本地共用同一份清单 |
| `.\deploy.ps1` | 启用汉化：为每个 `NVCleanstall*.exe` 复制同名配置；exe 同级已有 `zh-CN.txt` 时，用仓库版本覆盖它 |
| `.\deploy.ps1 -Status` | 查看各 exe 的哈希、签名与补丁文件状态 |
| `.\deploy.ps1 -Rollback` | 回滚：删除本补丁的配置与 DLL，不触碰 exe |
| `.\install.cmd` | （发布包用）双击为每个 `NVCleanstall*.exe` 生成同名配置 |

细节：

- `build.ps1` 会检查程序集版本是否为 `1.0.0.0`（与配置模板里的 `appDomainManagerAssembly` 绑定一致）；
  若修改 `AssemblyVersion`，需同步更新配置模板。
- `deploy.ps1` 遇到已存在且不含 `appDomainManagerType` 的其它配置时会拒绝覆盖，不碰无关文件。

## 词典格式

`zh-CN.txt` 为 UTF-8 无 BOM、LF 行尾，每行一条；`#` 或 `;` 开头为注释：

```text
key=value          精确匹配
*prefix=value      前缀匹配，未匹配的后缀原样保留
```

- key 与 value 都支持 `\n`、`\r`、`\t`、`\\` 转义（界面里的 CRLF 按 `\n` 匹配）；
- key 区分大小写（Ordinal），必须与界面文本逐字符一致：`Disable ansel` 匹配不到 `Disable Ansel`；
- 前缀规则的尾部空格是有意义的，不要修剪；
- 查找顺序：exe 同级的 `zh-CN.txt` 优先，找不到再读 `NVC_CHS\zh-CN.txt`；
  诊断版 `status.txt` 的 `dictionaryPath=` 写明实际读取的是哪一个。

## 补全词条

补词前先用诊断版构建并部署：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Diagnostics
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1
```

然后启动程序、走完各个页面，`NVC_CHS\` 下会持续写出 `missing.txt`（未命中的界面文本）、
`seen.txt`（已见文本）与 `status.txt`。把需要的行复制进 `zh-CN.txt` 并补上 `=译文`，保存即生效。
补完后再用**不带** `-Diagnostics` 的默认构建发布，安装目录就恢复零足迹。

切回发布版之前，先把要用的行复制进 `zh-CN.txt`。发布版一启动就会清掉 `NVC_CHS\` 下的诊断文件，
`missing.txt` 也就没了。`build.ps1` 发现残留的 `missing.txt` 会给出警告。

`deploy.ps1` 会用仓库版本覆盖 exe 同级的那份 `zh-CN.txt`（查找顺序见[词典格式](#词典格式)），
免得改了仓库里的词典却不生效。如果只想用仓库那份，删掉 exe 同级的 `zh-CN.txt` 就行。

**只取通用界面文本**：这两个文件会混入本机显卡型号与设备 ID、驱动版本号、软件版本等运行时数据，
写进词典就等于把设备信息公开提交。

有意不译：版本号、驱动文件名、显卡型号、窗口标题、组件专有名（PhysX、NV Container、ShadowPlay、GeForce Experience 等）。

## 目录结构

```text
NVC_CHS/
├── src/NvcChsManager.cs      AppDomainManager + WPF 反射扫描（NvcChs.NvcChsManager）
├── zh-CN.txt                 词典（UTF-8 无 BOM）
├── NVCleanstall.exe.config   部署用的配置模板
├── build.ps1                 编译并运行回归测试
├── package.ps1               按显式清单打出发布用 NvcChs.zip
├── deploy.ps1                启用 / 查看状态 / 回滚
├── install.cmd               （发布包用）为改名的 exe 生成同名配置
├── tests/test.ps1            回归测试（build.ps1 自动调用）
└── seen.txt / missing.txt / status.txt / error.log
                              仅诊断版（-Diagnostics）生成；error.log 仅出错时生成，均不入库
```

`build.ps1` 的产物与 `deploy.ps1` 部署的配置都写到上一级（exe 同级）。

## 隐私与分享前检查

诊断版构建（`-Diagnostics`）与出错时生成的 `error.log` 会记录本机运行时的界面文本与统计，
可能包含显卡型号、设备 ID、驱动版本、软件版本等可识别设备的信息。
它们由程序自动覆盖，已被 `.gitignore` 排除，**不会进入提交或 `git push`**；
发布包同样不会带上它们——`package.ps1` 按显式清单打包，只含 DLL、config、安装脚本、词典与 README。
但压缩整个目录、上传截图、复制文件夹分享时会一并带出。分享前删除
（不影响使用；诊断版会在下次启动时重新生成）：

```powershell
Remove-Item .\seen.txt, .\missing.txt, .\status.txt, .\error.log -ErrorAction SilentlyContinue
```

词典 `zh-CN.txt` 本身只收录通用界面文本，不含任何本机硬件、路径或账号信息。

通过 issue 反馈问题时，同样不要粘贴上述运行时文件的内容。

## 常见问题

**下载 Release 安装后界面还是全英文？**
先看安装目录有没有 `NVC_CHS\error.log`：出现 `DICT_MISSING` 就是词典没找到，
日志里列了两个候选路径（exe 同级与 `NVC_CHS\` 子目录），放到任一位置即可，同级优先。

如果连 `NVC_CHS\` 目录都没有，说明这次运行没报错，那就检查两件事：
DLL 是否真被加载——exe 改过名（如 `NVCleanstall_1.19.0.exe`）却没同名配置时，双击一次 `install.cmd`；
以及词典是否命中，见下一条。

**为什么有些文字还是英文？**
词典尚未覆盖。用 `-Diagnostics` 构建启动、走完对应页面后查看 `NVC_CHS\missing.txt`，
按[补全词条](#补全词条)流程补充即可；未命中的文本保持英文，不会报错。

**为什么版本号和驱动文件名不翻译？**
它们是动态字符串，翻译会破坏匹配并造成歧义；完整的不译清单见[补全词条](#补全词条)。

**上游 NVCleanstall 更新后补丁还能用吗？**
界面文案没变就能用，变了就补词典。若上游改为 .NET (Core) 或自包含部署，
本方案（依赖 .NET Framework WPF 反射）需要重做。

**修改 `zh-CN.txt` 后需要重启程序吗？**
不需要，保存即热重载。

**会影响 NVCleanstall 本身吗？**
exe 一个字节都不会被修改，签名保持不变；`deploy.ps1 -Rollback` 可完整回退。

## 第三方内容与商标

- 本仓库**不包含** NVCleanstall 的可执行文件、程序集、资源文件或源代码，也不包含任何 NVIDIA 驱动包内容。
- `zh-CN.txt` 中 `=` 左侧的英文文本是对 NVCleanstall 运行中界面字符串的观察记录，右侧中文为其译文（演绎）。
  相关权利归 TechPowerUp 及各原权利人所有；本仓库不主张这些文本的任何权利，也不授予第三方使用它们的权利，
  收录范围仅限实现界面本地化所必需的通用界面字符串，不含帮助文档、图标或驱动文件内容。
- `NVCleanstall`、`NVIDIA`、`GeForce`、`PhysX` 等名称与商标归各自权利人所有，此处仅用于指代，
  不表示关联、授权或背书。本项目为个人本地化用途的非官方作品，与 TechPowerUp / NVIDIA 无关联。
- 使用前请确保已合法取得 NVCleanstall 副本并遵守其许可条款；本补丁按「原样」提供，不提供任何担保。
- 若权利人认为相关内容不当，请通过 issue 提出，将及时移除。

## 致谢

- [NVCleanstall](https://www.techpowerup.com/download/techpowerup-nvcleanstall/)：本项目的本地化对象，由 TechPowerUp 开发。
- 徽章由 [shields.io](https://shields.io) 生成。

问题或建议请通过 GitHub Issues 提出。
