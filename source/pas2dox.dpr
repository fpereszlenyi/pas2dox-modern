program pas2dox;
{$APPTYPE CONSOLE}
{$RANGECHECKS ON}
{$OVERFLOWCHECKS ON}

{ Pas2Dox Modern, 2026-11-10. GPL-2.0; see LICENSE. }

uses
  System.SysUtils, System.StrUtils, System.Classes, System.IOUtils, System.JSON, Winapi.Windows,
  PasDoc_Parser, PasDoc_Items, PasDoc_Types, PasDoc_StringVector, PasDoc_Tokenizer,
  Dox_Syntax, Dox_Emitter, Dox_Manifest, Dox_Target, Dox_Calls;

const Version = '0.60.0-rc4';

function InputPath(const Value: string; Directory: Boolean = False): string;
var CodePage: Cardinal; Encoding, Utf8: TEncoding; Candidate: string;
begin
  Result:=Value;
  if FileExists(Value) or (Directory and DirectoryExists(Value)) then Exit;
  // Doxygen's Windows popen path passes UTF-8 through an ANSI command line.
  // Recover only a reversible spelling that names an existing input.
  Utf8:=TUTF8Encoding.Create;
  try
    for CodePage in TArray<Cardinal>.Create(GetACP,GetOEMCP) do
    begin
      Encoding:=TEncoding.GetEncoding(CodePage);
      try
        try
          Candidate:=Utf8.GetString(Encoding.GetBytes(Value));
          if (Encoding.GetString(Utf8.GetBytes(Candidate))=Value) and
            (FileExists(Candidate) or (Directory and DirectoryExists(Candidate))) then Exit(Candidate);
        except on E: EEncodingError do begin end; end;
      finally Encoding.Free; end;
    end;
  finally Utf8.Free; end;
end;

type
  TApplication = class
  private
    FWarnings: TStringList;
    FDefines, FIncludes: TStringVector;
    FEncoding: TEncoding;
    FKeepImplementation: Boolean;
    procedure MessageEvent(const Kind: TPasDocMessageType; const Message: string; const Level: Cardinal);
    procedure WriteBytes(Handle: THandle; const Bytes: TBytes);
    procedure Output(const Text: string; const FileName: string);
    function Parse(const FileName: string; ParseImplementation: Boolean): TPasUnit;
    function ParseDependency(const FileName: string): TPasUnit;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
  end;

constructor TApplication.Create;
begin
  inherited;
  FWarnings:=TStringList.Create;
  FDefines:=TStringVector.Create;
  FIncludes:=TStringVector.Create;
  FEncoding:=TUTF8Encoding.Create;
  DefaultInputEncoding:=FEncoding;
end;

destructor TApplication.Destroy;
begin FWarnings.Free; FDefines.Free; FIncludes.Free; FEncoding.Free; inherited; end;

procedure TApplication.MessageEvent(const Kind: TPasDocMessageType; const Message: string; const Level: Cardinal);
begin
  if GetEnvironmentVariable('PAS2DOX_TRACE')='1' then begin Writeln(ErrOutput,Level,': ',Message); Flush(ErrOutput); end;
  if Kind in [pmtWarning,pmtError] then FWarnings.Add(Message);
end;

procedure TApplication.WriteBytes(Handle: THandle; const Bytes: TBytes);
var Stream: THandleStream;
begin
  Stream:=THandleStream.Create(Handle);
  try if Length(Bytes)>0 then Stream.WriteBuffer(Bytes[0],Length(Bytes));
  finally Stream.Free; end;
end;

procedure TApplication.Output(const Text: string; const FileName: string);
var Handle: THandle; Succeeded: Boolean;
begin
  if FileName='' then begin WriteBytes(GetStdHandle(STD_OUTPUT_HANDLE),TEncoding.UTF8.GetBytes(Text)); Exit; end;
  // Create only after successful parsing; CREATE_NEW cannot overwrite a result.
  Handle:=CreateFile(PChar(FileName),GENERIC_WRITE,0,nil,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,0);
  if Handle=INVALID_HANDLE_VALUE then RaiseLastOSError;
  Succeeded:=False;
  try
    WriteBytes(Handle,TEncoding.UTF8.GetBytes(Text));
    if not FlushFileBuffers(Handle) then RaiseLastOSError;
    Succeeded:=True;
  finally
    CloseHandle(Handle);
    if not Succeeded then DeleteFile(PChar(FileName));
  end;
end;

function TApplication.Parse(const FileName: string; ParseImplementation: Boolean): TPasUnit;
var Parser: TParser;
begin
  Result:=nil;
  Parser:=TParser.Create(TFileStream.Create(FileName,fmOpenRead or fmShareDenyWrite),
    FDefines,FIncludes,MessageEvent,2,FileName,ExpandFileName(FileName),False);
  try
    Parser.ShowVisibilities:=AllVisibilities;
    Parser.KeepImplementation:=FKeepImplementation;
    Parser.ImplicitVisibility:=ivPublic;
    Parser.MarkersOptional:=True;
    Parser.IgnoreLeading:='';
    Parser.AutoBackComments:=False;
    if ParseImplementation then Parser.InfoMergeType:=imtPreferIntf else Parser.InfoMergeType:=imtNone;
    Parser.ParseUnitOrProgram(Result);
  except Result.Free; Result:=nil; Parser.Free; raise;
  end;
  Parser.Free;
end;

function TApplication.ParseDependency(const FileName: string): TPasUnit;
var Keep: Boolean; Count: Integer;
begin
  Result:=nil; Keep:=FKeepImplementation; Count:=FWarnings.Count;
  FKeepImplementation:=False;
  try
    try
      Result:=Parse(FileName,False);
      if FWarnings.Count>Count then begin Result.Free; Result:=nil; end;
    except
      on E: Exception do
        if GetEnvironmentVariable('PAS2DOX_TRACE')='1' then Writeln(ErrOutput,'import: ',E.Message);
    end;
  finally
    FKeepImplementation:=Keep;
    while FWarnings.Count>Count do FWarnings.Delete(FWarnings.Count-1);
  end;
end;

procedure TApplication.Run;
var I, Compiler: Integer; Arg, FileName, OutputName, Platform, DelphiVersion, Text, CallMapFile: string;
  InterfaceOnly, Expanded, SaveOutput, JsonOutput, NoCalls, AutoCalls: Boolean;
  UnitItem: TPasUnit; Emitter: TDoxEmitter; Resolver: TCallResolver; CallMap: TJSONObject;
begin
  InterfaceOnly:=False; Expanded:=False; SaveOutput:=False; JsonOutput:=False; NoCalls:=False;
  Platform:='win32'; DelphiVersion:='13';
  for I:=1 to ParamCount do
  begin
    Arg:=ParamStr(I);
    if (Arg='--version') then begin Output(Version+#10,''); Exit; end;
    if (Arg='-h') or (Arg='--help') then
    begin
      Output('Pas2Dox Modern '+Version+#10+
        'pas2dox [-i] [-o] [-DNAME[=VALUE]] [-IPATH] [--delphi=11|12|13]'+#10+
        '        [--platform=win32|win64|winarm64ec|linux64|android32|android64|ios64|iossimarm64|macosx64|macosarm64] [--expanded] file.pas'+#10+
        '-i: interface only; default also emits resolved static calls for Doxygen graphs'+#10+
        '--no-call-graph: declarations and implementation documentation only'+#10+
        '-o: create file.pas.cpp, refuse overwrite; output encoding is UTF-8'+#10+
        '--expanded: include complete original declarations and metadata in documentation'+#10+
        '--ast-json: export original declarations and source locations as JSON'+#10+
        '--implementation: retain implementation-only declarations and redacted body tokens'+#10+
        '--call-map=FILE: project call plan; emits expanded graph definitions'+#10+
        '--encoding=utf8|1250|codepage: fallback for files without a Unicode BOM'+#10+
        '--declare=NAME: declare an imported identifier for conditional expressions'+#10+
        '--option=NAME=VALUE: initial compiler option used by long IFOPT'+#10+
        '-DPAS2DOX_SIZEOF_Type=BYTES: explicit layout for conditional SizeOf(Type)'+#10+
        'Defaults: Delphi 13, win32, UTF-8. Include paths and defines are repeatable.'+#10,
        ''); Exit;
    end;
    if Arg='-i' then InterfaceOnly:=True
    else if Arg='--no-call-graph' then NoCalls:=True
    else if Arg='-o' then SaveOutput:=True
    else if Arg='--expanded' then Expanded:=True
    else if Arg='--ast-json' then JsonOutput:=True
    else if Arg='--implementation' then FKeepImplementation:=True
    else if Arg.StartsWith('--call-map=') then
    begin CallMapFile:=InputPath(Arg.Substring(11)); FKeepImplementation:=True; Expanded:=True; end
    else if Arg.StartsWith('-D') and (Length(Arg)>2) then FDefines.Add(Copy(Arg,3,MaxInt).Replace('=',':='))
    else if Arg.StartsWith('-I') and (Length(Arg)>2) then FIncludes.Add(ExpandFileName(InputPath(Copy(Arg,3,MaxInt),True)))
    else if Arg.StartsWith('--option=') then FDefines.Add('PAS2DOX_OPTION_'+Arg.Substring(9).Replace('=',':='))
    else if Arg.StartsWith('--declare=') then FDefines.Add('PAS2DOX_DECLARED_'+Arg.Substring(10))
    else if Arg.StartsWith('--encoding=') then
    begin
      FEncoding.Free; FEncoding:=nil;
      if MatchText(Arg.Substring(11),['utf-8','utf8']) then FEncoding:=TUTF8Encoding.Create
      else FEncoding:=TEncoding.GetEncoding(StrToInt(Arg.Substring(11).Replace('cp','')));
      DefaultInputEncoding:=FEncoding;
    end
    else if Arg.StartsWith('--delphi=') then DelphiVersion:=Arg.Substring(9)
    else if Arg.StartsWith('--platform=') then Platform:=Arg.Substring(11)
    else if (Arg='-j') or (Arg='-s') then begin end
    else if Arg.StartsWith('-') then raise Exception.Create('Unknown option; use --help')
    else if FileName<>'' then raise Exception.Create('Exactly one input file is required')
    else FileName:=Arg;
  end;
  if FileName='' then raise Exception.Create('An input file is required; use --help');
  if InterfaceOnly and FKeepImplementation then raise Exception.Create('-i and --implementation/--call-map cannot be combined');
  AutoCalls:=not InterfaceOnly and not JsonOutput and not NoCalls and (CallMapFile='');
  if AutoCalls then FKeepImplementation:=True;
  FileName:=InputPath(FileName);
  if not MatchText(DelphiVersion,['11','12','13']) then raise Exception.Create('Delphi version must be 11, 12 or 13');
  Compiler:=StrToInt(DelphiVersion)+24;
  FDefines.Add('CompilerVersion:='+IntToStr(Compiler)+'.0');
  FDefines.Add('RTLVersion:='+IntToStr(Compiler)+'.0');
  FDefines.Add('VER'+IntToStr(Compiler)+'0');
  AddTargetSymbols(FDefines,Platform);
  if GetEnvironmentVariable('PAS2DOX_TRACE')='1' then begin Writeln(ErrOutput,'parsing'); Flush(ErrOutput); end;
  UnitItem:=Parse(FileName,not InterfaceOnly);
  if GetEnvironmentVariable('PAS2DOX_TRACE')='1' then begin Writeln(ErrOutput,'parsed'); Flush(ErrOutput); end;
  try
    if JsonOutput then Text:=AstJson(UnitItem)
    else
    begin
      CallMap:=nil;
      if AutoCalls then
      begin
        Resolver:=TCallResolver.Create(UnitItem,FileName,
          function(const Name: string): TPasUnit begin Result:=ParseDependency(Name); end);
        try CallMap:=Resolver.CreateMap; finally Resolver.Free; end;
      end;
      Emitter:=TDoxEmitter.Create(FileName,Expanded,CallMapFile,CallMap);
      try Text:=Emitter.Render(UnitItem); finally Emitter.Free; end;
    end;
    if FWarnings.Count>0 then raise Exception.Create('Parser reported warnings: '+FWarnings.Text);
    if SaveOutput then OutputName:=FileName+'.cpp';
    Output(Text,OutputName);
  finally UnitItem.Free; end;
end;

var App: TApplication; MessageBytes: TBytes; Written: DWORD;
begin
  App:=TApplication.Create;
  try
    try App.Run;
    except
      on E: Exception do
      begin
        MessageBytes:=TEncoding.UTF8.GetBytes('pas2dox: '+E.Message+#10);
        if Length(MessageBytes)>0 then WriteFile(GetStdHandle(STD_ERROR_HANDLE),MessageBytes[0],Length(MessageBytes),Written,nil);
        ExitCode:=2;
      end;
    end;
  finally App.Free; end;
end.
