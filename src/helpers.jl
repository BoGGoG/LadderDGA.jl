#TODO: this should be a macro
@inline get_symm_f(f::Array{Complex{Float64},1}, i::Int64) = (i < 0) ? conj(f[-i]) : f[i+1]
@inline get_symm_f(f::Array{Complex{Float64},2}, i::Int64) = (i < 0) ? conj(f[-i,:]) : f[i+1,:]
store_symm_f(f::Array{T, 1}, range::UnitRange{Int64}) where T <: Number = [get_symm_f(f,i) for i in range]
store_symm_f(f::Array{T, 2}, range::UnitRange{Int64}) where T <: Number = [get_symm_f(f,i) for i in range]

# This function exploits, that χ(ν, ω) = χ*(-ν, -ω) and a storage of χ with only positive fermionic frequencies
# TODO: For now a fixed order of axis is assumed


function default_sum_range(mid_index::Int, lim_tuple::Tuple{Int,Int}) where T
    return union((mid_index - lim_tuple[2]):(mid_index - lim_tuple[1]), (mid_index + lim_tuple[1]):(mid_index + lim_tuple[2]))
end


function reduce_range(range::AbstractArray, red_prct::Float64)
    sub = floor(Int, length(range)/2 * red_prct)
    lst = maximum([last(range)-sub, ceil(Int,length(range)/2 + iseven(length(range)))])
    fst = minimum([first(range)+sub, ceil(Int,length(range)/2)])
    return fst:lst
end


split_n(str, n) = [str[(i-n+1):(i)] for i in n:n:length(str)]
split_n(str, n, len) = [str[(i-n+1):(i)] for i in n:n:len]

"""
    print 4 digits of the real part of `x`
"""
printr_s(x::Complex{Float64}) = round(real(x), digits=4)
printr_s(x::Float64) = round(x, digits=4)


function setup_LDGA(kGrid::ReducedKGrid, freqList::AbstractArray, mP::ModelParameters, sP::SimulationParameters, env::EnvironmentVars)
    fft_range = -(2*sP.n_iν+2*sP.n_iω):(2*sP.n_iν+2*sP.n_iω)
    in_file = env.inputVars
    if(myid() == 1)
        if env.inputDataType == "text"
            convert_from_fortran(sP, env, false)
            if env.loadAsymptotics
                readEDAsymptotics(env, mP)
            end
        elseif env.inputDataType == "parquet"
            convert_from_fortran_pq(sP, env)
            if env.loadAsymptotics
                readEDAsymptotics_parquet(env)
            end
        elseif env.inputDataType == "jld2"
            if env.loadAsymptotics
                readEDAsymptotics_julia(env)
            end
            in_file = env.inputDir*"/"*env.inputVars
        end
        f = load(in_file)
        Γch = f["Γch"]
        Γsp = f["Γsp"]
        χDMFTch = f["χDMFTch"]
        χDMFTsp = f["χDMFTsp"]
        gImp_in, Σ_loc = if haskey(f, "g0")
            gImp_in = copy(f["gImp"])
            g0 = copy(f["g0"])
            Σ_loc = Σ_Dyson(g0, gImp_in)
            gImp_in, Σ_loc
        else
            gImp_in = copy(f["gImp"])
            Σ_loc = copy(f["SigmaLoc"])
            gImp_in, Σ_loc
        end
        FUpDo_in = FUpDo_from_χDMFT(0.5 .* (χDMFTch - χDMFTsp), gImp_in, freqList, mP, sP)
        gImp_sym = store_symm_f(gImp_in, fft_range)
        gImp = reshape(gImp_sym, (length(gImp_sym),1))
        gLoc = G_from_Σ(Σ_loc, expandKArr(kGrid, kGrid.ϵkGrid)[:], fft_range, mP);
        gLoc_fft_in = flatten_2D(map(x->fft(reshape(x, gridshape(kGrid)...)), gLoc))
        gLoc_out = G_from_Σ(Σ_loc, kGrid.ϵkGrid, fft_range, mP);
        gLoc = flatten_2D(gLoc_out)
    end
    FUpDo = SharedArray{Complex{Float64},3}(size(FUpDo_in),pids=procs());copy!(FUpDo, FUpDo_in)
    gImp = OffsetArray(gImp, fft_range, :) 
    gLoc = OffsetArray(gLoc, fft_range, :) 
    gLoc_fft = OffsetArray(gLoc_fft_in, fft_range, :) 
    χDMFTch_new = SharedArray{Complex{Float64},3}(size(χDMFTch),pids=procs());copy!(χDMFTch_new, χDMFTch)
    χDMFTsp_new = SharedArray{Complex{Float64},3}(size(χDMFTsp),pids=procs());copy!(χDMFTsp_new, χDMFTsp)
    Γch_new = SharedArray{Complex{Float64},3}(size(Γch),pids=procs());copy!(Γch_new, Γch)
    Γsp_new = SharedArray{Complex{Float64},3}(size(Γsp),pids=procs());copy!(Γsp_new, Γsp)
    if env.loadAsymptotics
        asympt_vars = load(env.asymptVars)
        χchAsympt = asympt_vars["chi_ch_asympt"]
        χspAsympt = asympt_vars["chi_sp_asympt"]
    end
    #TODO: unify checks
    (sP.ωsum_type == :full && (sP.tc_type_b != :nothing)) && @warn "Full Sums combined with tail correction will probably yield wrong results due to border effects."
    (!sP.dbg_full_eom_omega && (sP.tc_type_b == :nothing)) && @warn "Having no tail correction activated usually requires full omega sums in EoM for error compansation. Add full_EoM_omega = true under [Debug] to your config.toml"
    sP.ωsum_type == :individual && println(stderr, "Individual ranges not tested yet")
    ((sP.n_iν < 30 || sP.n_iω < 15) && (sP.tc_type_f != :nothing)) && @warn "Improved sums usually require at least 30 positive fermionic frequencies"


    #TODO: this should no assume consecutive frequencies
    #νGrid = [(i,j) for i in 1:(2*sP.n_iω+1) for j in (1:2*sP.n_iν) .- trunc(Int64,sP.shift*(i-sP.n_iω-1)/2)]
    νGrid = Array{AbstractArray}(undef, 2*sP.n_iω+1);
    for i in 1:length(νGrid)
        νGrid[i] = (1:2*sP.n_iν) .- trunc(Int64,sP.shift*(i-1-sP.n_iω)/2)
    end
    #TODO: fix this! do not assume anything about freqGrid without reading from file

    sh_f = get_sum_helper(2*sP.n_iν, sP, :f)

    χLocsp_ω = sum_freq(χDMFTsp, [2,3], sh_f, mP.β)[:,1,1]
    χLocch_ω = sum_freq(χDMFTch, [2,3], sh_f, mP.β)[:,1,1]
    ωZero = sP.n_iω
    χLocsp_ω_tmp = deepcopy(χLocsp_ω)
    χLocch_ω_tmp = deepcopy(χLocch_ω)


    if sP.ω_smoothing == :full
        filter_MA!(χLocsp_ω[1:ωZero],3,χLocsp_ω[1:ωZero])
        filter_MA!(χLocsp_ω[ωZero:end],3,χLocsp_ω[ωZero:end])
        filter_MA!(χLocch_ω[1:ωZero],3,χLocch_ω[1:ωZero])
        filter_MA!(χLocch_ω[ωZero:end],3,χLocch_ω[ωZero:end])
        χLocsp_ω_tmp = deepcopy(χLocsp_ω)
        χLocch_ω_tmp = deepcopy(χLocch_ω)
    elseif sP.ω_smoothing == :range
        χLocsp_ω_tmp[1:ωZero]   = filter_MA(3,χLocsp_ω[1:ωZero])
        χLocsp_ω_tmp[ωZero:end] = filter_MA(3,χLocsp_ω[ωZero:end])
        χLocch_ω_tmp[1:ωZero]   = filter_MA(3,χLocch_ω[1:ωZero])
        χLocch_ω_tmp[ωZero:end] = filter_MA(3,χLocch_ω[ωZero:end])
    end


    usable_loc_sp = find_usable_interval(real(χLocsp_ω_tmp), reduce_range_prct=sP.usable_prct_reduction)
    usable_loc_ch = find_usable_interval(real(χLocch_ω_tmp), reduce_range_prct=sP.usable_prct_reduction)
    #if sP.tc_type_f != :nothing
    #    usable_loc_sp = reduce_range(usable_loc_sp, 1.0)
    #    usable_loc_ch = reduce_range(usable_loc_ch, 1.0)
    #end
    loc_range = intersect(usable_loc_sp, usable_loc_ch)
    if sP.ωsum_type == :common
        @info "setting usable ranges of sp and ch channel from $usable_loc_sp and $usable_loc_ch to the same range of $loc_range"
        usable_loc_ch = loc_range
        usable_loc_sp = loc_range
    end


    sh_b_sp = get_sum_helper(usable_loc_sp, sP, :b)
    sh_b_ch = get_sum_helper(usable_loc_ch, sP, :b)

    χLocsp = sum_freq(χLocsp_ω[usable_loc_sp], [1], sh_b_sp, mP.β)[1]
    χLocch = sum_freq(χLocch_ω[usable_loc_ch], [1], sh_b_ch, mP.β)[1]

    impQ_sp = ImpurityQuantities(Γsp_new, χDMFTsp_new, χLocsp_ω, χLocsp, usable_loc_sp, [0,0,mP.Ekin_DMFT])
    impQ_ch = ImpurityQuantities(Γch_new, χDMFTch_new, χLocch_ω, χLocch, usable_loc_ch, [0,0,mP.Ekin_DMFT])

    χupup_ω = 0.5 * (χLocsp_ω + χLocch_ω)
    iωn = 1im .* 2 .* (-sP.n_iω:sP.n_iω)[loc_range] .* π ./ mP.β
    χupup_DMFT_ω_sub = subtract_tail(χupup_ω[loc_range], mP.Ekin_DMFT, iωn)

    sh_b = get_sum_helper(loc_range, sP, :b)
    imp_density_pure = real(sum_freq(χupup_DMFT_ω_sub, [1], Naive(), mP.β, corr=-mP.Ekin_DMFT*mP.β^2/12))
    imp_density = real(sum_freq(χupup_DMFT_ω_sub, [1], sh_b, mP.β, corr=-mP.Ekin_DMFT*mP.β^2/12))

    @info """Inputs Read. Starting Computation.
      Local susceptibilities with ranges are:
      χLoc_sp($(impQ_sp.usable_ω)) = $(printr_s(impQ_sp.χ_loc)), χLoc_ch($(impQ_ch.usable_ω)) = $(printr_s(impQ_ch.χ_loc)) 
      sum χupup check (fit, tail sub, tail sub + fit, expected): $(0.5 .* real(χLocsp + χLocch)) ?≈? $(imp_density_pure) ?=? $(imp_density) ?≈? $(mP.n/2 * ( 1 - mP.n/2))"
      """
    return νGrid, sh_f, impQ_sp, impQ_ch, gImp, gLoc, gLoc_fft, Σ_loc, FUpDo
end


function flatten_2D(arr)
    res = zeros(eltype(arr[1]),length(arr), length(arr[1]))
    for i in 1:length(arr)
        res[i,:] = arr[i][:]
    end
    return res
end

@inline function OneToIndex_to_Freq(ωi::Int, νi::Int, sP::SimulationParameters)
    ωn = ωi-sP.n_iω-1
    νn = (νi-sP.n_iν-1) - trunc(Int,sP.shift*(ωn/2))
    return ωn, νn
end

@inline ν0Index_of_ωIndex(ωi::Int, sP)::Int = sP.n_iν + sP.shift*(trunc(Int, (ωi - sP.n_iω - 1)/2)) + 1

# ================== Noise Filter ==================

function filter_MA(m::Int, X::AbstractArray{T,1}) where T <: Number
    res = deepcopy(X) 
    offset = trunc(Int,m/2)
    res[1+offset] = sum(@view X[1:m])/m
    for (ii,i) in enumerate((2+offset):(length(X)-offset))
        res[i] = res[i-1] + (X[m+ii] - X[ii])/m
    end
    return res
end

function filter_MA!(res::AbstractArray{T,1}, m::Int, X::AbstractArray{T,1}) where T <: Number 
    offset = trunc(Int,m/2)
    res[1+offset] = sum(@view X[1:m])/m
    for (ii,i) in enumerate((2+offset):(length(X)-offset))
        res[i] = res[i-1] + (X[m+ii] - X[ii])/m
    end
    return res
end

function filter_KZ(m::Int, k::Int, X::AbstractArray{T,1}) where T <: Number
    res = filter_MA(m, X)
    for ki in 2:k
        res = filter_MA!(res, m, res)
    end
    return res
end
