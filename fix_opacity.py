import re, sys

def replace_with_opacity(text):
    result = []
    i = 0
    n = len(text)
    pattern = ".withOpacity("
    while True:
        idx = text.find(pattern, i)
        if idx == -1:
            result.append(text[i:])
            break
        result.append(text[i:idx])
        # find matching close paren starting after "("
        start = idx + len(pattern)
        depth = 1
        j = start
        while j < n and depth > 0:
            if text[j] == '(':
                depth += 1
            elif text[j] == ')':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        expr = text[start:j]  # j is index of matching ')'
        result.append(".withValues(alpha: " + expr.strip() + ")")
        i = j + 1
    return "".join(result)

for path in sys.argv[1:]:
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
    new_content = replace_with_opacity(content)
    if new_content != content:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(new_content)
        print("Updated:", path)
