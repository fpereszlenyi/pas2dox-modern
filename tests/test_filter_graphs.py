"""Exercise the native EXE as Doxygen INPUT_FILTER, without project preparation."""
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / 'build/pas2dox.exe'

SOURCES = {
    'Devices/Device.Protocol.pas': '''unit Device.Protocol; interface
type TDevice=class
public
  procedure ChangeMatrix(X,Y:Byte; State:Boolean);
  procedure MatrixOff;
  procedure Run;
  procedure Pick(X:Integer); overload;
  procedure Pick(X,Y:Integer); overload;
  procedure Ambiguous(X:Integer); overload;
  procedure Ambiguous(X:string); overload;
  procedure NeedsTwo(X,Y:Integer; Text:string='x=y');
end;
procedure Leaf;
implementation
procedure TDevice.ChangeMatrix(X,Y:Byte;State:Boolean); begin MatrixOff; end;
procedure TDevice.MatrixOff; begin end;
procedure TDevice.Run; begin self.changematrix(1,2,True); end;
procedure TDevice.Pick(X:Integer); begin end;
procedure TDevice.Pick(X,Y:Integer); begin end;
procedure TDevice.Ambiguous(X:Integer); begin end;
procedure TDevice.Ambiguous(X:string); begin end;
procedure TDevice.NeedsTwo(X,Y:Integer;Text:string); begin end;
procedure Leaf; begin end;
end.
''',
    'MainForm.pas': '''unit MainForm; interface
uses Device.Protocol;
type TMain=class public Device:TDevice; property Current:TDevice read Device; end;
var TheForm:TMain;
implementation end.
''',
    'Client.pas': '''unit Client; interface
uses MainForm, Device.Protocol;
type TCallback=reference to procedure;
TDeviceAlias=Device.Protocol.TDevice;
TClient=class
public
  procedure Direct;
  procedure Anonymous;
  procedure Nested;
  procedure ParameterCallback(Leaf:TCallback);
  procedure AssignCallback;
  procedure TypedAnonymous;
  procedure LocalAnonymous;
  procedure Inactive;
  procedure TypedLocal;
  procedure InferredLocal;
  procedure PropertyCall;
  procedure OverloadArity;
  procedure AmbiguousCall;
  procedure MissingArgument;
  procedure UnknownReceiver(External:TObject);
  procedure WithScope;
  function OwnResult:Integer;
end;
procedure ParameterCollision(Leaf:Integer);
implementation
procedure TClient.Direct;
begin mainform.theform.device.changematrix(1,2,True); end;
procedure TClient.Anonymous;
begin
  Queue(procedure begin TheForm.Device.ChangeMatrix(1,2,True); end);
end;
procedure TClient.Nested;
  procedure Hidden;
  begin TheForm.Device.ChangeMatrix(1,2,True); end;
begin end;
procedure TClient.ParameterCallback(Leaf:TCallback); begin Leaf; end;
procedure TClient.AssignCallback;
var Callback:TCallback;
begin Callback:=Device.Protocol.Leaf; RegisterCallback(Device.Protocol.Leaf); end;
procedure TClient.TypedAnonymous;
begin Queue(procedure(Leaf:Integer) begin TheForm.Device.ChangeMatrix(1,2,True); end); end;
procedure TClient.LocalAnonymous;
begin Queue(procedure var TheForm:TObject; begin TheForm.ChangeMatrix(1,2,True); end); end;
procedure TClient.Inactive;
begin {$IFDEF NEVER_DEFINED}TheForm.Device.ChangeMatrix(1,2,True);{$ENDIF}
  WriteLn('PRIVATE_BODY_SENTINEL_MUST_NOT_ESCAPE');
end;
procedure TClient.TypedLocal;
var Local:TDeviceAlias;
begin Local.ChangeMatrix(1,2,True); end;
procedure TClient.InferredLocal;
begin var Local:=TDevice.Create; Local.ChangeMatrix(1,2,True); end;
procedure TClient.PropertyCall; begin TheForm.Current.ChangeMatrix(1,2,True); end;
procedure TClient.OverloadArity; begin TheForm.Device.Pick(1,2); end;
procedure TClient.AmbiguousCall; begin TheForm.Device.Ambiguous(1); end;
procedure TClient.MissingArgument; begin TheForm.Device.NeedsTwo(1); end;
procedure TClient.UnknownReceiver(External:TObject); begin External.ChangeMatrix(1,2,True); end;
procedure TClient.WithScope; begin with TheForm.Device do ChangeMatrix(1,2,True); end;
function TClient.OwnResult:Integer; begin OwnResult:=1; end;
procedure ParameterCollision(Leaf:Integer); begin Device.Protocol.Leaf; end;
end.
''',
    'Transitive.pas': '''unit Transitive; interface
uses MainForm;
procedure Start;
implementation
procedure Start; begin TheForm.Device.ChangeMatrix(1,2,True); end;
end.
''',
}


class FilterGraphTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(dir=ROOT / 'build')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.folder = Path(cls.temp.name)
        (cls.folder / 'Example.dproj').write_text('<Project/>', encoding='utf-8')
        paths = []
        for name, text in SOURCES.items():
            path = cls.folder / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding='utf-8')
            paths.append('"' + path.as_posix() + '"')
        (cls.folder / 'Doxyfile').write_text(f'''PROJECT_NAME = Native_filter_graphs
INPUT = {' '.join(paths)}
INPUT_ENCODING = UTF-8
INPUT_FILTER = "{EXE.as_posix()} --delphi=11"
FILTER_SOURCE_FILES = YES
EXTENSION_MAPPING = pas=C++
FILE_PATTERNS = *.pas
OUTPUT_DIRECTORY = docs
EXTRACT_ALL = YES
EXTRACT_PRIVATE = YES
GENERATE_HTML = YES
GENERATE_XML = YES
GENERATE_LATEX = YES
HAVE_DOT = YES
DOT_IMAGE_FORMAT = svg
DOT_NUM_THREADS = 2
CALL_GRAPH = YES
CALLER_GRAPH = YES
SOURCE_BROWSER = NO
QUIET = YES
WARN_LOGFILE = warnings.txt
''', encoding='utf-8')
        run = subprocess.run(['doxygen', 'Doxyfile'], cwd=cls.folder, capture_output=True, timeout=40)
        assert run.returncode == 0, run.stderr.decode('utf-8')
        assert not (cls.folder / 'warnings.txt').read_text(encoding='utf-8').strip()
        cls.members = {}
        cls.all_members = {}
        for path in (cls.folder / 'docs/xml').glob('*.xml'):
            for member in ET.parse(path).findall('.//memberdef[@kind="function"]'):
                cls.members[member.findtext('qualifiedname')] = member
                cls.all_members[member.attrib['id']] = member

    def refs(self, name):
        return {ref.attrib['refid'] for ref in self.members[name].findall('references')}

    def test_direct_and_case_insensitive_unit_qualified_receiver(self):
        target = self.members['Device::Protocol::TDevice::ChangeMatrix'].attrib['id']
        self.assertIn(target, self.refs('Client::TClient::Direct'))

    def test_transitive_import_field_type_uses_declaring_unit(self):
        target = self.members['Device::Protocol::TDevice::ChangeMatrix'].attrib['id']
        self.assertIn(target, self.refs('Transitive::Start'))

    def test_anonymous_callback_sites_are_documented_and_labelled(self):
        method = self.members['Client::TClient::Anonymous']
        target = self.members['Device::Protocol::TDevice::ChangeMatrix'].attrib['id']
        self.assertIn(target, self.refs('Client::TClient::Anonymous'))
        self.assertIn('callback execution is not implied', ''.join(method.itertext()))

    def test_all_expected_callers_and_reciprocal_callee_edges(self):
        target = self.members['Device::Protocol::TDevice::ChangeMatrix']
        expected = {self.members[name].attrib['id'] for name in [
            'Device::Protocol::TDevice::Run', 'Client::TClient::Direct',
            'Client::TClient::Anonymous', 'Client::TClient::TypedLocal',
            'Client::TClient::InferredLocal', 'Client::TClient::PropertyCall', 'Transitive::Start']}
        self.assertEqual(expected, {r.attrib['refid'] for r in target.findall('referencedby')})
        self.assertEqual({self.members['Device::Protocol::TDevice::MatrixOff'].attrib['id']},
                         self.refs('Device::Protocol::TDevice::ChangeMatrix'))

    def test_unknown_dynamic_ambiguous_and_deferred_scopes_have_no_fake_edges(self):
        for method in ['Nested', 'ParameterCallback', 'AssignCallback', 'TypedAnonymous', 'LocalAnonymous',
                       'Inactive', 'AmbiguousCall', 'MissingArgument', 'UnknownReceiver', 'WithScope', 'OwnResult']:
            with self.subTest(method=method):
                self.assertEqual(set(), self.refs('Client::TClient::' + method))

    def test_overload_arity_selects_only_one_distinct_target(self):
        refs = self.refs('Client::TClient::OverloadArity')
        self.assertEqual(len(refs), 1)
        target = next(m for m in self.all_members.values() if m.attrib['id'] in refs)
        self.assertTrue(target.findtext('name').startswith('Pick__overload_'))
        self.assertEqual(len(target.findall('param')), 2)

    def test_parameter_name_collision_does_not_create_false_recursion(self):
        self.assertEqual({self.members['Device::Protocol::Leaf'].attrib['id']},
                         self.refs('Client::ParameterCollision'))

    def test_doxygen_generates_both_graph_directions_and_latex_graphs(self):
        html = self.folder / 'docs/html'
        latex = self.folder / 'docs/latex'
        self.assertTrue(list(html.glob('*_cgraph.svg')))
        self.assertTrue(list(html.glob('*_icgraph.svg')))
        self.assertTrue(list(latex.glob('*_cgraph.pdf')))
        self.assertTrue(list(latex.glob('*_icgraph.pdf')))

    def test_filter_interface_mode_and_body_privacy(self):
        source = self.folder / 'Client.pas'
        run = subprocess.run([str(EXE), str(source)], capture_output=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertNotIn(b'PRIVATE_BODY_SENTINEL_MUST_NOT_ESCAPE', run.stdout)
        run = subprocess.run([str(EXE), '-i', str(source)], capture_output=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertNotIn(b'::ChangeMatrix(', run.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
