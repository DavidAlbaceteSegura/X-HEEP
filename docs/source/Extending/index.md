# eXtending X-HEEP

X-HEEP is meant to be extended with your own custom IPs. X-HEEP itself possesses a hardware-software framework capable of working standalone. If you want to extend it, you will need to merge your hardware and software with X-HEEP's.

For this purpose we support the [CV-X-IF](https://docs.openhwgroup.org/projects/openhw-group-core-v-xif/en/latest/intro.html) interface with the [cv32e40px](https://github.com/x-heep/cv32e40px) or [cv32e40x](https://github.com/openhwgroup/cv32e40x) or [cv32e20](https://github.com/openhwgroup/cve2) RISC-V CPUs, and we expose master and slave ports to/from the bus.

> We recommend using the cv32e40px for pairing with your CV-X-IF compliant coprocessor. If you choose to use the cv32e40x, X-HEEP currently uses the revision [`0.9.0`](https://github.com/openhwgroup/cv32e40x/commit/f17028f2369373d9443e4636f2826218e8d54e0f). It is recommended to use the same revision in peripheral IPs to prevent conflicts during RTL compilation. While the cv32e20 does not support custom memory instructions.

The X-HEEP testbench only connects to the pads of X-HEEP (see [Testbench](../How_to/Testbench.md)): the bus ports and the CV-X-IF are tied off, so a coprocessor or bus device has to be integrated in your own system.

To learn how to extend X-HEEP you can read the guides in this section.

```{toctree}
:maxdepth: 3
:numbered: 1

eXtendingHW
eXtendingSW
eXamples
