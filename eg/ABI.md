# Technical Reference & Platform Portability Guide

This document details the architecture-specific ABI constraints, operating system quirks, binary layout decisions, and structural workarounds implemented in the `Brocken` compiler backend. It serves as a portability manual and design blueprint for maintaining or extending this compiler's binary generation pipelines.

---

## 1. Global ABI Constraints & Stack Alignment

### 1.1 AMD64 System V ABI Stack Alignment
The System V Application Binary Interface (ABI) for AMD64 architectures specifies strict alignment rules for the stack pointer (`%rsp`).

* **Rule**: The stack pointer must be aligned to a **16-byte boundary** immediately prior to any `call` instruction.
* **Mechanism**: A `call` instruction pushes an 8-byte return address onto the stack. Consequently, upon entering the target function (before the prologue executes), the stack is offset by exactly 8 bytes (i.e., `(%rsp + 8) % 16 == 0`).
* **Our Workaround**: When a process launches, the kernel transfers execution directly to the executable's entry point (`_start` / `e_entry`). At this boundary, `%rsp` points to `argc` and is not guaranteed to be 16-byte aligned. If we call functions within `libc.so` (like `exit` or `_exit`) while the stack is misaligned, vector-aligned SSE instructions (e.g., `movaps`) executed inside `libc` will trigger an immediate alignment fault (`SIGSEGV`).
  In the `_start` stub for `x86_64`, we forcefully align the stack pointer:
  ```assembly
  and rsp, -16    ; Opcode: 48 83 E4 F0 (Aligns RSP to 16 bytes)
  call main       ; Opcode: E8 [rel32] (Pushes 8 bytes, entering main at 16n + 8)
  ```
  Once `main` returns, `%rsp` is restored to `16n`. We then execute `call exit` (pushing 8 bytes) entering the dynamic linker/C library safely at the required `16n + 8` alignment.
* **References**:
  * [System V Application Binary Interface AMD64 Architecture Processor Supplement](https://refspecs.linuxbase.org/elf/x86_64-abi-0.99.pdf)

### 1.2 ARM64 (AArch64) Stack Alignment
* **Rule**: On ARM64, the stack pointer (`sp`) must be 16-byte aligned at any point where it is used to access memory.
* **Mechanism**: Hardware checks this alignment. Our generator bypasses stack pushes entirely within the `_start` entry stub, utilizing the Link Register (`x30`) to store the return address:
  ```assembly
  bl main         ; Branch with Link (sets x30, keeps SP untouched)
  ```
  Since `sp` is untouched and initialized as 16-byte aligned by the loader, ARM64 hardware constraints are naturally satisfied.

---

## 2. Platform-Specific Quirks & Workarounds

### 2.1 Haiku ABI Versioning & Symbols
Haiku's dynamic linker (`runtime_loader`) operates under an ABI versioning safeguard to guarantee backward compatibility with legacy BeOS R5 binaries.

* **Quirk**: Every modern Haiku executable or shared library must declare and export two global variables to the dynamic symbol table (`.dynsym`):
  1. `_gSharedObjectHaikuABI` (Typically set to `4` for modern gcc4+ x86_64 environments)
  2. `_gSharedObjectHaikuVersion` (Set to `0`)
* **Behavior**: If these symbols are missing or set to `0` (interpreting gcc2 BeOS legacy), the `runtime_loader` restricts the symbol visibility of `libroot.so`. Modern POSIX APIs (including `pthread_create`) are systematically hidden, causing the application to crash on startup with `B_MISSING_SYMBOL` (represented as exit status `3`).
* **Workaround**: We allocate 8 bytes within the `.data` segment of Haiku binaries and export these variables with global visibility (`STB_GLOBAL | STT_OBJECT`) to the dynamic symbol table and hash table:
  ```perl
  $payload = pack('L< L<', 4, 0); # ABI Version 4, OS Version 0
  ```
* **References**:
  * [Haiku runtime_loader Symbol Resolution Rules](https://git.haiku-os.org/haiku/tree/src/system/runtime_loader/images.cpp)

### 2.2 BSD `__progname` and `environ` Initialization
When dynamically linking against `libc.so` on FreeBSD, NetBSD, and DragonFly BSD, the library initialization routines (`_init` or `DT_INIT`) execute *before* the application's `_start` block receives control.

* **Quirk**: The BSD `libc` initialization routines actively dereference and update the `environ` and `__progname` symbol pointers. If these symbols are omitted during linking, or if they point to an invalid memory region, the loader or early initialization routines crash with a segmentation fault.
* **Workaround**: We manually generate these symbols within our writable `.data` section to point to safe, zero-initialized pointers:
  ```perl
  # Offset 0:  0 (Treated as empty environment array terminator)
  # Offset 8:  Points to offset 0 (Address of NULL pointer -> empty environ)
  # Offset 16: Points to offset 24 (Address of NUL char -> empty __progname string)
  # Offset 24: "\0" (NUL terminator)
  $payload = pack('Q< Q< Q<', 0, $base + $s->{rva}, $base + $s->{rva} + 24);
  ```
  This satisfies BSD libc expectations while yielding safe, empty defaults.

### 2.3 `exit` vs `_exit` (Bypassing Uninitialized Libc Destructors)
* **Quirk**: On NetBSD and DragonFly BSD, calling standard POSIX `exit()` without going through the compiler's platform-provided `crt1.o` runtime initialization means internal `libc` locks, streams, and `atexit` structures are left completely uninitialized. Calling `exit()` triggers a crash inside `libc` when attempting to clean up these non-existent structures, yielding an exit code of `0` (SIGSEGV/SIGSYS masked).
* **Workaround**: We dynamically resolve and call `_exit` on BSD systems instead of `exit`. `_exit` is a raw system call wrapper that directly terminates the process space without triggering library-level destructors, bypassing the uninitialized state entirely. On Haiku, we continue to use `exit` since `libroot` does not natively export `_exit` as a standalone symbol.

### 2.4 PT_GNU_RELRO Segment Sizing
* **Quirk**: The `PT_GNU_RELRO` program header tells the dynamic linker to mark specified segments of memory as Read-Only after relocation processing completes. However, if this segment inadvertently covers `.data` (containing `environ` or `__progname`) or the `.got` (Global Offset Table) on strict BSDs like DragonFly BSD without lazy binding explicitly disabled (`DF_1_NOW`), the dynamic linker will crash when attempting to update these structures.
* **Workaround**: We shrink the size of our `PT_GNU_RELRO` segment to cover *only* the `.dynamic` section. This protects critical dynamic structures while keeping our `.got` and `.data` safely writable.

### 2.5 NetBSD Native Identity and PaX Notes
* **Quirk**: The NetBSD kernel will refuse to execute any ELF binary that lacks a valid native identity note segment (`NT_NETBSD_IDENT`). Additionally, NetBSD enforces `PaX MPROTECT` memory safety, which can terminate processes violating W^X policies unless relaxed.
* **Workaround**: We construct a dual-note structure directly within our `PT_NOTE` program segment:
  1. `NT_NETBSD_IDENT`: Setting version `1099000000` (representing NetBSD 10.99.x compatibility).
  2. `NT_NETBSD_PAX`: Specifically injecting flag `0x0a` to relax PaX protections for our raw generated memory, preventing immediate `SIGKILL` or `SIGSEGV`.
* **References**:
  * [NetBSD elf(5) man page and PaX configurations](https://man.netbsd.org/elf.5)

### 2.6 Duality of Dynamic and Static Symbol Resolution
A recurring challenge across binary platforms is making sure symbols are visible to both runtime loaders and offline inspection utilities:
* **The Problem**: Toolchain analysis utilities (like GNU `nm` or `objdump`) inspect files statically on disk and expect standard static debug tables (`.symtab` on ELF, `IMAGE_SYMBOL` on PE, and `LC_SYMTAB` on Mach-O). However, modern dynamic loaders (like `ld.so`, `dyld`, and the Windows PE Loader) bypass these static tables entirely for speed and security, relying instead on highly optimized runtime tables (`.dynsym`/`.dynamic` on ELF, prefix-coded Export Tries on Mach-O, and Name Pointer Tables on PE).
* **The Solution**: Brocken hand-assembles both types of representation for ELF64 and Mach-O. The static tables are written with non-allocable markers to ensure they do not take up runtime memory space, keeping execution fast while remaining fully debuggable offline.

### 2.7 Windows ARM64 Loader Strictness & COFF Zeroing
Modern 64-bit Windows execution environments (PE32+)-particularly strict ones like Windows 11 on ARM64 (`aarch64-pc-windows-msvc`)-enforce rigid format validation checks on dynamic libraries and executables.
* **Quirk**: If a fully linked PE image file designates a non-zero value for `PointerToSymbolTable` or `NumberOfSymbols` inside the `IMAGE_FILE_HEADER` [1.2.1], the strict OS dynamic loader rejects the file as a malformed image or deprecated debug layout. The application fails to load with error codes such as `ERROR_BAD_EXE_FORMAT` [1.1.9], and static inspect tools on Windows ARM64 (like simulated GNU `nm` or `objdump`) report "file format not recognized".
* **Workaround**: For fully linked PE images, we zero out the legacy COFF symbol table fields:
  ```perl
  my $pointer_to_symbol_table = 0;
  my $num_coff_symbols        = 0;
  ```
  Windows dynamic symbol resolution (used by the OS loader and FFI libraries like `DynaLoader` / `Win32::API`) relies exclusively on the modern Optional Header data directories to resolve exported functions, keeping the image fully functional and stable.

### 2.8 macOS `dyld` Undefined Symbol Constraints
Under Darwin operating systems, the dynamic linker (`dyld`) enforces strict validation rules when processing executables that link against external libraries.
* **Quirk**: If a Mach-O executable uses dynamic binding opcodes (`LC_DYLD_INFO_ONLY`) to load external libraries (such as `_dlopen` and `_dlsym`), `dyld` requires that any imported symbol be explicitly declared in both the static Symbol Table (`LC_SYMTAB`) and Dynamic Symbol Table (`LC_DYSYMTAB`) as an undefined external symbol (`N_UNDF | N_EXT`). If the symbol table is omitted or left empty, `dyld` aborts process creation on startup with a segfault/SIGKILL signal.
* **Workaround**: We construct symbol tables for both Mach-O executables and shared libraries. All external dynamically-bound imports are compiled directly into the symbol structures with an `N_UNDF | N_EXT` type descriptor and registered under the `iundefsym` array index of the `LC_DYSYMTAB` load command, satisfying `dyld` loader constraints.

### 2.9 DynaLoader and Underscores on macOS
* **Quirk**: The standard POSIX `dlsym()` interface on macOS automatically handles the historical leading underscore (`_`) prefixed to C symbols.
* **Behavior**: If an FFI module (such as Perl's `DynaLoader`) requests the mangled name `_my_func` on macOS, `dlsym()` automatically prepends a second underscore and attempts to resolve `__my_func` inside the mapped image. This results in immediate symbol lookup failures.
* **Workaround**: Standardize all FFI dynamic loading lookups to request the clean unmangled name `"my_func"`. The underlying POSIX loader is left to handle target-specific underscore mangling rules transparently.

---

## 3. Structural Specification of Generated Binary Formats

### 3.1 ELF64 (Executable and Linkable Format)
Hand-assembled structures inside `Brocken::Jenny::Linker::ELF64` are constructed strictly aligned with the System V Application Binary Interface (64-bit).

#### ELF64 Header (`Elf64_Ehdr` - Exactly 64 Bytes)
| Field | Offset | Size | Value / Meaning |
| :--- | :--- | :--- | :--- |
| `e_ident[0..3]` | 0 | 4 | `\x7F` `E` `L` `F` (Magic signature) |
| `e_ident[4]` | 4 | 1 | `2` (ELFCLASS64 - 64-bit architecture) |
| `e_ident[5]` | 5 | 1 | `1` (ELFDATA2LSB - Little Endian) |
| `e_ident[6]` | 6 | 1 | `1` (EV_CURRENT - ELF Version 1) |
| `e_ident[7]` | 7 | 1 | OSABI (e.g., `9` for FreeBSD, `2` for NetBSD, `0` for Linux) |
| `e_ident[8..15]`| 8 | 8 | ABI Version & Padding (Zero-filled) |
| `e_type` | 16 | 2 | `2` (ET_EXEC) or `3` (ET_DYN / PIE) |
| `e_machine` | 18 | 2 | `62` (EM_X86_64), `183` (EM_AARCH64), or `243` (EM_RISCV) |
| `e_version` | 20 | 4 | `1` (Current version) |
| `e_entry` | 24 | 8 | Virtual Address of the entry point stub (`_start`) |
| `e_phoff` | 32 | 8 | File offset of the Program Header Table (Typically `64`) |
| `e_shoff` | 40 | 8 | File offset of the Section Header Table |
| `e_flags` | 48 | 4 | Processor-specific flags (Typically `0`) |
| `e_ehsize` | 52 | 2 | Size of this ELF header (`64` bytes) |
| `e_phentsize` | 54 | 2 | Size of one program header entry (`56` bytes) |
| `e_phnum` | 56 | 2 | Number of entries in the Program Header Table |
| `e_shentsize` | 58 | 2 | Size of one section header entry (`64` bytes) |
| `e_shnum` | 60 | 2 | Number of entries in the Section Header Table |
| `e_shstrndx` | 62 | 2 | Section header table index of `.shstrtab` (Section Names) |

#### ELF64 Program Header (`Elf64_Phdr` - Exactly 56 Bytes)
Defines segments used by the kernel during process creation.
* `p_type`: Segment type (e.g., `1` for PT_LOAD, `2` for PT_DYNAMIC, `3` for PT_INTERP, `4` for PT_NOTE).
* `p_flags`: Access permissions (`1` for Execute, `2` for Write, `4` for Read).
* `p_offset`: Offset from the beginning of the file to the segment payload.
* `p_vaddr` / `p_paddr`: Virtual/Physical addresses where the segment resides in memory.
* `p_filesz`: Size of the segment in the file.
* `p_memsz`: Size of the segment in memory (padded with zeroes if `p_memsz > p_filesz`).
* `p_align`: Segment memory alignment constraints (e.g., `0x1000` or `0x10000`).

#### ELF64 Symbol Tables (`.dynsym` & `.symtab` - 24 Bytes per entry)
Brocken populates both symbol tables using the standard `Elf64_Sym` structure layout:

| Field | Offset | Size | Value / Meaning |
| :--- | :--- | :--- | :--- |
| `st_name` | 0 | 4 | Offset into the string table (`.dynstr` or `.strtab`) |
| `st_info` | 4 | 1 | Bind and Type (e.g., `0x12` for `STB_GLOBAL \| STT_FUNC`) |
| `st_other` | 5 | 1 | Visibility (Typically `0` for `STV_DEFAULT`) |
| `st_shndx` | 6 | 2 | Section header index (e.g., `1` for `.text`, or `0` for `SHN_UNDEF`) |
| `st_value` | 8 | 8 | Value / virtual address of the symbol |
| `st_size` | 16 | 8 | Symbol size in bytes (Typically `0` for raw entry points) |

The `.dynsym` table is allocated with `SHF_ALLOC` flags in read-only memory, while `.symtab` resides at the end of the file with `flags = 0` (non-alloc), allowing static analysis tools to operate without causing runtime memory overhead.

---

### 3.2 Mach-O (64-Bit Mach-O Format)
Constructed inside `Brocken::Jenny::Linker::MachO` to conform with Apple's macOS kernel execution layer.

#### Mach-O Header (`mach_header_64` - Exactly 32 Bytes)
| Field | Offset | Size | Value / Meaning |
| :--- | :--- | :--- | :--- |
| `magic` | 0 | 4 | `0xfeedfacf` (MH_MAGIC_64) |
| `cputype` | 4 | 4 | `0x01000007` (CPU_TYPE_X86_64) or `0x0100000c` (CPU_TYPE_ARM64) |
| `cpusubtype` | 8 | 4 | `3` (CPU_SUBTYPE_I386_ALL) or `0` (CPU_SUBTYPE_ARM64_ALL) |
| `filetype` | 12 | 4 | `2` (MH_EXECUTE) or `6` (MH_BUNDLE / shared library) |
| `ncmds` | 16 | 4 | Number of load commands following this header |
| `sizeofcmds` | 20 | 4 | Total size of all load commands in bytes |
| `flags` | 24 | 4 | Header flags (e.g., `MH_NOUNDEFS`, `MH_DYLDLINK`, `MH_PIE`) |
| `reserved` | 28 | 4 | Reserved field (Zero-filled) |

#### Mach-O Load Commands
Load commands act as instructions for the kernel loader and dynamic linker (`dyld`).
1. **`LC_SEGMENT_64` (Segment Load Command - 72 Bytes + Section Headers)**:
   Specifies mapping constraints for virtual segments (e.g., `__PAGEZERO`, `__TEXT`, `__DATA`, `__LINKEDIT`).
2. **`LC_LOAD_DYLINKER` (32 Bytes)**:
   Defines the path to the system dynamic linker (hardcoded to `/usr/lib/dyld`).
3. **`LC_LOAD_DYLIB` (Variable Size)**:
   Loads a specific shared library (used to bind `/usr/lib/libSystem.B.dylib`).
4. **`LC_MAIN` (24 Bytes)**:
   Specifies the execution entry point (replaces older `LC_UNIXTHREAD` commands).
5. **`LC_DYLD_INFO_ONLY` (48 Bytes)**:
   Points to dynamic binding tables, exports, and weak references.

#### Mach-O Dynamic and Static Symbol Resolution
Mach-O handles symbols through two parallel mechanisms inside the `__LINKEDIT` segment:

* **Export Trie (`LC_DYLD_INFO_ONLY`)**: A prefix-encoded trie representing exported symbols. The trie state machine begins with a count of terminal/non-terminal edges, followed by name string slices, child node offset values, and terminal flags containing the target's relative virtual address (RVA).
* **Static Symbol Table (`LC_SYMTAB`)**: Contains an array of `struct nlist_64` structures (16 bytes each):

| Field | Offset | Size | Value / Meaning |
| :--- | :--- | :--- | :--- |
| `n_strx` | 0 | 4 | Offset of the string slice within the Mach-O String Table |
| `n_type` | 4 | 1 | Symbol type flags (e.g., `0x0f` for `N_SECT \| N_EXT`) |
| `n_sect` | 5 | 1 | Section index (1-based index; `.text` is `1`) |
| `n_desc` | 6 | 2 | Description flags (Set to `0`) |
| `n_value` | 8 | 8 | Fully resolved absolute virtual address of the symbol |

* **Underscore Prefixing**: The Mach-O ABI strictly mandates that all user-defined symbols exported statically or dynamically are prefixed with a leading underscore (e.g., `my_func` becomes `_my_func` on disk).

* **Apple Silicon Signature Requirement**: On ARM64 macOS platforms, execution of unsigned binary files is strictly prohibited at the kernel level.
  Our builder implements an automated sub-shell pass calling `codesign` to apply an ad-hoc (`-`) signature to the resulting file, satisfying kernel security verifications.

---

### 3.3 PE32+ (Windows Portable Executable Format)
Assembled within `Brocken::Jenny::Linker::PE` to support execution on modern Windows platforms (x86_64 & ARM64).

#### DOS MZ Header & Stub (Exactly 128 Bytes)
For compatibility, every PE binary contains a legacy MS-DOS MZ header.
* `e_magic`: Always set to `"MZ"` (`0x5A4D`).
* `e_lfanew` (Offset `60`): Contains the exact file offset of the actual PE Header (aligned to `0x80`).

#### COFF File Header (Exactly 20 Bytes)
| Field | Offset | Size | Value / Meaning |
| :--- | :--- | :--- | :--- |
| `Machine` | 0 | 2 | `0x8664` (AMD64) or `0xAA64` (ARM64) |
| `NumberOfSections` | 2 | 2 | Total PE sections (typically `.text`, `.data`, `.reloc`) |
| `TimeDateStamp` | 4 | 4 | Unix timestamp of binary generation (or deterministic override) |
| `PointerToSymbolTable`| 8 | 4 | File offset of COFF symbol table (Zeroed out for clean images) |
| `NumberOfSymbols` | 12 | 4 | Number of COFF symbols (Zeroed out for clean images) |
| `SizeOfOptionalHeader`| 16 | 2 | Size of the Optional Header (`240` bytes for PE32+) |
| `Characteristics` | 18 | 2 | Image flags (e.g., `0x0022` - `EXECUTABLE_IMAGE \| LARGE_ADDRESS_AWARE`) |

#### PE32+ Optional Header (Exactly 240 Bytes)
* **`Magic`**: Always `0x020b` (signaling PE32+ 64-bit architecture).
* **`AddressOfEntryPoint`**: RVA of our custom startup stub.
* **`SectionAlignment`**: Memory alignment of mapped sections (Default `4096` bytes).
* **`FileAlignment`**: Alignment of section data in the physical file (Default `512` bytes).
* **`DllCharacteristics`**: Security features. To enforce NX/W^X and modern ASLR, we pack flags `0x8160` (combining `HIGH_ENTROPY_VA | DYNAMIC_BASE | NX_COMPAT`).
* **`DataDirectories` (128 Bytes)**: Table containing RVAs and sizes of critical tables (e.g., Import Directories, Base Relocations).

#### Windows Export Directory `.edata` Section Layout
Modern Windows PE loaders and dynamic resolvers (such as `DynaLoader` / `GetProcAddress`) resolve exported symbols strictly using the **Export Directory Table** located within the `.edata` section [1.1.2] (or mapped as a dynamic sub-segment).

To ensure complete compatibility with third-party tools like standard GNU `objdump` or `llvm-readobj` [1.1.9], Brocken structures `.edata` strictly following MSVC-compiler alignment specifications:

1. **Alignment Offset 0**: The 40-byte `IMAGE_EXPORT_DIRECTORY` header resides at the **very beginning** of the `.edata` section (RVA `$edata_rva`, e.g., `0x2000`).
2. **Sub-Tables and Strings**: All auxiliary tables-the Export Address Table (EAT), Export Name Pointer Table (ENPT), and Export Ordinal Table (EOT)-together with raw ASCII string names, are appended at offsets following this 40-byte header.
3. **Contiguous Directory Registration**: The optional header Data Directory Index 0 (`IMAGE_DIRECTORY_ENTRY_EXPORT`) registers:
   * **`VirtualAddress`**: `$edata_rva` (the start of the entire `.edata` section, e.g., `0x2000`).
   * **`Size`**: The total byte length of the compiled `.edata` payload (`length($edata_bytes)`).
4. **Boundary Checks Prevention Padding**: GNU binutils enforces strict heap overflow boundary validation (`edt.ot_addr + (edt.num_names * 2) - adj >= datasize`) [8.3.3]. If the last byte of the Ordinal Table ends exactly at the registered size boundary, this assertion triggers false-positive bounds failures ("Invalid Ordinal Table rva"). Appending a safe trailing padding of `4` null bytes (`\x00` x 4) to the `.edata` payload cleanly prevents this error.

##### IMAGE_EXPORT_DIRECTORY Header (40 Bytes)
| Field | Offset | Size | Value / Meaning |
| :--- | :--- | :--- | :--- |
| `Characteristics` | 0 | 4 | Reserved (Typically `0`) |
| `TimeDateStamp` | 4 | 4 | Unix timestamp |
| `Major/Minor Version`| 8 | 4 | Table version (Typically `0`) |
| `Name` | 12 | 4 | RVA of the DLL name string |
| `Base` | 16 | 4 | Starting ordinal value (Typically `1`) |
| `NumberOfFunctions` | 20 | 4 | Number of EAT entries |
| `NumberOfNames` | 24 | 4 | Number of ENPT entries |
| `AddressOfFunctions`| 28 | 4 | RVA of the Export Address Table |
| `AddressOfNames` | 32 | 4 | RVA of the Export Name Pointer Table |
| `AddressOfNameOrdinals`| 36 | 4 | RVA of the Export Ordinal Table |

* **COFF Symbol Table (`IMAGE_SYMBOL` - Exactly 18 Bytes)**: Sits at the end of the PE file. Standard `nm` and static toolchains parse this structure:

| Field | Offset | Size | Value / Meaning |
| :--- | :--- | :--- | :--- |
| `ShortName / Offset`| 0 | 8 | 8-byte string or union of `0` (first 4 bytes) and String Table offset (last 4 bytes) |
| `Value` | 8 | 4 | Relative virtual address (RVA) of the symbol inside the section |
| `SectionNumber` | 12 | 2 | 1-based section index (e.g., `1` for the `.text` section) |
| `Type` | 14 | 2 | Symbol type (Typically `0x0020` representing `IMAGE_SYM_DTYPE_FUNCTION`) |
| `StorageClass` | 16 | 1 | Storage class (Typically `2` representing `IMAGE_SYM_CLASS_EXTERNAL`) |
| `NumberOfAuxSymbols`| 17 | 1 | Number of associated auxiliary symbol records (Set to `0`) |

---

## 4. Portability Quick-Reference Check

When porting new features or fixing compiler bugs across platforms, always check against this matrix:

| OS | Platform Key | Stack Rule | Binary Format | Primary Exit Method | Crucial Workaround |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Linux** | `linux` | 16-byte RSP | ELF64 | `_exit` (via GOT) | Default GNU Stack and Interpreter |
| **macOS** | `macos` | 16-byte RSP | Mach-O | `exit` (via dyld) | Ad-hoc `codesign` signature |
| **Windows** | `win64` | 16-byte RSP | PE32+ | `ExitProcess` | Dummy `.reloc` table for ARM64 |
| **FreeBSD** | `freebsd` | 16-byte RSP | ELF64 | `_exit` (via GOT) | `__progname`/`environ` symbol mapping |
| **NetBSD** | `netbsd` | 16-byte RSP | ELF64 | `_exit` (via GOT) | `NT_NETBSD_IDENT` + PaX note generation |
| **OpenBSD**| `openbsd` | 16-byte RSP | ELF64 | `_exit` (via GOT) | `PT_OPENBSD_PINTABLE` syscall mapping |
| **DragonFly**| `dragonfly` | 16-byte RSP | ELF64 | `_exit` (via GOT) | Shrunk `PT_GNU_RELRO` to prevent GOT crash |
| **Haiku** | `haiku` | 16-byte RSP | ELF64 | `exit` (via GOT) | `_gSharedObjectHaikuABI` variables |

---

## 5. Lindsay IR Dynamic Type Representation

Brocken represents dynamically typed variables (like Perl variables) through a 128-bit (16-byte) Fat Scalar layout mapped to the `dynamic` type in the Lindsay IR.

```
+--------------------------------+--------------------------------+
|       64-bit Type Tag          |         64-bit Payload         |
|  (e.g., Integer, String, Ptr)  |   (Literal value or Pointer)   |
+--------------------------------+--------------------------------+
```

### 5.1 Memory Layout
1. **Type Tag (8 bytes)**: A 64-bit unsigned integer identifying the scalar type:
   * `1` $\rightarrow$ Undefined / Null
   * `2` $\rightarrow$ Boolean
   * `3` $\rightarrow$ Native Integer (64-bit)
   * `4` $\rightarrow$ Native Float (double)
   * `5` $\rightarrow$ String Pointer (points to null-terminated char array)
   * `6` $\rightarrow$ Array / List Reference
2. **Payload (8 bytes)**: A 64-bit slot that holds either the literal native value (such as a 64-bit integer or double) or a pointer to heap-allocated objects (such as a string descriptor or array metadata).

### 5.2 Boxing and Unboxing Operations
* **`box <type> <val> to dynamic`**: Allocates stack space or a temporary register pair, loads the type identifier into the high 64 bits, copies the native value into the low 64 bits, and returns the 128-bit structure.
* **`unbox dynamic <val> to <type>`**: Compares the high 64-bit type tag against the requested type using an architecture-specific assertion. On match, it returns the low 64-bit payload directly. If there is a type mismatch, it branches to a type-coercion helper or throws an exception.

---

## 6. Haiku Dynamic Syscall Extraction Analysis

Because Haiku does not guarantee stable system call numbers across OS releases, the `Katsuro::Platform::Haiku` subsystem features a dynamic disassembly scanner that parses the instruction stream of `libroot.so` to extract syscall indices at runtime.

### 6.1 Assembly Instruction Scanning Heuristics
When running natively, the backend locates Haiku's dynamic library (`/boot/system/lib/libroot.so`) and runs a disassembler wrapper (`objdump -d`) targeting known wrapper stubs, such as `_kern_write`, `_kern_exit_team`, and `_kern_open`. The parser scans the assembly sequence of the stub to capture the immediate assignment that loads the system call index before invoking the software interrupt.

The parser matches the following architecture-specific patterns:

#### x86_64
The syscall number is loaded into the `%eax` or `%rax` register prior to calling `syscall`:
```assembly
mov    $0x90,%eax     ; Opcode: B8 90 00 00 00 (Loads system call 144 into EAX)
syscall               ; Opcode: 0F 05
```
* **Regex Pattern**: `/mov\s+\$0x([0-9a-f]+),\s*%[er]?ax/i`

#### AArch64 (ARM64)
The syscall number is loaded into the `x8` register prior to invoking `svc`:
```assembly
mov    x8, #0x90      ; Opcode: D2801208 (Loads system call 144 into X8)
svc    #0             ; Opcode: D4000001
```
* **Regex Pattern**: `/mov\s+x8,\s*#0x([0-9a-f]+)/i`

#### RISC-V 64
The syscall number is loaded into the `a7` register prior to calling `ecall`:
```assembly
li     a7, 144        ; Opcode: 09000893 (Loads system call 144 into A7)
ecall                 ; Opcode: 00000073
```
* **Regex Pattern**: `/li\s+a7,\s*#?0x([0-9a-f]+)/i`

If this extraction fails or if the compiler is cross-compiling, the backend falls back to standard BeOS/Haiku R1/beta4 system call constants.
