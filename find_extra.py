import re
s = open("lib/src/settings/settings_page.dart", encoding="utf-8").read()
s2 = re.sub(r"//.*", "", s)
s2 = re.sub(r"/\*.*?\*/", "", s2, flags=re.S)
s2 = re.sub(r'"[^"]*"', "", s2)
s2 = re.sub(r"'[^']*'", "", s2)
pairs = {")":"(", "]":"[", "}":"{"}
depth = {"(":0, "[":0, "{":0}
extras = []
for i, c in enumerate(s2):
    if c in "([{": depth[c]+=1
    elif c in ")]}":
        op = pairs[c]
        if depth[op]==0:
            extras.append((i, c, s2[:i].count("\n")+1))
        else:
            depth[op]-=1
print("Total extra closes found:", len(extras))
for i, c, line in extras:
    print(f"  EXTRA {c} at index {i} (line {line})")
    print(f"    context: {repr(s2[max(0,i-50):i+20])}")
