"""Summarize a KLayout .lyrdb by DRC rule and approximate error location."""
import re
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict

root = ET.parse(sys.argv[1]).getroot()
counts = Counter()
locations = defaultdict(list)
for item in root.findall(".//item"):
    category = item.findtext("category", "").strip("'") or "<uncategorized>"
    counts[category] += 1
    value = item.findtext("values/value", "")
    nums = [float(v) for v in re.findall(r"[-+]?[0-9]*\.?[0-9]+", value)]
    if len(nums) >= 2:
        locations[category].append((nums[0], nums[1]))

for category, count in counts.most_common():
    points = locations[category]
    if points:
        xs, ys = zip(*points)
        print(f"{count:4} {category:8} x={min(xs):.3f}..{max(xs):.3f} y={min(ys):.3f}..{max(ys):.3f}")
    else:
        print(f"{count:4} {category:8}")
