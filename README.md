# apt-lua
A full port of Debian APT & dpkg to ComputerCraft Lua. WIP.

## dpkg
### Working features
* Unpack, configure, and remove packages with `dpkg.lua`
* View archive info and extract packages with `dpkg-deb.lua`
* Access the dpkg database with `dpkg-query.lua`

### Features not implemented yet
* Diversions (they exist on the filesystem but the actual diversion handling is not implemented)
* Available files
* Multi-architecture (due to `craftos` arch requirement)
* Support for non-gz packages
* Changing install directories
* `--set-selections` switch in `dpkg.lua`

### How to create a package that works with dpkg-lua
The process is mostly the same as making any normal Debian package, but the architecture has to be `craftos` or `all` and the package has to be recompressed to only use gzip.
1. Create a normal Debian package tree (e.g. `debmake`)
2. Add whatever files you need to the package
    * Note: maintainer scripts should be able to be run with `shell.run`
3. Set the architecture in `debian/control` to `craftos` or `all`
4. Build the package (e.g. `debuild -us -uc`)
5. Use the included `convert_package.sh` script to recompress archive with gzip
6. Deploy package