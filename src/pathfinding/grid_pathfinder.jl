export CostMetric,
    DirectDistance,
    Chebyshev,
    HeightMap,
    AStar,
    delta_cost,
    find_path,
    set_target!,
    is_stationary,
    heightmap

"""
    Path{D}
An alias for `MutableLinkedList{Dims{D}}`. Used to represent the path to be
taken by an agent in a `D` dimensional [`GridSpace{D}`](@ref).
"""
const Path{D} = MutableLinkedList{Dims{D}}

"""
    CostMetric{D}
An abstract type representing a metric that measures the approximate cost of travelling
between two points in a `D` dimensional [`GridSpace{D}`](@ref). A struct with this as its
base type is used as the `cost_metric` for [`AStar`](@ref). To define a custom metric,
define a struct with this as its base type and a corresponding method for [`delta_cost`](@ref).
"""
abstract type CostMetric{D} end

struct DirectDistance{D} <: CostMetric{D}
    direction_costs::Vector{Int}
end

Base.show(io::IO, metric::DirectDistance) = print(io, "DirectDistance")

"""
    DirectDistance{D}(direction_costs::Vector{Int}=[floor(Int, 10.0*√x) for x in 1:D])
The default cost metric for [`AStar`](@ref). Distance is approximated as the shortest path between
the two points, where from any tile it is possible to step to any of its Moore neighbors.
`direction_costs` is a `Vector{Int}` where `direction_costs[i]` represents the cost of
going from a tile to the neighbording tile on the `i` dimensional diagonal. The default value is
`10√i` for the `i` dimensional diagonal, rounded down to the nearest integer.

If `moore_neighbors=false` in the [`AStar`](@ref) struct, then it is only possible to step to
VonNeumann neighbors. In such a case, only `direction_costs[1]` is used.
"""
DirectDistance{D}() where {D} = DirectDistance{D}([floor(Int, 10.0 * √x) for x in 1:D])

"""
    Chebyshev{D}()
Distance between two tiles is approximated as the Chebyshev distance (maximum of absolute
difference in coordinates) between them.
"""
struct Chebyshev{D} <: CostMetric{D} end

Base.show(io::IO, metric::Chebyshev) = print(io, "Chebyshev")

struct HeightMap{D} <: CostMetric{D}
    base_metric::CostMetric{D}
    hmap::Array{Int,D}
end

Base.show(io::IO, metric::HeightMap) =
    print(io, "HeightMap with base: $(metric.base_metric)")

"""
    HeightMap(hmap::Array{Int,D})
    HeightMap(hmap::Array{Int,D}, ::Type{<:CostMetric})
An alternative [`CostMetric`](@ref). This allows for a `D` dimensional heightmap to be provided as a
`D` dimensional integer array, of the same size as the corresponding [`GridSpace{D}`](@ref). This metric
approximates the distance between two positions as the sum of the shortest distance between them and the absolute
difference in heights between the two positions. The shortest distance is calculated using the underlying
`base_metric` field, which defaults to [`DirectDistance`](@ref)
"""
HeightMap(hmap::Array{Int,D}) where {D} = HeightMap{D}(DirectDistance{D}(), hmap)

HeightMap(hmap::Array{Int,D}, ::Type{M}) where {D,M<:CostMetric} =
    HeightMap{D}(M{D}(), hmap)

struct AStar{D,P,M} <: AbstractPathfinder
    agent_paths::Dict{Int,Path{D}}
    grid_dims::Dims{D}
    neighborhood::Vector{CartesianIndex{D}}
    admissibility::AbstractFloat
    walkable::Array{Bool,D}
    cost_metric::CostMetric{D}

    function AStar{D,P,M}(
        agent_paths::Dict,
        grid_dims::Dims{D},
        neighborhood::Vector{CartesianIndex{D}},
        admissibility::AbstractFloat,
        walkable::Array{Bool,D},
        cost_metric::CostMetric{D},
    ) where {D,P,M}

        @assert typeof(cost_metric) != HeightMap{D} || size(cost_metric.hmap) == grid_dims "Heightmap dimensions must be same as provided space"
        new(agent_paths, grid_dims, neighborhood, admissibility, walkable, cost_metric)
    end
end

"""
    AStar(space::GridSpace; kwargs...)
Stores path data of agents, and relevant pathfinding grid data. The dimensions are taken to be those of the space.

## Keywords
- `moore_neighbors::Bool=true` specifies if movement can be to Moore neighbors of a tile, or only Von Neumann neighbors.
- `admissibility::AbstractFloat=0.0` specifies how much a path can deviate from optimality, in favour of faster
  pathfinding. For an admissibility value of `ε`, a path with at most `(1+ε)` times the optimal path length will be
  calculated, exploring fewer nodes in the process. A value of `0` always finds the optimal path.
- `walkable::Array{Bool,D}=fill(true, size(space.s))` is used to specify (un)walkable positions of the space.
  Unwalkable positions are never part of any paths. By default, all positions are assumed to be walkable.
- `cost_metric::Union{Type{M},M} where {M<:CostMetric}=DirectDistance` specifies the metric used to approximate the
  distance between any two walkable points on the grid.
"""
function AStar(
    space::GridSpace{D,P};
    moore_neighbors::Bool = true,
    admissibility::AbstractFloat = 0.0,
    walkable::Array{Bool,D} = fill(true, size(space.s)),
    cost_metric::Union{Type{M},M} = DirectDistance,
) where {D,P,M<:CostMetric}

    @assert admissibility >= 0 "Invalid value for admissibility: $admissibility ≱ 0"

    neighborhood = moore_neighbors ? moore_neighborhood(D) : vonneumann_neighborhood(D)
    if typeof(cost_metric) <: CostMetric
        metric = cost_metric
    else
        metric = cost_metric{D}()
    end
    return AStar{D,P,moore_neighbors}(
        Dict{Int,Path{D}}(),
        size(space.s),
        neighborhood,
        admissibility,
        walkable,
        metric,
    )
end

moore_neighborhood(D) = [
    CartesianIndex(a)
    for a in Iterators.product([-1:1 for φ in 1:D]...) if a != Tuple(zeros(Int, D))
]

function vonneumann_neighborhood(D)
    hypercube = CartesianIndices((repeat([-1:1], D)...,))
    [β for β ∈ hypercube if LinearAlgebra.norm(β.I) == 1]
end

function Base.show(io::IO, pathfinder::AStar{D,P,M}) where {D,P,M}
    periodic = P ? "periodic, " : ""
    moore = M ? "moore, " : ""
    s = "A* in $(D) dimensions. $(periodic)$(moore)ϵ=$(pathfinder.admissibility), metric=$(pathfinder.cost_metric)"
    print(io, s)
end

"""
    position_delta(pathfinder::AStar{D}, from::NTuple{Int,D}, to::NTuple{Int,D})
Returns the absolute difference in coordinates between `from` and `to` taking into account periodicity of `pathfinder`.
"""
position_delta(pathfinder::AStar{D,true}, from::Dims{D}, to::Dims{D}) where {D} =
    min.(abs.(to .- from), pathfinder.grid_dims .- abs.(to .- from))

position_delta(pathfinder::AStar{D,false}, from::Dims{D}, to::Dims{D}) where {D} =
    abs.(to .- from)

"""
    delta_cost(pathfinder::AStar{D}, from::NTuple{D, Int}, to::NTuple{D, Int})
Calculates and returns an approximation for the cost of travelling from `from` to `to`. This calls the corresponding
`delta_cost(pathfinder, pathfinder.cost_metric, from, to)` function. In the case of a custom metric, define a method for
the latter function.
"""
function delta_cost(
    pathfinder::AStar{D,periodic,true},
    metric::DirectDistance{D},
    from::Dims{D},
    to::Dims{D},
) where {D,periodic}
    delta = collect(position_delta(pathfinder, from, to))

    sort!(delta)
    carry = 0
    hdist = 0
    for i in D:-1:1
        hdist += metric.direction_costs[i] * (delta[D+1-i] - carry)
        carry = delta[D+1-i]
    end
    return hdist
end

function delta_cost(
    pathfinder::AStar{D,periodic,false},
    metric::DirectDistance{D},
    from::Dims{D},
    to::Dims{D},
) where {D,periodic}
    delta = position_delta(pathfinder, from, to)

    return sum(delta) * metric.direction_costs[1]
end

delta_cost(
    pathfinder::AStar{D},
    metric::Chebyshev{D},
    from::Dims{D},
    to::Dims{D},
) where {D} = max(position_delta(pathfinder, from, to)...)

delta_cost(
    pathfinder::AStar{D},
    metric::HeightMap{D},
    from::Dims{D},
    to::Dims{D},
) where {D} =
    delta_cost(pathfinder, metric.base_metric, from, to) +
    abs(metric.hmap[from...] - metric.hmap[to...])

delta_cost(pathfinder::AStar{D}, from::Dims{D}, to::Dims{D}) where {D} =
    delta_cost(pathfinder, pathfinder.cost_metric, from, to)

struct GridCell
    f::Int
    g::Int
    h::Int
end

GridCell(g::Int, h::Int, admissibility::AbstractFloat) =
    GridCell(round(Int, g + (1 + admissibility) * h), g, h)

GridCell() = GridCell(typemax(Int), typemax(Int), typemax(Int))

"""
    find_path(pathfinder::AStar{D}, from::NTuple{D,Int}, to::NTuple{D,Int})
Using the specified [`AStar`](@ref), calculates and returns the shortest path from `from` to `to` using the A* algorithm.
Paths are returned as a `MutableLinkedList` of sequential grid positions. If a path does not exist between the given 
positions, this returns an empty linked list. This function usually does not need to be called explicitly, instead
the use the provided [`set_target!`](@ref) and [`move_agent!`](@ref) functions.
"""
function find_path(pathfinder::AStar{D}, from::Dims{D}, to::Dims{D}) where {D}
    grid = Dict{Dims{D},GridCell}()
    parent = Dict{Dims{D},Dims{D}}()

    open_list = MutableBinaryMinHeap{Tuple{Int,Dims{D}}}()
    open_list_handles = Dict{Dims{D},Int64}()
    closed_list = Set{Dims{D}}()

    grid[from] = GridCell(0, delta_cost(pathfinder, from, to), pathfinder.admissibility)
    push!(open_list, (grid[from].f, from))

    while !isempty(open_list)
        _, cur = pop!(open_list)
        cur == to && break
        push!(closed_list, cur)

        nbors = get_neighbors(cur, pathfinder)
        for nbor in Iterators.filter(n -> inbounds(n, pathfinder, closed_list), nbors)
            nbor_cell = haskey(grid, nbor) ? grid[nbor] : GridCell()
            new_g_cost = grid[cur].g + delta_cost(pathfinder, cur, nbor)

            if new_g_cost < nbor_cell.g
                parent[nbor] = cur
                grid[nbor] = GridCell(
                    new_g_cost,
                    delta_cost(pathfinder, nbor, to),
                    pathfinder.admissibility,
                )
                if haskey(open_list_handles, nbor)
                    update!(open_list, open_list_handles[nbor], (grid[nbor].f, nbor))
                else
                    open_list_handles[nbor] = push!(open_list, (grid[nbor].f, nbor))
                end
            end
        end
    end

    agent_path = Path{D}()
    cur = to
    while true
        haskey(parent, cur) || break
        pushfirst!(agent_path, cur)
        cur = parent[cur]
    end
    return agent_path
end

@inline get_neighbors(cur, pathfinder::AStar{D,true}) where {D} =
    (mod1.(cur .+ β.I, pathfinder.grid_dims) for β in pathfinder.neighborhood)
@inline get_neighbors(cur, pathfinder::AStar{D,false}) where {D} =
    (cur .+ β.I for β in pathfinder.neighborhood)
@inline inbounds(n, pathfinder, closed) =
    all(1 .<= n .<= pathfinder.grid_dims) && pathfinder.walkable[n...] && n ∉ closed

"""
    set_target!(agent::A, target::NTuple{D,Int}, model::ABM{<:GridSpace,A,<:AStar{D}})
This calculates and stores the shortest path to move the agent from its current position to `target`
using [`find_path`](@ref).
"""
function set_target!(
    agent::A,
    target::Dims{D},
    model::ABM{<:GridSpace{D},A,<:AStar{D}},
) where {D,A<:AbstractAgent}
    model.pathfinder.agent_paths[agent.id] = find_path(model.pathfinder, agent.pos, target)
end

"""
    is_stationary(agent, model::ABM{<:GridSpace,A,<:AStar{D}})
Return `true` if agent has reached it's target destination, or no path has been set for it.
"""
is_stationary(agent, model) = isempty(agent.id, model.pathfinder)

Base.isempty(id::Int, pathfinder::AStar) =
    !haskey(pathfinder.agent_paths, id) || isempty(pathfinder.agent_paths[id])

"""
    heightmap(model::ABM{<:GridSpace{D},A,<:AStar{D})
Return the heightmap of the pathfinder if the [`HeightMap`](@ref) metric is in use,
`nothing` otherwise.
"""
function heightmap(model::ABM{<:GridSpace{D},A,<:AStar{D}}) where {D,A}
    if model.pathfinder.cost_metric isa HeightMap
        return model.pathfinder.cost_metric.hmap
    else
        return nothing
    end
end

"""
    walkmap(model::ABM{<:GridSpace{D},A,<:AStar{D})
Return the walkable map of the pathfinder
"""
walkmap(model::ABM{<:GridSpace{D},A,<:AStar{D}}) where {D,A} = model.pathfinder.walkable

"""
    move_agent!(agent::A, model::ABM{<:GridSpace,A,<:AStar})
Moves the agent along the path to its target set by [`set_target!`](@ref). If the agent does
not have a precalculated path, or the path is empty, the agent does not move.
"""
function move_agent!(
    agent::A,
    model::ABM{<:GridSpace{D},A,<:AStar{D}},
) where {D,A<:AbstractAgent}
    isempty(agent.id, model.pathfinder) && return

    move_agent!(agent, first(model.pathfinder.agent_paths[agent.id]), model)
    popfirst!(model.pathfinder.agent_paths[agent.id])
end

function kill_agent!(
    agent::A,
    model::ABM{<:GridSpace{D},A,<:AStar{D}},
) where {D,A<:AbstractAgent}
    delete!(model.pathfinder.agent_paths, agent.id)
    delete!(model.agents, agent.id)
    remove_agent_from_space!(agent, model)
end