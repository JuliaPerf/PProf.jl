# PProf.jl
*Sometimes I need a hammer, sometimes I need a drill, this is a hammer-drill*

```julia
using Profile
using PProf

# collect a profile
@profile peakflops()

# write profile to pprof format
pprof()
```
This produces a file called `profile.pb.gz` that can be read by [`pprof`](https://github.com/google/pprof).
For usage examples see the pprof docs: https://github.com/google/pprof/blob/master/doc/README.md
