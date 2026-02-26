--!strict
--[[
	MathUtil.luau
	Centralized scaling math for stat stacking and RNG.

	Two core formulas are exposed:

	  HyperbolicScale  — for stats that should feel impactful at low stacks
	                     but must never exceed a hard ceiling (CritChance,
	                     CooldownReduction, DamageResistance, ProcChance).

	  LinearScale      — for stats where every stack should feel equally
	                     strong (RawDamage, MaxHP additive bonuses). Clamped
	                     to a hard cap so it still can't go infinite.

	──────────────────────────────────────────────────────────────────────────
	Stat → Formula mapping (definitive reference):

	  HYPERBOLIC (use HyperbolicScale):
	    CritChance         base=0.10  cap=0.90   (never 100% — miss chance preserved)
	    CooldownReduction  base=0.15  cap=0.75   (25% minimum CD always remains)
	    DamageResistance   base=0.08  cap=0.70   (enemies still deal 30% at infinite)
	    ProcChance         (per-proc) base=proc.Chance  cap=0.90

	  LINEAR (use LinearScale):
	    RawDamage          valuePerStack=item.Value  hardCap=determined per item
	    MaxHealth          valuePerStack=item.Value  hardCap=determined per item
	    WalkSpeed bonus    valuePerStack=item.Value  hardCap=capped by StatLib
	    AirJumps           valuePerStack=1           hardCap=5

	──────────────────────────────────────────────────────────────────────────
	Why NOT make damage hyperbolic?
	  Damage is the player's core power fantasy. Each SharpWhetstone should
	  feel equally satisfying. Hyperbolic diminishing returns on damage would
	  make stacking feel unrewarding. We use LinearScale with a high hard cap
	  instead so the growth stays satisfying while staying finite.

	Why NOT make HP hyperbolic?
	  HP is a linear survivability tradeoff. One RedMeatHook = +25 HP.
	  Two = +50 HP. Players count HP in their heads. Hyperbolic would make
	  the mental model confusing.
]]

local MathUtil = {}

--[[
	HyperbolicScale(n, baseValue, cap)

	Properties:
	  n=0  → 0
	  n=1  → exactly baseValue
	  n→∞  → approaches cap, NEVER reaches or exceeds it

	Formula:  (cap × base × n) / (cap + base × (n − 1))

	Derivation:
	  We want f(1) = base exactly (first stack always feels like the tooltip).
	  We want lim(n→∞) = cap (hard ceiling, guaranteed by algebra).
	  The only rational function of degree 1/1 satisfying both constraints
	  with f(0)=0 is the formula above.

	Table (CritChance: base=0.10, cap=0.90):
	  n=1  → 0.100  (10.0%)
	  n=3  → 0.225  (22.5%)
	  n=5  → 0.310  (31.0%)
	  n=10 → 0.474  (47.4%)
	  n=20 → 0.643  (64.3%)
	  n=50 → 0.822  (82.2%)
	  n=∞  → 0.900  (90.0%)  ← hard ceiling
]]
function MathUtil.HyperbolicScale(n: number, baseValue: number, cap: number): number
	if n <= 0 then
		return 0
	end
	if baseValue <= 0 then
		return 0
	end
	-- Safety: if base already ≥ cap, return cap immediately
	if baseValue >= cap then
		return cap
	end
	return (cap * baseValue * n) / (cap + baseValue * (n - 1))
end

--[[
	LinearScale(n, valuePerStack, hardCap)

	Simple additive stacking with a hard ceiling.
	Every stack contributes exactly valuePerStack, capped at hardCap.

	Use for stats where equal-per-stack growth is desirable
	(Damage multipliers, MaxHP, AirJumps).

	Table (SharpWhetstone: valuePerStack=0.10, hardCap=3.0):
	  n=1  → 0.10  (10% bonus)
	  n=5  → 0.50  (50% bonus)
	  n=10 → 1.00  (100% bonus)
	  n=30 → 3.00  (300% bonus — hard cap)
	  n=99 → 3.00  (still capped)
]]
function MathUtil.LinearScale(n: number, valuePerStack: number, hardCap: number): number
	return math.min(n * valuePerStack, hardCap)
end

return MathUtil
