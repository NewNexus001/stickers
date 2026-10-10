s = open("lib/src/settings/settings_page.dart", encoding="utf-8").read()
lines = s.split("\n")
# Line 91 (1-indexed) = index 90
print("line 91:", repr(lines[90]))
if not lines[90].rstrip().endswith(")"):
    lines[90] = lines[90].rstrip() + ")"
    print("added )")
else:
    print("already has )")
open("lib/src/settings/settings_page.dart", "w", encoding="utf-8").write("\n".join(lines))
