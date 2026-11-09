"""Read-only ARM64 Mach-O string references and function boundaries.

No application code is copied into this repository. Addresses refer to the
on-disk image; add its runtime ASLR slide when tracing a running process.
"""
import argparse
import bisect
import json
import struct
from pathlib import Path

from capstone import CS_ARCH_ARM64, CS_MODE_ARM, Cs


class Image:
    def __init__(self, path):
        self.data = Path(path).read_bytes()
        if self.data[:4] != b"\xcf\xfa\xed\xfe":
            raise ValueError("Expected a little-endian, thin 64-bit Mach-O")
        ncmds = struct.unpack_from("<I", self.data, 16)[0]
        offset = 32
        self.sections = []
        self.starts = []
        for _ in range(ncmds):
            kind, length = struct.unpack_from("<II", self.data, offset)
            if kind == 0x19:
                seg = struct.unpack_from("<II16sQQQQiiII", self.data, offset)
                for i in range(seg[-2]):
                    item = struct.unpack_from("<16s16sQQIIIIIIII", self.data, offset + 72 + 80 * i)
                    self.sections.append((item[0].rstrip(b"\0").decode(), item[2], item[3], item[4]))
                if seg[2].rstrip(b"\0") == b"__TEXT":
                    self.base = seg[3]
            if kind == 0x26:
                start, size = struct.unpack_from("<II", self.data, offset + 8)
                value, shift, address = 0, 0, self.base
                for b in self.data[start:start + size]:
                    value |= (b & 127) << shift
                    if b < 128:
                        if value == 0:
                            break
                        address += value
                        self.starts.append(address)
                        value, shift = 0, 0
                    else:
                        shift += 7
            offset += length

    def function(self, address):
        i = bisect.bisect_right(self.starts, address) - 1
        return self.starts[i] if i >= 0 else None

    def address(self, file_offset):
        for _, addr, size, offset in self.sections:
            if offset <= file_offset < offset + size:
                return addr + file_offset - offset
        return None

    def offset(self, address):
        for _, addr, size, offset in self.sections:
            if addr <= address < addr + size:
                return offset + address - addr
        raise ValueError("Address is outside sections")

    def xrefs(self, needles):
        targets = {}
        for text in needles:
            data = text.encode() + b"\0"
            start = 0
            while (pos := self.data.find(data, start)) >= 0:
                address = self.address(pos)
                if address:
                    targets[address] = text
                start = pos + 1
        pages = {x & ~0xfff for x in targets}
        section = next(s for s in self.sections if s[0] == "__text")
        _, addr, size, offset = section
        words = [x[0] for x in struct.iter_unpack("<I", self.data[offset:offset + size])]
        for index, word in enumerate(words):
            if word & 0x9f000000 != 0x90000000:
                continue
            immediate = (((word >> 5) & 0x7ffff) << 2) | ((word >> 29) & 3)
            if immediate & 0x100000:
                immediate -= 0x200000
            pc = addr + index * 4
            page = (pc & ~0xfff) + (immediate << 12)
            if page not in pages:
                continue
            reg = word & 31
            for step, add in enumerate(words[index + 1:index + 9], 1):
                if add & 0xffc00000 == 0x91000000 and (add >> 5) & 31 == reg:
                    target = page + ((add >> 10) & 0xfff)
                    if target in targets:
                        print(json.dumps({"text": targets[target], "string": hex(target),
                                          "reference": hex(pc + step * 4), "function": hex(self.function(pc))}))
                if add & 31 == reg and add & 0xffc00000 == 0x91000000:
                    break

    def disassemble(self, start, count):
        offset = self.offset(start)
        for instruction in Cs(CS_ARCH_ARM64, CS_MODE_ARM).disasm(self.data[offset:offset + count * 4], start):
            print(f"{instruction.address:#x}  {instruction.mnemonic:8} {instruction.op_str}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=str(Path.home() / "Library/Application Support/Zwift/ZwiftAppSilicon"))
    parser.add_argument("--strings", nargs="*")
    parser.add_argument("--disassemble", type=lambda s: int(s, 0))
    parser.add_argument("--count", type=int, default=80)
    args = parser.parse_args()
    image = Image(args.binary)
    if args.strings:
        image.xrefs(args.strings)
    if args.disassemble:
        image.disassemble(args.disassemble, args.count)
