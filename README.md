# The Universal Headers Project

This project distributes a set of C headers (.h files) that are compatible with
widely used libcs for various targets.

Instead of copy+pasting N different libc header files, and requiring the use of
`-I` in C compiler invocations, this repository provides cleaned up headers
which use the C preprocessor in order to automatically support different targets
with the same set of includes.

The main purpose of this project is for simplicity and smaller installation size
for the use case of cross-compiling.

In the context of Zig, this project exists to facilitate
[ziglang/zig#2879](https://github.com/ziglang/zig/issues/2879).
Idea being that the end-result we want to eventually accomplish, is a set of
multi-target C headers (this project) plus implementations of the functions in
Zig. The C header from this project would be periodically synchronized into the
Zig repository upstream.

## Supported Targets

 * [Mingw-w64](http://mingw-w64.org/) Headers
   - x86_64-windows-gnu
   - i386-windows-gnu
   - aarch64-windows-gnu
   - arm-windows-gnu
 * [Musl](http://musl.libc.org/) Headers
   - x86_64-linux-musl
   - i386-linux-musl
   - aarch64-linux-musl
   - arm-linux-musl
   - mips64-linux-musl
   - mips-linux-musl
   - powerpc64-linux-musl
   - powerpc-linux-musl
   - riscv64-linux-musl
   - s390x-linux-musl
 * [glibc](https://www.gnu.org/software/libc/) Headers
   - x86_64-linux-gnu
   - x86_64-linux-gnux32
   - i386-linux-gnu
   - aarch64-linux-gnu
   - aarch64_be-linux-gnu
   - arm-linux-gnueabi
   - arm-linux-gnueabihf
   - armeb-linux-gnueabi
   - armeb-linux-gnueabihf
   - csky-linux-gnueabi
   - csky-linux-gnueabihf
   - mips-linux-gnu
   - mips64-linux-gnuabi64
   - mips64-linux-gnuabin32
   - mips64el-linux-gnuabi64
   - mips64el-linux-gnuabin32
   - mipsel-linux-gnu
   - powerpc-linux-gnu
   - powerpc64-linux-gnu
   - powerpc64le-linux-gnu
   - riscv64-linux-gnu
   - s390x-linux-gnu
   - sparc-linux-gnu
   - sparcv9-linux-gnu
 * MacOS
   - aarch64-macos-gnu
   - x86_64-macos-gnu
 * Not associated with any particular implementation:
   - wasm-wasi-musl
   - wasm-freestanding-musl

## License

This project is MIT (Expat) licensed. It contains derived work from various
other licenses:
 
 * Public Domain
 * APSL
