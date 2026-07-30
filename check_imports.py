import re, os, sys

def get_imports(content):
    return re.findall(r"^import\s+'([^']+)'(?:\s+as\s+(\w+))?.*?;", content, re.MULTILINE)

def local_symbol_names(path):
    """Extract top-level class/enum/mixin/extension/typedef/function names from a dart file."""
    if not os.path.exists(path):
        return []
    with open(path, encoding='utf-8', errors='ignore') as f:
        c = f.read()
    names = set()
    for m in re.finditer(r'^\s*(?:abstract\s+)?class\s+(\w+)', c, re.MULTILINE):
        names.add(m.group(1))
    for m in re.finditer(r'^\s*enum\s+(\w+)', c, re.MULTILINE):
        names.add(m.group(1))
    for m in re.finditer(r'^\s*mixin\s+(\w+)', c, re.MULTILINE):
        names.add(m.group(1))
    for m in re.finditer(r'^\s*extension\s+(\w+)', c, re.MULTILINE):
        names.add(m.group(1))
    for m in re.finditer(r'^\s*typedef\s+(\w+)', c, re.MULTILINE):
        names.add(m.group(1))
    return names

root = 'lib'
for dirpath, _, files in os.walk(root):
    for fn in files:
        if not fn.endswith('.dart'):
            continue
        path = os.path.join(dirpath, fn)
        with open(path, encoding='utf-8', errors='ignore') as f:
            content = f.read()
        imports = get_imports(content)
        # body without import lines
        body = re.sub(r"^import\s+.*?;\s*$", "", content, flags=re.MULTILINE)
        for imp, alias in imports:
            if imp.startswith('dart:') or imp.startswith('package:flutter/') :
                continue  # too broad, skip common ones for this heuristic
            if imp.startswith('package:') and not imp.startswith('package:termul') and 'termullscan' not in imp:
                # third-party package import; skip heuristic (would need pubspec name)
                continue
            if alias:
                used = re.search(r'\b' + re.escape(alias) + r'\.', body)
                if not used:
                    print(f"{path}: possibly unused import '{imp}' as {alias}")
                continue
            # resolve relative import to file path
            if imp.startswith('package:'):
                # convert package:app_name/x/y.dart -> lib/x/y.dart
                parts = imp.split('/', 1)
                if len(parts) == 2:
                    target = os.path.join('lib', parts[1])
                else:
                    continue
            else:
                target = os.path.normpath(os.path.join(dirpath, imp))
            names = local_symbol_names(target)
            if not names:
                continue
            used_any = False
            for name in names:
                if re.search(r'\b' + re.escape(name) + r'\b', body):
                    used_any = True
                    break
            if not used_any:
                print(f"{path}: possibly unused import '{imp}' (defines: {names})")
