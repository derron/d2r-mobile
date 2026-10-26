"""现有自定义页中两位置换组开关的跨语言契约。 | Cross-language contract for the two-position switch in the existing Custom page. | Cross-language contract for the two-position switch in the existing Custom page."""
import importlib
import json
import os
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / 'ios/tools'))
os.environ.pop('DM_WEBDAV', None)
os.environ.pop('MOVIE_FFMPEG', None)   # 缺省包的自定义页（「配音」行只在 MOVIE_FFMPEG=1 时有，下面另核）
import touch_layout as layout

out, _ = layout._custom_page('"name": "VideoOptionsPanel", "name": "OptionsTable"')
page = json.loads(re.sub(r',\s*([}\]])', r'\1', out))
nodes = {}
def walk(node):
    if isinstance(node, dict):
        if 'name' in node:
            assert node['name'] not in nodes, node['name']
            nodes[node['name']] = node
        for child in node.values():
            walk(child)
    elif isinstance(node, list):
        for child in node:
            walk(child)
walk(page)
for name in ('TouchCustom_touch_swap_above', 'TouchCustom_touch_swap_above_near'):
    assert nodes[name]['type'] == 'ToggleButtonWidget'
    assert nodes[name]['fields']['onClickMessage'].endswith(name)
assert nodes['TouchCustom_touch_swap_above_Text']['fields']['rect']['height'] == 360
for suffix in ('Near', 'Far'):
    assert any(n.get('fields', {}).get('text') == '@dmCustomTouchSwap' + suffix for n in nodes.values())
host_src = (root / 'host/dm_custom.c').read_text()
def host_variant(voice, webdav):
    # 两个可选特性分别控制键表与默认值，不能把禁用块算进缺省布局。
    # Each optional feature controls its keys/defaults; disabled blocks are not part of the default layout.
    keep = re.sub(r'#if VOICE_ROW\n(.*?)#endif\n', (lambda m: m[1]) if voice else '', host_src, flags=re.S)
    keep = re.sub(r'#if DM_WEBDAV\n(.*?)#endif\n', (lambda m: m[1]) if webdav else '', keep, flags=re.S)
    return re.sub(r'(?m)^#.*\n', '', keep)
for voice in ((False, True) if "VOICE_ROW" in host_src else (False,)):
    for webdav in (False, True):
        for name, enabled in (('MOVIE_FFMPEG', voice), ('DM_WEBDAV', webdav)):
            if enabled: os.environ[name] = '1'
            else: os.environ.pop(name, None)
        layout = importlib.reload(layout)
        host = host_variant(voice, webdav)
        keys = re.findall(r'"([a-z_0-9]+)"', re.search(r'k_keys\[\].*?=\s*\{(.*?)\}', host, re.S)[1])
        assert keys == [key for key, _ in layout._CUSTOM_ALL], (voice, webdav, keys)
        assert ('voice' in keys) == voice
        assert ('webdav' in keys) == webdav
        defaults = [int(x) for x in re.search(r'k_def\[NK\].*?=\s*\{(.*?)\}', host, re.S)[1].split(',')]
        assert len(defaults) == len(keys) and defaults[keys.index('touch_swap_above')] == 0
        if webdav:
            assert defaults[keys.index('webdav')] == 0
            out, _ = layout._custom_page('"name": "VideoOptionsPanel", "name": "OptionsTable"')
            nodes.clear(); walk(json.loads(re.sub(r',\s*([}\]])', r'\1', out)))
            assert nodes['TouchCustom_webdav_settings']['type'] == 'ButtonWidget'
            assert nodes['TouchCustom_webdav_settings']['fields']['onClickMessage'].endswith('TouchCustom_webdav_settings')
os.environ.pop('MOVIE_FFMPEG', None); os.environ.pop('DM_WEBDAV', None); layout = importlib.reload(layout)
host = host_src
assert 'TouchCustom_touch_swap_above_near' in host
print('PASS touch layout options: generated radio pair, labels, defaults, host order (default and MOVIE_FFMPEG=1) and scrolling row extent')
