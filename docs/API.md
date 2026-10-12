# 派对框架接入 API

## 信任边界

`Session` 和完整状态只放在权威主机/服务端。生产环境绝不能把 Session 对象、私有成员、完整结果日志或其他玩家的 `private_snapshot` 发给客户端。客户端只拿公开快照以及服务器按已认证连接选择的自身私有快照。demo 的视角切换是本地测试权限，不能直接作为线上权限模型。

HostAdapter 中 `submit_choice(player_id,...)` / `private_snapshot(player_id)` 是受信主机或 demo API。线上客户端不能自行指定玩家 ID；应通过传输层真实发送者调用 `submit_from_peer` / `snapshot_for_peer`。`bind_authenticated_peer` 仅可由认证过的大厅服务调用，客户端无权绑定。此示例不实现 ENet、WebRTC、RPC 或第三方语音 SDK，也不宣称联网就绪。

## 创建与驱动

```gdscript
const HostAdapter = preload("res://adapters/host_adapter.gd")
var host = HostAdapter.new()
add_child(host)
host.start_game([
    {"id": "alice", "name": "Alice"},
    {"id": "bob", "name": "Bob"}
], {"duration_seconds": 30.0, "reveal_mode": "game_end"})
```

`start_game(players:Array, config:Dictionary={}) -> Dictionary`：先验证再修改，2–8 个非空唯一字符串 ID。失败 `{ok:false,error:code}` 不破坏现有局；成功新建 run_id，先关闭所有旧路由。配置复制冻结：`duration_seconds, reveal_mode, reward, temptation, punishment, sucker`。名次采用竞赛排名，例如 1、1、3。

HostAdapter `_process` 以 `Time.get_ticks_usec()` 单调时间驱动 Session；提交前再次更新时间，避免帧间过期请求被误接收。Session 本身不取系统时间，`advance(delta)` 由权威环境串行驱动，方便确定性测试。所有方法和路由确认应回主线程执行；不要从音频工作线程同时修改 Session。客户端传来的时间或倒计时不可信。

`submit_choice(player_id, run_id, round_index, choice)`：choice 为 `cooperate` / `defect`，round_index 从 0 开始。只有当前局、当前轮、在线、非轮空、未锁定的参与者可提交。到期同一瞬间按权威处理顺序执行：HostAdapter 先推进到当前时刻，再尝试提交，因此截止时刻及以后自动背叛优先。重复请求返回错误，不重复计分。

`set_connected(player_id, bool)`：断线不改变现有选择也不提前代选。重连后未过期且未提交可继续；已锁定仍不可改。局中不可换人、增人或改矩阵，名单变更请重新开局。`unbind_peer(peer_id)` 会标记对应玩家离线；重新认证连接后，大厅须先 `bind_authenticated_peer(new_peer_id, player_id)`，再 `set_connected(player_id, true)`。绑定映射本身不自动认定玩家在线，避免未完成重连准备时提前接收选择。

`cancel_game()`：递增 run_id，废弃旧请求，等待 close_all 成功后 cancelled；不会公布未揭晓的结果。`retry_voice()` 仅在 route_error 可调用。重启可调用 `start_game`，同样强制 close_all 屏障。

## 快照

`public_snapshot()` 返回独立深复制：

- `run_id, phase, round_index, round_count, remaining_seconds`
- `players: [{id,name}]`
- `pairs: [{id,a,b,complete}], bye`（空字符串表示无人轮空）
- `results, leaderboard`：仅 phase=finished 非空
- `error`：路由故障码

`private_snapshot(player_id)` 在公开快照之上增加 `self_choice`、`opponent_id`、`can_submit`、`connected`。未知 ID 直接错误。`pair_complete` 模式中 `results` 仅包含自己参与且双方完成的配对（含既往轮）；`game_end` 模式只在终局揭晓。自己选择跨轮清空，但获准查看的既往结果仍保留。故障/取消也不会扩大授权。

结果：`{round_index,pair_id,a,b,choice_a,choice_b,reason_a,reason_b,score_a,score_b}`。原因 `submitted` / `timeout` / `disconnected_timeout`。排行榜：`{player_id,name,score,rank}`。公开 `complete` 只说明双方已完成，不能推断具体选项；不会发布某一人的提交状态。

## 语音路由协议

Session `voice_requested(command)`：

```text
{id:int, run_id:int, action:String, pairs:Array, pair_id:String}
```

- `close_all`：撤销本小游戏的所有旧房间/订阅/发送权限。只有供应商确实关闭且不可再传音才成功确认。必须覆盖旧 run 的遗留路由。
- `open_pairs`：只允许 `pairs` 列表中的两人相互收听/发送；禁止轮空、观众、其他对、默认全局频道。开启成功后计时开始。
- `close_pair`：关闭 pair_id 对应双向语音；与其他未完成配对的路由隔离。

回调 `session.acknowledge_voice(id, run_id, success, message="")`。操作 ID 全进程单调增长，每次重试使用新 ID；旧局、旧操作和重复确认均拒绝。后端也必须以 run_id/操作序列 fencing 保证晚到的旧 open 命令不能复活旧路由；仅忽略旧 ACK 不足以取消后端真实操作。

协议一次仅一个待确认操作。每对完成发起 close_pair，全部结束后 close_all，获确认才 open_pairs。任意失败或 5 秒无确认进入 route_error，停止提交和倒计时、不打开新配对，保留失败操作供重试。已成功关闭的配对不受影响。重试必须幂等，供应商宜提供强制静音/撤权兜底；若关闭未确认，应向玩家显示音频状态未知并保持暂停，不要宣称语音已安全隔离。更换或取消游戏仍须调用 cancel/close_all，而不是只销毁 UI。

HostAdapter 默认使用 MockVoice。无需修改其源码即可接入外部后端：开始前调用 `configure_voice_backend(false)`，连接 `voice_command_requested(command)`，供应商完成后回调 `host.acknowledge_voice(id,run_id,success,message)`。只允许 idle/cancelled/finished 阶段更换后端；活跃游戏必须先取消并等旧后端关闭。外部信号未接入会在 5 秒后进入 route_error，不会默默回退 mock。真实实现要做异步确认、认证通话权限、失败提示、断线回收、旧命令取消/隔离，不能靠客户端 UI 隐藏实现隐私。

## 3D 框架最小接入

大厅提供固定名单与配置 → 服务端 start_game → 框架根据公开配对安排座位/3D 表现 → 客户端依私有快照展示按钮 → 认证后的提交 → 收到 finished 提取全局结果/排行榜并回派对框架。`state_changed` 仅为主机内部“重新取快照”通知；不要广播整个 Session。建议服务端按目标 peer 单独推送私有快照，并对提交消息限流。
