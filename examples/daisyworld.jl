# # Daisyworld
# ![](daisyworld.gif)
#
# Study this example to learn about
# - Simple agent properties with complex model interactions
# - Collecting data with the low-level data collection API
# - Diffusion of a quantity in a `GridSpace`
# - the `fill_space!` function
# - represent a space "surface property" as an agent
# - counting time in the model and having time-dependent dynamics
# - data collection in a mixed-agent model
#
# ## Overview of Daisyworld
#
# This model explores the [Gaia hypothesis](https://en.wikipedia.org/wiki/Gaia_hypothesis),
# which considers the Earth as a single, self-regulating system including both living and
# non-living parts.
#
# Daisyworld is filled with black and white daisies.
# Their albedo's differ, with black daisies absorbing light and heat,
# warming the area around them; white daisies doing the opposite.
# Daisies can only reproduce within a certain temperature range, meaning too much
# (or too little) heat coming from the sun and/or surrounds will ultimately halt daisy
# propagation.
#
# When the climate is too cold it is necessary for the black daisies to propagate in order
# to raise the temperature, and vice versa -- when the climate is too warm, it is
# necessary for more white daisies to be produced in order to cool the temperature.
# The interplay of the living and non living aspects of this world manages to find an
# equilibrium over a wide range of parameter settings, although with enough external
# forcing, the daisies will not be able to regulate the temperature of the planet
# and eventually go extinct.

# ## Defining the agent types

# `Daisy` has three values (other than the required
# `id` and `pos` for an agent that lives on a [`GridSpace`](@ref). Each daisy has an `age`,
# confined later by a maximum age set by the user, a `breed` (either `:black` or `:white`)
# and an associated `albedo` value, again set by the user.
# `Land` represents the surface. We could make `Land` also have an albedo field, but
# in this world, the entire surface has the same albedo and thus we make it a model parameter.

# Notice that the `Land` does not necessarily have to be an agent, and one could represent
# surface temperature via a matrix (parameter of the model). This is done in an older version,
# see file `examples/daisyworld_matrix.jl`. The old version has a slight performance advantage.
# However, the advantage of making the surface composed of
# agents is that visualization is simple and one can use the interactive application to also
# visualize surface temperature.

using Agents, AgentsPlots, Plots
using Statistics: mean
using Random # hide
gr() # hide

mutable struct Daisy <: AbstractAgent
    id::Int
    pos::Tuple{Int,Int}
    breed::Symbol
    age::Int
    albedo::Float64 # 0-1 fraction
end

mutable struct Land <: AbstractAgent
    id::Int
    pos::Tuple{Int,Int}
    temperature::Float64
end

const DaisyWorld = ABM{Union{Daisy, Land}};

# ## World heating

# The surface temperature of the world is heated by its sun, but daisies growing upon it
# absorb or reflect the starlight -- altering the local temperature.

function update_surface_temperature!(node::Int, model::DaisyWorld)
    ids = get_node_contents(node, model)
    ## All grid points have at least one agent (the land)
    absorbed_luminosity = if length(ids) == 1
        ## Set luminosity via surface albedo
        (1 - model.surface_albedo) * model.solar_luminosity
    else
        ## more than 1 agents: daisy exists
        ## Set luminosity via daisy albedo
        (1 - model[ids[2]].albedo) * model.solar_luminosity
    end
    ## We expect local heating to be 80 ᵒC for an absorbed luminosity of 1,
    ## approximately 30 for 0.5 and approximately -273 for 0.01.
    local_heating = absorbed_luminosity > 0 ? 72 * log(absorbed_luminosity) + 80 : 80
    ## Surface temperature is the average of the current temperature and local heating.
    T0 = model[ids[1]].temperature
    model[ids[1]].temperature = (T0 + local_heating) / 2
end

# In addition, temperature diffuses over time
function diffuse_temperature!(node::Int, model::DaisyWorld)
    ratio = get(model.properties, :ratio, 0.5) # diffusion ratio
    ids = space_neighbors(node, model)
    meantemp = sum(model[i].temperature for i in ids if model[i] isa Land)/8
    land = model[get_node_contents(node, model)[1]] # land at current node
    ## Each neighbor land patch is giving up 1/8 of the diffused
    ## amount to each of *its* neighbors
    land.temperature = (1 - ratio)*land.temperature + ratio*meantemp
end

# ## Daisy dynamics

# The final piece of the puzzle is the life-cycle of each daisy. This method defines an
# optimal temperature for growth. If the temperature gets too hot or too cold, daisies
# will not wish to propagate. So long as the temperature is favorable,
# daisies compete for land and attempt to spawn a new plant of their `breed` in locations
# close to them.

function propagate!(node::Int, model::DaisyWorld)
    ids = get_node_contents(node, model)
    if length(ids) > 1
        daisy = model[ids[2]]
        temperature = model[ids[1]].temperature
        ## Set optimum growth rate to 22.5 ᵒC, with bounds of [5, 40]
        seed_threshold = (0.1457 * temperature - 0.0032 * temperature^2) - 0.6443
        if rand() < seed_threshold
            ## Collect all adjacent cells that have no daisies
            empty_neighbors = Int[]
            neighbors = node_neighbors(node, model)
            for n in neighbors
                if length(get_node_contents(n, model)) == 1
                    push!(empty_neighbors, n)
                end
            end
            if !isempty(empty_neighbors)
                ## Seed a new daisy in one of those cells
                seeding_place = vertex2coord(rand(empty_neighbors), model)
                a = Daisy(nextid(model), seeding_place, daisy.breed, 0, daisy.albedo)
                add_agent_pos!(a, model)
            end
        end
    end
end

# And if the daisies cross an age threshold, they die out.
# Death is controlled by the `agent_step` function
function agent_step!(agent::Daisy, model::DaisyWorld)
    agent.age += 1
    agent.age >= model.max_age && kill_agent!(agent, model)
end

# We also need to define a version for the `Land` instances
# (the dynamics of the `Land` are resolved at model level)
agent_step!(agent::Land, model::DaisyWorld) = nothing

# The model step function and agent step functions for Agents.jl to advance
# Daisyworld's dynamics. Since we have constructed a number of helper functions,
# these methods are quite straightforward.

function model_step!(model)
    for n in nodes(model)
        update_surface_temperature!(n, model)
        diffuse_temperature!(n, model)
        propagate!(n, model)
    end
    model.tick += 1
    solar_activity!(model)
end

# Notice that `solar_activity!` changes the incoming solar radiation over time,
# if the given "scenario" (a model parameter) is `:ramp`.
# The parameter `tick` of the model keeps track of time.

function solar_activity!(model::DaisyWorld)
    if model.scenario == :ramp
        if model.tick > 200 && model.tick <= 400
            model.solar_luminosity += model.solar_change
        end
        if model.tick > 500 && model.tick <= 750
            model.solar_luminosity -= model.solar_change/2
        end
    elseif model.scenario == :change
        model.solar_luminosity += model.solar_change
    end
end

# ## Initialising Daisyworld

# Here, we construct a function to initialize a Daisyworld. We use [`fill_space!`](@ref)
# to fill the space with `Land` instances. Then, we need to know how many
# daisies of each type to seed the planet with and what their albedo's are.
# We also want a value for surface albedo, as well as solar intensity
# (and we also choose between constant or time-dependent intensity with `scenario`).

import StatsBase
import DrWatson: @dict

function daisyworld(;
        griddims = (30, 30),
        max_age = 25,
        init_white = 0.2, # % cover of the world surface of white breed
        init_black = 0.2, # % cover of the world surface of black breed
        albedo_white = 0.75,
        albedo_black = 0.25,
        surface_albedo = 0.4,
        solar_change = 0.005,
        solar_luminosity = 1.0, # initial luminosity
        scenario = :default,
    )

    space = GridSpace(griddims, moore = true, periodic = true)
    properties = @dict max_age surface_albedo solar_luminosity solar_change scenario
    properties[:tick] = 0
    ## create a scheduler that only schedules Daisies
    daisysched(model) = [a.id for a in allagents(model) if a isa Daisy]
    model = ABM(Union{Daisy, Land}, space;
        scheduler = daisysched, properties = properties, warn = false
    )

    ## fill model with `Land`: every grid cell has 1 land instance
    fill_space!(Land, model, 0.0) # zero starting temperature

    ## Populate with daisies: each cell has only one daisy (black or white)
    white_nodes = StatsBase.sample(1:nv(space), Int(init_white * nv(space)); replace = false)
    for n in white_nodes
        wd = Daisy(nextid(model), vertex2coord(n, space), :white, rand(0:max_age), albedo_white)
        add_agent_pos!(wd, model)
    end
    allowed = setdiff(1:nv(space), white_nodes)
    black_nodes = StatsBase.sample(allowed, Int(init_black * nv(space)); replace = false)
    for n in black_nodes
        wd = Daisy(nextid(model), vertex2coord(n, space), :black, rand(0:max_age), albedo_black)
        add_agent_pos!(wd, model)
    end

    return model
end

# ## Visualizing & animating
# %% #src
# Lets run the model with constant solar isolation and visualize the result

cd(@__DIR__) #src
Random.seed!(165) # hide
model = daisyworld()

# To visualize we need to define the necessary functions for [`plotabm`](@ref).
# The daisies will obviously be black or white, but the land will have a color
# that reflects its temperature, with -50 darkest and 100 ᵒC brightest color

daisycolor(a::Daisy) = a.breed
const landcolor = cgrad(:thermal)
daisycolor(a::Land) = landcolor[(a.temperature+50)/150]

# And we plot daisies as circles, and land patches as squares
daisyshape(a::Daisy) = :circle
daisysize(a::Daisy) = 7
daisyshape(a::Land) = :square
daisysize(a::Land) = 8.8

# Notice that we want to ensure that the `Land` patches are always plotted first.
plotsched = by_type((Land, Daisy), false)

plotkwargs = (
    ac = daisycolor, am = daisyshape, as = daisysize,
    scheduler = plotsched, aspect_ratio = 1, size = (600, 600), showaxis = false,
)

p = plotabm(model; plotkwargs...)

# And after a couple of steps
step!(model, agent_step!, model_step!, 5)
p = plotabm(model; plotkwargs...)

# Let's do some animation now
Random.seed!(165) # hide
model = daisyworld()
anim = @animate for i in 0:30
    p = plotabm(model; plotkwargs...)
    title!(p, "step $(i)")
    step!(model, agent_step!, model_step!)
end
gif(anim, "daisyworld.gif", fps = 3)

# Running this animation for longer hints that this world achieves quasi-equilibrium
# for some input parameters, where one `breed` does not totally dominate the other.
# Of course we can check this easily through data collection.
# Notice that here we have to define a function `breed` that gives the daisy's `breed`
# field. We cannot use just `:breed` to automatically find it, because in this mixed
# agent model, the `Land` doesn't have any `breed`.
# %% #src
black(y) = count(x -> x == :black, y)
white(y) = count(x -> x == :white, y)
breed(a) = a isa Daisy ? a.breed : :land
adata = [(breed, black), (breed, white)]

Random.seed!(165) # hide
model = daisyworld(; solar_luminosity = 1.0)

agent_df, model_df = run!(model, agent_step!, model_step!, 1000; adata = adata)

p = plot(agent_df[!, :step], agent_df[!, :black_breed], label = "black")
plot!(p, agent_df[!, :step], agent_df[!, :white_breed], label = "white")
plot!(p; xlabel = "tick", ylabel = "daisy count")

# ## Time dependent dynamics
# %% #src

# To use the time-dependent dynamics we simple use the keyword `scenario = :ramp` during
# model creation. However, we also want to see how the planet surface temperature changes
# and would be nice to plot solar luminosity as well.
# Thus, we define in addition
gettemperature(a) = a isa Land ? a.temperature : missing
meantemperature(x) = mean(skipmissing(x))
adata = [(breed, black), (breed, white), (gettemperature, meantemperature)]

# And, to have it as reference, we also record the solar luminosity value
mdata = [:solar_luminosity]

# And we run (and plot) everything
Random.seed!(165) # hide
model = daisyworld(solar_luminosity = 1.0, scenario = :ramp)
agent_df, model_df = run!(model, agent_step!, model_step!, 1000; adata = adata, mdata = mdata)

p = plot(agent_df[!, :step], agent_df[!, :black_breed], label = "black")
plot!(p, agent_df[!, :step], agent_df[!, :white_breed], label = "white")
plot!(p; xlabel = "tick", ylabel = "daisy count")

p2 = plot(agent_df[!, :step], agent_df[!, aggname(adata[3])], ylabel = "temperature")
p3 = plot(model_df[!, :step], model_df[!, :solar_luminosity], ylabel = "L", xlabel = "ticks")

plot(p, p2, p3, layout = (3, 1))
