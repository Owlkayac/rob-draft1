--!strict
-- クライアント(プレイヤーの端末)側の起動スクリプト。
-- 画面表示や操作の受け付けだけを行い、結果の判定はサーバーに任せる。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

print(`[{Config.GameName}] クライアント起動`)

-- 起動する部品の名前(Controllers フォルダの中の ModuleScript)。この順番で起動を始める
local CONTROLLER_NAMES = {
	"DiveController",
	"JetController",
	"MenuController", -- スタートメニュー(仕様書 015)
	"GuiController",
	"LightingController",
	"RiceSwayController",
	"CrayfishAnimator",
	"SoundController",
	"EnemyPresenceController",
}

local controllersFolder = script.Parent:WaitForChild("Controllers")

-- 部品を1つ起動する。読み込みや Start() でエラーが出ても、警告を出すだけで、ほかの部品は止めない
local function startController(name: string)
	local ok, err = pcall(function()
		local moduleScript = controllersFolder:WaitForChild(name) :: ModuleScript
		local controller = require(moduleScript) :: any
		controller.Start()
	end)
	if not ok then
		warn(`[Main] {name} の起動に失敗しました: {err}`)
	end
end

-- task.spawn で別々に起動する。1つが待ち(WaitForChild など)で止まっても、ほかの部品は起動する
for _, name in CONTROLLER_NAMES do
	task.spawn(startController, name)
end
