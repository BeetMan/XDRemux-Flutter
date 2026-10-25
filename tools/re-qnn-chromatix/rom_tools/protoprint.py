"""Print messages/enums of a FileDescriptorSet as .proto-like text.
  python protoprint.py SET.pb [regex]"""
import re
import sys

from google.protobuf import descriptor_pb2

T = {1: "double", 2: "float", 3: "int64", 4: "uint64", 5: "int32", 8: "bool", 9: "string",
     11: "msg", 12: "bytes", 13: "uint32", 14: "enum", 17: "sint32", 18: "sint64"}
fs = descriptor_pb2.FileDescriptorSet()
fs.ParseFromString(open(sys.argv[1], "rb").read())
pat = re.compile(sys.argv[2]) if len(sys.argv) > 2 else None


def pm(m, ind=""):
    print(f"{ind}message {m.name} {{")
    for f in m.field:
        t = f.type_name.split(".")[-1] if f.type in (11, 14) else T.get(f.type, f.type)
        lab = "repeated " if f.label == 3 else ""
        print(f"{ind}  {lab}{t} {f.name} = {f.number};")
    for n in m.nested_type:
        pm(n, ind + "  ")
    for e in m.enum_type:
        print(f"{ind}  enum {e.name} {{ " + ", ".join(f"{v.name}={v.number}" for v in e.value) + " }")
    print(f"{ind}}}")


for f in fs.file:
    for m in f.message_type:
        if pat is None or pat.search(m.name) or pat.search(f.name):
            print(f"// {f.name}")
            pm(m)
    for e in f.enum_type:
        if pat is None or pat.search(e.name) or pat.search(f.name):
            print(f"enum {e.name} {{ " + ", ".join(f"{v.name}={v.number}" for v in e.value) + " }")
