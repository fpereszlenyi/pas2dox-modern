"""Semantic tests for the native modern Delphi documentation filter."""
from pathlib import Path
import concurrent.futures
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
EXE=ROOT/'build/pas2dox.exe'

class ModernTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(dir=ROOT/'build')
        self.addCleanup(self.temp.cleanup)
        self.directory=Path(self.temp.name)

    def run_source(self, source, *options, encoding='utf-8', name='Example.pas'):
        path=self.directory/name
        path.write_text(source,encoding=encoding)
        return subprocess.run([str(EXE),*options,str(path)],capture_output=True,timeout=5)

    def convert(self, declarations, *options):
        source='unit Example;\ninterface\n'+declarations+'\nimplementation\nend.\n'
        result=self.run_source(source,'-i',*options)
        self.assertEqual(result.returncode,0,result.stderr.decode('utf-8'))
        return result.stdout.decode('utf-8')

    def doxygen(self, sources, *filter_options):
        paths=[]
        for name,source in sources.items():
            path=self.directory/name
            path.write_text(source,encoding='utf-8')
            paths.append('"'+path.as_posix()+'"')
        config=self.directory/'Doxyfile'
        config.write_text(f'''PROJECT_NAME = Modern_test
INPUT = {' '.join(paths)}
OUTPUT_DIRECTORY = "{(self.directory/'docs').as_posix()}"
EXTENSION_MAPPING = pas=C++
FILE_PATTERNS = *.pas
FILTER_PATTERNS = "*.pas={EXE.as_posix()} -i {' '.join(filter_options)}"
EXTRACT_ALL = YES
EXTRACT_PRIVATE = YES
GENERATE_XML = YES
GENERATE_HTML = NO
GENERATE_LATEX = NO
HAVE_DOT = NO
QUIET = YES
WARN_LOGFILE = "{(self.directory/'warnings.txt').as_posix()}"
''',encoding='utf-8')
        result=subprocess.run(['doxygen',str(config)],capture_output=True,timeout=20)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stderr,b'')
        self.assertEqual((self.directory/'warnings.txt').read_text().strip(),'')
        index=ET.parse(self.directory/'docs/xml/index.xml')
        return {item.findtext('name'):ET.parse(self.directory/'docs/xml'/(item.attrib['refid']+'.xml')) for item in index.findall('compound')}

    def test_namespaces_do_not_merge_identical_types(self):
        docs=self.doxygen({name+'.pas':f'unit {name}; interface\ntype TItem=class(TObject) public procedure Run; end;\nimplementation\nend.' for name in ['First.Unit1','Second.Unit1']})
        self.assertIn('First::Unit1::TItem',docs)
        self.assertIn('Second::Unit1::TItem',docs)

    def test_expanded_xml_comments_and_literal_attributes(self):
        docs=self.doxygen({'Expanded.pas':'''unit Expanded; interface
type
[Marker('/* */ <tag>')]
TBox<T: class> = class
public
/// <summary>Read a value.</summary>
/// <param name="value">Input text.</param>
/// <returns>Output text.</returns>
function Read(const Value:string):string;
end;
implementation end.
'''}, '--expanded')
        box=docs['Expanded::TBox']
        self.assertIn('/* */ <tag>', ''.join(box.getroot().itertext()))
        self.assertIn('TBox<T:class>', ''.join(box.getroot().itertext()))
        member=next(m for m in box.findall('.//memberdef') if m.findtext('name')=='Read')
        self.assertEqual(member.findtext('.//parametername'), 'Value')
        self.assertIn('Read a value.', ''.join(member.itertext()))
        self.assertIn('Output text.', ''.join(member.itertext()))

    def test_cpp_keyword_type_references_follow_renamed_declarations(self):
        docs=self.doxygen({'Keywords.pas':'''unit Keywords; interface
type int=class end;
TBox=class public function Read: int; end;
implementation end.
'''})
        self.assertIn('Keywords::pas2dox_kw_int', docs)
        method=next(m for m in docs['Keywords::TBox'].findall('.//memberdef') if m.findtext('name')=='Read')
        self.assertEqual(''.join(method.find('type').itertext()), 'pas2dox_kw_int')
        self.assertIsNotNone(method.find('type/ref'))

    def test_generics_nested_types_and_visibility_xml(self):
        docs=self.doxygen({'Modern.Types.pas':(ROOT/'tests/Modern.Types.pas').read_text(encoding='utf-8')})
        box=docs['Modern::Types::TBox']
        members={m.findtext('name'):m for m in box.findall('.//memberdef')}
        self.assertEqual(members['FItems'].attrib['prot'],'private')
        self.assertEqual(members['ReadItems'].attrib['prot'],'protected')
        self.assertEqual(members['Snapshot'].findtext('location').strip() if members['Snapshot'].findtext('location') else '', '')
        self.assertEqual(members['Snapshot'].find('location').attrib['line'],'19')
        self.assertIn('TArray< TList< T > >',''.join(members['Snapshot'].find('type').itertext()))
        self.assertEqual(members['Identity'].findtext('templateparamlist/param/type'),'class TValue')
        self.assertIn('Árvíztűrő tükörfúrógép.',''.join(box.getroot().itertext()))

    def test_generic_overloads_remain_distinct(self):
        docs=self.doxygen({'Overloads.pas':'unit Overloads; interface\ntype TItem=class(TObject) end;\nTItem<T>=class(TItem) Value:T; end;\nTItem<T,U>=class(TObject) Other:U; end;\nimplementation\nend.'})
        self.assertIn('Overloads::TItem',docs)
        self.assertIn('Overloads::TItem< T >',docs)
        self.assertIn('Overloads::TItem< T, U >',docs)

    def test_generics_comments_constraints_and_aliases(self):
        text=self.convert('type\nTBox<T: {angle > in comment} class, constructor; U: interface; V: unmanaged> = class(TObject)\n public function Get: TArray<TList<{another >} U>>; end;\nTItems<T>=TArray<T>;')
        self.assertIn('template<class T, class U, class V>',text)
        self.assertIn('TArray<TList<U>> Get()',text)
        self.assertIn('template<class T> using TItems = TArray<T>;',text)

    def test_multiple_ancestor_interfaces(self):
        text=self.convert('type\nTThing=class(TObject,IAlpha,IBeta<Integer>,IGamma) end;')
        self.assertIn('public TObject, public IAlpha, public IBeta<Integer>, public IGamma',text)

    def test_abstract_sealed_and_ast_ancestor_metadata(self):
        source='unit Modifiers; interface\ntype TBase=class abstract end;\nTFinal=class sealed(TBase, IAlpha) end;\nimplementation end.'
        docs=self.doxygen({'Modifiers.pas':source})
        self.assertIn('Delphi abstract class', ''.join(docs['Modifiers::TBase'].getroot().itertext()))
        self.assertIn('Delphi sealed class', ''.join(docs['Modifiers::TFinal'].getroot().itertext()))
        result=self.run_source(source, '-i', '--ast-json')
        self.assertEqual(result.returncode, 0, result.stderr)
        final=next(item for item in json.loads(result.stdout)['items'] if item['name']=='TFinal')
        self.assertEqual(final['modifier'], 'sealed')
        self.assertEqual(final['ancestors'], ['TBase', 'IAlpha'])

    def test_nested_classes_and_records(self):
        docs=self.doxygen({'Nested.pas':'unit Nested; interface\ntype TOuter=class(TObject)\npublic type TInner=record\nValue:Integer;\nend;\npublic function Read: TInner;\nend;\nimplementation\nend.'})
        self.assertIn('Nested::TOuter::TInner',docs)
        self.assertIn('Read',[m.findtext('name') for m in docs['Nested::TOuter'].findall('.//memberdef')])

    def test_callbacks_preserve_signatures(self):
        text=self.convert('type\nTFactory<T>=reference to function(const Name:string; var Value:T):T;\nTNotify=procedure(Sender:TObject) of object;')
        self.assertIn('using TFactory = T (*)(const string Name, T& Value);',text)
        self.assertIn('using TNotify = void (*)(TObject Sender);',text)

    def test_managed_records_and_operators(self):
        text=self.convert('type\nTRec=record Value:Integer;\nclass operator Initialize(out Dest:TRec);\nclass operator Assign(var Dest:TRec; const [ref] Src:TRec);\nclass operator Add(const A,B:TRec):TRec; end;')
        self.assertIn('static void Initialize(TRec& Dest)',text)
        self.assertIn('static void Assign(TRec& Dest, const TRec& Src)',text)
        self.assertIn('static TRec Add(const TRec A, const TRec B)',text)

    def test_indexed_and_class_properties(self):
        text=self.convert('type\nTData=class(TObject)\nproperty Items[Index:Integer]:TList<string> read GetItems; default;\nclass property Count:Integer read GetCount;\nend;')
        self.assertIn('TList<string> Items(Integer Index);',text)
        self.assertIn('static Integer Count;',text)

    def test_arrays_sets_pointers_and_ranges(self):
        text=self.convert('type\nTData=class(TObject)\nA:array[0..3] of Integer;\nB:array of string;\nC:set of Byte;\nD:^Integer;\nend;\nTClassRef=class of TData;\nTRange=1..8;')
        for expected in ['DelphiArray<Integer> A;','DelphiArray<string> B;','DelphiSet<Byte> C;','Integer* D;','DelphiClassRef<TData> TClassRef;','DelphiOrdinalRange TRange;']:
            self.assertIn(expected,text)

    def test_variant_records(self):
        text=self.convert('type TVariant=record case Kind:Boolean of True:(Number:Integer); False:(Text:PChar); end;')
        for field in ['Kind','Number','Text']:self.assertIn(field,text)

    def test_anonymous_records_and_enumerations(self):
        text=self.convert('type TData=class(TObject)\nPosition:record X,Y:Integer; end;\nColor:(Red,Green,Blue);\nend;')
        self.assertIn('struct { Integer X; Integer Y; } Position;',text)
        self.assertIn('enum { Red, Green, Blue } Color;',text)

    def test_named_constructors_remain_distinct(self):
        docs=self.doxygen({'Constructors.pas':'unit Constructors; interface\ntype TItem=class(TObject) constructor Create(Value:Integer);\nconstructor FromValue(Value:Integer); end;\nimplementation\nend.'})
        members=[m.findtext('name') for m in docs['Constructors::TItem'].findall('.//memberdef')]
        self.assertIn('Create',members)
        self.assertIn('FromValue',members)

    def test_compilable_modern_unit_with_implementations(self):
        result=subprocess.run([str(EXE),'--ast-json','--delphi=11',str(ROOT/'tests/CompiledModern11.pas')],capture_output=True,timeout=5)
        self.assertEqual(result.returncode,0,result.stderr)
        names={i['name'] for i in json.loads(result.stdout)['items']}
        self.assertTrue({'TBox','TInfo','Map','TManaged','Assign','TIntListHelper','Calculate'}.issubset(names))

    def test_generic_helper_and_class_constructor(self):
        text=self.convert('type\nTHelper=class helper for TList<Integer>\nprocedure Touch; end;\nTData=class(TObject)\nclass constructor Create;\nclass destructor Destroy;\nend;')
        self.assertIn('Delphi helper for TList<Integer>',text)
        self.assertIn('DelphiClass_Create',text)
        self.assertIn('DelphiClass_Destroy',text)

    def test_unicode_identifiers_and_path(self):
        result=self.run_source('unit UnicodeTest; interface\ntype TÁrvíz=class(TObject)\nprocedure Őriz;\nend;\nimplementation\nend.','-i',name='Árvíztűrő 文件.pas')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('TÁrvíz',result.stdout.decode())
        self.assertIn('Őriz',result.stdout.decode())

    def test_doxygen_with_unicode_input_file_name(self):
        docs=self.doxygen({'Árvíztűrő 文件.pas':'unit UnicodeTest; interface\ntype TData=class(TObject) end;\nimplementation\nend.'})
        self.assertIn('UnicodeTest::TData',docs)

    def test_escaped_identifiers(self):
        text=self.convert('type\nTData=class(TObject)\n&class:Integer;\nprocedure &type(const &string:Integer);\nend;')
        self.assertIn('Integer pas2dox_kw_class;',text)
        self.assertIn('type(const Integer string)',text)

    def test_utf8_and_utf16_encodings(self):
        for encoding in ['utf-8','utf-8-sig','utf-16','utf-16-be']:
            with self.subTest(encoding=encoding):
                source='unit UnicodeTest; interface\n/// Árvíztűrő\nprocedure Test;\nimplementation\nend.'
                if encoding=='utf-16-be':source='\ufeff'+source
                result=self.run_source(source,'-i',encoding=encoding)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertIn('Árvíztűrő',result.stdout.decode())

    def test_explicit_legacy_codepage(self):
        source='unit Example; interface\n/// Árvíztűrő\nprocedure Test;\nimplementation\nend.'
        result=self.run_source(source,'-i','--encoding=1250',encoding='cp1250')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('Árvíztűrő',result.stdout.decode())

    def test_attribute_cpp_comment_delimiters_do_not_break_doxygen(self):
        source="unit Attr; interface\ntype [Marker('/* comment */')] TData=class(TObject) end;\nimplementation\nend."
        docs=self.doxygen({'Attr.pas':source})
        self.assertIn('Attr::TData',docs)
        self.assertIn('/* comment */',''.join(docs['Attr::TData'].getroot().itertext()))

    def test_multiline_strings_and_long_literals(self):
        text=self.convert("const\nText='''\n  <tag> end; {'quoted'}\n  ''';\nLongText='"+'x'*1000+"';\nprocedure AfterStrings;")
        self.assertIn('const auto Text;',text)
        self.assertIn('void AfterStrings();',text)

    def test_five_quote_multiline_delimiter(self):
        text=self.convert("const\nText='''''\n  embedded ''' is content\n  ''''';\nprocedure AfterStrings;")
        self.assertIn('void AfterStrings();',text)

    def test_conditionals_defines_elseif_and_include(self):
        (self.directory/'types.inc').write_text('type TIncluded=class(TObject) end;',encoding='utf-8')
        text=self.convert('{$DEFINE ENABLED}\n{$IF Defined(ENABLED) and (CompilerVersion>=37)}\n{$I types.inc}\n{$ELSEIF Defined(OTHER)}\nprocedure Wrong;\n{$ELSE}\nprocedure AlsoWrong;\n{$IFEND}\nprocedure Correct;')
        self.assertIn('class TIncluded',text)
        self.assertIn('void Correct();',text)
        self.assertNotIn('Wrong',text)

    def test_nested_multiline_includes_keep_their_owning_unit_line(self):
        (self.directory/'inner.inc').write_text('type TInner=class\npublic\nprocedure Inner;\nend;')
        (self.directory/'outer.inc').write_text('{$I inner.inc}\ntype TOuter=class\npublic\nprocedure Outer;\nend;')
        source='unit Example;\ninterface\n{$I outer.inc}\ntype TOutside=class\npublic\nprocedure Outside;\nend;\nimplementation\nend.'
        result=self.run_source(source,'-i','--ast-json')
        self.assertEqual(result.returncode,0,result.stderr)
        items={i['name']:i for i in json.loads(result.stdout)['items']}
        self.assertEqual(items['TInner']['unitLine'],3)
        self.assertEqual(items['TInner']['line'],1)
        self.assertEqual(items['TOuter']['unitLine'],3)
        docs=self.doxygen({'Example.pas':source})
        for name in ['TInner','TOuter','TOutside']:self.assertIn('Example::'+name,docs)

    def test_conditional_values_declared_and_sizeof(self):
        text=self.convert('const LocalVersion=2.5;\ntype TKnown=Integer;\n{$IF Declared(TKnown) and (SizeOf(Pointer)=8) and (LocalVersion>2)}\nprocedure Correct;\n{$ELSE}\nprocedure Wrong;\n{$ENDIF}', '--platform=win64')
        self.assertIn('void Correct();',text)
        self.assertNotIn('Wrong',text)

    def test_arithmetic_constant_expressions(self):
        text=self.convert('const Shifted=1 shl 3;\nAdjusted=Shifted+2;\nNegative=-4;\n{$IF (Adjusted=10) and (Negative<0)}\nprocedure Correct;\n{$ELSE}\nprocedure Wrong;\n{$IFEND}')
        self.assertIn('Correct',text)
        self.assertNotIn('Wrong',text)

    def test_configurable_compiler_versions(self):
        source='{$IF CompilerVersion>=37}\nprocedure New13;\n{$ELSEIF CompilerVersion>=36}\nprocedure New12;\n{$ELSE}\nprocedure Old11;\n{$IFEND}'
        for version,name in [('11','Old11'),('12','New12'),('13','New13')]:
            with self.subTest(version=version):self.assertIn('void '+name+'();',self.convert(source,'--delphi='+version))

    def test_command_line_defines(self):
        text=self.convert('{$IF Defined(CUSTOM) and (LIBVER=3)}\nprocedure Selected;\n{$IFEND}','-DCUSTOM','-DLIBVER=3')
        self.assertIn('Selected',text)

    def test_scoped_enums_values_and_member_comments(self):
        source='''unit Enums;
interface
{$SCOPEDENUMS ON}
type TState=(
  /// Waiting state.
  Waiting=2,
  Running=$10
);
implementation
end.
'''
        docs=self.doxygen({'Enums.pas':source})
        xml=docs['Enums']
        enum=xml.find('.//memberdef[@kind="enum"]')
        self.assertEqual(enum.attrib['strong'],'yes')
        members={e.findtext('name'):e for e in enum.findall('enumvalue')}
        self.assertEqual(members['Waiting'].findtext('initializer').replace(' ',''),'=2')
        self.assertIn('Waiting state.',''.join(members['Waiting'].itertext()))

    def test_long_ifopt_and_option_stack(self):
        text=self.convert('{$SCOPEDENUMS OFF}\n{$PUSHOPT}\n{$SCOPEDENUMS ON}\n{$IFOPT SCOPEDENUMS ON}\nprocedure Inside;\n{$ENDIF}\n{$POPOPT}\n{$IFOPT SCOPEDENUMS OFF}\nprocedure Outside;\n{$ENDIF}')
        self.assertIn('Inside',text)
        self.assertIn('Outside',text)

    def test_long_and_short_switches_agree(self):
        text=self.convert('{$RANGECHECKS ON}\n{$IFOPT R+}\nprocedure Correct;\n{$ELSE}\nprocedure Wrong;\n{$ENDIF}')
        self.assertIn('Correct',text)
        self.assertNotIn('Wrong',text)

    def test_short_options_numeric_aliases_and_initial_configuration(self):
        text=self.convert('''{$R+,A8,D2,Z4}
{$IFOPT RANGECHECKS ON}procedure RangeOn;{$ENDIF}
{$IFOPT ALIGN 8}procedure Aligned;{$ENDIF}
{$IFOPT DEBUGINFO 2}procedure DebugFull;{$ENDIF}
{$IFOPT MINENUMSIZE 4}procedure WideEnum;{$ENDIF}
{$LONGSTRINGS OFF}
{$IFOPT H-}procedure ShortStrings;{$ENDIF}''')
        for name in ['RangeOn','Aligned','DebugFull','WideEnum','ShortStrings']:
            self.assertIn('void '+name+'();',text)
        text=self.convert('{$IFOPT R+}procedure InitialRange;{$ENDIF}', '--option=RANGECHECKS=ON')
        self.assertIn('void InitialRange();',text)
        text=self.convert('type TState=(Ready,Busy);', '--option=SCOPEDENUMS=ON')
        self.assertIn('enum class TState',text)

    def test_explicit_imported_symbols_and_options(self):
        text=self.convert('{$IF Declared(ImportedType)}\nprocedure Found;\n{$IFEND}\n{$IFOPT DYNAMICBASE ON}\nprocedure Dynamic;\n{$ENDIF}','--declare=ImportedType','--option=DYNAMICBASE=ON')
        self.assertIn('Found',text)
        self.assertIn('Dynamic',text)

    def test_long_ifopt_numeric_and_warning_modes(self):
        text=self.convert('{$SETPEOSVERSION 6.0}\n{$IFOPT SETOSVERSION>=6.0}\nprocedure VersionOk;\n{$ENDIF}\n{$SETPEFLAGS $140}\n{$IFOPT SETPEFLAGS $40}\nprocedure FlagOk;\n{$ENDIF}\n{$WARN SYMBOL_PLATFORM OFF}\n{$IFOPT WARN SYMBOL_PLATFORM OFF}\nprocedure WarningOk;\n{$ENDIF}')
        for name in ['VersionOk','FlagOk','WarningOk']:self.assertIn(name,text)

    def test_platform_presets_have_explicit_cpu_architecture(self):
        checks={'win32':'WIN32 and CPU32BITS and CPUX86','win64':'WIN64 and CPU64BITS and CPUX64',
                'linux64':'LINUX64 and POSIX64 and CPUX64','android64':'ANDROID64 and CPUARM64',
                'ios64':'IOS64 and MACOS64 and CPUARM64','macosarm64':'OSX64 and CPUARM64',
                'winarm64ec':'WIN64 and ARM64EC and CPUARM64'}
        for platform,condition in checks.items():
            expression=' and '.join('Defined('+part.strip()+')' for part in condition.split('and'))
            with self.subTest(platform=platform):
                text=self.convert('{$IF '+expression+'}\nprocedure Selected;\n{$IFEND}','--platform='+platform)
                self.assertIn('Selected',text)

    def test_ast_export_preserves_original_declarations(self):
        result=self.run_source('unit Example; interface\ntype TData=class(TObject)\nValues:array[1..8] of Integer;\nend;\nimplementation\nend.','-i','--ast-json')
        self.assertEqual(result.returncode,0,result.stderr)
        data=json.loads(result.stdout)
        fields={i['name']:i for i in data['items']}
        self.assertIn('array[1..8]',fields['Values']['declaration'].replace(' ',''))
        self.assertEqual(fields['Values']['line'],3)

    def test_unresolved_sizeof_fails_without_output(self):
        result=self.run_source('unit Example; interface\n{$IF SizeOf(UnknownType)>4}\nprocedure P;\n{$IFEND}\nimplementation\nend.','-i')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(result.stdout,b'')
        self.assertIn(b'SizeOf',result.stderr)

    def test_implementation_skips_inline_vars_anonymous_methods_and_13_expressions(self):
        source='''unit Example;
interface
function Test(N:Integer):Integer;
implementation
function Test(N:Integer):Integer;
begin
  var Callback := procedure begin var X:=1; end;
  const Local=1;
  Result:=if N>0 then Local else 0;
  if N not in [1,2] then Result:=0;
end;
end.
'''
        result=self.run_source(source)
        self.assertEqual(result.returncode,0,result.stderr)
        text=result.stdout.decode()
        self.assertIn('Integer Test(Integer N);',text)
        self.assertNotIn('Callback',text)

    def test_noreturn_and_new_constraints(self):
        text=self.convert('type TInterfaceBox<T:interface> = class(TObject) end;\nTUnmanagedBox<T:unmanaged>=record Value:T; end;\nprocedure RaiseFailure; noreturn;')
        self.assertIn('class TInterfaceBox',text)
        self.assertIn('struct TUnmanagedBox',text)
        self.assertIn('void RaiseFailure();',text)

    def test_helpinsight_xml_comments(self):
        source='''unit XmlDoc;
interface
/// <summary>Calculate a value.</summary>
/// <param name="Value">Input number.</param>
/// <returns>Output number.</returns>
function Calculate(Value:Integer):Integer;
implementation
end.
'''
        docs=self.doxygen({'XmlDoc.pas':source})
        text=''.join(docs['XmlDoc'].getroot().itertext())
        self.assertIn('Calculate a value.',text)
        self.assertIn('Input number.',text)
        self.assertIn('Output number.',text)

    def test_line_count_and_locations(self):
        source='unit Example;\ninterface\n\ntype TItem=class(TObject)\npublic\nprocedure Test;\nend;\nimplementation\nend.\n'
        result=self.run_source(source,'-i')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(len(source.splitlines()),len(result.stdout.decode().splitlines()))
        self.assertIn('void Test();',result.stdout.decode().splitlines()[5])

    def test_negative_inputs_never_emit_partial_results(self):
        cases=['unit Broken; interface type TBox<T=class',
               'unit Broken; interface type [Marker( T=class',
               "unit Broken; interface const S='''\n  unclosed",
               'unit Broken; interface {$IFDEF MISSING}']
        for source in cases:
            with self.subTest(source=source):
                result=self.run_source(source,'-i')
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(result.stdout,b'')

    def test_output_never_overwrites(self):
        source='unit Example; interface\nimplementation\nend.'
        path=self.directory/'Example.pas'
        path.write_text(source)
        args=[str(EXE),'-o',str(path)]
        first=subprocess.run(args,capture_output=True,timeout=5)
        self.assertEqual(first.returncode,0,first.stderr)
        output=Path(str(path)+'.cpp');output.write_bytes(b'KEEP')
        result=subprocess.run(args,capture_output=True,timeout=5)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(output.read_bytes(),b'KEEP')

if __name__=='__main__':unittest.main(verbosity=2)
