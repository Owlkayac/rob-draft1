--!strict
-- クライアント(プレイヤーの端末)側の起動スクリプト。
-- 画面表示や操作の受け付けだけを行い、結果の判定はサーバーに任せる。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

print(`[{Config.GameName}] クライアント起動`)

local DiveController = require(script.Parent.Controllers.DiveController)

DiveController.Start()
