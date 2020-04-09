# Internal traits for sharing methods
struct _All_ end
struct _Read_ end
struct _Write_ end

# Set up the rule data to loop over
maprule!(simdata::SimData, rule::Rule) = begin
    rkeys, rgrids = getdata(_Read_(), rule, simdata)
    wkeys, wgrids = getdata(_Write_(), rule, simdata)
    # Copy the source to dest for grids we are writing to,
    # if they need to be copied
    _maybeupdate_dest!(wgrids, rule)
    # Combine read and write grids to a temporary simdata object
    tempsimdata = @set simdata.data = combinedata(rkeys, rgrids, wkeys, wgrids)
    # Run the rule loop
    ruleloop(opt(simdata), rule, tempsimdata, rkeys, rgrids, wkeys, wgrids)
    # Copy the source status to dest status for all write grids
    copystatus!(wgrids)
    # Swap the dest/source of grids that were written to
    wgrids = swapsource(wgrids) |> _to_readonly
    # Combine the written grids with the original simdata
    replacedata(simdata, wkeys, wgrids)
end

_to_readonly(data::Tuple) = map(ReadableGridData, data)
_to_readonly(data::WritableGridData) = ReadableGridData(data)

_maybeupdate_dest!(ds::Tuple, rule) =
    map(d -> _maybeupdate_dest!(d, rule), ds)
_maybeupdate_dest!(d::WritableGridData, rule::Rule) =
    handleoverflow!(d)
_maybeupdate_dest!(d::WritableGridData, rule::PartialRule) = begin
    @inbounds parent(dest(d)) .= parent(source(d))
    handleoverflow!(d)
end

# Separated out for both modularity and as a function barrier for type stability

ruleloop(::PerformanceOpt, rule::Rule, simdata, rkeys, rgrids, wkeys, wgrids) = begin
    nrows, ncols = gridsize(simdata)
    for j in 1:ncols, i in 1:nrows
        ismasked(mask(simdata), i, j) && continue
        readvals = _readstate(rkeys, rgrids, i, j)
        writevals = applyrule(rule, simdata, readvals, (i, j))
        _writetogrids!(wgrids, writevals, i, j)
    end
end
ruleloop(::PerformanceOpt, rule::PartialRule, simdata, rkeys, rgrids, wkeys, wgrids) = begin
    nrows, ncols = gridsize(data(simdata)[1])
    for j in 1:ncols, i in 1:nrows
        ismasked(mask(simdata), i, j) && continue
        read = _readstate(rkeys, rgrids, i, j)
        applyrule!(rule, simdata, read, (i, j))
    end
end
#= Run the rule for all cells, writing the result to the dest array
The neighborhood is copied to the rules neighborhood buffer array for performance.
Empty blocks are skipped for NeighborhoodRules. =#
ruleloop(opt::NoOpt, rule::Union{NeighborhoodRule,Chain{R,W,<:Tuple{<:NeighborhoodRule,Vararg}}},
         simdata, rkeys, rgrids, wkeys, wgrids) where {R,W} = begin
    r = radius(rule)
    griddata = simdata[neighborhoodkey(rule)]
    blocksize = 2r
    hoodsize = 2r + 1
    nrows, ncols = gridsize(griddata)
    # We unwrap offset arrays and work with the underlying array
    src, dst = parent(source(griddata)), parent(dest(griddata))
    blockrows, blockcols = indtoblock.(size(src), blocksize)
    # curstatus and newstatus track active status for 4 local blocks
    # Get the preallocated neighborhood buffers
    bufs = buffers(griddata)
    # Center of the buffer for both axes
    bufcenter = r + 1

    #= Run the rule row by row. When we move along a row by one cell, we access only
    a single new column of data the same hight of the nighborhood, and move the existing
    data in the neighborhood buffer array accross by one column. This saves on reads
    from the main array, and focusses reads and writes in the small buffer array that
    should be in fast local memory. =#

    # Loop down a block COLUMN
    for bi = 1:blockrows
        rowsinblock = min(blocksize, nrows - blocksize * (bi - 1))
        # Get current block
        i = blocktoind(bi, blocksize)
        

        # Loop along the block ROW. This is faster because we are reading
        # 1 column from the main array for multiple blocks at each step, 
        # not actually along the row.  
        for j = 1:ncols
            # Which block column are we in
            if j == 1
                # Reinitialise neighborhood buffers
                for y = 1:hoodsize
                    for b in 1:rowsinblock
                        for x = 1:hoodsize
                            val = src[i + b + x - 2, y]
                            @inbounds bufs[b][x, y] = val
                        end
                    end
                end
            else
                # Move the neighborhood buffers accross one column
                for b in 1:rowsinblock
                    @inbounds buf = bufs[b]
                    # copyto! uses linear indexing, so 2d dims are transformed manually
                    @inbounds copyto!(buf, 1, buf, hoodsize + 1, (hoodsize - 1) * hoodsize)
                end
                # Copy a new column to each neighborhood buffer
                for b in 1:rowsinblock
                    @inbounds buf = bufs[b]
                    for x in 1:hoodsize
                        @inbounds buf[x, hoodsize] = src[i + b + x - 2, j + 2r]
                    end
                end
            end

            curblockj = indtoblock(j, blocksize)

            # Loop over the grid ROWS inside the block
            for b in 1:rowsinblock
                I = i + b - 1, j
                ismasked(simdata, I...) && continue
                # Which block row are we in
                curblocki = b <= r ? 1 : 2
                # Run the rule using buffer b
                buf = bufs[b]
                readval = _readstate(keys2vals(readkeys(rule)), rgrids, I...)
                #read = buf[bufcenter, bufcenter]
                writeval = applyrule(rule, griddata, readval, I, buf)
                _writetogrids!(wgrids, writeval, I...)
                # Update the status for the block
            end
        end
    end
end

ruleloop(opt::SparseOpt, rule::Union{NeighborhoodRule,Chain{R,W,<:Tuple{<:NeighborhoodRule,Vararg}}},
         simdata, rkeys, rgrids, wkeys, wgrids) where {R,W} = begin

    rgrids isa Tuple && length(rgrids) > 1 && error("`SparseOpt` can't handle rules with multiple read grids yet. Use `opt=NoOpt()`")
    r = radius(rule)
    griddata = simdata[neighborhoodkey(rule)]
    #= Blocks are cell smaller than the hood, because this works very nicely for
    #looking at only 4 blocks at a time. Larger blocks mean each neighborhood is more
    #likely to be active, smaller means handling more than 2 neighborhoods per block.
    It would be good to test if this is the sweet spot for performance,
    it probably isn't for game of life size grids. =#
    blocksize = 2r
    hoodsize = 2r + 1
    nrows, ncols = gridsize(griddata)
    # We unwrap offset arrays and work with the underlying array
    src, dst = parent(source(griddata)), parent(dest(griddata))
    srcstatus, dststatus = sourcestatus(griddata), deststatus(griddata)
    # curstatus and newstatus track active status for 4 local blocks
    newstatus = localstatus(griddata)
    # Initialise status for the dest. Is this needed?
    # deststatus(data) .= false
    # Get the preallocated neighborhood buffers
    bufs = buffers(griddata)
    # Center of the buffer for both axes
    bufcenter = r + 1

    #= Run the rule row by row. When we move along a row by one cell, we access only
    a single new column of data the same hight of the nighborhood, and move the existing
    data in the neighborhood buffer array accross by one column. This saves on reads
    from the main array, and focusses reads and writes in the small buffer array that
    should be in fast local memory. =#

    # Loop down the block COLUMN
    for bi = 1:size(srcstatus, 1) - 1
        i = blocktoind(bi, blocksize)
        # Get current block
        rowsinblock = min(blocksize, nrows - blocksize * (bi - 1))
        skippedlastblock = true
        freshbuffer = true

        # Initialise block status for the start of the row
        @inbounds bs11, bs12 = srcstatus[bi,     1], srcstatus[bi,     2]
        @inbounds bs21, bs22 = srcstatus[bi + 1, 1], srcstatus[bi + 1, 2]
        newstatus .= false

        # Loop along the block ROW. This is faster because we are reading
        # 1 column from the main array for 2 blocks at each step, not actually along the row.
        for bj = 1:size(srcstatus, 2) - 1
            @inbounds newstatus[1, 1] = newstatus[1, 2]
            @inbounds newstatus[2, 1] = newstatus[2, 2]
            @inbounds newstatus[1, 2] = false
            @inbounds newstatus[2, 2] = false

            # Get current block status from the source status array
            bs11, bs21 = bs12, bs22
            @inbounds bs12, bs22 = srcstatus[bi, bj + 1], srcstatus[bi + 1, bj + 1]

            jstart = blocktoind(bj, blocksize)
            jstop = min(jstart + blocksize - 1, ncols)

            # Use this block unless it or its neighbors are active
            if !(bs11 | bs12 | bs21 | bs22)
                if !skippedlastblock
                    newstatus .= false
                end
                # Skip this block
                skippedlastblock = true
                # Run the rest of the chain if it exists
                # TODO: test this
                # if rule isa Chain && length(rule) > 1
                #     # Loop over the grid COLUMNS inside the block
                #     for j in jstart:jstop
                #         # Loop over the grid ROWS inside the block
                #         for b in 1:rowsinblock
                #             ii = i + b - 1
                #             ismasked(simdata, ii, j) && continue
                #             read = _readstate(rkeys, rgrids, i, j)
                #             write = applyrule(tail(rule), griddata, read, (ii, j), buf)
                #             if wgrids isa Tuple
                #                 map(wgrids, write) do d, w
                #                     @inbounds dest(d)[i, j] = w
                #                 end
                #             else
                #                 @inbounds dest(wgrids)[i, j] = write
                #             end
                #         end
                #     end
                # end
                continue
            end

            # Reinitialise neighborhood buffers if we have skipped a section of the array
            if skippedlastblock
                for y = 1:hoodsize
                    for b in 1:rowsinblock
                        for x = 1:hoodsize
                            val = src[i + b + x - 2, jstart + y - 1]
                            @inbounds bufs[b][x, y] = val
                        end
                    end
                end
                skippedlastblock = false
                freshbuffer = true
            end

            # Loop over the grid COLUMNS inside the block
            for j in jstart:jstop
                # Which block column are we in
                curblockj = j - jstart < r ? 1 : 2
                if freshbuffer
                    freshbuffer = false
                else
                    # Move the neighborhood buffers accross one column
                    for b in 1:rowsinblock
                        @inbounds buf = bufs[b]
                        # copyto! uses linear indexing, so 2d dims are transformed manually
                        @inbounds copyto!(buf, 1, buf, hoodsize + 1, (hoodsize - 1) * hoodsize)
                    end
                    # Copy a new column to each neighborhood buffer
                    for b in 1:rowsinblock
                        @inbounds buf = bufs[b]
                        for x in 1:hoodsize
                            @inbounds buf[x, hoodsize] = src[i + b + x - 2, j + 2r]
                        end
                    end
                end

                # Loop over the grid ROWS inside the block
                for b in 1:rowsinblock
                    I = i + b - 1, j
                    ismasked(simdata, I...) && continue
                    # Which block row are we in
                    curblocki = b <= r ? 1 : 2
                    # Run the rule using buffer b
                    buf = bufs[b]
                    readval = _readstate(keys2vals(readkeys(rule)), rgrids, I...)
                    #read = buf[bufcenter, bufcenter]
                    writeval = applyrule(rule, griddata, readval, I, buf)
                    _writetogrids!(wgrids, writeval, I...)
                    # Update the status for the block
                    cellstatus = if writeval isa NamedTuple
                        @inbounds val = writeval[neighborhoodkey(rule)]
                        val != zero(val)
                    else
                        writeval != zero(writeval)
                    end
                    @inbounds newstatus[curblocki, curblockj] |= cellstatus
                end

                # Combine blocks with the previous rows / cols
                @inbounds dststatus[bi, bj] |= newstatus[1, 1]
                @inbounds dststatus[bi, bj+1] |= newstatus[1, 2]
                @inbounds dststatus[bi+1, bj] |= newstatus[2, 1]
                # Start new block fresh to remove old status
                @inbounds dststatus[bi+1, bj+1] = newstatus[2, 2]
            end
        end
    end
    srcstatus .= dststatus
end

@inline _writetogrids!(data::Tuple, vals::NamedTuple, I...) =
    map(data, values(vals)) do d, v
        @inbounds dest(d)[I...] = v
    end
@inline _writetogrids!(data::GridData, val, I...) =
    (@inbounds dest(data)[I...] = val)

#= Wrap overflow where required. This optimisation allows us to ignore
bounds checks on neighborhoods and still use a wraparound grid. =#
handleoverflow!(griddata) = handleoverflow!(griddata, overflow(griddata))
handleoverflow!(griddata::GridData{T,2}, ::WrapOverflow) where T = begin
    r = radius(griddata)

    # TODO optimise this. Its mostly a placeholder so wrapping still works in GOL tests.
    src = source(griddata)
    nrows, ncols = gridsize(griddata)

    startpadrow = startpadcol = 1-r:0
    endpadrow = nrows+1:nrows+r
    endpadcol = ncols+1:ncols+r
    startrow = startcol = 1:r
    endrow = nrows+1-r:nrows
    endcol = ncols+1-r:ncols
    rows = 1:nrows
    cols = 1:ncols

    # Left
    @inbounds copyto!(src, CartesianIndices((rows, startpadcol)),
                      src, CartesianIndices((rows, endcol)))
    # Right
    @inbounds copyto!(src, CartesianIndices((rows, endpadcol)),
                      src, CartesianIndices((rows, startcol)))
    # Top
    @inbounds copyto!(src, CartesianIndices((startpadrow, cols)),
                      src, CartesianIndices((endrow, cols)))
    # Bottom
    @inbounds copyto!(src, CartesianIndices((endpadrow, cols)),
                      src, CartesianIndices((startrow, cols)))

    # Copy four corners
    # Top Left
    @inbounds copyto!(src, CartesianIndices((startpadrow, startpadcol)),
                      src, CartesianIndices((endrow, endcol)))
    # Top Right
    @inbounds copyto!(src, CartesianIndices((startpadrow, endpadcol)),
                      src, CartesianIndices((endrow, startcol)))
    # Botom Left
    @inbounds copyto!(src, CartesianIndices((endpadrow, startpadcol)),
                      src, CartesianIndices((startrow, endcol)))
    # Botom Right
    @inbounds copyto!(src, CartesianIndices((endpadrow, endpadcol)),
                      src, CartesianIndices((startrow, startcol)))

    # Wrap status
    status = sourcestatus(griddata)
    # status[:, 1] .|= status[:, end-1] .| status[:, end-2]
    # status[1, :] .|= status[end-1, :] .| status[end-2, :]
    # status[end-1, :] .|= status[1, :]
    # status[:, end-1] .|= status[:, 1]
    # status[end-2, :] .|= status[1, :]
    # status[:, end-2] .|= status[:, 1]
    # FIXME: Buggy currently, just running all in Wrap mode
    status .= true
    griddata
end
handleoverflow!(griddata::WritableGridData, ::RemoveOverflow) = begin
    r = radius(griddata)
    # Zero edge padding, as it can be written to in writable rules.
    src = parent(source(griddata))
    npadrows, npadcols = size(src)

    startpadrow = startpadcol = 1:r
    endpadrow = npadrows-r+1:npadrows
    endpadcol = npadcols-r+1:npadcols
    padrows, padcols = axes(src)

    for j = startpadcol, i = padrows 
        src[i, j] = zero(eltype(src))
    end
    for j = endpadcol, i = padrows
        src[i, j] = zero(eltype(src))
    end
    for j = padcols, i = startpadrow
        src[i, j] = zero(eltype(src))
    end
    for j = padcols, i = endpadrow
        src[i, j] = zero(eltype(src))
    end
    griddata
end


@inline _readstate(keys::Tuple, data::Union{<:Tuple,<:NamedTuple}, I...) = begin
    vals = map(d -> _readstate(keys, d, I...), data)
    NamedTuple{map(unwrap, keys),typeof(vals)}(vals)
end
@inline _readstate(keys, data::GridData, I...) = data[I...]


# getdata retreives GridDatGridData to match the requirements of a Rule.

# Choose key source
getdata(context::_All_, simdata::AbstractSimData) =
    getdata(context, keys(simdata), keys(simdata), simdata)
getdata(context::_Write_, rule::Rule, simdata::AbstractSimData) =
    getdata(context, keys(simdata), writekeys(rule), simdata::AbstractSimData)
getdata(context::_Read_, rule::Rule, simdata::AbstractSimData) =
    getdata(context, keys(simdata), readkeys(rule), simdata)
@inline getdata(context, gridkeys, rulekeys, simdata::AbstractSimData) =
    getdata(context, keys2vals(rulekeys), simdata)
# When there is only one grid, use its key and ignore the rule key
# This can make scripting easier as you can safely ignore the keys
# for smaller models.
@inline getdata(context, gridkeys::Tuple{Symbol}, rulekeys::Tuple{Symbol}, simdata::AbstractSimData) =
    getdata(context, (Val(gridkeys[1]),), simdata)
@inline getdata(context, gridkeys::Tuple{Symbol}, rulekey::Symbol, simdata::AbstractSimData) =
    getdata(context, Val(gridkeys[1]), simdata)

# Iterate when keys are a tuple
@inline getdata(context, keys::Tuple{Val,Vararg}, simdata::AbstractSimData) = begin
    k, d = getdata(context, keys[1], simdata)
    ks, ds = getdata(context, tail(keys), simdata)
    (k, ks...), (d, ds...)
end
@inline getdata(context, keys::Tuple{}, simdata::AbstractSimData) = (), ()

# Choose data source
@inline getdata(::_Write_, key::Val{K}, simdata::AbstractSimData) where K =
    key, WritableGridData(simdata[K])
@inline getdata(::Union{_Read_,_All_}, key::Val{K}, simdata::AbstractSimData) where K =
    key, simdata[K]


combinedata(rkey, rgrids, wkey, wgrids) =
    combinedata((rkey,), (rgrids,), (wkey,), (wgrids,))
combinedata(rkey, rgrids, wkeys::Tuple, wgrids::Tuple) =
    combinedata((rkey,), (rgrids,), wkeys, wgrids)
combinedata(rkeys::Tuple, rgrids::Tuple, wkey, wgrids) =
    combinedata(rkeys, rgrids, (wkey,), (wgrids,))
@generated combinedata(rkeys::Tuple{Vararg{<:Val}}, rgrids::Tuple,
                       wkeys::Tuple{Vararg{<:Val}}, wgrids::Tuple) = begin
    rkeys = _vals2syms(rkeys)
    wkeys = _vals2syms(wkeys)
    keysexp = Expr(:tuple, QuoteNode.(wkeys)...)
    dataexp = Expr(:tuple, :(wgrids...))

    for (i, key) in enumerate(rkeys)
        if !(key in wkeys)
            push!(dataexp.args, :(rgrids[$i]))
            push!(keysexp.args, QuoteNode(key))
        end
    end

    quote
        NamedTuple{$keysexp}($dataexp)
    end
end

replacedata(simdata::AbstractSimData, wkeys, wgrids) =
    @set simdata.data = replacedata(data(simdata), wkeys, wgrids)
@generated replacedata(allgrids::NamedTuple, wkeys::Tuple, wgrids::Tuple) = begin
    writekeys = map(unwrap, wkeys.parameters)
    allkeys = allgrids.parameters[1]
    expr = Expr(:tuple)
    for key in allkeys
        if key in writekeys
            i = findfirst(k -> k == key, writekeys)
            push!(expr.args, :(wgrids[$i]))
        else
            push!(expr.args, :(allgrids.$key))
        end
    end
    quote
        vals = $expr
        NamedTuple{$allkeys,typeof(vals)}(vals)
    end
end
@generated replacedata(allgrids::NamedTuple, wkey::Val, wgrids::GridData) = begin
    writekey = unwrap(wkey)
    allkeys = allgrids.parameters[1]
    expr = Expr(:tuple)
    for key in allkeys
        if key == writekey
            push!(expr.args, :(wgrids))
        else
            push!(expr.args, :(allgrids.$key))
        end
    end
    quote
        vals = $expr
        NamedTuple{$allkeys,typeof(vals)}(vals)
    end
end

_vals2syms(x::Type{<:Tuple}) = map(v -> _vals2syms(v), x.parameters)
_vals2syms(::Type{<:Val{X}}) where X = X


#= Runs simulations over the block grid. Inactive blocks do not run.
This can lead to order of magnitude performance improvments in sparse
simulations where large areas of the grid are filled with zeros. =#
blockrun!(data::GridData, context, args...) = begin
    nrows, ncols = gridsize(data)
    r = radius(data)
    if r > 0
        blocksize = 2r
        status = sourcestatus(data)

        @inbounds for bj in 1:size(status, 2) - 1, bi in 1:size(status, 1) - 1
            status[bi, bj] || continue
            # Convert from padded block to init dimensions
            istart = blocktoind(bi, blocksize) - r
            jstart = blocktoind(bj, blocksize) - r
            # Stop at the init row/column size, not the padding or block multiple
            istop = min(istart + blocksize - 1, nrows)
            jstop = min(jstart + blocksize - 1, ncols)
            # Skip the padding
            istart = max(istart, 1)
            jstart = max(jstart, 1)

            for j in jstart:jstop, i in istart:istop
                celldo!(data, context, (i, j), args...)
            end
        end
    else
        for j in 1:ncols, i in 1:nrows
            celldo!(data, context, (i, j), args...)
        end
    end
end

# Run rule for particular cell. Applied to active cells inside blockrun!
@inline celldo!(data::GridData, rule::Rule, I) = begin
    @inbounds state = source(data)[I...]
    @inbounds dest(data)[I...] = applyrule(rule, data, state, I)
    nothing
end


# """
# Parital rules must copy the grid to dest as not all cells will be written.
# Block status is also updated.
# """
# maprule!(data::GridData, rule::PartialRule) = begin
#     data = WritableGridData(data)
#     # Update active blocks in the dest array
#     @inbounds parent(dest(data)) .= parent(source(data))
#     # Run the rule for active blocks
#     blockrun!(data, rule)
#     copystatus!(data)
# end

# @inline celldo!(data::WritableGridData, rule::PartialRule, I) = begin
#     state = source(data)[I...]
#     state == zero(state) && return
#     applyrule!(rule, data, state, I)
# end

# @inline celldo!(data::WritableGridData, rule::PartialNeighborhoodRule, I) = begin
#     state = source(data)[I...]
#     state == zero(state) && return
#     applyrule!(rule, data, state, I)
#     _zerooverflow!(data, overflow(data), radius(data))
# end