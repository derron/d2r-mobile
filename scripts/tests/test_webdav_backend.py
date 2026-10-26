"""共用核心与真实 HTTP 的隔离回归，不使用任何旧 WebDAV 实现。 | Isolated shared-core/real-HTTP regression, independent of the old implementation."""
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import threading
import time
import unittest
from urllib.parse import unquote, urlsplit
from xml.sax.saxutils import escape
ROOT = Path(__file__).resolve().parents[2]

class Endpoint(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def respond(self, code, data=b'', **headers):
        self.send_response(code)
        self.send_header('Content-Length', str(len(data)))
        for name,value in headers.items(): self.send_header(name.replace('_','-'),str(value))
        self.end_headers()
        if self.command != 'HEAD':
            try: self.wfile.write(data)
            except (BrokenPipeError,ConnectionResetError): pass
    def handle_one_request(self):
        try: super().handle_one_request()
        except (BrokenPipeError,ConnectionResetError): self.close_connection=True
    def record(self):
        self.server.calls.append((self.command,self.path))
        self.server.connections.add(self.client_address)
        if self.server.auth_error:
            self.respond(403)
            return False
        return True
    def do_PROPFIND(self):
        self.rfile.read(int(self.headers.get('Content-Length','0')))
        if not self.record(): return
        if self.server.list_error: return self.respond(503)
        if self.server.bad_xml: return self.respond(207,b'<broken>')
        path=unquote(urlsplit(self.path).path)
        if path not in self.server.folders and path not in self.server.files: return self.respond(404)
        names=[path]
        if self.headers.get('Depth')=='1': names+=sorted(p for p in self.server.files if p.startswith(path) and '/' not in p[len(path):])
        rows=[]
        for name in names:
            folder=name in self.server.folders
            size=len(self.server.files.get(name,b'')) + self.server.prop_delta
            props='<d:resourcetype><d:collection/></d:resourcetype>' if folder else '<d:resourcetype/>'
            if not folder and not self.server.no_sizes: props+=f'<d:getcontentlength>{size}</d:getcontentlength>'
            rows.append(f'<d:response><d:href>{escape(name)}</d:href><d:propstat><d:prop>{props}</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>')
        if self.server.extra_href: rows.append(f'<d:response><d:href>{escape(self.server.extra_href)}</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>')
        self.respond(207,('<d:multistatus xmlns:d="DAV:">'+''.join(rows)+'</d:multistatus>').encode())
    def digest_headers(self, data):
        if not self.server.hash_algorithm: return {}
        algorithm=self.server.hash_algorithm
        digest=hashlib.new(algorithm.replace('-',''),data).digest()
        if self.server.bad_hash: digest=bytes(len(digest))
        return {'Repr-Digest':algorithm+'=:'+base64.b64encode(digest).decode()+':'}
    def do_HEAD(self):
        if not self.record(): return
        if self.server.head_delay: time.sleep(self.server.head_delay)
        if self.server.head_code!=200: return self.respond(self.server.head_code)
        path=unquote(urlsplit(self.path).path)
        data=self.server.files.get(path)
        if data is None: return self.respond(404)
        self.send_response(200)
        if not self.server.no_sizes: self.send_header('Content-Length',str(len(data)+self.server.head_delta+(self.server.final_delta if path.endswith(".pack") else 0)))
        for name,value in self.digest_headers(data).items(): self.send_header(name,value)
        # HEAD 的 Content-Digest 是空正文摘要。 | A HEAD Content-Digest describes an empty body.
        self.send_header('Content-Digest','sha-256=:'+base64.b64encode(hashlib.sha256(b'').digest()).decode()+':')
        self.end_headers()
    def do_GET(self):
        if not self.record(): return
        path=unquote(urlsplit(self.path).path)
        data=self.server.files.get(path)
        if data is None: return self.respond(404)
        self.respond(200,data,**self.digest_headers(data))
    def do_PUT(self):
        data=self.rfile.read(int(self.headers.get('Content-Length','0')))
        if not self.record(): return
        if self.server.fail_put: return self.respond(507)
        path=unquote(urlsplit(self.path).path)
        if self.server.corrupt: data=(b'Z'+data[1:]) if data else b'Z'
        self.server.files[path]=data
        headers={'X-Hash-SHA256':hashlib.sha256(data).hexdigest()} if self.server.put_hash else {}
        self.respond(201,**headers)
    def do_MOVE(self):
        if not self.record(): return
        if self.server.fail_move: return self.respond(503)
        source=unquote(urlsplit(self.path).path)
        target=unquote(urlsplit(self.headers['Destination']).path)
        if source not in self.server.files: return self.respond(404)
        self.server.files[target]=self.server.files.pop(source)
        self.respond(503 if self.server.lose_move else 201)
    def do_MKCOL(self):
        if not self.record(): return
        self.server.folders.add(unquote(urlsplit(self.path).path));self.respond(201)
    def do_DELETE(self):
        if not self.record(): return
        path=unquote(urlsplit(self.path).path)
        self.server.files={k:v for k,v in self.server.files.items() if k!=path and not k.startswith(path)}
        self.server.folders.discard(path);self.respond(204)

class WebDAVBackendTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build=tempfile.TemporaryDirectory(prefix='webdav-packs-build-')
        cls.binary=Path(cls.build.name)/'driver'
        subprocess.run(['xcrun','--sdk','macosx','clang','-DDM_WEBDAV=1','-fobjc-arc','-Wall','-Wextra','-Werror',str(ROOT/'dm/host/tests/webdav_pack_driver.m'),str(ROOT/'dm/ios/Sources/webdav_store.m'),str(ROOT/'dm/host/dm_cloudsync.c'),str(ROOT/'dm/host/dm_i18n.c'),'-framework','Foundation','-o',str(cls.binary)],check=True)
    @classmethod
    def tearDownClass(cls): cls.build.cleanup()
    def setUp(self):
        self.folder=tempfile.TemporaryDirectory(prefix='webdav-packs-data-')
        self.base=Path(self.folder.name)
        self.server=ThreadingHTTPServer(('127.0.0.1',0),Endpoint)
        self.server.daemon_threads=True
        self.server.files={};self.server.folders={'/packs/'}
        self.server.calls=[];self.server.connections=set()
        for key,value in dict(auth_error=False,list_error=False,bad_xml=False,extra_href='',hash_algorithm='',bad_hash=False,no_sizes=False,prop_delta=0,head_delta=0,final_delta=0,head_code=200,head_delay=0,fail_put=False,put_hash=False,corrupt=False,fail_move=False,lose_move=False).items(): setattr(self.server,key,value)
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.url=f'http://127.0.0.1:{self.server.server_port}/packs'
        self.addCleanup(self.folder.cleanup);self.addCleanup(self.server.server_close);self.addCleanup(self.server.shutdown)
    def save(self,device='a',name='Hero',data=b'first',stamp=1000):
        p=self.base/device/'save'/name/(name+'.d2s');p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data);os.utime(p,(stamp,stamp));return p
    def run_sync(self,device='a',allow=0,timeout=8):
        p=subprocess.run([str(self.binary),self.url,str(self.base/device),str(allow),str(timeout)],capture_output=True,text=True,timeout=15)
        self.assertEqual(p.returncode,0,p.stderr)
        result=int(p.stdout.split('result=')[1].split()[0]);return result,p
    def test_round_trip_same_core_and_sidecars(self):
        source=self.save();side=source.with_suffix('.sw_kills');side.write_bytes(b'kills')
        self.assertEqual(self.run_sync()[0],1)
        self.assertEqual(set(self.server.files),{'/packs/Hero.pack'})
        self.assertEqual(self.run_sync('b',1)[0],1)
        self.assertEqual((self.base/'b/save/Hero/Hero.d2s').read_bytes(),b'first')
        self.assertEqual((self.base/'b/save/Hero/Hero.sw_kills').read_bytes(),b'kills')
    def test_first_collision_keeps_local_backup_and_uses_remote(self):
        self.save(data=b'remote');self.run_sync();self.save('b',data=b'local',stamp=2000)
        self.assertEqual(self.run_sync('b',1)[0],1)
        self.assertEqual((self.base/'b/save/Hero/Hero.d2s').read_bytes(),b'remote')
        self.assertEqual((self.base/'b/backups/Hero-2000000/Hero/Hero.d2s').read_bytes(),b'local')
    def test_backup_failure_prevents_local_replacement(self):
        self.save(data=b'remote');self.run_sync();self.save('b',data=b'local',stamp=2000)
        (self.base/'b/backups').write_bytes(b'blocked')
        self.run_sync('b',1)
        self.assertEqual((self.base/'b/save/Hero/Hero.d2s').read_bytes(),b'local')
    def test_verified_upload_has_no_readback_and_reuses_connection(self):
        self.save();self.server.hash_algorithm='sha-256';self.assertEqual(self.run_sync()[0],1)
        self.assertFalse(any(m=='GET' for m,p in self.server.calls))
        self.assertEqual(len(self.server.connections),1)
        self.assertEqual(sum(m=='HEAD' for m,p in self.server.calls),2)
    def test_supported_hashes(self):
        for algorithm in ['sha-512','sha-256','sha-1','md5']:
            with self.subTest(algorithm=algorithm):
                self.server.files={};self.server.hash_algorithm=algorithm;self.save(algorithm)
                self.assertEqual(self.run_sync(algorithm)[0],1)
    def test_put_server_hash_is_checked(self):
        self.save();self.server.put_hash=True;self.server.corrupt=True
        self.assertEqual(self.run_sync()[0],-1);self.assertNotIn('/packs/Hero.pack',self.server.files)
    def test_corrupt_same_size_hash_rejects_before_publish(self):
        self.save();self.server.hash_algorithm='sha-256';self.server.corrupt=True
        self.assertEqual(self.run_sync()[0],-1);self.assertNotIn('/packs/Hero.pack',self.server.files)
        self.assertFalse((self.base/'a/state').read_text().strip())
    def test_bad_server_digest_stops(self):
        self.save();self.server.hash_algorithm='sha-256';self.server.bad_hash=True
        self.assertEqual(self.run_sync()[0],-1)
    def test_size_mismatch_stops_before_move(self):
        self.save();self.server.head_delta=1;self.assertEqual(self.run_sync()[0],-1)
        self.assertFalse(any(m=='MOVE' for m,p in self.server.calls))
    def test_propfind_size_fallback(self):
        self.save();self.server.head_code=405;self.assertEqual(self.run_sync()[0],1)
    def test_no_sizes_is_not_success(self):
        self.save();self.server.no_sizes=True;self.assertEqual(self.run_sync()[0],-1)
    def test_listing_failure_never_becomes_empty_remote(self):
        self.save();self.server.list_error=True;self.assertEqual(self.run_sync()[0],-1)
        self.assertEqual([m for m,p in self.server.calls],['PROPFIND'])
    def test_authentication_stops_after_one_request(self):
        self.save();self.server.auth_error=True;self.assertEqual(self.run_sync()[0],-1)
        self.assertEqual(len(self.server.calls),1)
    def test_wrong_origin_href_rejected(self):
        self.save();self.server.extra_href='http://example.invalid/packs/Hero.pack';self.assertEqual(self.run_sync()[0],-1)
        self.assertFalse(any(m=='PUT' for m,p in self.server.calls))
    def test_malformed_xml_rejected(self):
        self.save();self.server.bad_xml=True;self.assertEqual(self.run_sync()[0],-1)
    def test_lost_move_response_reconciles_next_attempt(self):
        self.save();self.server.lose_move=True;self.assertEqual(self.run_sync()[0],-1)
        self.assertIn('/packs/Hero.pack',self.server.files)
        self.server.lose_move=False;self.assertEqual(self.run_sync()[0],0)
        self.assertIn('Hero',(self.base/'a/state').read_text())
    def test_failed_put_stops_and_retry_preserves_current(self):
        self.save();self.server.fail_put=True;self.assertEqual(self.run_sync()[0],-1)
        self.assertFalse(self.server.files)
        self.server.fail_put=False;self.assertEqual(self.run_sync()[0],1)
    def test_deleted_character_uses_pack_tombstone(self):
        p=self.save();self.run_sync();p.unlink();p.parent.rmdir();self.assertEqual(self.run_sync()[0],1)
        magic,stamp,flag,count=struct.unpack('<8sQII',self.server.files['/packs/Hero.pack'])
        self.assertEqual((magic,flag,count),(b'SWPK1\n\0\0',1,0))
    def test_startup_missing_character_downloads_instead_of_deleting(self):
        self.save();self.run_sync();self.assertEqual(self.run_sync('b',1)[0],1)
        p=self.base/'b/save/Hero/Hero.d2s';p.unlink();p.parent.rmdir()
        self.assertEqual(self.run_sync('b',1)[0],1);self.assertTrue(p.exists())
    def test_download_hash_mismatch_keeps_existing_save(self):
        self.save();self.run_sync();self.save('b',data=b'local',stamp=2000);self.server.hash_algorithm='sha-256';self.server.bad_hash=True
        self.assertEqual(self.run_sync('b',1)[0],-1);self.assertEqual((self.base/'b/save/Hero/Hero.d2s').read_bytes(),b'local')
    def test_timeout_does_not_confirm_upload(self):
        self.save();self.server.head_delay=.4;self.assertEqual(self.run_sync(timeout=.15)[0],-1)
        self.assertNotIn('/packs/Hero.pack',self.server.files)
    def test_same_instance_timeout_reconnects_and_isolates_late_callback(self):
        self.save(); self.server.head_delay=.3
        result,process=self.run_sync(allow='reuse-timeout',timeout=.1)
        self.assertIn('first=-1',process.stdout)
        self.assertEqual(result,1,process.stderr)
        self.assertGreaterEqual(len(self.server.connections),2)
        self.assertIn('/packs/Hero.pack',self.server.files)
    def test_final_size_failure_does_not_confirm_baseline(self):
        self.save(); self.server.final_delta=1
        self.assertEqual(self.run_sync()[0],-1)
        self.assertNotIn('W Hero', (self.base/'a/state').read_text())
        self.server.final_delta=0
        self.assertGreaterEqual(self.run_sync()[0],0)

    def test_shared_stash_collision_uses_existing_inbox_and_backup(self):
        def stash(device,items,chron,stamp):
            data=bytearray(68+chron);data[:4]=bytes.fromhex('55aa55aa');struct.pack_into('<I',data,16,68);data[64:66]=b'JM';struct.pack_into('<H',data,66,items)
            data[68:72]=bytes.fromhex('55aa55aa');struct.pack_into('<I',data,84,chron)
            p=self.base/device/'save/ModernSharedStashSoftCoreV2/ModernSharedStashSoftCoreV2.d2i';p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data);os.utime(p,(stamp,stamp));return p,bytes(data)
        a,remote=stash('a',5,300,1000);self.assertEqual(self.run_sync()[0],1)
        b,local=stash('b',3,400,2000);self.assertEqual(self.run_sync('b',1)[0],1)
        self.assertEqual(b.read_bytes(),remote)
        self.assertEqual(len(list((self.base/'b/save/_cloudinbox').glob('*/mine.pack'))),1)
        self.assertEqual((self.base/'b/backups/_stash-2000000/ModernSharedStashSoftCoreV2/ModernSharedStashSoftCoreV2.d2i').read_bytes(),local)
    def test_foreign_character_payload_is_rejected(self):
        name=b'Other/Other.d2s';payload=struct.pack('<8sQII',b'SWPK1\n\0\0',1000000,0,1)+struct.pack('<H',len(name))+name+struct.pack('<QI',1000000,4)+b'evil'
        self.server.files['/packs/Hero.pack']=payload
        self.assertEqual(self.run_sync('b',1)[0],-1)
        self.assertFalse((self.base/'b/save/Other').exists())
    def test_unicode_character_name_round_trips(self):
        self.save(name='测试角色');self.assertEqual(self.run_sync()[0],1);self.assertEqual(self.run_sync('b',1)[0],1)
        self.assertEqual((self.base/'b/save/测试角色/测试角色.d2s').read_bytes(),b'first')
    def test_orphan_staging_is_cleaned_before_retry(self):
        self.save();self.server.fail_move=True;self.assertEqual(self.run_sync()[0],-1)
        self.assertTrue(any('.d2r-upload-' in p for p in self.server.files))
        self.server.fail_move=False;self.assertEqual(self.run_sync()[0],1)
        self.assertEqual(set(self.server.files),{'/packs/Hero.pack'})
    def test_probe_uses_and_removes_only_temporary_directory(self):
        self.server.files['/packs/untouched']=b'user';self.assertEqual(self.run_sync(allow='probe')[0],0)
        self.assertEqual(self.server.files,{'/packs/untouched':b'user'})

if __name__=='__main__': unittest.main()
