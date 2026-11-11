#!/usr/bin/env python3
"""inject.py — 给 OPEN 主程序加一条 LC_LOAD_DYLIB，并把 dylib 放进 Frameworks。

用法:
    python inject.py <in.ipa> <payload.dylib> <out.ipa> [load_path]

默认 load_path = @executable_path/Frameworks/AppRuntime/<dylib 文件名>
（与样本自带的 ATHelper.dylib 同目录，dyld 能直接找到）

说明:
  * 只改 Mach-O 头部（ncmds/sizeofcmds + 追加一条 load command），
    __TEXT 头部有 16KB 对齐留白，足够放几十条命令，不需要搬移 section。
  * 不改 __LINKEDIT / 不重算 CodeDirectory —— 本样本签名本来就已经失效
    （CodeResources 与被删框架、被替换的 libuiopsersvc/flag 不符），
    产物必须重新 ldid/codesign 后才能安装，签名步骤不在这里做。
"""

import shutil
import struct
import sys
import tempfile
import zipfile
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB = 0xC
LC_SEGMENT_64 = 0x19


def put_load_command(data: bytearray, load_path: str) -> int:
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != MH_MAGIC_64:
        raise SystemExit("不是 thin arm64 Mach-O")
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    # 找命令区结束位置
    off = 32
    end = 32 + sizeofcmds
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmdsize < 8:
            raise SystemExit("load command 损坏")
        off += cmdsize
    if off != end:
        # 容忍：以实际遍历结果为准
        end = off

    # 找第一个 section 的文件偏移，确认头部留白够用
    first_sec_off = None
    off2 = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off2)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, off2 + 64)[0]
            if nsects:
                sec_off = struct.unpack_from("<I", data, off2 + 72 + 48)[0]
                if first_sec_off is None or sec_off < first_sec_off:
                    first_sec_off = sec_off
        off2 += cmdsize

    name = load_path.encode() + b"\0"
    cmdsize = (8 + 4 + 4 + 4 + 4 + len(name) + 7) & ~7
    if end + cmdsize + 16 > (first_sec_off or 0):
        raise SystemExit("头部留白不足，需要更复杂的注入方式")

    blob = bytearray(cmdsize)
    struct.pack_into("<II", blob, 0, LC_LOAD_DYLIB, cmdsize)
    struct.pack_into("<I", blob, 8, 24)          # name offset
    struct.pack_into("<I", blob, 12, 2)          # timestamp
    struct.pack_into("<I", blob, 16, 0x10000)    # current_version
    struct.pack_into("<I", blob, 20, 0x10000)    # compatibility_version
    blob[24:24 + len(name)] = name

    data[end:end + cmdsize] = blob
    struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + cmdsize)
    return cmdsize


def main() -> None:
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    src, dylib, dst = (Path(x) for x in sys.argv[1:4])
    load_path = sys.argv[4] if len(sys.argv) > 4 else f"@executable_path/Frameworks/AppRuntime/{dylib.name}"

    with tempfile.TemporaryDirectory() as td:
        work = Path(td) / "work"
        with zipfile.ZipFile(src) as z:
            z.extractall(work)
        apps = list((work / "Payload").glob("*.app"))
        if not apps:
            raise SystemExit("IPA 里没有 Payload/*.app")
        app = apps[0]
        # Info.plist 指向的可执行文件名
        exe = app / app.name.split(".")[0]
        if not exe.exists():
            cands = [p for p in app.iterdir() if p.is_file() and p.name not in ("Info.plist",) and p.stat().st_size > 100000]
            if not cands:
                raise SystemExit("找不到主程序")
            exe = max(cands, key=lambda p: p.stat().st_size)

        data = bytearray(exe.read_bytes())
        size_added = put_load_command(data, load_path)
        exe.write_bytes(data)

        target = app / "Frameworks" / "AppRuntime" / dylib.name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(dylib, target)

        # 重新打包（保持扩展名 + 不压缩 exe 也合法，统一 deflate 即可）
        if dst.exists():
            dst.unlink()
        with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
            for p in sorted(work.rglob("*")):
                if p.is_file():
                    z.write(p, p.relative_to(work).as_posix())
        print(f"injected: {load_path}  (+{size_added} bytes load cmd)")
        print(f"payload : {target.relative_to(work).as_posix()}")
        print(f"output  : {dst}  ({dst.stat().st_size} bytes)")
        print("提醒: 产物签名已失效，需 ldid -S <entitlements>（保留 identifier=com.apple.mobile.MobileHouseArrest）后安装")


if __name__ == "__main__":
    main()
