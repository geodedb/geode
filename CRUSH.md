# GPU linking notes

When building with system libdl and CUDA driver present, set the following in build.zig or environment:

- Linker will resolve __libc_dlopen/__libc_dlsym/__libc_dlclose and cuInit if system libraries are present.
- The code falls back to runtime stubs when symbols are not available.

If you want to force linking against libdl and libcuda add linker options in build.zig or pass -lc -lcuda to link step.
