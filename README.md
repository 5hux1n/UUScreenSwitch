<p align="center">
  <img src="assets/icon.png" width="112" height="112" alt="UUScreenSwitch Icon" />
</p>

<h1 align="center">UU远控切屏 · UUScreenSwitch</h1>

<p align="center">
  把默认控制菜单里的展开全部窗口和显示桌面替换为直接切换显示器，适合双显示器用户。
</p>

---

## 功能简介

UU远程（`com.netease.uuremote`）默认的切换显示器功能位于「操作 → 显示 → 多显示屏管理」，需要三层菜单才能切换。本插件将远控底部默认控制栏中的：

- **展开所有窗口** → **显示器1**
- **显示桌面** → **显示器2**

在底部栏单击即可直接切换对应显示器，调用链路与官方「多显示屏管理」菜单完全一致（`ControlPanelViewModel.switchScreen(_:)`）。

## 环境与兼容性

- **适用应用**：UU远程 `4.42.0`（带版本及指令签名校验，其它版本不执行切屏调用以防错位崩溃）
- **系统要求**：iOS 15.0 及以上（不设上限）
- **架构支持**：`arm64`（Rootless）+ `arm64e`（RootHide），零 `CydiaSubstrate` 依赖

## 安装方式

### 1. APT 越狱源安装（推荐）

在 Sileo / Zebra 中添加源：

```text
https://apt.mjh.im/
```

搜索 **UU远控切屏** 安装对应环境版本（Rootless / RootHide）。

### 2. 手动安装 DEB

从 [Releases](https://github.com/5hux1n/UUScreenSwitch/releases) 下载对应架构安装包：

- Rootless（Dopamine / palera1n）：`UUScreenSwitch_1.0.0_arm64.deb`
- RootHide：`UUScreenSwitch_1.0.0_arm64e.deb`

## 构建

```bash
./scripts/build.sh
```

输出产物位于 `dist/`：
- `dist/UUScreenSwitch_1.0.0_arm64.deb`
- `dist/UUScreenSwitch_1.0.0_arm64e.deb`

## 许可证

MIT © junhong
