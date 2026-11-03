--!strict
-- 天敵まわりで共有する「型」(データの形の約束)をまとめた部品。
-- 型は、「この表には、こういう名前で、こういう種類の値が入る」という約束。
-- この部品は型だけで、処理は入っていない。ほかの部品はここを読み込むだけで、ここは何も読み込まない
-- (循環 require を防ぐため)。

-- 数字の表。名前(文字)→ 数字。
-- 数字の名前の例: WalkSpeed, ChaseSpeed, SightDistance, CatchDistance, CatchHiddenDistance,
-- PatrolArriveDistance, WaypointReachDistance, AgentRadius, AgentHeight, LoseSightSeconds, SearchSeconds,
-- Speed(稲刈り機の進む速さ)
export type StatTable = { [string]: number }

-- 見える相手1人ぶんの情報
export type Target = {
	Player: Player,
	Position: Vector3,
	Distance: number, -- 横方向(XZ)の距離
}

-- 経路探索の記憶(Movement が使う)
export type MoveState = {
	Waypoints: { PathWaypoint }, -- 経路の通過点
	WaypointIndex: number, -- 次に向かう通過点の番号
	LastPathAt: number, -- 最後に経路を作った時刻(os.clock)
	Generation: number, -- 世代番号。変わったら、古い経路計算の結果を捨てる
}

-- 行動(見回り・追跡・探す、など)。1つの行動は、この3つの関数を持つ
export type Behavior = {
	Enter: (ctx: Context) -> (), -- この行動に切り替わったとき、1回だけ呼ばれる
	Update: (ctx: Context, dt: number) -> string?, -- 毎回の判断で呼ばれる。次の行動の名前を返す(変えないなら nil)
	Exit: (ctx: Context) -> (), -- この行動をやめるとき、1回だけ呼ばれる
}

-- 補正(モディファイア)に渡される情報
export type ModifierInfo = {
	Definition: Definition, -- どの種類の天敵の数字か
	Player: Player?, -- 狙う相手(いなければ nil)
}

-- 補正の関数。「どの数字に何倍か」の表を返す(例: { SightDistance = 0.8 })。何もしないなら nil
export type ModifierFn = (info: ModifierInfo) -> StatTable?

-- 天敵の種類の定義(農家さん、サギ、...)。1種類につき1つ
export type Definition = {
	Name: string, -- 種類の名前
	Create: () -> Model, -- 見た目(モデル)を作る。Workspace にはまだ入れない(実際の倍率を BaseStats に反映するのもここ)
	GetFootY: (model: Model) -> number, -- 足元の高さ(ワールドのY)。モデルを囲む箱の底から求める
	PlaceAt: (model: Model, point: Vector3) -> (), -- point の横位置に置き、足元の高さを床の上に補正する
	OnPlaced: (model: Model) -> (), -- Workspace に入れた直後に呼ばれる(動きの計算をサーバーにする、など)
	BaseStats: StatTable, -- 基本の数字
	Behaviors: { [string]: Behavior }, -- 使う行動の一覧(名前 → 行動)
	InitialBehavior: string, -- 最初の行動の名前(捕まえたあとに戻る行動でもある)

	-- ここから下は「任意」。書かない天敵(農家さん)は、いままでどおりの動きになる
	IsActive: (() -> boolean)?, -- 「いま、出番か」。ない天敵は常に出番。出番でない間は、モデルを置かず、判断もしない
	CheckCatch: ((ctx: Context, player: Player, root: BasePart) -> boolean)?, -- 捕まえる判定を自分で決める。ない天敵は距離の判定(Perception)
	ResetOnCatch: boolean?, -- 捕まえたあと、最初の行動に戻すか。nil か true なら戻す。false なら、そのまま続ける(機械向け)
	FindBody: ((model: Model) -> (Humanoid?, BasePart?))?, -- 体の部品を探す。Humanoid を使わない天敵用(root が nil なら作成失敗)。ない天敵は人型を探す
	IsModelUsable: ((ctx: Context) -> boolean)?, -- モデルがまだ使えるか。Humanoid を使わない天敵用。ない天敵は人型の確認
	SkipScan: boolean?, -- true なら、毎回の「見回し」(Perception.Scan)をしない。見ない天敵向け
}

-- 天敵1体の「実行時の状態」(コンテキスト)。行動の関数に渡される
export type Context = {
	Definition: Definition,
	Model: Model,
	Humanoid: Humanoid?, -- 人型でない天敵(稲刈り機)では nil
	Root: BasePart, -- 位置の基準になる部品(人型なら HumanoidRootPart、そうでなければ PrimaryPart)
	SpawnPoint: Vector3, -- 出現した横位置(やり直しで戻す場所。高さは Definition.PlaceAt が決める)
	PatrolPoints: { Vector3 }, -- 見回り地点の一覧
	PatrolIndex: number, -- 次に向かう見回り地点の番号
	BehaviorName: string, -- いまの行動の名前
	SwitchCount: number, -- 行動を切り替えた回数(待っている間に切り替わったかの確認用)
	LastTickAt: number, -- 前回の判断の時刻(os.clock)
	Finished: boolean, -- 行動が「終わった」印。立てると、EnemyService が天敵を消す(稲刈り機が田んぼを出たとき)

	-- 今回の判断で見えたもの(Perception.Scan が毎回入れる)
	Target: Target?, -- いちばん近い「見える相手」
	AnyPlaying: boolean, -- 遊んでいる人が1人でもいるか

	-- 追跡・探すときの記憶
	ChasePlayer: Player?, -- 追っている相手
	LastSeenPosition: Vector3?, -- 最後に見えた位置
	LostSightSince: number?, -- 見えなくなった時刻(os.clock)
	SearchEndAt: number, -- 探し終わる時刻(os.clock)

	Move: MoveState,
}

return {}
