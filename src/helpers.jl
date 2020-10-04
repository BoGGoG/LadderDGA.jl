#TODO: this should be a macro
@inline get_symm_f(f::Array{Complex{Float64},1}, i::Int64) = (i < 0) ? conj(f[-i]) : f[i+1]
@inline get_symm_f(f::Array{Complex{Float64},2}, i::Int64) = (i < 0) ? conj(f[-i,:]) : f[i+1,:]
store_symm_f(f::Array{T, 1}, range::UnitRange{Int64}) where T <: Number = [get_symm_f(f,i) for i in range]
store_symm_f(f::Array{T, 2}, range::UnitRange{Int64}) where T <: Number = [get_symm_f(f,i) for i in range]

# This function exploits, that χ(ν, ω) = χ*(-ν, -ω) and a storage of χ with only positive fermionic frequencies
# TODO: For now a fixed order of axis is assumed

function convert_to_real(f; eps=10E-12)
    if maximum(imag.(f)) > eps
        throw(InexactError("Imaginary part too large for conversion!"))
    end
    return real.(f)
end

iω(n) = 1im*2*n*π/(modelParams.β);


split_n(str, n) = [str[(i-n+1):(i)] for i in n:n:length(str)]
split_n(str, n, len) = [str[(i-n+1):(i)] for i in n:n:len]

"""
    padlength(a,b)

computes the length of zero-padding required for convolution, using fft
This is the next larger or equally large number to max(a,b)
TODO: does only support padding for cube like arrays (i.e. all dimension have the same size).

# Examples
```
julia> padlength(1:5,1:14)
8
julia> padlength(1:4,1:13)
4
```
"""
padlength(a,b) = 2^floor(Int, log(2,size(a,1)+size(b,1)-1))


function fft_conv(a, b)
    zero_pad_length = padlength(a,b)
    PaddedView(0, collect(a), Tuple(repeat([pad(a,b)], ndims(a))))
end

"""
    print 4 digits of the real part of `x`
"""
printr_s(x::Complex{Float64}) = round(real(x), digits=4)
printr_s(x::Float64) = round(x, digits=4)


function setup_LDGA(configFile, loadFromBak)
    modelParams, simParams, env = readConfig(configFile)#
    if env.loadFortran == "text"
        convert_from_fortran(simParams, env, false)
        if env.loadAsymptotics
            readEDAsymptotics(env, modelParams)
        end
    elseif env.loadFortran == "parquet"
        convert_from_fortran_pq(simParams, env)
        if env.loadAsymptotics
            readEDAsymptotics_parquet(env)
        end
    end
    @info "loading from " env.inputVars
    vars    = load(env.inputVars) 
    G0      = vars["g0"]
    GImp    = vars["gImp"]
    Γch_tmp     = vars["GammaCharge"]
    Γsp_tmp     = vars["GammaSpin"]
    Γch = SharedArray{Complex{Float64},3}(size(Γch_tmp),pids=procs());copy!(Γch, Γch_tmp)
    Γsp = SharedArray{Complex{Float64},3}(size(Γsp_tmp),pids=procs());copy!(Γsp, Γsp_tmp)
    χDMFTch = vars["chiDMFTCharge"]
    χDMFTsp = vars["chiDMFTSpin"]
    @warn "TODO: check beta consistency, config <-> g0man, chi_dir <-> gamma dir"
    ωGrid   = (-simParams.n_iω):(simParams.n_iω)
    νGrid   = (-simParams.n_iν):(simParams.n_iν-1)
    if env.loadAsymptotics
        asympt_vars = load(env.asymptVars)
        χchAsympt = asympt_vars["chi_ch_asympt"]
        χspAsympt = asympt_vars["chi_sp_asympt"]
    end
    #TODO: unify checks
    (simParams.Nk % 2 != 0) && throw("For FFT, q and integration grids must be related in size!! 2*Nq-2 == Nk")
    (simParams.fullωRange_Σ && simParams.tail_corrected) && println(stderr, "Full Sums combined with tail correction will probably yield wrong results due to border effects.")

    Σ_loc = Σ_Dyson(G0, GImp)
    FUpDo = FUpDo_from_χDMFT(0.5 .* (χDMFTch - χDMFTsp), GImp, ωGrid, νGrid, νGrid, modelParams.β)

    χLocsp_ω = sum_freq(χDMFTsp, [2,3], simParams.tail_corrected, modelParams.β)[:,1,1]
    usable_loc_sp = simParams.fullLocSums ? (1:length(χLocsp_ω)) : find_usable_interval(real(χLocsp_ω))
    χLocsp = sum_freq(χLocsp_ω[usable_loc_sp], [1], simParams.tail_corrected, modelParams.β)[1]

    χLocch_ω = sum_freq(χDMFTch, [2,3], simParams.tail_corrected, modelParams.β)[:,1,1]
    usable_loc_ch = simParams.fullLocSums ? (1:length(χLocch_ω)) : find_usable_interval(real(χLocch_ω))
    χLocch = sum_freq(χLocch_ω[usable_loc_ch], [1], simParams.tail_corrected, modelParams.β)[1]

    impQ_sp = ImpurityQuantities(Γsp, χDMFTsp, χLocsp_ω, χLocsp, usable_loc_sp)
    impQ_ch = ImpurityQuantities(Γch, χDMFTch, χLocch_ω, χLocch, usable_loc_ch)

    return modelParams, simParams, env, impQ_sp, impQ_ch, GImp, Σ_loc, FUpDo
end


function flatten_2D(arr)
    res = zeros(eltype(arr[1]),length(arr), length(arr[1]))
    for i in 1:length(arr)
        res[i,:] = arr[i]
    end
    return res
end

function calc_E_Pot(Σ_ladder, ϵkGrid, mP::ModelParameters, sP::SimulationParameters; weights=nothing)
    νGrid = 0:simParams.n_iν-1
    Σ_hartree = mP.n * mP.U/2
    ϵkGrid_red = reduce_kGrid(cut_mirror(collect(ϵkGrid)))
    tail_corr_0 = 0.0
    tail_corr_inv_0 = mP.β * Σ_hartree/2
    tail_corr_1 = (mP.U^2 * 0.5 * mP.n * (1-0.5*mP.n) .+ Σ_hartree .* (ϵkGrid_red .+ Σ_hartree .- mP.μ))' ./ (iν_array(mP.β, 0:(sP.n_iν-1)) .^ 2)
    tail_corr_inv_1 = 0.5 * mP.β * (mP.U^2 * 0.5 * mP.n * (1-0.5*mP.n) .+ Σ_hartree .* (ϵkGrid_red .+ Σ_hartree .- mP.μ))


    Σ_ladder_corrected = Σ_ladder.+ Σ_hartree
    G0_full = G_from_Σ(zeros(Complex{Float64}, sP.n_iν), ϵkGrid, νGrid, mP);
    G0 = flatten_2D(reduce_kGrid.(cut_mirror.(G0_full)))
    G_new = flatten_2D(G_from_Σ(Σ_ladder_corrected, ϵkGrid_red, νGrid, mP));

    norm = (mP.β * sP.Nk^mP.D)
    tmp = real.(G_new .* Σ_ladder_corrected .+ tail_corr_0 .- tail_corr_1);
    res = [sum( (2 .* sum(tmp[1:i,:], dims=[1])[1,:] .+ tail_corr_inv_0 .- tail_corr_inv_1 .* 0.5 .* mP.β) .* qMultiplicity) / norm for i in 1:sP.n_iν]
    return (weights != nothing) ? fit_νsum(weights, res[(end-size(weights,2)+1):end]) : res[end]
    #Wν    = build_weights(floor(Int64, 15), sP.n_iν, collect(0:6))
end

macro slice_middle(arr, n)
    :($arr[($n:(length($arr))-$n)])
end

macro slice_usable(arr, usable)
    n = :(ceil(Int64,(length($arr)-length($usable)+2)/2))
    :($arr[($n:(length($arr))-$n+1)])
end

stripped_type(t) = (t |> typeof |> Base.typename).wrapper
sum_drop(arr::AbstractArray) = sum(a,dims=dims)[[(i in dims ? 1 : axes(a,i)) for i in 1:ndims(a)]...]

# ================== FFT + Intervals Workaround ==================
lo(arr::Array{Interval{Float64}}) = map(x->x.lo,arr)
hi(arr::Array{Interval{Float64}}) = map(x->x.hi,arr) 
lo(arr::Array{Complex{Interval{Float64}}}) = map(x->x.lo,real.(arr)) .+ map(x->x.lo,imag.(arr)) .* im
hi(arr::Array{Complex{Interval{Float64}}}) = map(x->x.hi,real.(arr)) .+ map(x->x.hi,imag.(arr)) .* im
cmplx_interval(x::Tuple{Complex{Float64},Complex{Float64}}) = Complex(interval(minimum(real.(x)),maximum(real.(x))),
                                                                      interval(minimum(imag.(x)),maximum(imag.(x))))
AbstractFFTs.fft(arr::Array{Interval{Float64}}) = map(x->interval(minimum(x),maximum(x)),zip(fft(lo(arr)), fft(lo(arr))))
AbstractFFTs.fft(arr::Array{Complex{Interval{Float64}}}) = map(x->cmplx_interval(x),zip(fft(lo(arr)), fft(hi(arr))))
AbstractFFTs.ifft(arr::Array{Interval{Float64}}) = map(x->interval(minimum(x),maximum(x)),zip(ifft(lo(arr)), ifft(lo(arr))))
AbstractFFTs.ifft(arr::Array{Complex{Interval{Float64}}}) = map(x->cmplx_interval(x),zip(ifft(lo(arr)), ifft(hi(arr))))
