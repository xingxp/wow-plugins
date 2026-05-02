# DK滚鼠标 插件交接

更新时间：2026-04-30

## 当前插件位置

游戏插件目录：

```text
/Volumes/DATA/blizzard/World of Warcraft/_classic_titan_/Interface/AddOns/DKGunShuBiao
```

当前文件：

```text
DKGunShuBiao.toc
DKGunShuBiao.lua
media/wheel-up.tga
media/wheel-down.tga
```

插件列表显示名：

```text
DK滚鼠标
```

斜杠命令：

```text
/dkm
/dkm debug
/dkm reset
/dkm size 96
/dkm show
/dkm hide
```

## 运行环境

- WoW 路径：`/Volumes/DATA/blizzard/World of Warcraft/_classic_titan_`
- 客户端：时光服/泰坦重铸，接口版本从本地插件观察为 `50503`
- WeakAuras：本地路径 `Interface/AddOns/WeakAuras`，版本 `5.21.6`
- UI 插件：用户当前有 NDui，动作条来自 NDui 的 `LibActionButton-1.0-NDui`

## 需求背景

最初用户想用 WeakAuras 镜像动作条按钮，尤其是鼠标上滚/下滚绑定的两个序列宏按钮：

- `MOUSEWHEELUP` 绑定到动作槽 `68`
- `MOUSEWHEELDOWN` 绑定到动作槽 `69`

WA 字符串能做固定槽位镜像，也能运行时拖动，但纯 WA 在“不改宏、不接管滚轮”的前提下无法稳定知道“刚刚触发的是上滚还是下滚”。诊断 WA 证明：普通 WA hook 不到用户实际按钮触发路径，按按钮和滚轮都没有变化。

因此改为独立插件方案。

## 当前插件功能

插件只监测绑定了鼠标键的动作按钮，并显示最后触发的鼠标动作按钮：

- 显示动作按钮当前图标。
- 显示动作按钮冷却。
- 显示物品/技能数量。
- 图标左上角显示动作槽编号。
- 只响应鼠标绑定按钮：
  - `MOUSEWHEELUP`
  - `MOUSEWHEELDOWN`
  - `BUTTON1` 到 `BUTTON5`
  - 也支持 `SHIFT-MOUSEWHEELUP` 这类带修饰键的绑定。
- 不响应普通键盘绑定按钮。
- 不接管鼠标滚轮，不覆盖绑定，不改宏。
- 支持 `Shift + 左键` 拖动显示框，位置按角色保存。
- 图标右侧显示 DK 符文能量竖条：
  - 仅 DK 角色显示。
  - 数值显示为 `当前/最大`，例如 `72/100`。
  - 监听 `UNIT_POWER_UPDATE`、`UNIT_POWER_FREQUENT`、`PLAYER_ENTERING_WORLD`。
- 上下滚方向标识：
  - 上滚显示 `media/wheel-up.tga`，绿色上三角，出现在图标上方。
  - 下滚显示 `media/wheel-down.tga`，蓝色下三角，出现在图标下方。
  - 三角形宽度跟图标宽度一致。

## 实现要点

主文件：`DKGunShuBiao.lua`

核心数据：

```lua
local hookedButtons = {}
local mouseBoundSlots = {}
local mouseBoundDirections = {}
```

按钮槽位读取：

```lua
button.action
button._state_action
button:GetAttribute("action")
button:GetAttribute("action1")
button:GetAttribute("labaction-0")
button:GetAttribute("labaction-1")
```

鼠标绑定判断：

```lua
GetBindingKey(target)
```

其中 `target` 会尝试：

```lua
button.keyBoundTarget
button.bindName
button.config.keyBoundTarget
button:GetName()
"CLICK " .. name .. ":Keybind"
"CLICK " .. name .. ":LeftButton"
```

方向判断：

```lua
MOUSEWHEELUP$   -> "UP"
MOUSEWHEELDOWN$ -> "DN"
```

hook 覆盖面：

- 暴雪动作条按钮：
  - `ActionButton1..12`
  - `MultiBarBottomLeftButton1..12`
  - `MultiBarBottomRightButton1..12`
  - `MultiBarRightButton1..12`
  - `MultiBarLeftButton1..12`
  - `BonusActionButton1..12`
- NDui 动作条：
  - `NDui_ActionBar1..8`
  - `NDui_ActionBarXButtonY`
  - `header.buttons`
- NDui LibActionButton：
  - `LibStub("LibActionButton-1.0-NDui", true)`
  - `RegisterCallback("OnButtonCreated")`
  - `RegisterCallback("OnButtonUpdate")`
  - `GetAllButtons()` 或 `buttonRegistry`
- 兜底：
  - `hooksecurefunc("UseAction")`
  - `hooksecurefunc("ActionButtonDown")`
  - `hooksecurefunc("ActionButtonUp")`

注意：`UseAction/ActionButtonDown/ActionButtonUp` 路径只在槽位已经被识别为鼠标绑定槽时才会更新显示。

## 已知坑和结论

1. 不要再用 WA 的 `SetOverrideBindingClick` 接管滚轮。
   - 在这个客户端里会抢到滚轮，但安全按钮没有可靠转发原动作。
   - 用户遇到过“滚轮被接管，动作不触发”。

2. 纯 WA 能读到绑定关系，但不能稳定读到当前触发方向。
   - `GetBindingAction("MOUSEWHEELUP")` 能知道上滚绑定到哪个动作槽。
   - 但这不等于 WA 知道刚才实际触发了上滚还是下滚。

3. 两个滚轮槽位都是序列宏时，不能用图标/CD变化反推方向。
   - 两个宏可能显示同一个技能或同一个 CD。
   - 所以必须拿到实际触发按钮或绑定键。

4. NDui 使用 `LibActionButton-1.0-NDui`。
   - 按钮里常见可读字段有 `_state_action`、`action`、`keyBoundTarget`、`bindName`。
   - NDui 会用 `SetOverrideBindingClick(frame, false, key, button:GetName(), "Keybind")` 把系统绑定转成按钮点击。

5. 插件目录用 ASCII 名字更稳。
   - 显示名可以是中文：`DK滚鼠标`。
   - 当前目录名是 `DKGunShuBiao`。

## 当前源码摘要

`DKGunShuBiao.toc`：

```text
## Interface: 50503
## Title: DK滚鼠标
## Notes: 显示 DK 鼠标滚轮动作图标、冷却和符文能量。
## Author: Codex
## Version: 0.1.0
## SavedVariablesPerCharacter: DKGunShuBiaoDB

DKGunShuBiao.lua
```

资源路径：

```lua
"Interface\\AddOns\\DKGunShuBiao\\media\\wheel-up.tga"
"Interface\\AddOns\\DKGunShuBiao\\media\\wheel-down.tga"
```

## 验证方式

每次修改后至少运行：

```bash
lua -e 'assert(loadfile("/Volumes/DATA/blizzard/World of Warcraft/_classic_titan_/Interface/AddOns/DKGunShuBiao/DKGunShuBiao.lua"))'
```

游戏内：

1. `/reload`
2. 插件列表确认启用 `DK滚鼠标`
3. 用鼠标上滚/下滚触发绑定按钮
4. 检查：
   - 图标是否变成对应动作槽图标
   - CD 是否正确
   - 上滚是否显示上方绿色三角
   - 下滚是否显示下方蓝色三角
   - DK 符文能量是否显示为 `当前/最大`

调试：

```text
/dkm debug
```

开启后会在聊天框输出被识别的槽位和来源。

## 后续可继续做的方向

- 符文能量低于阈值时变色。
- 给三角形加淡入淡出。
- 增加 `/dkm lock`，避免误拖。
- 增加只显示滚轮上/下，不显示其它鼠标侧键的配置。
- 增加战斗中自动显示、脱战自动隐藏。
- 把所有可调参数做成 SavedVariables：
  - 图标大小
  - 能量条宽度
  - 三角形高度
  - 是否显示槽位编号
  - 是否显示数量

