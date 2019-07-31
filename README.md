# PProf.jl

[![Build Status](https://travis-ci.com/vchuravy/PProf.jl.svg?branch=master)](https://travis-ci.com/vchuravy/PProf.jl)


*Sometimes I need a hammer, sometimes I need a drill, this is a hammer-drill*

```julia
using Profile
using PProf

# collect a profile
@profile peakflops()

# Export pprof profile and open interactive profiling web interface.
pprof()
```

This opens a webpage in your browser to inspect the profile you've collected. It produces a file called `profile.pb.gz` that can be read by [`pprof`](https://github.com/google/pprof), and then opens the `pprof` tool in interactive, "web" mode.

For more usage examples see the pprof docs: https://github.com/google/pprof/blob/master/doc/README.md

## Dependencies
- [Graphviz](https://www.graphviz.org/)
    - In order to use pprof's web graph view (which is one of the best parts of pprof), you need to have graphviz installed.

## Usage
```julia
  pprof(data, period;
          web = true, webhost = "localhost", webport = 57599,
          out = "profile.pb.gz", from_c = true, drop_frames = "", keep_frames = "")

  Fetches and converts Profile data to the pprof format.
```

## Google PProf Web View
<img width=500px src="docs/graph.png" alt="graph"/>

!["flamegraph"](docs/flamegraph.png)
