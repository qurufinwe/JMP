function iterate_qᵍ!(sd::SOEdef; verbose::Bool=false, tol = 1e-12, maxiter = 1500)
	""" Uses the government's repayment function to set the price of debt """
	dist, iter = 1+tol, 0
	init_t = time()

	gr, pars = sd.gr, sd.pars

	qᵍ_mat = reshape_long(sd, sd.eq[:qᵍ])
	rep_mat = reshape_long_shocks(sd, sd.gov[:repay])

	qᵍ = copy(qᵍ_mat)
	spread = zeros(size(qᵍ))
	
	Jgrid = agg_grid(sd)

	while dist > tol && iter < maxiter
		old_q  = copy(qᵍ)
		itp_qᵍ = make_itp(sd, qᵍ, agg=true)

		Threads.@threads for js in 1:size(Jgrid,1)
			jb, jμ, jσ, jξ, jζ, jz = Jgrid[js, :]

			ξv = sd.gr[:ξ][jξ]
			ζv, zv = sd.gr[:ζ][jζ], sd.gr[:z][jz]

			exp_rep = rep_mat[jb, jμ, jσ, jξ, jζ, jz, :, :]

			jdefault = (ζv == 0)

			bpv = sd.eq[:issuance][js]

			E_rep, check = 0.0, 0.0
			if jdefault == false
				for (jξp, ξpv) in enumerate(sd.gr[:ξ])
					coupon = pars[:κ] * (1 - ξpv)
					for (jzp, zpv) in enumerate(sd.gr[:z])
						prob = sd.prob[:z][jz, jzp] * sd.prob[:ξ][jξ, jξp]

						ζpv = 1.0
						μpv = sd.LoM[:μ][js, jξp, jzp][2]
						σpv = sd.LoM[:σ][js, jξp, jzp][2]
						E_rep += prob * (coupon + (1.0-pars[:ρ]) * itp_qᵍ(bpv, μpv, σpv, ξpv, ζpv, zpv)) * exp_rep[jξp, jzp]

						ζpv = 0.0
						μpv = sd.LoM[:μ][js, jξp, jzp][1]
						σpv = sd.LoM[:σ][js, jξp, jzp][1]
						E_rep += prob * (1.0-pars[:ℏ]) * (1.0-pars[:ρ]) * itp_qᵍ((1 - pars[:ℏ])*bpv, μpv, σpv, ξpv, ζpv, zpv) * (1.0-exp_rep[jξp, jzp])
						check += prob
					end
				end
			else
				for (jξp, ξpv) in enumerate(sd.gr[:ξ])
					coupon = pars[:κ] * (1 - ξpv)
					for (jzp, zpv) in enumerate(sd.gr[:z])
						prob = sd.prob[:z][jz, jzp] * sd.prob[:ξ][jξ, jξp]

						ζ_reent = 1.0
						μpv = sd.LoM[:μ][js, jξp, jzp][2]
						σpv = sd.LoM[:σ][js, jξp, jzp][2]
						E_rep += prob * (coupon + (1.0-pars[:ρ]) * itp_qᵍ(bpv, μpv, σpv, ξpv, ζ_reent, zpv)) * pars[:θ]
						check += prob * pars[:θ]

						ζ_cont = 0.0
						μpv = sd.LoM[:μ][js, jξp, jzp][1]
						σpv = sd.LoM[:σ][js, jξp, jzp][1]
						E_rep += prob * itp_qᵍ(bpv, μpv, σpv, ξpv, ζ_cont, zpv) * (1 - pars[:θ])
						check += prob * (1 - pars[:θ])
					end
				end
			end

			isapprox(check, 1) || print_save("WARNING: wrong transitions in update_qᵍ!")
			qst = E_rep / (1 + pars[:r_star])
			qᵍ[jb, jμ, jσ, jξ, jζ, jz] = qst

			coupon = pars[:κ] * (1 - ξv)
			spread[jb, jμ, jσ, jξ, jζ, jz] = 1.0 / qst - coupon / (pars[:r_star] + pars[:ρ])
		end
		iter += 1
		dist = sum( (qᵍ - old_q).^2 ) / sum(old_q.^2)
	end

	sd.eq[:qᵍ] = flatten(qᵍ)
	sd.eq[:spread] = flatten(spread)

	end_t = time()
	if dist <= tol
		if verbose
			print_save("Updated prices after $iter iterations in $(time_print(end_t-init_t))")
		end
	else
		print_save("WARNING: Iteration on qᵍ aborted at distance $(@sprintf("%.3g",dist)) after $(time_print(end_t-init_t))")
	end

	nothing
end

function compute_netexports(sd::SOEdef)
	itp_ϕc = make_itp(sd, sd.ϕ[:c]; agg=false)
	pars, gr = sd.pars, sd.gr
	Jgrid = agg_grid(sd)

	aggC_T = zeros(size(Jgrid, 1))
	supply_T = zeros(size(Jgrid, 1))
	for js in 1:size(Jgrid, 1)
		bv = gr[:b][Jgrid[js, 1]]
		μv = gr[:μ][Jgrid[js, 2]]
		σv = gr[:σ][Jgrid[js, 3]]
		ξv = gr[:ξ][Jgrid[js, 4]]
		ζv = gr[:ζ][Jgrid[js, 5]]
		zv = gr[:z][Jgrid[js, 6]]

		pNv = sd.eq[:pN][js]
		pC = price_index(sd, pNv)

		aggC = integrate_itp(sd, bv, μv, σv, ξv, ζv, zv, itp_ϕc)
		aggC_T[js] = aggC  * pars[:ϖ] * (1.0/pC)^(-pars[:η])

		wt = sd.eq[:wage][js]
		Ld_N, Ld_T  = labor_demand(sd, wt, zv, ζv, pNv)
		supply_T[js] = TFP_T(zv, pars[:Δ], ζv) * Ld_T^(pars[:α_N])
	end

	demand_G_T = sd.eq[:spending] * (1 - pars[:ϑ])
	NX = supply_T - aggC_T - demand_G_T

	return NX
end

function update_fiscalrules!(sd::SOEdef)
	eq, gr, pars = sd.eq, sd.gr, sd.pars
	Jgrid = agg_grid(sd)
	unemp = (1 .- eq[:Ld])*100
	unemp2= unemp.^2
	debt  = gr[:b][Jgrid[:, 1]]
	BoY   = debt ./ (4 * eq[:output]) * 100
	BoY2  = BoY.^2
	spread= eq[:spread] * 100 # measure in percent
	spr2  = spread.^2
	NX 	  = compute_netexports(sd)./(1 * eq[:output]) * 100
	NX2   = NX.^2

	# 1995-2017
	coef_g = [19.388883717621617, 0.7318621187420387, -0.01003959944577756, -0.3053882899089156, 0.0020388470724173624, -0.3413113896542817, -0.017556077299932617]
	coef_B = [1.9856075574374101, 0.39047177486146917, -0.002689902012952461, -0.08758992175493524, 0.000470228839455479, 0.2359018342143836, 0.021025051307723436]
	
	# 2000-2017
	# coef_g = [8.691002130724508,  1.2981918660138876, -0.026200973417119165, -0.09658749846191536,  0.000458067860023396, -0.15625547720262814,  0.04772567864518697]
	# coef_B = [-3.7139713360228805,  0.7275741192021965, -0.012592821100531077,  0.029271612946090327, -0.00048424943218523987,  0.4565495935872437,  0.06805551623006546]

	## LINEAR RULES
	# 1995 - 2017 linear
	# coef_g = [12.00811756014769, 0.33276619752273356, 0.0058208411240279374, -0.38319021373662154]
	# coef_B = [-0.6448062538289729, 0.2911404029799364, -0.0007066803638515664, 0.04988953023186958]

	# 2000 - 2017 linear
	# coef_g = [14.352347082060987, 0.33019070832467035, -0.02146673953213393, -0.16719444232628608]
	# coef_B = [1.027214446707925, 0.2855166552789347, -0.019868887012357048, 0.21211914925459147]

	# coef_g = [coef_g[1], coef_g[2], 0, coef_g[3], 0, coef_g[4], 0]
	# coef_B = [coef_B[1], coef_B[2], 0, coef_B[3], 0, coef_B[4], 0]

	# All Europe 2000 - 2017



	# coef_g = [20.6746151785, 0.0307028678, 0.0021122640, 0.0095750707, -0.0002004299, 0.0090837466, -0.0001310273]

	# coef_B = [1.0786829981, 0.3342813521, 0.0001223178, -0.0102040316, 0.0001494438, 0.0461321365, -0.00014158229 ]
	g = [ ones(size(unemp)) unemp unemp2 BoY BoY2 NX NX2 ] * coef_g / 100
	net_iss = [ ones(size(unemp)) unemp unemp2 BoY BoY2 NX NX2 ] * coef_B / 100

	eq[:spending] = max.(min.(vec(g), 0.35), 0) .* (1 * eq[:output])
	eq[:issuance] = min.(0.35,max.(0, vec(net_iss))) .* (4 * eq[:output]) + (1 - pars[:ρ])*debt

	def_states = gr[:ζ][Jgrid[:, 5]] .== 0
	eq[:issuance][def_states] = gr[:b][Jgrid[def_states, 1]]

	eq[:issuance] = max.(min.(eq[:issuance], maximum(gr[:b])-1e-6), minimum(gr[:b])+1e-6)

	nothing
end

function govt_bc(sd::SOEdef, wage_bill)
	"""
	Computes lump-sum taxes from the government's budget constraint.
	`wage_bill` here is w * Lᵈ
	"""
	qᵍ_vec = sd.eq[:qᵍ]
	Jgrid = agg_grid(sd)
	def_states = (sd.gr[:ζ][Jgrid[:, 5]] .== 0)

	B′ = sd.eq[:issuance]
	B  = sd.gr[:b][Jgrid[:, 1]]

	remaining_debt = (1 .- sd.pars[:ρ] * (1 .- def_states)) .* B

	coupons = (1 .- def_states) .* sd.pars[:κ] .* B
	g 		= sd.eq[:spending]
	inc_tax = sd.pars[:τ] * wage_bill
	net_iss = qᵍ_vec .* (B′ - remaining_debt)

	sd.eq[:T] = coupons + g - inc_tax - net_iss
	T_mat = reshape(sd.eq[:T], N(sd,:b), N(sd,:μ), N(sd,:σ), N(sd,:ξ), N(sd,:ζ), N(sd,:z))
	return T_mat
end

function _unpackstatefs(sd::SOEdef)
	eq, pars = sd.eq, sd.pars
	Jgrid = agg_grid(sd)

	wL = eq[:Ld] .* eq[:wage] .* (1 - pars[:τ])

	pC = price_index(sd, eq[:pN])

	taxes_mat = govt_bc(sd, eq[:wage] .* eq[:Ld])

	profits_mat = reshape( eq[:output] - eq[:wage] .* eq[:Ld], N(sd,:b), N(sd,:μ), N(sd,:σ), N(sd,:ξ), N(sd,:ζ), N(sd,:z))

	T_mat = taxes_mat# - profits_mat

	qʰ_mat = reshape(eq[:qʰ], N(sd,:b), N(sd,:μ), N(sd,:σ), N(sd,:ξ), N(sd,:ζ), N(sd,:z))
	qᵍ_mat = reshape(eq[:qᵍ], N(sd,:b), N(sd,:μ), N(sd,:σ), N(sd,:ξ), N(sd,:ζ), N(sd,:z))
	wL_mat = reshape(wL, 	  N(sd,:b), N(sd,:μ), N(sd,:σ), N(sd,:ξ), N(sd,:ζ), N(sd,:z))
	pC_mat = reshape(pC, 	  N(sd,:b), N(sd,:μ), N(sd,:σ), N(sd,:ξ), N(sd,:ζ), N(sd,:z))

	return qʰ_mat, qᵍ_mat, wL_mat, T_mat, pC_mat, profits_mat
end

