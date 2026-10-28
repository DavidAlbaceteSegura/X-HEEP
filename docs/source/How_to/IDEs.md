# Set up an IDE

For FW development, `X-HEEP` can be used together with different Integrated Development Environments (IDEs) flavours. Up to now, full support is just provided by [Segger Embedded Studio (SES)](https://www.segger.com/products/development-tools/embedded-studio/editions/risc-v/). This readme guides you through all the needed steps to build `X-HEEP` applications with SES for the pynq-z2 board.

## SES installation

The platform was only tested under Linux and version 7.32 of the Embedded Studio for RISC-V. Please, go to the Segger [download center](https://www.segger.com/downloads/embedded-studio/) to get that version. It is assumed that you have already installed the RISC-V compiler. If not, check the main [README](https://github.com/x-heep/x-heep#setup) please.

## Configuration

After installing SES, you need to indicate to Segger your Toolchain directory (RISC-V Compiler) in the `xheep.emProject` file, **line 62**:
```
build_toolchain_directory="/home/< user >/tools/riscv/bin"
```
Please, substitute that path to your current path where the RISC-V compiler was installed. Do not forget to target the `bin` folder inside the installation folder of the toolchain.

## Building

Once the paths are set properly, you can open `xheep.emProject` with SES. That will launch SES with one solution already configured, `xheep_ses`, and one project into that solution `helloworld`. Note that this project has already everything configured to run the `helloworld` application of the main repo, i.e. all the source files are linked to the project as well as the `c user include directories` already set up. Moreover, this project is configured to compile and link by using the on-chip linker `sw/linker/link.ld`. If you want to change any of these options, you will need to change the options of the project or the options of the solution. Note that the project is currently set-up to be working on the `Debug_External` configuration. Please, do not move to other configuration when building. Finally, to build the whole project just press `F7` or `Build > Build helloworld`.

The output should be like this:

![SES Build](/images/ses_build.png)

Note that on the right part, you have the memory usage based on the linker we have configured. If you do not see this, you can activate that view in `View > Memory Usage`.
