using QuantEcon, BasisMatrices, Interpolations, Optim, LaTeXStrings, Distributions, JLD, HCubature, Distributed, Dates, ForwardDiff, Printf, Random, LinearAlgebra, DataFrames, GLM, PlotlyJS, ColorSchemes
using ORCA, JSON

include("type_def.jl")
include("handle_guesses.jl")
include("handle_itps.jl")
include("fiscal.jl")
include("hh_pb.jl")
include("comp_eqm.jl")
include("gov_pol.jl")
include("reporting_routines.jl")
include("simul.jl")

# print("mpe_iter!(sd)")
params_center = Dict(
	:r_loc	=> 0.09,
	:γ		=> 12.0,
	:τ		=> 0.2,
	:wbar	=> 0.897,
	:ρz		=> 0.97,
	:σz		=> 0.0026,
	:meanξ	=> 0.01,
	:ρξ		=> 0.95,
	:σξ		=> 0.0025,
)

function wrapper_run(par_vec, nodef, noΔ, rep_agent, L, gs; do_all::Bool=true)
	params = Dict(
		:r_loc	=> par_vec[1],
		:γ		=> par_vec[2],
		:τ		=> par_vec[3],
		:wbar	=> par_vec[4],
		:ρz		=> par_vec[5],
		:σz		=> par_vec[6],
		:meanξ	=> par_vec[7],
		:ρξ		=> par_vec[8],
		:σξ		=> par_vec[9],
	)

	time_init = time()
	
	if !do_all
		params[:ρξ] = 0.995
		params[:σξ] = 0.002
		params[:τ]  = 0.092
		params[:ρz] = 0.970
	end
	push!(L, length(L)+1)
	run_number = L[end]
	savedir = pwd() * "/../Output/run$(run_number)/"

	s = read("../Output/big_output.txt", String)
	write("../Output/big_output.txt", s * "run number : $(run_number). ")

	# Initialize output file
	write("../Output/output.txt", "\nAggregate Demand and Sovereign Debt Crises\n")

	print_save("\nStarting run number $(run_number) on $(nprocs()) cores and $(Threads.nthreads()) threads at $(Dates.format(now(),"HH:MM")) on $(Dates.monthname(now())) $(Dates.day(now()))")


	sd = make_guess(nodef, noΔ, rep_agent, params, run_number);

	already_done = false
	try
		params = load(pwd() * "/../Output/run$(run_number)/params.jld", "params")
		print_save("\nFound params file for run $(run_number).")
		if params == pars(sd)
			print_save(" Parameters correct. Looking for g value.")
			try
				g = load(pwd() * "/../Output/run$(run_number)/g.jld", "g")
				print_save(" Found g.")
				print_save("\ng = $(g)")
				print_save("\nLooking for path")
				path = load("../Output/run$(run_number)/p_bench.jld", "pp")
				print_save(": ✓")
				already_done = true
			catch
				print_save(" Couldn't find g.")
			end
		else
			print_save(" Found different parameters, rewriting.")
		end
	catch
		print_save("\nNo previous file found.")
	end

	if !already_done
		run(`rm $savedir -rf`)
		run(`mkdir -p $savedir`)

		save(savedir * "params.jld", "params", params)
		params_table = make_params_table(sd)
		write(savedir * "params_table.txt", params_table)

		mpe_iter!(sd; nodef = nodef, noΔ = noΔ, rep_agent = rep_agent, run_number=run_number, save_copies=true)
		# plot_hh_policies(h, run_number=run_number)
		# plot_contour_debtprice(h, savedir)
		# plot_contour_unemp(h, savedir)
		
		years = 10000
		g, p_bench, πthres, v_m, def_freq = make_simulated_path(sd, savedir, years)
		save(savedir * "g.jld", "g", g)
		run(`cp ../Output/SOEdef.jld ../Output/run$(run_number)/SOEdef.jld`)
	else
		p_bench = load("../Output/run$(run_number)/p_bench.jld", "pp")
		v_m = simul_stats(p_bench)
		ζ_vec = series(p_bench,:ζ)
		Ndefs = sum([ (ζ_vec[jj] == 0) & (ζ_vec[jj-1] == 1) for jj in 2:length(ζ_vec)])
		years = floor(Int64,periods(p_bench)*0.25)
		def_freq = Ndefs / years
		# _, πthres = plot_episodes(p_bench; episode_type="onlyspread", slides=true, πthres=0.95)
	end

	s = read("../Output/big_output.txt", String)
	s *= "g = $(@sprintf("%0.3g",g)) in $(time_print(time()-time_init))"
	push!(gs, g)
	if g == minimum(gs)
		print_save("Minimum g for now. Computing no-def comparison")
		s *= " ✓"

		v_noΔ, v_nodef, v_nob, freq_noΔ, freq_nodef, freq_nob = make_comparison_simul(sd, noΔ, rep_agent, run_number, years, p_bench, "onlyspread", πthres, savedir)

		calib_table_comp = make_calib_table_comp([v_m; 100*def_freq], [v_nodef; 100*freq_nodef], [v_noΔ; 100*freq_noΔ], [v_nob; 100*freq_nob])
		write(savedir * "calib_table_comp.txt", calib_table_comp)
	else
		print_save("Suboptimal g. Skipping computation of no-def")
	end

	if !already_done
		run(`cp ../Output/run$(run_number)/hank.jld ../Output/hank.jld`)
		run(`cp ../Output/output.txt ../Output/run$(run_number)/output.txt`)
	end

	s *= "\n"
	write("../Output/big_output.txt", s)


	# s = read("../Output/output.txt", String)
	# write(savedir * "output.txt", s)

	params = pars(h)
	save(savedir * "params.jld", "params", params)
	
	return g
end

function SMM(p_dict; do_all::Bool=true)
	write("../Output/big_output.txt", "")
	params_center = [p_dict[:r_loc], p_dict[:γ], p_dict[:τ], p_dict[:wbar], p_dict[:ρz], p_dict[:σz], p_dict[:meanξ], p_dict[:ρξ], p_dict[:σξ]]
	#				 
	# params_center = [0.094; 0.02 ; 12.032; 0.092; 0.970; 0.005; 0.995; 0.002; 0.91]
	if do_all
		mins = 	      [0.05 ; 5   ; 0.05 ; 0.82 ; 0.85 ; 0.0001; 0.0001; 0.92 ; 1e-8 ]
		maxs = 		  [0.15 ; 20  ; 0.35 ; 1.00 ; 0.99 ; 0.012 ; 0.05  ; 0.999; 0.003]
	else
		mins = 	      [0.05 ; 5   ;      ; 0.82 ;      ; 0.0001; 0.0001;      ;      ]
		maxs = 		  [0.15 ; 20  ;      ; 1.00 ;      ; 0.012 ; 0.05  ;      ;      ]
		params_center = [p_dict[:r_loc], p_dict[:γ], p_dict[:wbar], p_dict[:σz], p_dict[:meanξ]]
	end

	L = Vector{Int64}(undef, 0)
	gs = Vector{Float64}(undef, 0)
	# inner_opt = LBFGS(;linesearch=LineSearches.HagerZhang(linesearchmax=200))
	nlprecon = GradientDescent(alphaguess=Optim.LineSearches.InitialStatic(alpha=1e-4,scaled=true),
                           linesearch=Optim.LineSearches.Static())
	inner_opt = OACCEL(nlprecon=nlprecon, wmax=10)

	inner_opt = NelderMead()
	res = Optim.optimize(
		params -> wrapper_run(params, false, false, false, L, gs, do_all=do_all)
		# , params_center
		, mins, maxs, params_center, Fminbox(inner_opt)
		)

	print("$(res)")
	s = read("../Output/big_output.txt", String)
	write("../Output/big_output.txt", s * "$(res)\n")

	nothing
end

SMM(params_center, do_all=true)
