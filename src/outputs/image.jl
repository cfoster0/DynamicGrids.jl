
const RulesetOrSimData = Union{Ruleset,AbstractSimData}

"""
Graphic outputs that display the simulation grid(s) as RGB images.

Although the majority of the code is maintained here to enable sharing
and reuse, no `ImageOutput`s are provided in DynamicGrids.jl to avoid
heavey dependencies on graphics libraries. See
[DynamicGridsGtk.jl](https://github.com/cesaraustralia/DynamicGridsGtk.jl)
and [DynamicGridsInteract.jl](https://github.com/cesaraustralia/DynamicGridsInteract.jl)
for implementations.
"""
abstract type ImageOutput{T} <: GraphicOutput{T} end

"""
Construct one ImageOutput from another ImageOutput or GraphicOutput
"""
(::Type{F})(o::T; kwargs...) where F <: ImageOutput where T <: ImageOutput = F(;
    frames=frames(o),
    starttime=starttime(o),
    stoptime=stoptime(o),
    fps=fps(o),
    showfps=showfps(o),
    timestamp=timestamp(o),
    stampframe=stampframe(o),
    store=store(o),
    processor=processor(o),
    minval=minval(o),
    maxval=maxval(o),
    kwargs...
)

"""
Mixin fields for `ImageOutput`s
"""
@premix @default_kw struct Image{P,Mi,Ma}
    processor::P | ColorProcessor()
    minval::Mi   | 0
    maxval::Ma   | 1
end

processor(o::Output) = Greyscale()
processor(o::ImageOutput) = o.processor

minval(o::Output) = 0
minval(o::ImageOutput) = o.minval

maxval(o::Output) = 1
maxval(o::ImageOutput) = o.maxval


# Allow construcing a frame with the ruleset passed in instead of SimData
showgrid(o::ImageOutput, f, t) = showgrid(o[f], o, Ruleset(), f, t)
showgrid(grid, o::ImageOutput, data::RulesetOrSimData, f, t) =
    showimage(grid2image(o, data, grid, t), o, data, f, t)

"""
    showimage(image, output, f, t)

Show image generated by and `GridProcessor` in an ImageOutput.
"""
function showimage end
showimage(image, o, data, f, t) = showimage(image, o, f, t)

"""
Default colorscheme. Better performance than using a Colorschemes.jl
scheme as there is no interpolation.
"""
struct Greyscale{M1,M2}
    min::M1
    max::M2
end
Greyscale(; min=nothing, max=nothing) = Greyscale(min, max)

Base.get(scheme::Greyscale, x) = scale(x, scheme.min, scheme.max)

"Alternate name for Greyscale()"
const Grayscale = Greyscale


"""
Grid processors convert a frame of the simulation into an RGB image for display.
Frames may hold one or multiple grids.
"""
abstract type GridProcessor end

textconfig(::GridProcessor) = nothing

"""
    grid2image(o::ImageOutput, data::Union{Ruleset,SimData}, grid, t)
    grid2image(p::GridProcessor, minval, maxval, data::Union{Ruleset,SimData}, grids, t)

Convert a grid or named tuple of grids to an RGB image, using a GridProcessor

[`GridProcessor`](@reg) is intentionally not dispatched with the output type in
the methods that finally generate images, to reduce coupling.
But it they can be distpatched on together when required for custom outputs.
"""
function grid2image end

grid2image(o::ImageOutput, data::RulesetOrSimData, grids, t) =
    grid2image(processor(o), o, data, grids, t)
grid2image(processor::GridProcessor, o::ImageOutput, data::RulesetOrSimData, grids, t) =
    grid2image(processor::GridProcessor, minval(o), maxval(o), data, grids, t)

"""
Grid processors that convert one grid to an image.

The first grid will be displayed if a SingleGridProcessor is
used with a NamedTuple of grids.
"""
abstract type SingleGridProcessor <: GridProcessor end

allocimage(grid::AbstractArray) = allocimage(size(grid))
allocimage(size::Tuple) = fill(ARGB32(0.0, 0.0, 0.0, 1.0), size)

grid2image(p::SingleGridProcessor, minval, maxval,
           data::RulesetOrSimData, grids::NamedTuple, t) =
grid2image(p, minval, maxval, data, first(grids), t, string(first(keys(grids))))
grid2image(p::SingleGridProcessor, minval, maxval,
           data::RulesetOrSimData, grid::AbstractArray, t, name=nothing) = begin
    img = allocimage(grid)
    for j in 1:size(img, 2), i in 1:size(img, 1)
        @inbounds val = grid[i, j]
        pixel = rgb(cell2rgb(p, minval, maxval, data, val, i, j))
        @inbounds img[i, j] = pixel
    end
    rendertext!(img, textconfig(p), name, t)
    img
end

"""
Processors that convert multiple grids to a single image.
"""
abstract type MultiGridProcessor <: GridProcessor end

"""
    TextConfig(; font::String, namepixels=14, timepixels=14,
               namepos=(timepixels+namepixels, timepixels),
               timepos=(timepixels, timepixels),
               fcolor=ARGB32(1.0), bcolor=ARGB32(RGB(0.0), 1.0),)
    TextConfig(face, namepixels, namepos, timepixels, timepos, fcolor, bcolor)

Text configuration for printing timestep and grid name on the image.

# Arguments

`namepixels` and `timepixels` set the pixel size of the font. 
`timepos` and `namepos` are tuples that set the label positions, in pixels.
`fcolor` and `bcolor` are the foreground and background colors, as `ARGB32`.
"""
struct TextConfig{F,NPi,NPo,TPi,TPo,FC,BC}
    face::F
    namepixels::NPi
    namepos::NPo
    timepixels::TPi
    timepos::TPo
    fcolor::FC
    bcolor::BC
end
TextConfig(; font, namepixels=12, timepixels=12,
           namepos=(3timepixels + namepixels, timepixels),
           timepos=(2timepixels, timepixels),
           fcolor=ARGB32(1.0), bcolor=ARGB32(RGB(0.0), 1.0),
          ) = begin
    face = FreeTypeAbstraction.findfont(font)
    face isa Nothing && throw(ArgumentError("Font $font can not be found in this system"))
    TextConfig(face, namepixels, namepos, timepixels, timepos, fcolor, bcolor)
end

rendertext!(img, config::TextConfig, name, t) = begin
    rendername!(img, config::TextConfig, name)
    rendertime!(img, config::TextConfig, t)
end
rendertext!(img, config::Nothing, name, t) = nothing

rendername!(img, config::TextConfig, name) =
    renderstring!(img, name, config.face, config.namepixels, config.namepos...;
                  fcolor=config.fcolor, bcolor=config.bcolor)
rendername!(img, config::TextConfig, name::Nothing) = nothing
rendername!(img, config::Nothing, name) = nothing
rendername!(img, config::Nothing, name::Nothing) = nothing

rendertime!(img, config::TextConfig, t) =
    renderstring!(img, string(t), config.face, config.timepixels, config.timepos...;
                  fcolor=config.fcolor, bcolor=config.bcolor)
rendertime!(img, config::Nothing, t) = nothing
rendertime!(img, config::TextConfig, t::Nothing) = nothing
rendertime!(img, config::Nothing, t::Nothing) = nothing

""""
    ColorProcessor(; scheme=Greyscale(), zerocolor=nothing, maskcolor=nothing)

Converts output grids to a colorsheme.

## Arguments / Keyword Arguments
- `scheme`: a ColorSchemes.jl colorscheme.
- `zerocolor`: an `RGB` color to use when values are zero, or `nothing` to ignore.
- `maskcolor`: an `RGB` color to use when cells are masked, or `nothing` to ignore.
"""
@default_kw struct ColorProcessor{S,Z,M,TC} <: SingleGridProcessor
    scheme::S      | Greyscale()
    zerocolor::Z   | nothing
    maskcolor::M   | nothing
    textconfig::TC | nothing
end

scheme(processor::ColorProcessor) = processor.scheme
zerocolor(processor::ColorProcessor) = processor.zerocolor
maskcolor(processor::ColorProcessor) = processor.maskcolor
textconfig(processor::ColorProcessor) = processor.textconfig

# Show colorscheme in Atom etc
Base.show(io::IO, m::MIME"image/svg+xml", p::ColorProcessor) =
    show(io, m, scheme(p))

@inline cell2rgb(p::ColorProcessor, minval, maxval, data::RulesetOrSimData, val, I...) =
    if !(maskcolor(p) isa Nothing) && ismasked(mask(data), I...)
        rgb(maskcolor(p))
    else
        normval = normalise(val, minval, maxval)
        if !(zerocolor(p) isa Nothing) && normval == zero(normval)
            rgb(zerocolor(p))
        else
            rgb(scheme(p), normval)
        end
    end

struct SparseOptInspector <: SingleGridProcessor end

@inline cell2rgb(p::SparseOptInspector, minval, maxval, data::AbstractSimData, val, I...) = begin
    r = radius(first(grids(data)))
    blocksize = 2r
    blockindex = indtoblock.((I[1] + r,  I[2] + r), blocksize)
    normedval = normalise(val, minval, maxval)
    if sourcestatus(first(data))[blockindex...]
        if normedval > 0
            rgb(normedval)
        else
            rgb(0.0, 0.5, 0.5)
        end
    elseif normedval > 0
        rgb(1.0, 0.0, 0.0) # This (a red cell) would mean there is a bug in SparseOpt
    else
        rgb(0.5, 0.5, 0.0)
    end
end


abstract type BandColor end

struct Red <: BandColor end
struct Green <: BandColor end
struct Blue <: BandColor end

"""
    ThreeColorProcessor(; colors=(Red(), Green(), Blue()), zerocolor=nothing, maskcolor=nothing)

Assigns `Red()`, `Blue()`, `Green()` or `nothing` to
any number of dynamic grids in any order. Duplicate colors will be summed.
The final color sums are combined into a composite color image for display.

## Arguments / Keyword Arguments
- `colors`: a tuple or `Red()`, `Green()`, `Blue()`, or `nothing` matching the number of grids.
- `zerocolor`: an `RGB` color to use when values are zero, or `nothing` to ignore.
- `maskcolor`: an `RGB` color to use when cells are masked, or `nothing` to ignore.
"""
@default_kw struct ThreeColorProcessor{C<:Tuple,Z,M,TC} <: MultiGridProcessor
    colors::C      | (Red(), Green(), Blue())
    zerocolor::Z   | nothing
    maskcolor::M   | nothing
    textconfig::TC | nothing
end

colors(processor::ThreeColorProcessor) = processor.colors
zerocolor(processor::ThreeColorProcessor) = processor.zerocolor
maskcolor(processor::ThreeColorProcessor) = processor.maskcolor

grid2image(p::ThreeColorProcessor, minval::Tuple, maxval::Tuple,
           data::RulesetOrSimData, grids::NamedTuple, t) = begin
    img = allocimage(first(grids))
    ncols, ngrids, nmin, nmax = map(length, (colors(p), grids, minval, maxval))
    if !(ngrids == ncols == nmin == nmax)
        ArgumentError(
            "Number of grids ($ngrids), processor colors ($ncols), " *
            "minval ($nmin) and maxival ($nmax) must be the same"
        ) |> throw
    end
    for i in CartesianIndices(first(grids))
        img[i] = if !(maskcolor(p) isa Nothing) && ismasked(mask(data), i)
            rgb(maskcolor(p))
        else
            xs = map(values(grids), minval, maxval) do g, mi, ma
                normalise(g[i], mi, ma)
            end
            if !(zerocolor(p) isa Nothing) && all(map((x, c) -> c isa Nothing || x == zero(x), xs, colors(p)))
                rgb(zerocolor(p))
            else
                rgb(combinebands(colors(p), xs))
            end
        end
    end
    img
end

"""
    LayoutProcessor(layout::Array, processors)

LayoutProcessor allows displaying multiple grids in a block layout,
by specifying a layout matrix and a list of SingleGridProcessors to
be run for each.

## Arguments / Keyword arguments
- `layout`: A Vector or Matrix containing the keys or numbers of grids in the locations to
  display them. `nothing`, `missing` or `0` values will be skipped.
- `processors`: tuple of SingleGridProcessor, one for each grid in the simulation.
  Can be `nothing` or any other value for grids not in layout.
- `textconfig` : [`TextConfig`] object for printing time and grid name labels.
"""
@default_kw struct LayoutProcessor{L<:AbstractMatrix,P,TC} <: MultiGridProcessor
    layout::L      | throw(ArgumentError("must include an Array for the layout keyword"))
    processors::P  | throw(ArgumentError("include a tuple of processors for each grid"))
    textconfig::TC | nothing
    LayoutProcessor(layouts::L, processors::P, textconfig::TC) where {L,P,TC} = begin
        processors = map(p -> (@set p.textconfig = textconfig), processors)
        new{L,typeof(processors),TC}(layouts, processors, textconfig)
    end
end
# Convenience constructor to convert Vector input to a column Matrix
LayoutProcessor(layout::AbstractVector, processors, textconfig) =
    LayoutProcessor(reshape(layout, length(layout), 1), processors, textconfig)

layout(p::LayoutProcessor) = p.layout
processors(p::LayoutProcessor) = p.processors
textconfig(p::LayoutProcessor) = p.textconfig

grid2image(p::LayoutProcessor, minval::Tuple, maxval::Tuple,
           data::RulesetOrSimData, grids::NamedTuple, t) = begin
    ngrids, nmin, nmax = map(length, (grids, minval, maxval))
    if !(ngrids == nmin == nmax)
        ArgumentError(
            "Number of grids ($ngrids), minval ($nmin) and maxval ($nmax) must be the same"
        ) |> throw
    end

    grid_ids = layout(p)
    sze = size(first(grids))
    img = allocimage(sze .* size(grid_ids))
    # Loop over the layout matrix
    for i in 1:size(grid_ids, 1), j in 1:size(grid_ids, 2)
        grid_id = grid_ids[i, j]
        # Accept symbol keys and numbers, skip missing/nothing/0
        (ismissing(grid_id) || grid_id === nothing || grid_id == 0)  && continue
        n = if grid_id isa Symbol
            found = findfirst(k -> k === grid_id, keys(grids))
            found === nothing && throw(ArgumentError("$grid_id is not in $(keys(grids))"))
            found
        else
            grid_id
        end
        # Run processor for section
        key = keys(grids)[n]
        _sectionloop(processors(p)[n], img, minval[n], maxval[n], data, grids[n], key, i, j)
    end
    println((textconfig(p), t))
    rendertime!(img, textconfig(p), t)
    img
end

_sectionloop(processor::SingleGridProcessor, img, minval, maxval, data, grid, key, i, j) = begin
    # We pass an empty string for time as we don't want to print it multiple times.
    section = grid2image(processor, minval, maxval, data, grid, nothing, string(key))
    @assert eltype(section) == eltype(img)
    sze = size(section)
    # Copy section into image
    for y in 1:sze[2], x in 1:sze[1]
        img[x + (i - 1) * sze[1], y + (j - 1) * sze[2]] = section[x, y]
    end
end


"""
    savegif(filename::String, o::Output, data; [processor=processor(o)], [kwargs...])

Write the output array to a gif. You must pass a processor keyword argument for any
`Output` objects not in `ImageOutput` (which allready have a processor attached).

Saving very large gifs may trigger a bug in Imagemagick.
"""
savegif(filename::String, o::Output, ruleset=Ruleset();
        processor=processor(o), minval=minval(o), maxval=maxval(o), kwargs...) = begin
    images = map(frames(o), collect(firstindex(o):lastindex(o))) do frame, t
        grid2image(processor, minval, maxval, ruleset, frame, t)
    end
    array = cat(images..., dims=3)
    FileIO.save(filename, array; kwargs...)
end


# Color manipulation tools

"""
    normalise(x, min, max)

Set a value to be between zero and one, before converting to Color.
min and max of `nothing` are assumed to be 0 and 1.
"""
normalise(x, minval::Number, maxval::Number) =
    max(min((x - minval) / (maxval - minval), oneunit(x)), zero(x))
normalise(x, minval::Number, maxval::Nothing) =
    max((x - minval) / (oneunit(x) - minval), zero(x))
normalise(x, minval::Nothing, maxval::Number) =
    min(x / maxval, oneunit(x), oneunit(x))
normalise(x, minval::Nothing, maxval::Nothing) = x

"""
    scale(x, min, max)

Rescale a value between 0 and 1 to be between `min` and `max`.
This can be used to shrink the range of a colorsheme that is displayed.
min and max of `nothing` are assumed to be 0 and 1.
"""
scale(x, min, max) = x * (max - min) + min
scale(x, ::Nothing, max) = x * max
scale(x, min, ::Nothing) = x * (oneunit(min) - min) + min
scale(x, ::Nothing, ::Nothing) = x

"""
    rgb(val)

Convert a number, tuple or color to an ARGB32 value.
"""
rgb(vals::Tuple) = ARGB32(vals...)
rgb(vals...) = ARGB32(vals...)
rgb(val::Number) = ARGB32(RGB(val))
rgb(val::Color) = ARGB32(val)
rgb(val::ARGB32) = val
"""
    rgb(scheme, val)

Convert a color scheme and value to an RGB value.
"""
rgb(scheme, val) = ARGB32(get(scheme, val))

"""
    combinebands(c::Tuple{Vararg{<:BandColor}, acc, xs)

Assign values to color bands given in any order, and output as RGB.
"""
combinebands(colors, xs) = combinebands(colors, xs, (0.0, 0.0, 0.0))
combinebands(c::Tuple{Red,Vararg}, xs, acc) =
    combinebands(tail(c), tail(xs), (acc[1] + xs[1], acc[2], acc[3]))
combinebands(c::Tuple{Green,Vararg}, xs, acc) =
    combinebands(tail(c), tail(xs), (acc[1], acc[2] + xs[1], acc[3]))
combinebands(c::Tuple{Blue,Vararg}, xs, acc) =
    combinebands(tail(c), tail(xs), (acc[1], acc[2], acc[3] + xs[1]))
combinebands(c::Tuple{Nothing,Vararg}, xs, acc) =
    combinebands(tail(c), tail(xs), acc)
combinebands(c::Tuple{}, xs, acc) = rgb(acc...)
