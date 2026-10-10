path = "lib/src/settings/settings_page.dart"
s = open(path, encoding="utf-8").read()
lines = s.split("\n")
for i, l in enumerate(lines):
    if "return Scaffold(" in l:
        print("build() body starts at line", i+1)
        for j in range(i, len(lines)):
            if ');' in lines[j] and j > i:
                print("build method ends at line", j+1)
                break
        print("\nBuild() content:")
        for k in range(i, len(lines)):
            print(f"{k+1}: {lines[k]}")
        break
