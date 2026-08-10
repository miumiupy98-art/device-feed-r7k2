# MiuRead Beta

MiuRead（觅阅 · 微信读书助手）是面向 KOReader 的非官方微信读书客户端。本仓库是 **Beta / Pre-release 通道**，用于公开测试尚未进入稳定版的功能与修复。

## 使用提醒

- Beta 版本可能存在功能回退、界面异常或性能问题；重要阅读数据请自行保留备份。
- 本仓库不包含用户账号、Cookie、下载书籍、阅读数据或设备日志。
- MiuRead 与 WeRead、Tencent、KOReader 及上游项目维护者均无官方隶属或背书关系。

## 安装与更新

1. 在 GitHub Releases 中选择最新的 `vX.Y.Z-beta.N` **Pre-release**。
2. 下载 `miuread-vX.Y.Z-beta.N-full.zip`。
3. 解压后将 `miuread.koplugin` 放入 KOReader 的插件目录，并重启 KOReader。
4. 已安装 Beta 版本可使用 MiuRead 内置更新功能继续升级。

从 `4.3.0-beta.27` 起，Beta 更新清单由 GitHub Actions 在发布时自动生成，不再通过每个版本修改仓库中的 `update-beta.json`。仓库根目录的 `update-beta.json` 只用于把旧版 Beta 用户引导到 `4.3.0-beta.27`，之后保持冻结。

## 版本与发布

- Beta tag：`vX.Y.Z-beta.N`
- Beta Release：GitHub **Pre-release**
- 版本记录：统一维护 [`CHANGELOG.md`](CHANGELOG.md)
- 创建 Beta tag 后，GitHub Actions 自动校验版本、打包、创建/更新 Pre-release，并更新固定 Beta 更新清单。

发布时，tag、`miuread.koplugin/miuread/config.lua` 和 `miuread.koplugin/_meta.lua` 中的版本必须一致，否则发布会停止。

## 开源与来源

MiuRead 起源于 `finlater/weread.koplugin` v0.1.1 的修改版本，随后进行了较大规模的重构、修改与扩展。上游来源与第三方归属见 `NOTICE` 和 `THIRD_PARTY_NOTICES`。

本项目按 **GNU Affero General Public License v3 only (AGPL-3.0-only)** 发布，完整条款见 `LICENSE`。
