# 运行与验收

## 本机运行

1. 安装 Godot 4.7.x（本交付已使用 4.7.2 stable 验证）。
2. 解压整个项目文件夹，在项目管理器“导入”选 `project.godot`。
3. F5 启动；不需要插件、联网账号、麦克风权限或外部美术资源。
4. 选择 2–8 人、每轮时长、揭晓模式，再点开始。配置只在新局生效。
5. 在“玩家视角”切换每位本地玩家，点击合作/背叛；或勾选自动演示快速跑完整局。

场景和主题均可在 Godot 编辑器中修改：`demo/main.tscn`、`demo/debug_theme.tres`。根节点 Inspector 可设置默认人数、时长、收益矩阵和刷新节奏。界面是调试工具；不能当作真实网络客户端或语音权限隔离。

## 自动测试

在项目目录运行（把 godot 换成实际 Godot 4.7.2 可执行文件）：

```sh
godot --headless --path . --script res://tests/run_tests.gd
godot --headless --path . --script res://tests/run_ui_tests.gd
```

退出码 0 且输出 `RESULT: … checks, 0 failures` 表示核心测试通过；失败退出码非 0。不要只检查进程退出码而忽略 Godot 脚本编译错误。

在受限云环境，可将缓存和用户目录设到可写位置：

```sh
mkdir -p /tmp/psychological-home /tmp/psychological-xdg/{data,config,cache}
export HOME=/tmp/psychological-home
export XDG_DATA_HOME=/tmp/psychological-xdg/data
export XDG_CONFIG_HOME=/tmp/psychological-xdg/config
export XDG_CACHE_HOME=/tmp/psychological-xdg/cache
godot --headless --path . --editor --quit
godot --headless --path . --script res://tests/run_tests.gd
godot --headless --path . --quit-after 120
```

测试涵盖排程 2–8 人、每对一次、奇数轮空、两种揭晓隐私、深复制隔离、四种收益、总分排名、重复/过期/非法请求、精确截止时刻、断线与重连、路由序列、失败/超时/重试、取消与重开及旧确认、同步确认重入。详见测试文件与实际终端输出。

## 手动验收清单

- 4 人默认模式：一人提交后对手视角不能看到选择；本对完成后仍隐藏结果；其他对继续计时；三轮后显示所有六对结果和排行榜。
- 3 人立即揭晓：每轮一人轮空且不能选择；已完成对的结果只在双方视角出现；共三轮三对。
- 2 人，时限 1 秒，不提交：终局两人均背叛，各得 1 分，原因显示超时。
- 勾选“下一次路由失败”，再开始或完成配对：显示暂停，不能继续选；点击重试恢复。模拟失败不证明真实供应商音频停止。
- 游戏中取消：所有模拟路由关闭，状态取消，未揭晓结果不外泄；重开从新局第一轮计分，不接受旧局消息。
- 运行中改配置，仅下一次重开应用；当前局时长、名单和规则保持不变。

## 尚未验证 / 未实现

不包含真实语音 SDK、真实网络传输、多人跨设备认证、音频串线安全渗透测试、断线供应商回收、移动端/主机导出或统一 3D 派对框架接线。后续集成必须测试真实后端乱序命令的隔离和关闭确认语义，不能把本地 mock 测试等同于线上保密保证。

## 本次交付的实际验证（2026-10-11）

- 引擎：Godot 4.7.2 stable official（ed1daf0bf）。
- 权威规则/适配器测试：1,861 checks，0 failures。
- UI 交互测试：29 passed，0 failed。
- 编辑器 headless 导入与主场景启动烟雾测试：无脚本/资源错误。
- 实际 GUI：4 人 120 秒即时揭晓模式，验证提交前隐藏、双方完成后 0/5 揭晓、已完成对语音路由关闭、其他对视角不可见该结果；自动完成三轮并显示排名。
- 实际 GUI：2 人 1 秒不提交，双方默认背叛，各 1 分并列第一，标注超时默认。
- 云 GUI 日志仅有环境无声卡/VSync 警告，无脚本异常。本项目无真实音频输入/输出逻辑。
- 后续终局计时文字修正已由自动化 UI 断言复核。
