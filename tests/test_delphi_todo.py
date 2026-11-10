"""External regression checks; keep the user's source-only project clean."""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'build'
EXE = Path(os.environ.get('PAS2DOX_TEST_EXE', str(ROOT / 'build/pas2dox.exe')))


class DelphiTodoTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=WORK)
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)

    def doxygen(self, source, options='', extra=None, enabled=True):
        path = self.folder / 'TodoSample.pas'
        path.write_text(source, encoding='utf-8')
        for name, text in (extra or {}).items():
            (self.folder / name).write_text(text, encoding='utf-8')
        (self.folder / 'Doxyfile').write_text(f'''PROJECT_NAME = TODO_test
INPUT = TodoSample.pas
INPUT_ENCODING = UTF-8
INPUT_FILTER = "{EXE.as_posix()} {options}"
FILTER_SOURCE_FILES = YES
EXTENSION_MAPPING = pas=C++
FILE_PATTERNS = *.pas
EXTRACT_ALL = YES
EXTRACT_PRIVATE = YES
GENERATE_HTML = YES
GENERATE_XML = YES
GENERATE_LATEX = YES
GENERATE_TODOLIST = {'YES' if enabled else 'NO'}
HAVE_DOT = NO
OUTPUT_DIRECTORY = docs
QUIET = YES
WARN_LOGFILE = warnings.txt
''', encoding='utf-8')
        run = subprocess.run(['doxygen', 'Doxyfile'], cwd=self.folder, capture_output=True, timeout=25)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual((self.folder / 'warnings.txt').read_text(encoding='utf-8').strip(), '')
        files = [ET.parse(p) for p in (self.folder / 'docs/xml').glob('*.xml')]
        todos = next((doc for doc in files if doc.findtext('compounddef/compoundname') == 'todo'), None)
        return files, todos

    def test_standard_comment_forms_metadata_unicode_and_single_entries(self):
        _, todo = self.doxygen('''unit TodoSample;
{ TODO 1 -o"Alex User" -cUI : Árvíztűrő META_TASK }
interface
// ToDo: LINE_TASK
(* TODO 2 -oTeam -cCore : BLOCK_TASK *)
procedure Run;
implementation
procedure Run;
begin
  { TODO: BODY_TASK }
end;
end.
''')
        self.assertIsNotNone(todo)
        text = ''.join(todo.getroot().itertext())
        for marker in ['META_TASK', 'LINE_TASK', 'BLOCK_TASK', 'BODY_TASK']:
            self.assertEqual(text.count(marker), 1, marker)
        for preserved in ['1 -o"Alex User" -cUI', 'Árvíztűrő', 'TodoSample.pas:']:
            self.assertIn(preserved, text)
        self.assertTrue((self.folder / 'docs/html/todo.html').is_file())
        self.assertTrue((self.folder / 'docs/latex/todo.tex').is_file())

    def test_body_task_belongs_to_routine_in_both_implementation_modes(self):
        source = '''unit TodoSample; interface procedure Run; implementation
procedure Run; begin { TODO: OWNER_TASK } end; end.'''
        for options in ['', '--no-call-graph']:
            with self.subTest(options=options):
                docs, todo = self.doxygen(source, options)
                member = next(m for doc in docs for m in doc.findall('.//memberdef')
                              if m.findtext('name') == 'Run')
                self.assertIn('OWNER_TASK', ''.join(member.itertext()))
                self.assertIn('Run', ''.join(todo.getroot().itertext()))

    def test_inactive_comments_strings_and_nonstandard_prefix_are_not_tasks(self):
        _, todo = self.doxygen('''unit TodoSample; interface
const S='TODO: STRING_NOT_TASK';
{ TODOList: PREFIX_NOT_TASK }
{ Description mentions TODO: MENTION_NOT_TASK }
{$IFDEF ENABLE_TODO}
{ TODO: ACTIVE_TASK }
{$ELSE}
{ TODO: INACTIVE_NOT_TASK }
{$ENDIF}
implementation end.
''', '-DENABLE_TODO')
        text = ''.join(todo.getroot().itertext())
        self.assertIn('ACTIVE_TASK', text)
        for marker in ['STRING_NOT_TASK', 'PREFIX_NOT_TASK', 'MENTION_NOT_TASK', 'INACTIVE_NOT_TASK']:
            self.assertNotIn(marker, text)

    def test_include_todo_keeps_source_file_and_line(self):
        _, todo = self.doxygen('''unit TodoSample; interface procedure Run; implementation
procedure Run; begin {$I TodoBody.inc} end; end.''',
                              extra={'TodoBody.inc': '{ TODO: INCLUDED_TASK }\n'})
        text = ''.join(todo.getroot().itertext())
        self.assertIn('INCLUDED_TASK', text)
        self.assertIn('TodoBody.inc:1', text)

    def test_interface_only_excludes_implementation_tasks(self):
        _, todo = self.doxygen('''unit TodoSample; interface
{ TODO: INTERFACE_TASK }
procedure Run;
implementation
procedure Run; begin { TODO: IMPLEMENTATION_NOT_TASK } end; end.''', '-i')
        text = ''.join(todo.getroot().itertext())
        self.assertIn('INTERFACE_TASK', text)
        self.assertNotIn('IMPLEMENTATION_NOT_TASK', text)

    def test_existing_doxygen_todo_stays_single(self):
        _, todo = self.doxygen('''unit TodoSample; interface
/// @todo EXISTING_DOXYGEN_TASK
procedure Run;
implementation procedure Run; begin end; end.''')
        self.assertEqual(''.join(todo.getroot().itertext()).count('EXISTING_DOXYGEN_TASK'), 1)

    def test_payload_is_literal_and_multiline_is_one_task(self):
        _, todo = self.doxygen('''unit TodoSample; interface
{ TODO: LITERAL_TASK @brief \\endcond <tag> */
  SECOND_LINE }
implementation end.''')
        text = ''.join(todo.getroot().itertext())
        for marker in ['LITERAL_TASK', '@brief', '\\endcond', '<tag>', 'SECOND_LINE']:
            self.assertIn(marker, text)

    def test_doxygen_can_disable_todo_list(self):
        _, todo = self.doxygen('unit TodoSample; interface { TODO: HIDDEN_TASK } implementation end.', enabled=False)
        self.assertIsNone(todo)

    def test_ast_exports_task_location_and_owner(self):
        path = self.folder / 'TodoSample.pas'
        path.write_text('''unit TodoSample; interface { TODO: UNIT_TASK } procedure Run;
implementation procedure Run; begin { TODO: ROUTINE_TASK } end; end.''', encoding='utf-8')
        run = subprocess.run([str(EXE), '--ast-json', '--implementation', str(path)], capture_output=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        data = json.loads(run.stdout)
        self.assertEqual(len(data['todos']), 2)
        method = next(i for i in data['items'] if i['name'] == 'Run')
        self.assertNotIn('owner', data['todos'][0])
        self.assertEqual(data['todos'][1]['owner'], method['id'])
        self.assertEqual(data['todos'][1]['line'], 2)

    def test_initialization_finalization_and_trailing_tasks(self):
        _, todo = self.doxygen('''unit TodoSample; interface implementation
initialization { TODO: INITIALIZATION_TASK }
finalization { TODO: FINALIZATION_TASK }
end. { TODO: TRAILING_TASK }''')
        text = ''.join(todo.getroot().itertext())
        for marker in ['INITIALIZATION_TASK', 'FINALIZATION_TASK', 'TRAILING_TASK']:
            self.assertEqual(text.count(marker), 1)

    def test_program_body_tasks_and_lexical_errors(self):
        _, todo = self.doxygen('program TodoSample; begin { TODO: PROGRAM_TASK } end.')
        self.assertIn('PROGRAM_TASK', ''.join(todo.getroot().itertext()))
        path = self.folder / 'Broken.pas'
        path.write_text("unit Broken; interface implementation end. 'unterminated", encoding='utf-8')
        run = subprocess.run([str(EXE), str(path)], capture_output=True, timeout=10)
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(run.stdout, b'')


if __name__ == '__main__':
    unittest.main(verbosity=2)
