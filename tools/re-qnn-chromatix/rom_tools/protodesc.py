"""Extract serialized FileDescriptorProtos embedded in a binary (protobuf C++ generated code).

  python protodesc.py LIB OUT.pb     -> FileDescriptorSet with every embedded .proto
"""
import re
import sys

from google.protobuf import descriptor_pb2

from mipb import varint


def try_parse(data, start):
    """Greedy: grow a FileDescriptorProto field by field from `start`."""
    i, end = start, start
    while i < len(data):
        try:
            k, j = varint(data, i)
        except IndexError:
            break
        f, wt = k >> 3, k & 7
        if not (1 <= f <= 14) or wt not in (0, 2):
            break
        if wt == 0:
            _, j = varint(data, j)
        else:
            n, j = varint(data, j)
            j += n
            if j > len(data):
                break
        i = end = j
    fd = descriptor_pb2.FileDescriptorProto()
    try:
        fd.ParseFromString(data[start:end])
    except Exception:
        return None
    return fd if fd.name.endswith(".proto") and (fd.message_type or fd.enum_type) else None


def main():
    data = open(sys.argv[1], "rb").read()
    fs = descriptor_pb2.FileDescriptorSet()
    seen = set()
    for m in re.finditer(rb"\x0a([\x01-\x7f])([A-Za-z0-9_./]+\.proto)", data):
        if len(m.group(2)) != m.group(1)[0]:
            continue
        fd = try_parse(data, m.start())
        if fd and fd.name not in seen:
            seen.add(fd.name)
            fs.file.append(fd)
    open(sys.argv[2], "wb").write(fs.SerializeToString())
    for f in fs.file:
        print(f.name, f.package, len(f.message_type), "msgs", list(f.dependency))


if __name__ == "__main__":
    main()
