#!/usr/bin/python3 -I
# Patches claude-code-router (3.1.x) in place. Each patch is skipped once its marker is present.
#   cu-ptl2: an upstream context-overflow error reaches Claude Code as a 400
#     "prompt is too long", the phrase Claude Code needs to compact and retry.
#     The router reports "All target providers failed." with the upstream text
#     buried in attempts, so Claude Code never learns the context is full.
#     Only the last attempt counts, and only a 4xx: the first version (cu-ptl)
#     matched the whole attempts JSON, so an upstream 500 outage became
#     "500 prompt is too long" and Claude Code retried instead of reporting it.
#     The gateway bundle holds two copies of that error builder; both are patched,
#     and a cu-ptl copy is upgraded in place.
#   cu-img: an image inside a tool result (Read on a .png) becomes a one-line
#     text note. The router otherwise sends the image as its base64 text:
#     100k-500k tokens the model cannot see as an image.
# CU_ROUTER_DIST is the router's dist/main directory (claude-unlocked passes it).
# Exit 0: nothing new to apply. Exit 10: patched now, restart the router.
# Exit 1: a patch failed (the others still apply).
import os
import shutil
import sys
import time

DIST = os.environ.get("CU_ROUTER_DIST", "")
GATEWAY_JS = os.path.join(DIST, "next-ai-gateway.js")
CLI_JS = os.path.join(DIST, "cli.js")

OVERFLOW = (
    r"maximum context length|context size|context window|context_length_exceeded"
    r"|too many tokens|prompt is too long|input is too long|exceeds the (available|maximum)"
)
BUILDER = 'let r=t[t.length-1];return{status:r&&typeof r.status=="number"&&r.status>=100&&r.status<=599?r.status:502,'
FAILED = BUILDER + 'payload:{error:{message:"All target providers failed.",'
# cu-ptl (first version): any overflow phrase anywhere in the attempts, status untouched.
FAILED_V1 = BUILDER + (
    'payload:{error:{message:/*cu-ptl*/(/' + OVERFLOW + '/i.test(JSON.stringify(t))'
    '?"prompt is too long (upstream context overflow): ":"")+"All target providers failed.",'
)
IMAGE_NOTE = (
    '"[Image not forwarded: this router passes tool-result images only as base64 text, '
    'which the model cannot see ("+(m(n.source?.media_type)||"image")+", "'
    '+Math.round(String(n.source?.data||"").length*3/4096)+" KB). Inspect the file with '
    'text tools instead: OCR (tesseract), metadata (identify), or Python/PIL pixel reads.]"'
)
WIT = (
    'function wit(e){if(typeof e=="string")return e;if(Array.isArray(e)){'
    'let t=e.filter(n=>!I(n)||m(n.type)!=="tool_reference")'
)
PATCHES = [
    {
        "name": "context-overflow errors",
        "target": GATEWAY_JS,
        "marker": "/*cu-ptl2*/",
        "original": FAILED,
        "superseded": [FAILED_V1],
        "count": 2,
        # t is the attempts array and r its last entry in both error builders: function X(e,t){let r=t[t.length-1];...
        "patched": (
            'let r=t[t.length-1],cuO=/*cu-ptl2*/!!r&&typeof r.status=="number"&&r.status>=400&&r.status<500'
            '&&/' + OVERFLOW + '/i.test(JSON.stringify([r.message,r.details]));'
            'return{status:cuO?400:r&&typeof r.status=="number"&&r.status>=100&&r.status<=599?r.status:502,'
            'payload:{error:{message:(cuO?"prompt is too long (upstream context overflow): ":"")+"All target providers failed.",'
        ),
    },
    {
        "name": "tool-result images",
        "target": GATEWAY_JS,
        "marker": "/*cu-img*/",
        "original": WIT,
        "count": 1,
        "patched": WIT + '.map(/*cu-img*/n=>I(n)&&m(n.type)==="image"?{type:"text",text:' + IMAGE_NOTE + "}:n)",
    },
    {
        "name": "disable claude-code settings hijacking",
        "target": CLI_JS,
        "marker": "/*cu-no-settings*/",
        "original": "function ete(e,t,r,n){",
        "count": 1,
        "patched": 'function ete(e,t,r,n){/*cu-no-settings*/return{appliedAt:n,client:t.agent,enabled:!1,message:"Claude Code management disabled.",ok:!0,path:cu(t)};',
    },
]


def apply(patch):
    target = patch["target"]
    try:
        source = open(target, encoding="utf-8").read()
    except OSError as exc:
        print(f"claude-unlocked: router patch for {patch['name']} skipped: {exc}", file=sys.stderr)
        return "failed"
    if patch["marker"] in source:
        return "present"
    original = patch["original"]
    for older in patch.get("superseded", []):
        if source.count(older) == patch["count"]:
            original = older
            break
    count = source.count(original)
    if count != patch["count"]:
        print(
            f"claude-unlocked: router patch for {patch['name']} skipped: "
            f"anchor matched {count} times in {os.path.basename(target)}, want {patch['count']} (router updated?)",
            file=sys.stderr,
        )
        return "failed"
    # Two patches of one file in the same second share the name: the first backup (the unpatched file) is kept.
    backup = f"{target}.orig.{time.strftime('%Y%m%d-%H%M%S')}"
    if not os.path.exists(backup):
        shutil.copy2(target, backup)
    tmp = target + ".cu-tmp"
    with open(tmp, "w", encoding="utf-8") as out:
        out.write(source.replace(original, patch["patched"]))
    shutil.copymode(target, tmp)
    os.replace(tmp, target)
    print(f"claude-unlocked: router patched for {patch['name']} (backup {backup})", file=sys.stderr)
    return "applied"


results = [apply(patch) for patch in PATCHES]
if "applied" in results:
    sys.exit(10)
sys.exit(1 if "failed" in results else 0)
