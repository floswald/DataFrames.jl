# Rows grouping.
# Maps row contents to the indices of all the equal rows.
# Used by groupby(), join(), nonunique()
struct RowGroupDict{T<:AbstractDataFrame}
    "source data table"
    df::T
    "row hashes (optional, can be empty)"
    rhashes::Vector{UInt}
    "hashindex -> index of group-representative row (optional, can be empty)"
    gslots::Vector{Int}
    "group index for each row"
    groups::Vector{Int}
    "permutation of row indices that sorts them by groups"
    rperm::Vector{Int}
    "starts of ranges in rperm for each group"
    starts::Vector{Int}
    "stops of ranges in rperm for each group"
    stops::Vector{Int}
end

# "kernel" functions for hashrows()
# adjust row hashes by the hashes of column elements
function hashrows_col!(h::Vector{UInt},
                       n::Vector{Bool},
                       v::AbstractVector{T},
                       firstcol::Bool) where T
    @inbounds for i in eachindex(h)
        el = v[i]
        h[i] = hash(el, h[i])
        if length(n) > 0
            n[i] |= ismissing(el)
        end
    end
    h
end

# should give the same hash as AbstractVector{T}
function hashrows_col!(h::Vector{UInt},
                       n::Vector{Bool},
                       v::AbstractCategoricalVector,
                       firstcol::Bool)
    index = CategoricalArrays.index(v.pool)
    # When hashing the first column, no need to take into account previous hash,
    # which is always zero
    if firstcol
        hashes = Vector{UInt}(undef, length(levels(v.pool))+1)
        hashes[1] = hash(missing)
        hashes[2:end] .= hash.(index)
        @inbounds for (i, ref) in enumerate(v.refs)
            h[i] = hashes[ref+1]
        end
    else
        @inbounds for (i, ref) in enumerate(v.refs)
            if eltype(v) >: Missing && ref == 0
                h[i] = hash(missing, h[i])
            else
                h[i] = hash(index[ref], h[i])
            end
        end
    end
    # Doing this step separately is faster, as it would disable SIMD above
    if eltype(v) >: Missing && length(n) > 0
        @inbounds for (i, ref) in enumerate(v.refs)
            n[i] |= (ref == 0)
        end
    end
    h
end

# Calculate the vector of `df` rows hash values.
function hashrows(cols::Tuple{Vararg{AbstractVector}}, skipmissing::Bool)
    len = length(cols[1])
    rhashes = zeros(UInt, len)
    missings = fill(false, skipmissing ? len : 0)
    for (i, col) in enumerate(cols)
        hashrows_col!(rhashes, missings, col, i == 1)
    end
    return (rhashes, missings)
end

# table columns are passed as a tuple of vectors to ensure type specialization
isequal_row(cols::Tuple{AbstractVector}, r1::Int, r2::Int) =
    isequal(cols[1][r1], cols[1][r2])
isequal_row(cols::Tuple{Vararg{AbstractVector}}, r1::Int, r2::Int) =
    isequal(cols[1][r1], cols[1][r2]) && isequal_row(Base.tail(cols), r1, r2)

isequal_row(cols1::Tuple{AbstractVector}, r1::Int, cols2::Tuple{AbstractVector}, r2::Int) =
    isequal(cols1[1][r1], cols2[1][r2])
isequal_row(cols1::Tuple{Vararg{AbstractVector}}, r1::Int,
            cols2::Tuple{Vararg{AbstractVector}}, r2::Int) =
    isequal(cols1[1][r1], cols2[1][r2]) &&
        isequal_row(Base.tail(cols1), r1, Base.tail(cols2), r2)

# Helper function for RowGroupDict.
# Returns a tuple:
# 1) the highest group index in the `groups` vector
# 2) vector of row hashes (may be empty if hash=Val(false))
# 3) slot array for a hash map, non-zero values are
#    the indices of the first row in a group
# 4) whether groups are already sorted
# Optional `groups` vector is set to the group indices of each row (starting at 1)
# With skipmissing=true, rows with missing values are attributed index 0.
function row_group_slots(cols::Tuple{Vararg{AbstractVector}},
                         hash::Val = Val(true),
                         groups::Union{Vector{Int}, Nothing} = nothing,
                         skipmissing::Bool = false)::Tuple{Int, Vector{UInt}, Vector{Int}, Bool}
    @assert groups === nothing || length(groups) == length(cols[1])
    rhashes, missings = hashrows(cols, skipmissing)
    # inspired by Dict code from base cf. https://github.com/JuliaData/DataTables.jl/pull/17#discussion_r102481481
    # but using open addressing with a table with as many slots as rows
    sz = Base._tablesz(length(rhashes))
    @assert sz >= length(rhashes)
    szm1 = sz-1
    gslots = zeros(Int, sz)
    # If missings are to be skipped, they will all go to group 0,
    # which will be removed by functions down the stream
    ngroups = 0
    @inbounds for i in eachindex(rhashes)
        # find the slot and group index for a row
        slotix = rhashes[i] & szm1 + 1
        # Use -1 for non-missing values to catch bugs if group is not found
        gix = skipmissing && missings[i] ? 0 : -1
        probe = 0
        if !skipmissing || !missings[i]
            while true
                g_row = gslots[slotix]
                if g_row == 0 # unoccupied slot, current row starts a new group
                    gslots[slotix] = i
                    gix = ngroups += 1
                    break
                elseif rhashes[i] == rhashes[g_row] # occupied slot, check if miss or hit
                    if isequal_row(cols, i, g_row) # hit
                        gix = groups !== nothing ? groups[g_row] : 0
                        break
                    end
                end
                slotix = slotix & szm1 + 1 # check the next slot
                probe += 1
                @assert probe < sz
            end
        end
        if groups !== nothing
            groups[i] = gix
        end
    end
    return ngroups, rhashes, gslots, false
end

nlevels(x::PooledArray) = length(x.pool)
nlevels(x) = length(levels(x))

function row_group_slots(cols::NTuple{N,<:Union{CategoricalVector,PooledVector}},
                         hash::Val{false},
                         groups::Union{Vector{Int}, Nothing} = nothing,
                         skipmissing::Bool = false)::Tuple{Int, Vector{UInt}, Vector{Int}, Bool} where N
    # Computing neither hashes nor groups isn't very useful,
    # and this method needs to allocate a groups vector anyway
    @assert groups !== nothing && all(col -> length(col) == length(groups), cols)

    # If skipmissing=true, rows with missings all go to group 0,
    # which will be removed by functions down the stream
    ngroupstup = map(cols) do c
        nlevels(c) + (!skipmissing && eltype(c) >: Missing)
    end
    ngroups = prod(ngroupstup)

    # Fall back to hashing if there would be too many empty combinations.
    # The first check ensures the computation of ngroups did not overflow.
    # The rationale for the 2 threshold is that while the fallback method is always slower,
    # it allocates a hash table of size length(groups) instead of the remap vector
    # of size ngroups (i.e. the number of possible combinations) in this method:
    # so it makes sense to allocate more memory for better performance,
    # but it needs to remain reasonable compared with the size of the data frame.
    if prod(Int128.(ngroupstup)) > typemax(Int) || ngroups > 2 * length(groups)
        return invoke(row_group_slots,
                      Tuple{Tuple{Vararg{AbstractVector}}, Val,
                            Union{Vector{Int}, Nothing}, Bool},
                      cols, hash, groups, skipmissing)
    end

    seen = fill(false, ngroups)
    # Compute vector mapping missing to -1 if skipmissing=true,
    # and sorting CategoricalArray levels (since it's cheap)
    refmaps = map(cols) do col
        nlevs = nlevels(col)
        if col isa CategoricalVector
            # When levels are in the same order as the index and there are no missing values,
            # we could simply use refs, but the performance gain is negligible,
            # so always sort groups in the order of levels
            refmap = Vector{Int}(undef, nlevs + 1)
            refmap[1] = skipmissing ? -1 : nlevs
            refmap[2:end] .= CategoricalArrays.order(col.pool) .- 1
        else # PooledVector
            # First value in refmap is never used
            # (corresponds to ref 0 which is only used by CategoricalArray)
            refmap = collect(-1:nlevs-1)
            if eltype(col) >: Missing && skipmissing
                missingind = get(col.invpool, missing, 0)
                if missingind > 0
                    refmap[missingind+1] = -1
                    refmap[missingind+2:end] .-= 1
                end
            end
        end
        refmap
    end
    strides = (cumprod(collect(reverse(ngroupstup)))[end-1:-1:1]..., 1)::NTuple{N,Int}
    @inbounds for i in eachindex(groups)
        local refs
        let i=i # Workaround for julia#15276
            refs = map(c -> c.refs[i], cols)
        end
        vals = map((m, r, s) -> m[r+1] * s, refmaps, refs, strides)
        j = sum(vals) + 1
        # x < 0 happens with -1 in refmap, which corresponds to missing
        if skipmissing && any(x -> x < 0, vals)
            j = 0
        else
            seen[j] = true
        end
        groups[i] = j
    end
    if !all(seen) # Compress group indices to remove unused ones
        oldngroups = ngroups
        remap = zeros(Int, ngroups)
        ngroups = 0
        @inbounds for i in eachindex(remap, seen)
            ngroups += seen[i]
            remap[i] = ngroups
        end
        @inbounds for i in eachindex(groups)
            gix = groups[i]
            groups[i] = gix > 0 ? remap[gix] : 0
        end
        # To catch potential bugs inducing unnecessary computations
        @assert oldngroups != ngroups
    end
    sorted = all(col -> col isa CategoricalVector, cols)
    return ngroups, UInt[], Int[], sorted
end


# Return a 3-tuple of a permutation that sorts rows into groups,
# and the positions of the first and last rows in each group in that permutation
# `groups` must contain group indices in 0:ngroups
# Rows with group index 0 are skipped (used when skipmissing=true)
# Partly uses the code of Wes McKinney's groupsort_indexer in pandas (file: src/groupby.pyx).
function compute_indices(groups::AbstractVector{<:Integer}, ngroups::Integer)
    # count elements in each group
    stops = zeros(Int, ngroups+1)
    @inbounds for gix in groups
        stops[gix+1] += 1
    end

    # group start positions in a sorted table
    starts = Vector{Int}(undef, ngroups+1)
    if length(starts) > 1
        starts[1] = 1
        @inbounds for i in 1:ngroups
            starts[i+1] = starts[i] + stops[i]
        end
    end

    # define row permutation that sorts them into groups
    rperm = Vector{Int}(undef, length(groups))
    copyto!(stops, starts)
    @inbounds for (i, gix) in enumerate(groups)
        rperm[stops[gix+1]] = i
        stops[gix+1] += 1
    end
    stops .-= 1

    # When skipmissing=true was used, group 0 corresponds to missings to drop
    # Otherwise it's empty
    popfirst!(starts)
    popfirst!(stops)

    return rperm, starts, stops
end

# Build RowGroupDict for a given DataFrame, using all of its columns as grouping keys
function group_rows(df::AbstractDataFrame)
    groups = Vector{Int}(undef, nrow(df))
    ngroups, rhashes, gslots, sorted =
        row_group_slots(ntuple(i -> df[!, i], ncol(df)), Val(true), groups, false)
    rperm, starts, stops = compute_indices(groups, ngroups)
    return RowGroupDict(df, rhashes, gslots, groups, rperm, starts, stops)
end

# Find index of a row in gd that matches given row by content, 0 if not found
function findrow(gd::RowGroupDict,
                 df::DataFrame,
                 gd_cols::Tuple{Vararg{AbstractVector}},
                 df_cols::Tuple{Vararg{AbstractVector}},
                 row::Int)
    (gd.df === df) && return row # same table, return itself
    # different tables, content matching required
    rhash = rowhash(df_cols, row)
    szm1 = length(gd.gslots)-1
    slotix = ini_slotix = rhash & szm1 + 1
    while true
        g_row = gd.gslots[slotix]
        if g_row == 0 || # not found
            (rhash == gd.rhashes[g_row] &&
            isequal_row(gd_cols, g_row, df_cols, row)) # found
            return g_row
        end
        slotix = (slotix & szm1) + 1 # miss, try the next slot
        (slotix == ini_slotix) && break
    end
    return 0 # not found
end

# Find indices of rows in 'gd' that match given row by content.
# return empty set if no row matches
function findrows(gd::RowGroupDict,
                  df::DataFrame,
                  gd_cols::Tuple{Vararg{AbstractVector}},
                  df_cols::Tuple{Vararg{AbstractVector}},
                  row::Int)
    g_row = findrow(gd, df, gd_cols, df_cols, row)
    (g_row == 0) && return view(gd.rperm, 0:-1)
    gix = gd.groups[g_row]
    return view(gd.rperm, gd.starts[gix]:gd.stops[gix])
end

function Base.getindex(gd::RowGroupDict, dfr::DataFrameRow)
    g_row = findrow(gd, parent(dfr), ntuple(i -> gd.df[!, i], ncol(gd.df)),
                    ntuple(i -> parent(dfr)[!, i], ncol(parent(dfr))), row(dfr))
    (g_row == 0) && throw(KeyError(dfr))
    gix = gd.groups[g_row]
    return view(gd.rperm, gd.starts[gix]:gd.stops[gix])
end
