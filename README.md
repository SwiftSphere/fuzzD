
# fuzzD

**IOKit Kernel Fuzzer for macOS**

![Version](https://img.shields.io/badge/version-0.1b-blue)
![Platform](https://img.shields.io/badge/platform-macOS-lightblue)
![License](https://img.shields.io/badge/license-MIT-lightgreen)
![Language](https://img.shields.io/badge/language-C-purple)

## Overview

fuzzD is an advanced IOKit fuzzer designed to discover vulnerabilities in macOS kernel extensions through intelligent fuzzing techniques.

## Planned features

- **Better Flip Bit**

## Build

```bash
gcc -o fuzzer fuzzer.c -framework IOKit 
```
# Usage

```bash
./fuzzer
```
# Disclaimer
For educational and security research purposes only. May cause system instability. Use responsibly.

# License
MIT License
