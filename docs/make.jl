using Documenter, RemoteREPL

makedocs(;
    modules=[RemoteREPL],
    format=Documenter.HTML(),
    pages=[
        "Overview"   => "index.md",
        "Tutorial"   => "tutorial.md",
        "How To"     => "howto.md",
        "Reference"  => "reference.md",
        "Design"     => "design.md",
    ],
    repo="https://github.com/JuliaWeb/RemoteREPL.jl/blob/{commit}{path}#L{line}",
    sitename="RemoteREPL.jl",
    authors = "Claire Foster and contributors: https://github.com/JuliaWeb/RemoteREPL.jl/graphs/contributors"
)

deploydocs(;
    repo="github.com/JuliaWeb/RemoteREPL.jl",
    devbranch="main",
    push_preview=true
)
