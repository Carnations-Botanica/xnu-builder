<h1 align="center">xnu-builder</h1>

<h5 align="center">A repository designed to automate the building of the latest Carnations XNU kernel source and its dependencies.</h5>

```bash
Usage:   ./build.sh [options] <action>
Example: ./build.sh fetch
Example: ./build.sh clean
Example: ./build.sh build -k DEVELOPMENT -a X86_64
Example: ./build.sh build -k RELEASE -a ARM64 -m VMAPPLE

Actions:
  fetch       Fetch the Carnations XNU Source Code
  clean       Clean build artifacts
  build       Build the source code

Options:
  -h, --help         Show this help message
  -v, --version      Show the version of the script
  -k, --kerneltype   Set kernel type (RELEASE / DEVELOPMENT)
  -a, --arch         Set architecture (x86_64 / ARM64)
  -m, --machine      Set machine configuration (T8101, T8103, T6000, VMAPPLE for ARM64 only)
```

The full instructions have yet to be written, but the purpose of this tool is to require the least amount of setup from the end-user, to get a functional booting build of the latest XNU source code, with the modifications made from Carnations Botanica. While there is support for official XNU source code, it must be manually configured.
