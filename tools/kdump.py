#!/usr/bin/env python3
"""Pretty-print Kismet bytecode from a kismet-analyzer/UAssetAPI JSON dump.

usage: kdump.py <asset.json> [FunctionName ...]   (no names = list functions)
"""
import json
import sys


def name_of(ptr):
    if ptr is None:
        return "?"
    new = ptr.get("New") if isinstance(ptr, dict) else None
    if new and new.get("Path"):
        return ".".join(new["Path"])
    return "?"


class Dumper:
    def __init__(self, asset):
        self.asset = asset
        self.imports = asset.get("Imports", [])
        self.exports = asset.get("Exports", [])

    def obj(self, idx):
        if isinstance(idx, dict):
            idx = idx.get("Index", 0)
        if not idx:
            return "None"
        if idx < 0:
            imp = self.imports[-idx - 1]
            return imp["ObjectName"]
        return self.exports[idx - 1]["ObjectName"]

    def ex(self, e):
        if e is None:
            return "None"
        t = e["$type"].split(",")[0].split(".")[-1]
        f = getattr(self, "x_" + t, None)
        if f:
            return f(e)
        rest = {k: v for k, v in e.items() if k != "$type"}
        return f"{t}({json.dumps(rest)[:160]})"

    def args(self, e):
        return ", ".join(self.ex(p) for p in e.get("Parameters", []))

    # variables
    def x_EX_LocalVariable(self, e): return name_of(e["Variable"])
    def x_EX_LocalOutVariable(self, e): return "out:" + name_of(e["Variable"])
    def x_EX_InstanceVariable(self, e): return "self." + name_of(e["Variable"])
    def x_EX_DefaultVariable(self, e): return "default." + name_of(e["Variable"])
    def x_EX_Self(self, e): return "self"
    def x_EX_NoObject(self, e): return "null"
    def x_EX_Nothing(self, e): return "nop"
    def x_EX_True(self, e): return "true"
    def x_EX_False(self, e): return "false"
    def x_EX_IntConst(self, e): return str(e["Value"])
    def x_EX_Int64Const(self, e): return str(e["Value"])
    def x_EX_FloatConst(self, e): return str(e["Value"])
    def x_EX_DoubleConst(self, e): return str(e["Value"])
    def x_EX_ByteConst(self, e): return str(e["Value"])
    def x_EX_IntConstByte(self, e): return str(e["Value"])
    def x_EX_IntZero(self, e): return "0"
    def x_EX_IntOne(self, e): return "1"
    def x_EX_StringConst(self, e): return json.dumps(e["Value"])
    def x_EX_UnicodeStringConst(self, e): return json.dumps(e["Value"])
    def x_EX_NameConst(self, e): return "'" + str(e["Value"]) + "'"
    def x_EX_ObjectConst(self, e): return "<" + self.obj(e["Value"]) + ">"
    def x_EX_SoftObjectConst(self, e): return "soft(" + self.ex(e["Value"]) + ")"
    def x_EX_NoInterface(self, e): return "null_iface"
    def x_EX_VectorConst(self, e): return "vec(%s)" % json.dumps(e.get("Value"))
    def x_EX_TextConst(self, e):
        v = e.get("Value") or {}
        for k in ("SourceString", "CultureInvariantString", "LocalizedSource"):
            if v.get(k):
                return "text(" + self.ex(v[k]) + ")"
        return "text()"

    # context
    def x_EX_Context(self, e):
        return self.ex(e["ObjectExpression"]) + "->" + self.ex(e["ContextExpression"]).removeprefix("self.")
    x_EX_Context_FailSilent = x_EX_Context
    x_EX_ClassContext = x_EX_Context
    def x_EX_InterfaceContext(self, e): return self.ex(e["InterfaceValue"])
    def x_EX_StructMemberContext(self, e):
        return self.ex(e["StructExpression"]) + "." + name_of(e["StructMemberExpression"])
    def x_EX_ArrayGetByRef(self, e):
        return self.ex(e["ArrayVariable"]) + "[" + self.ex(e["ArrayIndex"]) + "]"

    # calls
    def call(self, e):
        fn = e.get("StackNode")
        n = self.obj(fn) if fn is not None else str(e.get("VirtualFunctionName"))
        return f"{n}({self.args(e)})"
    x_EX_FinalFunction = call
    x_EX_LocalFinalFunction = call
    x_EX_CallMath = call
    x_EX_VirtualFunction = call
    x_EX_LocalVirtualFunction = call
    def x_EX_CallMulticastDelegate(self, e):
        return "broadcast " + self.ex(e.get("Delegate")) + f"({self.args(e)})"

    # assignment
    def let(self, e):
        return self.ex(e["VariableExpression"]) + " = " + self.ex(e["AssignmentExpression"])
    x_EX_LetBool = let
    x_EX_LetObj = let
    x_EX_LetWeakObjPtr = let
    x_EX_LetDelegate = let
    x_EX_LetMulticastDelegate = let
    def x_EX_Let(self, e):
        return self.ex(e["Variable"]) + " = " + self.ex(e["Expression"])
    def x_EX_LetValueOnPersistentFrame(self, e):
        return "frame." + name_of(e["DestinationProperty"]) + " = " + self.ex(e["AssignmentExpression"])

    # casts
    def x_EX_DynamicCast(self, e):
        return "cast<" + self.obj(e["ClassPtr"]) + ">(" + self.ex(e.get("TargetExpression") or e.get("Target")) + ")"
    x_EX_MetaCast = x_EX_DynamicCast
    x_EX_ObjToInterfaceCast = x_EX_DynamicCast
    def x_EX_InterfaceToObjCast(self, e):
        return "icast<" + self.obj(e["ClassPtr"]) + ">(" + self.ex(e.get("Target") or e.get("TargetExpression")) + ")"
    def x_EX_PrimitiveCast(self, e):
        return "(" + str(e.get("ConversionType")) + ")" + self.ex(e["Target"])
    x_EX_Cast = x_EX_PrimitiveCast

    # flow
    def x_EX_Jump(self, e): return "goto %s" % e["CodeOffset"]
    def x_EX_JumpIfNot(self, e): return "if !(%s) goto %s" % (self.ex(e["BooleanExpression"]), e["CodeOffset"])
    def x_EX_ComputedJump(self, e): return "goto [" + self.ex(e["CodeOffsetExpression"]) + "]"
    def x_EX_PushExecutionFlow(self, e): return "push %s" % e["PushingAddress"]
    def x_EX_PopExecutionFlow(self, e): return "pop"
    def x_EX_PopExecutionFlowIfNot(self, e): return "if !(%s) pop" % self.ex(e["BooleanExpression"])
    def x_EX_Return(self, e): return "return " + self.ex(e["ReturnExpression"])
    def x_EX_EndOfScript(self, e): return "end"
    def x_EX_Tracepoint(self, e): return None
    def x_EX_WireTracepoint(self, e): return None

    def x_EX_SwitchValue(self, e):
        cases = "; ".join(self.ex(c["CaseIndexValueTerm"]) + ": " + self.ex(c["CaseTerm"]) for c in e.get("Cases", []))
        return "switch(" + self.ex(e["IndexTerm"]) + "){" + cases + "; default: " + self.ex(e["DefaultTerm"]) + "}"
    def x_EX_StructConst(self, e):
        return self.obj(e["Struct"]) + "{" + ", ".join(self.ex(v) for v in e.get("Value", [])) + "}"
    def x_EX_SetArray(self, e):
        return self.ex(e["AssigningProperty"]) + " = [" + ", ".join(self.ex(v) for v in e.get("Elements", [])) + "]"
    def x_EX_ArrayConst(self, e):
        return "[" + ", ".join(self.ex(v) for v in e.get("Elements", [])) + "]"
    def x_EX_BindDelegate(self, e):
        return "bind(" + self.ex(e["Delegate"]) + ", " + self.ex(e["ObjectTerm"]) + "." + str(e["FunctionName"]) + ")"
    def x_EX_AddMulticastDelegate(self, e):
        return self.ex(e["Delegate"]) + " += " + self.ex(e["DelegateToAdd"])
    def x_EX_RemoveMulticastDelegate(self, e):
        return self.ex(e["Delegate"]) + " -= " + self.ex(e["DelegateToAdd"])
    def x_EX_InstanceDelegate(self, e): return "delegate:" + str(e["FunctionName"])

    def dump(self, exp):
        props = exp.get("LoadedProperties", [])
        sig = []
        for p in props:
            fl = p.get("PropertyFlags", "")
            if "CPF_Parm" in fl:
                kind = "ret " if "CPF_ReturnParm" in fl else ("out " if "CPF_OutParm" in fl else "")
                sig.append(kind + p["SerializedType"].replace("Property", "") + " " + p["Name"])
        print(f"\n=== {exp['ObjectName']}({', '.join(sig)})")
        for i, e in enumerate(exp.get("ScriptBytecode") or []):
            s = self.ex(e)
            if s is not None:
                print(f"  [{i}] {s}")


def main():
    asset = json.load(open(sys.argv[1]))
    d = Dumper(asset)
    funcs = [e for e in asset["Exports"] if "FunctionExport" in e["$type"]]
    if len(sys.argv) == 2:
        print(" ".join(sorted(e["ObjectName"] for e in funcs)))
        return
    for want in sys.argv[2:]:
        for e in funcs:
            if e["ObjectName"] == want:
                d.dump(e)


if __name__ == "__main__":
    main()
