#!/usr/bin/env python3
"""Inspect or delete UEFI variables in an OVMF NVRAM file (OVMF_VARS.fd).

OVMF keeps its UEFI variables in the pflash file QEMU maps as the second
pflash, and they survive between VM runs. While a `BootOrder` variable
exists, OVMF boots strictly in that order and ignores QEMU's `-boot` option
entirely — which is how a headless ISO test VM silently boots the installed
disk instead of the ISO.

    ./scripts/uefi-vars.py OVMF_VARS.fd                 # list the variables
    ./scripts/uefi-vars.py OVMF_VARS.fd drop BootOrder  # delete one variable
    ./scripts/uefi-vars.py OVMF_VARS.fd promote "QEMU DVD-ROM"  # boot the ISO next

`drop` clears the state bits of the live record, exactly the way OVMF's own
variable driver supersedes one, and leaves every other record (the Boot####
entries included) byte-identical. Note that dropping BootOrder does NOT make a
run boot QEMU's order: with no BootOrder OVMF rebuilds one that puts the
persisted OS entries (an install's "Aelum", for instance) ahead of the CD.

`promote <label>` rewrites the live BootOrder's data in place so that every
live Boot#### entry whose data contains <label> (its description or file path)
comes first and everything else keeps its place; the order has fixed capacity,
so entries fall off its tail — in practice the stale IDs OVMF left dangling.
OVMF uses an existing BootOrder verbatim, so this is how a run says "boot
this" without touching any entry.

Both edits need no checksum recompute: records in this store carry zeroed CRC
fields and OVMF accepts a record whose bytes were changed in place (measured
across a real boot — a promoted order survived, and OVMF rewrote on top of it
keeping the new head).

Exit codes: 0 = dropped, or the variable was not there; 0 = promoted, or no
BootOrder exists (a fresh template holds an empty store, and OVMF then boots
QEMU's order); 1 = promote found a BootOrder but no entry matching <label>.

The layout is EDK2's (MdeModulePkg/Include/Guid/VariableFormat.h). The store
header is store GUID, UINT32 Size, UINT8 Format, UINT8 State, reserved.
Records are `StartId=0x55AA, State, Reserved, Attributes, …, NameSize,
DataSize, VendorGuid, name, data`, 4-byte aligned. Two header shapes occur in
the wild and are told apart by which one walks the store cleanly:

  32-byte (plain VARIABLE_HEADER)  NameSize at +8, DataSize +12, GUID +16
  60-byte (authenticated store)    NameSize at +36, DataSize +40, GUID +44

State is a bitmask: 0x3F is the live record; OVMF retires one by clearing
bits 0-1 (0x3C), which is why a store holds the whole history of a variable
and the last 0x3F record of a name is the effective one.
"""

import argparse
import struct
import sys

# GUIDs as stored in memory (Data1/2/3 little-endian, Data4 as-is).
STORE_GUIDS = {
    bytes.fromhex("1636cfdd7532644198b6fe85707ffe7d"): "variables",      # EFI_VARIABLE_GUID
    bytes.fromhex("782cf3aa7b949a43a1802e144ec37792"): "authenticated",  # EFI_AUTHENTICATED_VARIABLE_GUID
}

VARIABLE_DATA = 0x55AA
VAR_ADDED = 0x3F                       # the live record of a name
VAR_RETIRED = VAR_ADDED & ~0x3        # 0x3C: what OVMF writes when it supersedes one
STATE_NAMES = {
    VAR_ADDED: "live",
    VAR_RETIRED: "retired",
    0xFE: "deleting",
    0xFD: "deleted",
    0x7F: "header-only",
}

STORE_HEADER_SIZE = 28  # GUID + Size + Format + State + reserved
# (NameSize, DataSize, VendorGuid) offsets inside a record header.
HEADER_LAYOUTS = ((8, 12, 16, 32), (36, 40, 44, 60))
ALIGN = 4


def uuid_to_guid(text: str) -> bytes:
    """'8be4df61-93ca-11d2-aa0d-0090273fc9fd' -> the 16 bytes as stored."""
    h = bytes.fromhex(text.replace("-", ""))
    return h[0:4][::-1] + h[4:6][::-1] + h[6:8][::-1] + h[8:16]


def guid_to_uuid(b: bytes) -> str:
    g = b.hex()
    return f"{g[6:8]}{g[4:6]}{g[2:4]}{g[0:2]}-{g[10:12]}{g[8:10]}-{g[14:16]}{g[16:32]}"


def find_store(data: bytes):
    """Locate the variable store: (offset, format name, store size)."""
    for guid, kind in STORE_GUIDS.items():
        pos = data.find(guid)
        while pos != -1:
            size = struct.unpack_from("<I", data, pos + 16)[0]
            if 0 < size <= len(data) - pos:
                return pos, kind, size
            pos = data.find(guid, pos + 1)
    raise SystemExit("no variable store found (is this an OVMF_VARS file?)")


def read_records(data: bytes, start: int, limit: int, layout):
    """Walk the store with one header layout; None if it does not hold."""
    ns_at, ds_at, guid_at, header_size = layout
    out, pos = [], start
    while pos + header_size <= limit:
        start_id, state = struct.unpack_from("<HB", data, pos)
        if start_id != VARIABLE_DATA:
            break
        name_size, data_size = struct.unpack_from("<II", data, pos + ns_at)
        if not (0 < name_size <= 1024 and data_size <= 1 << 20
                and pos + header_size + name_size + data_size <= limit):
            return None
        name = data[pos + header_size:pos + header_size + name_size]
        try:
            name = name.decode("utf-16-le").rstrip("\x00")
        except UnicodeDecodeError:
            return None
        out.append((pos, state, struct.unpack_from("<I", data, pos + 4)[0], name,
                    data[pos + guid_at:pos + guid_at + 16], name_size, data_size))
        pos = (pos + header_size + name_size + data_size + ALIGN - 1) & ~(ALIGN - 1)
    return out


def read_store(data: bytes):
    """Locate the store and walk it with whichever header shape fits."""
    off, kind, size = find_store(data)
    best = None
    for layout in HEADER_LAYOUTS:
        records = read_records(data, off + STORE_HEADER_SIZE, off + size, layout)
        if records and (best is None or len(records) > len(best[0])):
            best = (records, layout)
    if not best:
        # A fresh OVMF template holds a valid but empty store: a header and the
        # end marker, no records. That is not corruption — there is simply
        # nothing to read yet.
        layout = HEADER_LAYOUTS[1] if kind == "authenticated" else HEADER_LAYOUTS[0]
        return off, kind, size, [], layout
    return off, kind, size, best[0], best[1]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("path", help="the OVMF NVRAM file (OVMF_VARS.fd)")
    sub = ap.add_subparsers(dest="cmd")
    sub.add_parser("list", help="print every variable (default)")
    drop = ap.add_subparsers  # noqa: F841 (kept for --help clarity)
    drop = sub.add_parser("drop", help="retire a variable's live record")
    drop.add_argument("name", help="variable name, e.g. BootOrder")
    drop.add_argument("--guid", default="8be4df61-93ca-11d2-aa0d-00e098032b8c",
                      help="vendor GUID (default: EFI_GLOBAL_VARIABLE)")
    promote = sub.add_parser("promote", help="move matching boot entries to the head of BootOrder")
    promote.add_argument("label", help="match Boot#### entries whose data contains this text")
    args = ap.parse_args()

    with open(args.path, "rb") as f:
        data = bytearray(f.read())
    off, kind, size, records, layout = read_store(data)

    if args.cmd == "drop":
        want = uuid_to_guid(args.guid)
        dropped = 0
        for pos, state, _attrs, name, guid, _ns, _ds in records:
            if name == args.name and guid == want and state == VAR_ADDED:
                data[pos + 2] = state & ~0x3  # the State byte; everything else untouched
                dropped += 1
        if dropped:
            with open(args.path, "wb") as f:
                f.write(data)
        print(f"{'retired' if dropped else 'no'} {args.name!r} "
              f"{'record(s)' if dropped else ''} in {args.path} ({kind} store)")
        return 0

    if args.cmd == "promote":
        want = uuid_to_guid("8be4df61-93ca-11d2-aa0d-00e098032b8c")
        order_rec = None
        for rec in records:  # the last live record of a name is the effective one
            if rec[3] == "BootOrder" and rec[4] == want and rec[1] == VAR_ADDED:
                order_rec = rec
        if not order_rec:
            print(f"no BootOrder in {args.path}: nothing to promote "
                  f"(a store without one boots QEMU's order)")
            return 0
        pos, _state, _attrs, _name, _guid, ns, ds = order_rec
        doff = pos + layout[3] + ns
        order = list(struct.unpack_from("<%dI" % (ds // 4), data, doff))
        label_b = args.label.encode("utf-16-le")
        promoted = []
        for rpos, rstate, _ra, rname, rguid, rns, rds in records:
            if rstate != VAR_ADDED or rguid != want or not rname.startswith("Boot"):
                continue
            try:
                num = int(rname[4:], 16)
            except ValueError:
                continue
            rdata = data[rpos + layout[3] + rns: rpos + layout[3] + rns + rds]
            if label_b in rdata and num not in promoted:
                promoted.append(num)
        if not promoted:
            print(f"no Boot#### entry matching {args.label!r} in {args.path}; "
                  f"BootOrder left as is")
            return 1
        new = promoted + [n for n in order if n not in promoted]
        new = new[:len(order)]  # fixed capacity: the tail (stale IDs) falls off
        struct.pack_into("<%dI" % len(new), data, doff, *new)
        with open(args.path, "wb") as f:
            f.write(data)
        fmt = lambda nums: " ".join(f"{n:04x}" for n in nums)
        print(f"promoted {args.label!r} in {args.path}: BootOrder [{fmt(order)}] -> [{fmt(new)}]")
        return 0

    print(f"# {args.path}: {kind} store at 0x{off:x}, {len(records)} record(s), "
          f"{layout[3]}-byte headers")
    for _pos, state, attrs, name, guid, _ns, ds in records:
        state_name = STATE_NAMES.get(state, f"0x{state:02x}")
        print(f"{state_name:>10}  attrs=0x{attrs:08x}  size={ds:<6} "
              f"{guid_to_uuid(guid)}  {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
