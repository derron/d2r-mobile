"""验证共用生命周期、条件布局及构建开关。 | Verify shared lifecycle, conditional layout and build switches."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
class WebDAVIntegrationTests(unittest.TestCase):
    def test_actual_shared_lifecycle(self):
        with tempfile.TemporaryDirectory() as folder:
            binary=Path(folder)/'lifecycle'
            subprocess.run(['xcrun','--sdk','macosx','clang','-DDM_WEBDAV=1','-I'+str(ROOT/'dm/host'),'-fobjc-arc','-Wall','-Wextra','-Werror',str(ROOT/'dm/host/tests/webdav_lifecycle_driver.m'),'-framework','Foundation','-framework','Network','-o',str(binary)],check=True)
            result=subprocess.run([str(binary)],capture_output=True,text=True,check=True)
            self.assertIn('PASS:',result.stdout)
    def test_layout_options_keep_original_order_and_append_optional_controls(self):
        code='import sys,json;sys.path.insert(0,"dm/ios/tools");import touch_layout as t;print(json.dumps(t._CUSTOM_KEYS));print(t._custom_settings_row(len(t._CUSTOM_ALL)-1,"Settings") if "webdav" in t._CUSTOM_KEYS else "off")'
        outputs={}
        voice_options=['0','1'] if 'VOICE_ROW' in (ROOT/'dm/host/dm_custom.c').read_text() else ['0']
        for voice in voice_options:
            for enabled in ['0','1']:
                result=subprocess.run(['python3','-c',code],cwd=ROOT,env={**os.environ,'DM_WEBDAV':enabled,'MOVIE_FFMPEG':voice},capture_output=True,text=True,check=True)
                import json
                outputs[voice,enabled]=json.loads(result.stdout.splitlines()[0])
                if enabled=='1': self.assertIn('PanelManager:ClosePanel:TouchCustom_webdav_settings',result.stdout)
            self.assertEqual(outputs[voice,'1'][:-2],outputs[voice,'0'])
            self.assertEqual(outputs[voice,'1'][-2:],['webdav','webdav_settings'])
        if '1' in voice_options: self.assertEqual(outputs['1','0'][1:],outputs['0','0'])
    def test_default_link_command_has_no_webdav_implementation_or_security_dependency(self):
        for enabled in ['0','1']:
            result=subprocess.run(['make','-s','-n','-B','-C',str(ROOT/'dm/host'),'dmhost','WEBDAV='+enabled],capture_output=True,text=True,check=True)
            command=next(line for line in result.stdout.splitlines() if line.startswith('clang '))
            self.assertEqual('webdav_store.m' in command,enabled=='1')
            self.assertEqual('-DDM_WEBDAV=1' in command,enabled=='1')
            self.assertEqual('-framework Security' in command,enabled=='1')
    def test_project_usage_description_is_opt_in(self):
        with tempfile.TemporaryDirectory() as folder:
            output=Path(folder)/'enabled.yml'
            subprocess.run(['python3',str(ROOT/'dm/ios/tools/project_webdav.py'),str(ROOT/'dm/ios/project.yml'),str(output)],check=True)
            self.assertNotIn('NSLocalNetworkUsageDescription',(ROOT/'dm/ios/project.yml').read_text())
            self.assertIn('NSLocalNetworkUsageDescription',output.read_text())
if __name__=='__main__':unittest.main()
