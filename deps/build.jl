# THIS FILE WAS MANUALLY CONSTRUCTED FOLLOWING THE STRUCTURE OF BINARYPROVIDER

using BinaryProvider

# Parse some basic command-line arguments
const verbose = "--verbose" in ARGS
const prefix = Prefix(get([a for a in ARGS if a != "--verbose"], 1, joinpath(@__DIR__, "usr")))

# Instantiate products:
go_pprof = ExecutableProduct(prefix, "pprof", :go_pprof)
products = [go_pprof]

# Download binaries from hosted location
bin_prefix = "https://github.com/vchuravy/PProf.jl/releases/download/v0.1.2-dev"

# Listing of files generated by BinaryBuilder:
download_info = Dict(
    BinaryProvider.Linux(:aarch64, :glibc) => ("$bin_prefix/pprof_linux_arm64.tar.gz", "50eda2201fb102a6b1ed1a8be492643dd9d8b5326ec98f22ab4a8863c7976a22"),
    BinaryProvider.Linux(:armv7l, :glibc)  => ("$bin_prefix/pprof_linux_arm.tar.gz", "2979cdbbc4f2f2317364c1711bcd87610b8b2642d6319cc40096aa065fb017b0"),
    BinaryProvider.Linux(:i686, :glibc)    => ("$bin_prefix/pprof_linux_386.tar.gz", "304d7e361dec38cb09c97376aeb960b015b249a8bc40b9324e10d77880805a63"),
    BinaryProvider.Linux(:powerpc64le, :glibc) => ("$bin_prefix/pprof_linux_ppc64.tar.gz", "f06326b9d332df022d305d00a1c860674461ae68df4608b19a424e2dff418b7e"),
    BinaryProvider.Linux(:x86_64, :glibc)  => ("$bin_prefix/pprof_linux_amd64.tar.gz", "544761d1363dcf5081a0f74433b5885c3d81d1410b1850dbd38dd6f785a73015"),

    BinaryProvider.FreeBSD(:x86_64)        => ("$bin_prefix/pprof_freebsd_386.tar.gz", "deb6809bc15f4047c92e167eeaec2b4fc546f97676f4521ede5935f226ea7c10"),
    BinaryProvider.FreeBSD(:armv7l)        => ("$bin_prefix/pprof_freebsd_arm.tar.gz", "5c495ea30f503449160b7da6f36edf2e1c4b13a522a6d32b19eee5759a6a3898"),
    BinaryProvider.FreeBSD(:aarch64)        => ("$bin_prefix/pprof_freebsd_amd64.tar.gz", "de8671f6c71a41d54c19584132056cf938f5fdf3f3317cf0abf5d4aa58c50c9a"),

    BinaryProvider.MacOS(:x86_64)          => ("$bin_prefix/pprof_darwin_amd64.tar.gz", "93f5c227af23ade110fedbd07eff0bd57644fec0cde77ad359515bb254c43802"),

    BinaryProvider.Windows(:i686)          => ("$bin_prefix/pprof_windows_386.exe.tar.gz", "90a343e9ae8888c0f52322761dc028d9c7edf4a202e81aea2989ac182e77010c"),
    BinaryProvider.Windows(:x86_64)        => ("$bin_prefix/pprof_windows_amd64.exe.tar.gz", "21702d1f7317d969a283d094898e92ba3da4961c419c5351d359f3abf0894d43"),
)

# First, check to see if we're all satisfied
if any(!satisfied(p; verbose=verbose) for p in products)
    try
        # Download and install binaries
        url, tarball_hash = choose_download(download_info)
        install(url, tarball_hash; prefix=prefix, force=true, verbose=true)
        # NHDALY MANUALLY ADDED THESE LINES TO HOOK UP THE BINARY
        bin = mkpath(joinpath(prefix, "bin"))
        dir = splitext(splitext(basename(url))[1])[1]
        @show dir
        cp(joinpath(prefix, dir, "pprof"), joinpath(bin, "pprof"))
    catch e
        if typeof(e) <: ArgumentError
            error("Your platform $(Sys.MACHINE) is not supported by this package!")
        else
            rethrow(e)
        end
    end

    # Finally, write out a deps.jl file
    write_deps_file(joinpath(@__DIR__, "deps.jl"), products)
end
