"""
往开着的 Blender（Blender Lab MCP 扩展，127.0.0.1:9876）里送一段 Python，打印结果。协议同官方 blender-mcp：
JSON {"type": "execute", "code": ..., "strict_json": ...}，以 \\0 结尾；代码里给 `result = {...}` 作为返回。
Claude Code 里接上 MCP（`claude mcp add blender -s user -- ~/.local/bin/blender-mcp`）后用 MCP 工具即可，这个脚本是备用直连。
运行：python3 scripts/Blender/bl.py 文件.py [-- 参数]   或   echo 'result={"n": len(bpy.data.objects)}' | python3 scripts/Blender/bl.py -
"""
import json, socket, sys


def run(code, host="127.0.0.1", port=9876, timeout=3600):
    with socket.create_connection((host, port), timeout=timeout) as s:
        s.sendall((json.dumps({"type": "execute", "code": code, "strict_json": False}) + "\0").encode())
        buf = b""
        while not buf.endswith(b"\0"):
            chunk = s.recv(1 << 16)
            if not chunk: break
            buf += chunk
    return json.loads(buf.rstrip(b"\0").decode())


if __name__ == "__main__":
    src = sys.argv[1] if len(sys.argv) > 1 else "-"
    code = sys.stdin.read() if src == "-" else open(src, encoding="utf-8").read()
    if src != "-":                                                         # 脚本：补上 __file__ 和参数（-- 之后的）
        import os
        args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
        code = "import sys\n__file__ = {!r}\nsys.argv = {!r}\n__name__ = '__main__'\n".format(
            os.path.abspath(src), ["blender", "--", *args]) + code
    r = run(code)
    for k in ("stdout", "stderr"):
        if r.get(k): print(r[k], end="" if r[k].endswith("\n") else "\n", file=sys.stderr if k == "stderr" else sys.stdout)
    if r.get("status") != "ok":
        print(r.get("message", r), file=sys.stderr); sys.exit(1)
    print(json.dumps(r.get("result"), ensure_ascii=False))
