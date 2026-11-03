--!strict
-- ゲームの設定値(価格、時間、確率など)はここにまとめる。
-- コードの中に数字を直書きしない。

local Config = {
	GameName = "Untitled",

	-- ザリガニの操作(仕様書 001)。数字は仮の初期値で、遊びながら調整する。
	CrayfishWalkSpeed = 16, -- 歩く速さ
	DiveMaxSeconds = 3, -- 連続で潜れる最大の時間(秒)
	DiveCooldownSeconds = 5, -- 浮上してから、次に潜れるまでの時間(秒)
	DiveRequestMinInterval = 0.2, -- 潜る操作の受け付け間隔の最小値(秒)。連打対策

	DiveRemoteName = "DiveRequest", -- 潜る/やめるのお願いを送る RemoteEvent の名前
	DiveTransparency = 0.6, -- 潜っている間の透明度(0=見える、1=完全に透明)
	CrayfishColor = Color3.fromRGB(200, 40, 30), -- ザリガニの仮の色(赤)
}

return Config
