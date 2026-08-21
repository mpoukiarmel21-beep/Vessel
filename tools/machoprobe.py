"""Minimal Mach-O probe: arch, cryptid, LC_LOAD_DYLIB list, rpaths.
Enough to answer: is this binary decrypted, and does it already have a tweak injected?
"""
import struct
import sys

FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE

LC_REQ_DYLD = 0x80000000
LC_LOAD_DYLIB = 0x0C
LC_ID_DYLIB = 0x0D
LC_LOAD_WEAK_DYLIB = 0x18 | LC_REQ_DYLD
LC_REEXPORT_DYLIB = 0x1F | LC_REQ_DYLD
LC_LOAD_UPWARD_DYLIB = 0x23 | LC_REQ_DYLD
LC_RPATH = 0x1C | LC_REQ_DYLD
LC_ENCRYPTION_INFO_64 = 0x2C
LC_CODE_SIGNATURE = 0x1D
LC_SEGMENT_64 = 0x19

CPU_TYPE = {0x0100000C: "arm64", 0x0000000C: "arm", 0x01000007: "x86_64"}
CPU_SUB = {0: "arm64-all", 1: "arm64-v8", 2: "arm64e"}


def cstr(b):
    i = b.find(b"\x00")
    return (b[:i] if i >= 0 else b).decode("utf-8", "replace")


def probe_slice(data, off, label):
    magic = struct.unpack_from("<I", data, off)[0]
    if magic not in (MH_MAGIC_64, MH_CIGAM_64):
        print(f"  [{label}] not a 64-bit Mach-O (magic=0x{magic:08X})")
        return
    en = "<" if magic == MH_MAGIC_64 else ">"
    cputype, cpusub, filetype, ncmds, sizeofcmds, flags = struct.unpack_from(en + "iiIIII", data, off + 4)
    arch = CPU_TYPE.get(cputype & 0xFFFFFFFF, f"cpu{cputype}")
    sub = CPU_SUB.get(cpusub & 0x00FFFFFF, str(cpusub))
    print(f"  [{label}] arch={arch} subtype={sub} filetype={filetype} ncmds={ncmds} flags=0x{flags:08X}")

    p = off + 32
    dylibs, rpaths = [], []
    cryptid = None
    has_codesig = False
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from(en + "II", data, p)
        if cmdsize == 0:
            break
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB, LC_ID_DYLIB):
            nameoff = struct.unpack_from(en + "I", data, p + 8)[0]
            name = cstr(data[p + nameoff:p + cmdsize])
            kind = "ID" if cmd == LC_ID_DYLIB else "LOAD"
            dylibs.append((kind, name))
        elif cmd == LC_RPATH:
            nameoff = struct.unpack_from(en + "I", data, p + 8)[0]
            rpaths.append(cstr(data[p + nameoff:p + cmdsize]))
        elif cmd == LC_ENCRYPTION_INFO_64:
            cryptoff, cryptsize, cid = struct.unpack_from(en + "III", data, p + 8)
            cryptid = cid
            print(f"    LC_ENCRYPTION_INFO_64 cryptoff={cryptoff} cryptsize={cryptsize} cryptid={cid}")
        elif cmd == LC_CODE_SIGNATURE:
            has_codesig = True
        p += cmdsize

    if cryptid is None:
        print("    LC_ENCRYPTION_INFO_64: ABSENT (binary is decrypted / never encrypted)")
    else:
        print(f"    -> {'DECRYPTED (cryptid=0)' if cryptid == 0 else '*** STILL ENCRYPTED ***'}")
    print(f"    LC_CODE_SIGNATURE present: {has_codesig}")
    print(f"    rpaths: {rpaths}")
    print(f"    linked dylibs ({len(dylibs)}):")
    suspicious = []
    for kind, n in dylibs:
        mark = ""
        low = n.lower()
        if "substrate" in low or "ellekit" in low or "libhooker" in low:
            mark = "  <== SUBSTRATE-CLASS HOOK LIB"
            suspicious.append(n)
        elif n.startswith("@executable_path") or n.startswith("@rpath/lib") or n.startswith("@loader_path"):
            mark = "  <== BUNDLED/INJECTED"
        print(f"      {kind:4} {n}{mark}")
    if suspicious:
        print(f"    !! substrate-class dependencies: {suspicious}")


def main(path):
    with open(path, "rb") as f:
        data = f.read()
    print(f"file: {path}  size={len(data)} bytes ({len(data)/1048576:.1f} MiB)")
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic in (FAT_MAGIC, FAT_CIGAM):
        nfat = struct.unpack_from(">I", data, 4)[0]
        print(f"FAT binary with {nfat} slices")
        for i in range(nfat):
            o = 8 + i * 20
            cputype, cpusub, offset, size, align = struct.unpack_from(">iiIII", data, o)
            probe_slice(data, offset, f"slice{i}")
    else:
        print("THIN binary")
        probe_slice(data, 0, "thin")


if __name__ == "__main__":
    main(sys.argv[1])
