# AutoBangumi Synology SPK

自动监控并使用群晖官方工具链交叉构建 [AutoBangumi](https://github.com/EstrellaXD/Auto_Bangumi) 的 DSM 7 套件。

[![构建状态](https://github.com/tbc0309/autobangumi-spk/actions/workflows/build.yml/badge.svg)](https://github.com/tbc0309/autobangumi-spk/actions/workflows/build.yml)
[![许可证](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## 构建说明

- 使用 AutoBangumi 官方发布的 `app-v*.zip`、`pyproject.toml` 和 `uv.lock`。
- 使用 Python 3.14；安装套件前需先安装群晖 Python 3.14 套件。
- 主线使用 SynoCommunity `spksrc` 与群晖官方 DSM 7.1 工具链，交叉编译 DSM 无法直接安装的原生 Python 依赖。
- 交叉编译在 x86_64 GitHub 托管节点完成，完整 SPK 分别在 x86_64、armv8 原生节点组装，产物支持 DSM 7.1 及以上版本。
- `package.tgz` 使用 XZ 压缩，`INFO` 中的 `checksum` 为 `package.tgz` 的 MD5。
- 定时检查上游 Release；发现新版本后构建两个架构的 SPK，并在全部成功后发布正式 GitHub Release。

## GitHub Actions

- **AutoBangumi｜群晖交叉编译并发布（主线）**：默认构建及发布流程，支持定时检查和手动指定版本。
- **AutoBangumi｜Manylinux 构建（备用）**：仅供手动对比和故障排查，只保存 Action artifacts，不修改 Release。

在主线工作流中，`version` 留空时使用 AutoBangumi 官方最新 Release，也可以填写指定版本进行构建。

本项目只提供群晖套件构建脚本。AutoBangumi 本体的版权及许可证归上游项目所有。

## 许可证

本项目构建脚本使用 [MIT License](LICENSE)。
