#!/usr/bin/env python3
"""为显式启用的包加入局域网用途说明；默认工程原样保留。 | Add local-network usage text only to explicitly enabled builds."""
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[1:])
text = source.read_text()
anchor = '        CFBundleDisplayName: D2R Mobile\n'
if text.count(anchor) != 1:
    raise SystemExit('Expected exactly one main App display-name property')
destination.write_text(text.replace(anchor, anchor + '        NSLocalNetworkUsageDescription: Connect to WebDAV to sync save packs.\n'))
