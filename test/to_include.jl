include("subincludes/subinclude1.jl")

module IncludedModule
    include("subincludes/subinclude3.jl")
end

var_in_included_file = 12345
