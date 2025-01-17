# structure for iterating over a csv file
# no automatic type inference is done, but types are allowed to be passed
# for as many columns as desired; `CSV.detect(row, i)` can also be used to
# use the same inference logic used in `CSV.File` for determing a cell's typed value
struct Rows{transpose, IO, customtypes, V, stringtype}
    name::String
    names::Vector{Symbol} # only includes "select"ed columns
    columns::Vector{Column}
    columnmap::Vector{Int} # maps "select"ed column index to actual file column index
    buf::IO
    datapos::Int64
    datarow::Int
    len::Int
    limit::Int64
    options::Parsers.Options
    reusebuffer::Bool
    values::Vector{V} # once values are parsed, put in values; allocated on each iteration if reusebuffer=false
    lookup::Dict{Symbol, Int}
    numwarnings::Base.RefValue{Int}
    maxwarnings::Int
    ctx::Context
end

function Base.show(io::IO, r::Rows)
    println(io, "CSV.Rows(\"$(r.name)\"):")
    println(io, "Size: $(length(r.columns))")
    show(io, Tables.schema(r))
end

"""
    CSV.Rows(source; kwargs...) => CSV.Rows

Read a csv input returning a `CSV.Rows` object.

The `source` argument can be one of:
  * filename given as a string or FilePaths.jl type
  * an `AbstractVector{UInt8}` like a byte buffer or `codeunits(string)`
  * an `IOBuffer`

To read a csv file from a url, use the HTTP.jl package, where the `HTTP.Response` body can be passed like:
```julia
f = CSV.Rows(HTTP.get(url).body)
```

For other `IO` or `Cmd` inputs, you can pass them like: `f = CSV.Rows(read(obj))`.

While similar to [`CSV.File`](@ref), `CSV.Rows` provides a slightly different interface, the tradeoffs including:
  * Very minimal memory footprint; while iterating, only the current row values are buffered
  * Only provides row access via iteration; to access columns, one can stream the rows into a table type
  * Performs no type inference; each column/cell is essentially treated as `Union{String, Missing}`, users can utilize the performant `Parsers.parse(T, str)` to convert values to a more specific type if needed, or pass types upon construction using the `type` or `types` keyword arguments

Opens the file and uses passed arguments to detect the number of columns, ***but not*** column types (column types default to `String` unless otherwise manually provided).
The returned `CSV.Rows` object supports the [Tables.jl](https://github.com/JuliaData/Tables.jl) interface
and can iterate rows. Each row object supports `propertynames`, `getproperty`, and `getindex` to access individual row values.
Note that duplicate column names will be detected and adjusted to ensure uniqueness (duplicate column name `a` will become `a_1`).
For example, one could iterate over a csv file with column names `a`, `b`, and `c` by doing:

```julia
for row in CSV.Rows(file)
    println("a=\$(row.a), b=\$(row.b), c=\$(row.c)")
end
```

$KEYWORD_DOCS
"""
function Rows(source;
    # file options
    # header can be a row number, range of rows, or actual string vector
    header::Union{Integer, Vector{Symbol}, Vector{String}, AbstractVector{<:Integer}}=1,
    normalizenames::Bool=false,
    # by default, data starts immediately after header or start of file
    datarow::Integer=-1,
    skipto::Integer=-1,
    footerskip::Integer=0,
    transpose::Bool=false,
    comment::Union{String, Nothing}=nothing,
    ignoreemptyrows::Bool=true,
    ignoreemptylines=nothing,
    select=nothing,
    drop=nothing,
    limit::Union{Integer, Nothing}=nothing,
    # parsing options
    missingstrings=String[],
    missingstring="",
    delim::Union{Nothing, Char, String}=nothing,
    ignorerepeated::Bool=false,
    quoted::Bool=true,
    quotechar::Union{UInt8, Char}='"',
    openquotechar::Union{UInt8, Char, Nothing}=nothing,
    closequotechar::Union{UInt8, Char, Nothing}=nothing,
    escapechar::Union{UInt8, Char}='"',
    dateformat::Union{String, Dates.DateFormat, Nothing, AbstractDict}=nothing,
    dateformats=nothing,
    decimal::Union{UInt8, Char}=UInt8('.'),
    truestrings::Union{Vector{String}, Nothing}=TRUE_STRINGS,
    falsestrings::Union{Vector{String}, Nothing}=FALSE_STRINGS,
    # type options
    type=nothing,
    types=nothing,
    typemap::Dict=Dict{Type, Type}(),
    pool::Union{Bool, Real, AbstractVector, AbstractDict}=false,
    downcast::Bool=false,
    stringtype::StringTypes=PosLenString,
    lazystrings::Bool=stringtype === PosLenString,
    strict::Bool=false,
    silencewarnings::Bool=false,
    maxwarnings::Int=100,
    debug::Bool=false,
    parsingdebug::Bool=false,
    reusebuffer::Bool=false,
    )
    ctx = Context(source, header, normalizenames, datarow, skipto, footerskip, transpose, comment, ignoreemptyrows, ignoreemptylines, select, drop, limit, nothing, nothing, nothing, 0, nothing, missingstrings, missingstring, delim, ignorerepeated, quoted, quotechar, openquotechar, closequotechar, escapechar, dateformat, dateformats, decimal, truestrings, falsestrings, type, types, typemap, pool, downcast, lazystrings, stringtype, strict, silencewarnings, maxwarnings, debug, parsingdebug, true)
    foreach(col -> col.pool = 0.0, ctx.columns)
    allocate!(ctx.columns, 1)
    values = all(x->x.type === stringtype && x.anymissing, ctx.columns) && lazystrings ? Vector{PosLen}(undef, ctx.cols) : Vector{Any}(undef, ctx.cols)
    columnmap = collect(1:ctx.cols)
    for i = ctx.cols:-1:1
        col = ctx.columns[i]
        if col.willdrop
            deleteat!(ctx.names, i)
            deleteat!(columnmap, i)
        end
    end
    lookup = Dict(nm=>i for (i, nm) in enumerate(ctx.names))
    return Rows{transpose, typeof(ctx.buf), ctx.customtypes, eltype(values), stringtype}(
        ctx.name,
        ctx.names,
        ctx.columns,
        columnmap,
        ctx.buf,
        ctx.datapos,
        ctx.datarow,
        ctx.len,
        ctx.limit,
        ctx.options,
        reusebuffer,
        values,
        lookup,
        Ref(0),
        maxwarnings,
        ctx
    )
end

Tables.rowtable(::Type{<:Rows}) = true
Tables.rows(r::Rows) = r
Tables.schema(r::Rows) = Tables.Schema(r.names, [coltype(x) for x in view(r.columns, r.columnmap)])
Base.eltype(::Rows) = Row2
Base.IteratorSize(::Type{<:Rows}) = Base.SizeUnknown()

@inline function setcustom!(::Type{customtypes}, values, columns, i) where {customtypes}
    if @generated
        block = Expr(:block)
        push!(block.args, quote
            error("CSV.jl code-generation error, unexpected column type: $(typeof(column))")
        end)
        for i = 1:fieldcount(customtypes)
            T = fieldtype(customtypes, i)
            vT = vectype(T)
            pushfirst!(block.args, quote
                column = columns[i].column
                if column isa $vT
                    @inbounds values[i] = column[1]
                    return
                end
            end)
        end
        pushfirst!(block.args, Expr(:meta, :inline))
        # @show block
        return block
    else
        # println("generated function failed")
        @inbounds values[i] = columns[i].column[1]
        return
    end
end

function checkwidencolumns!(r::Rows{t, ct, V}, cols) where {t, ct, V}
    if cols > length(r.values)
        # we widened while parsing this row, need to widen other supporting objects
        for i = (length(r.values) + 1):cols
            push!(r.values, V === Any ? missing : Base.bitcast(PosLen, Parsers.MISSING_BIT))
            nm = Symbol(:Column, i)
            push!(r.names, nm)
            r.lookup[nm] = length(r.values)
            push!(r.columnmap, i)
        end
    end
    return
end

@inline function Base.iterate(r::Rows{transpose, IO, customtypes, V, stringtype}, (pos, len, row)=(r.datapos, r.len, 1)) where {transpose, IO, customtypes, V, stringtype}
    (pos > len || row > r.limit) && return nothing
    pos = parserow(1, 1, r.numwarnings, r.ctx, r.buf, pos, len, 1, r.datarow + row - 2, r.columns, Val(transpose), customtypes)
    columns = r.columns
    cols = length(columns)
    checkwidencolumns!(r, cols)
    values = r.reusebuffer ? r.values : Vector{V}(undef, cols)
    for i = 1:cols
        @inbounds column = columns[i].column
        if column isa MissingVector
            @inbounds values[i] = missing
        elseif column isa Vector{PosLen}
            @inbounds values[i] = column[1]
        elseif column isa Vector{Union{Missing, Int8}}
            @inbounds values[i] = column[1]
        elseif column isa Vector{Union{Missing, Int16}}
            @inbounds values[i] = column[1]
        elseif column isa Vector{Union{Missing, Int32}}
            @inbounds values[i] = column[1]
        elseif column isa SVec{Int64}
            @inbounds values[i] = column[1]
        elseif column isa SVec{Int128}
            @inbounds values[i] = column[1]
        elseif column isa SVec{Float64}
            @inbounds values[i] = column[1]
        elseif column isa SVec{InlineString1}
            @inbounds values[i] = column[1]
        elseif column isa SVec{InlineString3}
            @inbounds values[i] = column[1]
        elseif column isa SVec{InlineString7}
            @inbounds values[i] = column[1]
        elseif column isa SVec{InlineString15}
            @inbounds values[i] = column[1]
        elseif column isa SVec{InlineString31}
            @inbounds values[i] = column[1]
        elseif column isa SVec{InlineString63}
            @inbounds values[i] = column[1]
        elseif column isa SVec{InlineString127}
            @inbounds values[i] = column[1]
        elseif column isa SVec{InlineString255}
            @inbounds values[i] = column[1]
        elseif column isa SVec2{String}
            @inbounds values[i] = column[1]
        elseif column isa SVec{Date}
            @inbounds values[i] = column[1]
        elseif column isa SVec{DateTime}
            @inbounds values[i] = column[1]
        elseif column isa SVec{Time}
            @inbounds values[i] = column[1]
        elseif column isa Vector{Union{Missing, Bool}}
            @inbounds values[i] = column[1]
        elseif column isa Vector{UInt32}
            @inbounds values[i] = column[1]
        elseif customtypes !== Tuple{}
            setcustom!(customtypes, values, columns, i)
        else
            error("bad array type: $(typeof(column))")
        end
    end
    return Row2{V, stringtype}(r.names, r.columns, r.columnmap, r.lookup, values, r.buf), (pos, len, row + 1)
end

struct Row2{V, stringtype} <: Tables.AbstractRow
    names::Vector{Symbol}
    columns::Vector{Column}
    columnmap::Vector{Int}
    lookup::Dict{Symbol, Int}
    values::Vector{V}
    buf::Vector{UInt8}
end

getnames(r::Row2) = getfield(r, :names)
getcolumns(r::Row2) = getfield(r, :columns)
getcolumnmap(r::Row2) = getfield(r, :columnmap)
getlookup(r::Row2) = getfield(r, :lookup)
getvalues(r::Row2) = getfield(r, :values)
getbuf(r::Row2) = getfield(r, :buf)
getV(::Row2{V}) where {V} = V
getstringtype(::Row2{V, stringtype}) where {V, stringtype} = stringtype

Tables.columnnames(r::Row2) = getnames(r)

Base.checkbounds(r::Row2, i) = 0 < i < length(r)

Tables.getcolumn(r::Row2, nm::Symbol) = Tables.getcolumn(r, getlookup(r)[nm])
Tables.getcolumn(r::Row2, i::Int) = Tables.getcolumn(r, coltype(getcolumns(r)[i]), i, getnames(r)[i])

Base.@propagate_inbounds function Tables.getcolumn(r::Row2, ::Type{T}, i::Int, nm::Symbol) where {T}
    @boundscheck checkbounds(r, i)
    j = getcolumnmap(r)[i]
    values = getvalues(r)
    V = getV(r)
    @inbounds val = j > length(values) ? (V === PosLen ? Parsers.MISSING_BIT : missing) : values[j]
    stringtype = getstringtype(r)
    if V === PosLen
        # column type must be stringtype
        # @show T, stringtype
        @assert T === Union{stringtype, Missing}
        e = getcolumns(r)[j].options.e
        if (val isa PosLen && val.missingvalue) || val == Parsers.MISSING_BIT
            return missing
        elseif stringtype === PosLenString
            return PosLenString(getbuf(r), val, e)
        elseif stringtype === String
            return Parsers.getstring(getbuf(r), val, e)
        end
    else
        # at least some column types were manually provided
        if val isa PosLen
            if val.missingvalue
                return missing
            else
                e = getcolumns(r)[j].options.e
                return PosLenString(getbuf(r), val, e)
            end
        else
            return val
        end
    end
end

@noinline stringsonly() = error("Parsers.parse only allowed on String column types")

Base.@propagate_inbounds function Parsers.parse(::Type{T}, r::Row2, i::Int) where {T}
    @boundscheck checkbounds(r, i)
    @inbounds begin
        j = getcolumnmap(r)[i]
        col = getcolumns(r)[j]
        col.type isa StringTypes || stringsonly()
        poslen = getvalues(r)[j]
        poslen.missingvalue && return missing
        pos = poslen.pos
        res = Parsers.xparse(T, getbuf(r), pos, pos + poslen.len, col.options)
    end
    return Parsers.ok(res.code) ? (res.val::T) : missing
end

Base.@propagate_inbounds function detect(r::Row2, i::Int)
    @boundscheck checkbounds(r, i)
    @inbounds begin
        j = getcolumnmap(r)[i]
        col = getcolumns(r)[j]
        col.type isa StringTypes || stringsonly()
        poslen = getvalues(r)[j]
        poslen.missingvalue && return missing
        pos = poslen.pos
        code, tlen, x, xT = detect(pass, getbuf(r), pos, pos + poslen.len - 1, col.options)
        return x === nothing ? r[i] : x
    end
end

function Parsers.parse(::Type{T}, r::Row2, nm::Symbol) where {T}
    @inbounds x = Parsers.parse(T, r, getlookup(r)[nm])
    return x
end

function detect(r::Row2, nm::Symbol)
    @inbounds x = detect(r, getlookup(r)[nm])
    return x
end
