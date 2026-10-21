<p align="center">
  <img src="assets/icon.png" width="108" height="108" alt="uu 远控增强" />
</p>

# uu 远控增强

UU 远程 iOS 客户端增强插件，支持 iOS 15.0 及以上。显示器快捷切换适用于多显示器电脑，组合键和圆环滚轮可用于日常远控。

## 功能

- 将远控底部控制栏的“展开全部窗口”和“显示桌面”替换为“显示器1”和“显示器2”，当前显示器以蓝色高亮。
- 切换显示器时记住缩放和定位，支持 App 从后台返回后继续使用。
- 电脑键盘增加六个常用组合键：Shift+Enter、全选、撤销、剪切、复制、粘贴。Mac 使用 ⌘，Windows 使用 Ctrl。
- 虚拟鼠标采用圆环滚轮，旋转即可滚动；慢转精细滚动，快转加速滚动。

## 安装

正式版本：**1.1.0**。包名：`uuhelper`（RootHide 为 `uuhelper.roothide`）。

| 环境 | 下载 |
|---|---|
| Rootless | [uuhelper_1.1.0_arm64.deb](https://github.com/5hux1n/UUScreenSwitch/releases/download/v1.1.0/uuhelper_1.1.0_arm64.deb) |
| RootHide | [uuhelper_1.1.0_arm64e.deb](https://github.com/5hux1n/UUScreenSwitch/releases/download/v1.1.0/uuhelper_1.1.0_arm64e.deb) |

也可通过插件源 [apt.mjh.im](https://apt.mjh.im/) 安装。安装完成后重新打开 UU 远程即可使用。本版沿用固定快捷功能，没有新增配置菜单。

功能适配基于 UU 远程 **4.42.0**。Mac 远控已由使用者实机确认，Windows 组合键映射尚待实机验证。

旧名称为 UU远控切屏，历史版本和下载链接保留。安装新版时包管理器会替换旧包。若已安装 `1.1.0+N` 测试版，正式版 `1.1.0` 在 Debian 版本排序中较低，需要在包管理器中明确选择替换为正式版。

## 1.1.0 更新

- 新增常用组合键，按被控电脑平台使用 Mac 或 Windows 修饰键。
- 新增圆环滚轮，支持旋转滚动与速度调节。
- 新增显示器缩放与定位记忆，支持切屏及后台返回后恢复视角。

## 反馈与支持

- [反馈问题](https://pingme.pm/uuhelper)
- [作者 Junhong](https://mjh.im/)
- [GitHub Release](https://github.com/5hux1n/UUScreenSwitch/releases)
