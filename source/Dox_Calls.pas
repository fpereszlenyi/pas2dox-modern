unit Dox_Calls;

{ Pas2Dox Modern, 2026-11-10. GPL-2.0; see LICENSE.
  Native, read-only call resolution for a single Doxygen filter invocation.
  Imported interfaces supply types; no project preparation or Python is needed. }

interface

uses System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  PasDoc_Items, PasDoc_StringVector;

type
  TUnitLoader = reference to function(const FileName: string): TPasUnit;
  TCallResolver = class
  private
    FUnits: TObjectDictionary<string,TJSONObject>;
    FTypes, FAliases, FRoutines, FVariableItems: TDictionary<string,TJSONObject>;
    FMembers: TObjectDictionary<string,TList<TJSONObject>>;
    FVariables, FFiles, FTypeCache: TDictionary<string,string>;
    FInput, FRoot, FOwnUnit: string;
    FLoader: TUnitLoader;
    FIndexed: Boolean;
    function FindUnit(const Name: string): string;
    procedure IndexDirectory(const Directory: string; var Remaining: Integer);
    procedure LoadImports(Data: TJSONObject);
    procedure IndexItems;
    function Imports(Item: TJSONObject): TArray<string>;
    function FindType(const Name: string; Item: TJSONObject): string;
    function Ancestors(const Scope: string; Item: TJSONObject): TArray<string>;
    function VariableType(const Name, Scope: string; Item: TJSONObject;
      Locals: TDictionary<string,string>): string;
    function Resolve(const Chain: TArray<string>; ArgCount: Integer; Item: TJSONObject;
      Locals: TDictionary<string,string>): TJSONObject;
    function LocalsFor(Item: TJSONObject): TDictionary<string,string>;
    function CallsFor(Item: TJSONObject; out HasCallback: Boolean): TJSONArray;
    function CppName(Item: TJSONObject): string;
  public
    constructor Create(UnitItem: TPasUnit; const InputFile: string; Loader: TUnitLoader);
    destructor Destroy; override;
    function CreateMap: TJSONObject;
  end;

implementation

uses System.IOUtils, System.StrUtils, System.RegularExpressions, System.Character,
  Winapi.Windows, Dox_Manifest, Dox_Syntax;

function Value(Data: TJSONObject; const Name: string): string;
var Item: TJSONValue;
begin Item:=Data.GetValue(Name); if Item=nil then Result:='' else Result:=Item.Value; end;

function ArrayOf(Data: TJSONObject; const Name: string): TJSONArray;
begin Result:=Data.GetValue(Name) as TJSONArray; end;

function Canonical(const Text: string): string;
var C: Char; Depth: Integer;
begin
  Result:=''; Depth:=0;
  for C in Text.Replace('::','.') do
    if C='<' then Inc(Depth)
    else if C='>' then Dec(Depth)
    else if (Depth=0) and not C.IsWhiteSpace and not CharInSet(C,['&','^']) then Result:=Result+C;
  Result:=LowerCase(Result.Trim(['.']));
end;

function IsName(const Text: string): Boolean;
var I, Start: Integer;
begin
  Result:=False; Start:=1;
  if Text.StartsWith('&') then Inc(Start);
  if Start>Length(Text) then Exit;
  if not (Text[Start].IsLetter or (Text[Start]='_')) then Exit;
  for I:=Start+1 to Length(Text) do
    if not (Text[I].IsLetterOrDigit or (Text[I]='_')) then Exit;
  Result:=True;
end;

function WordsOf(Data: TJSONObject; const Name: string): TArray<string>;
var A: TJSONArray; I: Integer;
begin
  A:=ArrayOf(Data,Name); Result:=nil;
  if A=nil then Exit;
  SetLength(Result,A.Count);
  for I:=0 to A.Count-1 do Result[I]:=A[I].Value;
end;

function DeclaredType(const Declaration: string): string;
var W: TWords; I, P: Integer;
begin
  W:=Lex(Declaration); P:=FindTop(W,':'); Result:='';
  if P<0 then Exit;
  I:=P+1;
  while (I<Length(W)) and not MatchText(W[I],[';','=','read','write','stored','default',
    'nodefault','index','dispid','implements']) do Inc(I);
  Result:=Join(Slice(W,P+1,I-P-1));
end;

function RequiredParameters(const Declaration: string): Integer;
var W, Group: TWords; Open, Close, Depth: Integer;
begin
  Result:=0; W:=Lex(Declaration); Open:=FindTop(W,'(');
  if Open<0 then Exit;
  Close:=Open+1; Depth:=1;
  while (Close<Length(W)) and (Depth>0) do
  begin
    if W[Close]='(' then Inc(Depth);
    if W[Close]=')' then Dec(Depth);
    if Depth>0 then Inc(Close);
  end;
  for Group in Groups(Slice(W,Open+1,Close-Open-1),';') do
    if FindTop(Group,'=')<0 then
      Inc(Result,Length(ParameterNames(Lex('procedure P('+Join(Group)+');'))));
end;

function DeferredMask(const Tokens: TArray<string>): TArray<Boolean>;
var I, Start, Level, J: Integer;
begin
  SetLength(Result,Length(Tokens)); I:=0;
  while I<Length(Tokens) do
  begin
    if not MatchText(Tokens[I],['procedure','function']) then begin Inc(I); Continue; end;
    Start:=I;
    while (I<Length(Tokens)) and not MatchText(Tokens[I],['begin','asm']) do Inc(I);
    Level:=0;
    while I<Length(Tokens) do
    begin
      if MatchText(Tokens[I],['begin','asm','case','try']) then Inc(Level)
      else if SameText(Tokens[I],'end') then
      begin Dec(Level); if Level=0 then begin Inc(I); Break; end; end;
      Inc(I);
    end;
    for J:=Start to I-1 do Result[J]:=True;
  end;
end;

constructor TCallResolver.Create(UnitItem: TPasUnit; const InputFile: string; Loader: TUnitLoader);
var Data: TJSONObject; Candidate: string; I: Integer;
begin
  inherited Create;
  FInput:=ExpandFileName(InputFile); FRoot:=ExtractFileDir(FInput); FLoader:=Loader;
  // A protocol/source subdirectory commonly imports a form in the project root.
  // Ascend only to a nearby project marker, never recursively scan a drive root.
  Candidate:=FRoot;
  for I:=0 to 2 do
  begin
    if (Length(TDirectory.GetFiles(Candidate,'*.dproj'))>0) or
       (Length(TDirectory.GetFiles(Candidate,'*.dpr'))>0) or
       (Length(TDirectory.GetFiles(Candidate,'*.doxygen'))>0) then
    begin FRoot:=Candidate; Break; end;
    Candidate:=ExtractFileDir(Candidate);
    if Candidate=ExcludeTrailingPathDelimiter(ExtractFileDrive(Candidate)) then Break;
  end;
  FUnits:=TObjectDictionary<string,TJSONObject>.Create([doOwnsValues]);
  FTypes:=TDictionary<string,TJSONObject>.Create;
  FAliases:=TDictionary<string,TJSONObject>.Create;
  FTypeCache:=TDictionary<string,string>.Create;
  FVariableItems:=TDictionary<string,TJSONObject>.Create;
  FRoutines:=TDictionary<string,TJSONObject>.Create;
  FMembers:=TObjectDictionary<string,TList<TJSONObject>>.Create([doOwnsValues]);
  FVariables:=TDictionary<string,string>.Create;
  FFiles:=TDictionary<string,string>.Create;
  Data:=TJSONObject.ParseJSONValue(AstJson(UnitItem)) as TJSONObject;
  FOwnUnit:=Canonical(UnitItem.Name);
  FUnits.Add(Canonical(UnitItem.Name),Data);
  LoadImports(Data);
  IndexItems;
end;

destructor TCallResolver.Destroy;
begin
  FFiles.Free; FVariables.Free; FVariableItems.Free; FTypeCache.Free; FAliases.Free;
  FMembers.Free; FRoutines.Free; FTypes.Free; FUnits.Free;
  inherited;
end;

procedure TCallResolver.IndexDirectory(const Directory: string; var Remaining: Integer);
var Search: TSearchRec; Key, Path, Previous: string;
begin
  if Remaining<=0 then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(Directory)+'*',faAnyFile,Search)<>0 then Exit;
  try
    repeat
      if (Search.Name='.') or (Search.Name='..') then Continue;
      if (Search.FindData.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT)<>0 then Continue;
      Path:=TPath.Combine(Directory,Search.Name);
      if (Search.Attr and faDirectory)<>0 then
      begin
        if MatchText(Search.Name,['.git','.svn','Doxygen','output','build','node_modules',
          '__history','__recovery','Win32','Win64']) then Continue;
        IndexDirectory(Path,Remaining);
      end else if SameText(ExtractFileExt(Search.Name),'.pas') then
      begin
        Dec(Remaining); Key:=LowerCase(ChangeFileExt(Search.Name,''));
        if FFiles.TryGetValue(Key,Previous) and not SameFileName(Previous,Path) then Path:='';
        FFiles.AddOrSetValue(Key,Path); // Ambiguous duplicate names are not guessed.
      end;
      if Remaining<=0 then Break;
    until FindNext(Search)<>0;
  finally System.SysUtils.FindClose(Search); end;
end;

function TCallResolver.FindUnit(const Name: string): string;
var Remaining: Integer;
begin
  Result:=TPath.Combine(ExtractFileDir(FInput),Name+'.pas');
  if FileExists(Result) then Exit;
  if not FIndexed then
  begin
    FIndexed:=True; Remaining:=10000;
    IndexDirectory(FRoot,Remaining);
  end;
  if not FFiles.TryGetValue(LowerCase(Name),Result) then Result:='';
end;

procedure TCallResolver.LoadImports(Data: TJSONObject);
var Used: TJSONArray; Name: TJSONValue; Key, Path: string; Parsed: TPasUnit; Imported: TJSONObject;
begin
  Used:=ArrayOf(Data,'uses');
  if Used=nil then Exit;
  for Name in Used do
  begin
    Key:=Canonical(Name.Value);
    if FUnits.ContainsKey(Key) then Continue;
    FUnits.Add(Key,nil); // Also guards circular uses and repeated missing libraries.
    Path:=FindUnit(Name.Value);
    if Path='' then Continue;
    Parsed:=FLoader(Path);
    if Parsed=nil then Continue;
    try Imported:=TJSONObject.ParseJSONValue(AstJson(Parsed)) as TJSONObject;
    finally Parsed.Free; end;
    if Canonical(Value(Imported,'unit'))<>Key then begin Imported.Free; Continue; end;
    FUnits[Key]:=Imported;
    LoadImports(Imported);
  end;
end;

procedure TCallResolver.IndexItems;
var Pair: TPair<string,TJSONObject>; Node: TJSONValue; Data: TJSONObject;
  Scope, Key, Kind, Alias: string; Members: TList<TJSONObject>; Group: TPair<string,TList<TJSONObject>>;
begin
  for Pair in FUnits do
  begin
    if Pair.Value=nil then Continue;
    for Node in ArrayOf(Pair.Value,'items') do
    begin
      Data:=Node as TJSONObject;
      Data.AddPair('_unit',Pair.Key); Scope:=Canonical(Value(Data,'scope'));
      Data.AddPair('_scope',Scope); Kind:=Value(Data,'kind');
      Key:=Scope+'|'+Canonical(Value(Data,'name'));
      if Kind='TPasCio' then FTypes.AddOrSetValue(Scope+'.'+Canonical(Value(Data,'name')),Data)
      else if MatchText(Kind,['TPasType','TPasAliasType']) then
        FAliases.AddOrSetValue(Scope+'.'+Canonical(Value(Data,'name')),Data)
      else if MatchText(Kind,['TPasFieldVariable','TPasProperty']) then
      begin
        FVariables.AddOrSetValue(Key,DeclaredType(Value(Data,'declaration')));
        FVariableItems.AddOrSetValue(Key,Data);
      end
      else if (Kind='TPasRoutine') and (Value(Data,'isType')<>'true') then
      begin
        Data.AddPair('_required',TJSONNumber.Create(RequiredParameters(Value(Data,'declaration'))));
        FRoutines.AddOrSetValue(Value(Data,'id'),Data);
        if not FMembers.TryGetValue(Key,Members) then
        begin Members:=TList<TJSONObject>.Create; FMembers.Add(Key,Members); end;
        Members.Add(Data);
      end;
    end;
  end;
  for Group in FMembers do
    if Group.Value.Count>1 then
      for Data in Group.Value do
      begin
        Alias:=Identifier(Value(Data,'name'))+'__overload_'+Copy(Value(Data,'id'),1,8);
        Data.AddPair('_cpp_alias',Alias);
      end;
end;

function TCallResolver.Imports(Item: TJSONObject): TArray<string>;
var UnitData: TJSONObject; A: TJSONArray; I, Count: Integer;
begin
  SetLength(Result,1); Result[0]:=Value(Item,'_unit');
  if not FUnits.TryGetValue(Result[0],UnitData) or (UnitData=nil) then Exit;
  A:=ArrayOf(UnitData,'uses'); if A=nil then Exit;
  Count:=1; SetLength(Result,A.Count+1);
  for I:=A.Count-1 downto 0 do begin Result[Count]:=Canonical(A[I].Value); Inc(Count); end;
end;

function TCallResolver.FindType(const Name: string; Item: TJSONObject): string;
var CacheKey: string;
  function Lookup(const TypeName: string; Owner: TJSONObject; Depth: Integer): string;
  var Key, Context, Candidate: string; Data: TJSONObject; W: TWords; P: Integer;
    Candidates: TArray<string>;
  begin
    Result:=''; if Depth>15 then Exit;
    Key:=Canonical(TypeName);
    Candidates:=TArray<string>.Create(Key,Value(Owner,'_scope')+'.'+Key);
    for Context in Imports(Owner) do Candidates:=Candidates+TArray<string>.Create(Context+'.'+Key);
    for Candidate in Candidates do
    begin
      if FTypes.ContainsKey(Candidate) then Exit(Candidate);
      if FAliases.TryGetValue(Candidate,Data) then
      begin
        W:=Lex(Value(Data,'declaration')); P:=FindTop(W,'=');
        if P>=0 then
        begin
          W:=Slice(W,P+1);
          if (Length(W)>0) and (W[High(W)]=';') then W:=Slice(W,0,Length(W)-1);
          if (Length(W)>0) and SameText(W[0],'type') then W:=Slice(W,1);
          Exit(Lookup(Join(W),Data,Depth+1));
        end;
      end;
    end;
  end;
begin
  CacheKey:=Canonical(Name)+'|'+Value(Item,'_scope')+'|'+Value(Item,'_unit');
  if FTypeCache.TryGetValue(CacheKey,Result) then Exit;
  Result:=Lookup(Name,Item,0); FTypeCache.Add(CacheKey,Result);
end;

function TCallResolver.Ancestors(const Scope: string; Item: TJSONObject): TArray<string>;
var List: TList<string>; Seen: TDictionary<string,Boolean>;
  procedure Visit(const Current: string);
  var Data: TJSONObject; Parents: TJSONArray; Parent: TJSONValue; Found: string;
  begin
    if (Current='') or Seen.ContainsKey(Current) then Exit;
    Seen.Add(Current,True); List.Add(Current);
    if not FTypes.TryGetValue(Current,Data) then Exit;
    Parents:=ArrayOf(Data,'ancestors'); if Parents=nil then Exit;
    for Parent in Parents do
    begin Found:=FindType(Parent.Value,Data); if Found<>'' then Visit(Found); end;
  end;
begin
  List:=TList<string>.Create; Seen:=TDictionary<string,Boolean>.Create;
  try Visit(Scope); Result:=List.ToArray;
  finally Seen.Free; List.Free; end;
end;

function TCallResolver.VariableType(const Name, Scope: string; Item: TJSONObject;
  Locals: TDictionary<string,string>): string;
var Key, Kind, Context: string; Declaration: TJSONObject;
begin
  Key:=Canonical(Name); Result:='';
  if Key='self' then Exit(Scope);
  if Key='result' then Exit(FindType(DeclaredType(Value(Item,'declaration')),Item));
  if (Locals<>nil) and Locals.TryGetValue(Key,Kind) then Exit(FindType(Kind,Item));
  for Context in Ancestors(Scope,Item)+Imports(Item) do
    if FVariables.TryGetValue(Context+'|'+Key,Kind) then
    begin
      Declaration:=FVariableItems[Context+'|'+Key];
      Exit(FindType(Kind,Declaration));
    end;
end;

function TCallResolver.Resolve(const Chain: TArray<string>; ArgCount: Integer; Item: TJSONObject;
  Locals: TDictionary<string,string>): TJSONObject;
var Contexts: TArray<string>; Scope, Name, Owner, Context: string;
  I, Prefix, Minimum, Maximum: Integer; Members: TList<TJSONObject>; Candidate: TJSONObject;
begin
  Result:=nil; if Length(Chain)=0 then Exit;
  Name:=Canonical(Chain[High(Chain)]); Scope:=Value(Item,'_scope');
  if Length(Chain)=1 then
  begin
    if Locals.ContainsKey(Name) then Exit;
    Contexts:=Ancestors(Scope,Item)+Imports(Item);
    for Context in Contexts do if FVariables.ContainsKey(Context+'|'+Name) then Exit;
  end else
  begin
    Owner:=Canonical(string.Join('.',Copy(Chain,0,Length(Chain)-1)));
    Contexts:=nil;
    if Owner='inherited' then Contexts:=Copy(Ancestors(Scope,Item),1,MaxInt)
    else if FUnits.ContainsKey(Owner) then Contexts:=TArray<string>.Create(Owner)
    else
    begin
      Context:=FindType(Owner,Item);
      if Context='' then
      begin
        Prefix:=0;
        for I:=High(Chain)-1 downto 1 do
          if FUnits.ContainsKey(Canonical(string.Join('.',Copy(Chain,0,I)))) then
          begin Prefix:=I; Break; end;
        if Prefix>0 then
          Context:=VariableType(Chain[Prefix],Canonical(string.Join('.',Copy(Chain,0,Prefix))),Item,nil)
        else Context:=VariableType(Chain[0],Scope,Item,Locals);
        for I:=Prefix+1 to High(Chain)-1 do
          if Context<>'' then Context:=VariableType(Chain[I],Context,Item,nil);
      end;
      if Context<>'' then Contexts:=Ancestors(Context,Item);
    end;
  end;
  for Context in Contexts do
    if FMembers.TryGetValue(Context+'|'+Name,Members) then
    begin
      for Candidate in Members do
      begin
        Maximum:=ArrayOf(Candidate,'parameterTypes').Count;
        Minimum:=StrToInt(Value(Candidate,'_required'));
        if (Minimum<=ArgCount) and (ArgCount<=Maximum) then
        begin if Result<>nil then Exit(nil); Result:=Candidate; end;
      end;
      Exit; // The nearest declaring scope wins, including ambiguous overloads.
    end;
end;

function TCallResolver.LocalsFor(Item: TJSONObject): TDictionary<string,string>;
var Names, Types, Tokens: TArray<string>; I, J, K: Integer; Kind: string; Deferred: TArray<Boolean>;
begin
  Result:=TDictionary<string,string>.Create;
  Names:=WordsOf(Item,'parameterNames'); Types:=WordsOf(Item,'parameterTypes');
  for I:=0 to High(Names) do
    if I<Length(Types) then Result.AddOrSetValue(Canonical(Names[I]),Types[I]);
  Tokens:=WordsOf(Item,'bodyTokens');
  Deferred:=DeferredMask(Tokens);
  for I:=1 to High(Tokens) do if not Deferred[I] and (Tokens[I]=':') then
  begin
    K:=I+1;
    while (K<Length(Tokens)) and not MatchText(Tokens[K],[';',':=','=']) do Inc(K);
    Kind:=Join(Slice(Tokens,I+1,K-I-1)); J:=I-1;
    while (J>=0) and IsName(Tokens[J]) do
    begin
      Result.AddOrSetValue(Canonical(Tokens[J]),Kind);
      if (J<2) or (Tokens[J-1]<>',') then Break;
      Dec(J,2);
    end;
  end;
  for I:=0 to Length(Tokens)-5 do
    if not Deferred[I] and SameText(Tokens[I],'var') and (Tokens[I+2]=':=') then
    begin
      J:=I+3;
      while (J<Length(Tokens)) and (IsName(Tokens[J]) or (Tokens[J]='.')) do Inc(J);
      if J>=I+6 then
      begin
        Kind:=Join(Slice(Tokens,I+3,J-I-5));
        if FindType(Kind,Item)<>'' then Result.AddOrSetValue(Canonical(Tokens[I+1]),Kind);
      end;
    end;
end;

function TCallResolver.CppName(Item: TJSONObject): string;
var Name: string;
begin
  Name:=Value(Item,'_cpp_alias'); if Name='' then Name:=Identifier(Value(Item,'name'));
  if Value(Item,'declaration').ToLower.StartsWith('class ') and
    MatchText(Value(Item,'routineKind'),['constructor','destructor']) then Name:='DelphiClass_'+Name;
  Result:='::'+CppTypeText(Value(Item,'scope'))+'::'+Name;
end;

function TCallResolver.CallsFor(Item: TJSONObject; out HasCallback: Boolean): TJSONArray;
var Tokens, Chain: TArray<string>; Pos, Ending, Cursor, Level, ArgCount, I, BeginAt: Integer;
  Parentheses, Plausible, HasWith, Anonymous, HasSignature: Boolean; Target: TJSONObject;
  Locals, Excluded: TDictionary<string,string>; Unique: TDictionary<string,Boolean>;
  Token, Following, Preceding, Expression: string;
begin
  Result:=TJSONArray.Create; HasCallback:=False;
  Locals:=LocalsFor(Item); Excluded:=TDictionary<string,string>.Create;
  Unique:=TDictionary<string,Boolean>.Create;
  try
    Tokens:=WordsOf(Item,'bodyTokens'); HasWith:=False;
    for I:=0 to High(Tokens)-1 do
    begin
      if SameText(Tokens[I],'with') then HasWith:=True;
      if MatchText(Tokens[I],['procedure','function']) and IsName(Tokens[I+1]) then
        Excluded.AddOrSetValue(Canonical(Tokens[I+1]),'nested routine');
    end;
    Pos:=0;
    while Pos<Length(Tokens) do
    begin
      Token:=Tokens[Pos];
      if MatchText(Token,['procedure','function']) then
      begin
        Cursor:=Pos+1; Anonymous:=(Cursor<Length(Tokens)) and not IsName(Tokens[Cursor]);
        // "begin" is lexically an identifier, but starts a parameterless callback.
        if (Cursor<Length(Tokens)) and SameText(Tokens[Cursor],'begin') then Anonymous:=True;
        HasSignature:=False;
        while (Cursor<Length(Tokens)) and not MatchText(Tokens[Cursor],['begin','asm']) do
        begin
          if (Tokens[Cursor]=':') or SameText(Tokens[Cursor],'var') then HasSignature:=True;
          Inc(Cursor);
        end;
        BeginAt:=Cursor; Level:=0;
        while Cursor<Length(Tokens) do
        begin
          if MatchText(Tokens[Cursor],['begin','asm','case','try']) then Inc(Level)
          else if SameText(Tokens[Cursor],'end') then
          begin Dec(Level); if Level=0 then begin Inc(Cursor); Break; end; end;
          Inc(Cursor);
        end;
        if Anonymous and not HasSignature then
        begin HasCallback:=True; Pos:=BeginAt+1; Continue; end;
        Pos:=Cursor; Continue;
      end;
      if not IsName(Token) or ((Pos>0) and MatchText(Tokens[Pos-1],['.','@'])) then
      begin Inc(Pos); Continue; end;
      Chain:=TArray<string>.Create(Token); Ending:=Pos+1;
      while (Ending+1<Length(Tokens)) and (Tokens[Ending]='.') and IsName(Tokens[Ending+1]) do
      begin Chain:=Chain+TArray<string>.Create(Tokens[Ending+1]); Inc(Ending,2); end;
      if (Ending<Length(Tokens)) and (Tokens[Ending]='<') then
      begin
        Cursor:=Ending+1; Level:=1;
        while (Cursor<Length(Tokens)) and (Level>0) do
        begin
          if not (IsName(Tokens[Cursor]) or MatchText(Tokens[Cursor],['<','>',',','.','[',']','^'])) then Break;
          if MatchText(Tokens[Cursor],['then','do','begin','end','and','or']) then Break;
          if Tokens[Cursor]='<' then Inc(Level);
          if Tokens[Cursor]='>' then Dec(Level);
          Inc(Cursor);
        end;
        if (Level=0) and (Cursor<Length(Tokens)) and MatchText(Tokens[Cursor],['(','.']) then Ending:=Cursor;
      end;
      ArgCount:=0; Parentheses:=(Ending<Length(Tokens)) and (Tokens[Ending]='(');
      if Parentheses then
      begin
        Cursor:=Ending+1; Level:=0;
        if (Cursor<Length(Tokens)) and (Tokens[Cursor]<>')') then ArgCount:=1;
        while Cursor<Length(Tokens) do
        begin
          if MatchText(Tokens[Cursor],['(','[']) then Inc(Level)
          else if MatchText(Tokens[Cursor],[')',']']) then
          begin if Level=0 then Break; Dec(Level); end
          else if (Tokens[Cursor]=',') and (Level=0) then Inc(ArgCount);
          Inc(Cursor);
        end;
      end;
      Following:=''; Preceding:='';
      if Ending<Length(Tokens) then Following:=Tokens[Ending];
      if Pos>0 then Preceding:=Tokens[Pos-1];
      if SameText(Preceding,'inherited') then Chain:=TArray<string>.Create('inherited')+Chain;
      Plausible:=Parentheses or (not MatchText(Following,[':',':=','.']) and
        not MatchText(Preceding,['var','type','const','procedure','function']));
      if (Length(Chain)=1) and SameText(Token,Value(Item,'name')) and
        (Value(Item,'routineKind')='function') and not Parentheses then Plausible:=False;
      if HasWith and (Length(Chain)=1) then Plausible:=False;
      if Plausible and not Excluded.ContainsKey(Canonical(Chain[0])) then
      begin
        Target:=Resolve(Chain,ArgCount,Item,Locals);
        // A procedure name used as an expression is a callback value, not a
        // call. Bare statement calls (MatrixOff;) remain supported.
        if (Target<>nil) and not Parentheses and (Value(Target,'routineKind')='procedure') and
          not MatchText(Preceding,['','begin',';','then','do','else','repeat','end']) then Target:=nil;
        if Target<>nil then
        begin
          Expression:=CppName(Target)+'(';
          for I:=1 to ArgCount do
          begin if I>1 then Expression:=Expression+','; Expression:=Expression+'0'; end;
          Expression:=Expression+')';
          if not Unique.ContainsKey(Expression) then
          begin Result.Add(Expression); Unique.Add(Expression,True); end;
        end;
      end;
      Inc(Pos);
    end;
  finally Unique.Free; Excluded.Free; Locals.Free; end;
end;

function TCallResolver.CreateMap: TJSONObject;
var Calls, Names, Definitions, Callbacks: TJSONObject; Pair: TPair<string,TJSONObject>;
  Data: TJSONObject; HasCallback: Boolean; A: TJSONArray;
begin
  Result:=TJSONObject.Create;
  Calls:=TJSONObject.Create; Names:=TJSONObject.Create; Definitions:=TJSONObject.Create; Callbacks:=TJSONObject.Create;
  Result.AddPair('automatic',TJSONBool.Create(True));
  Result.AddPair('calls',Calls); Result.AddPair('names',Names);
  Result.AddPair('definitions',Definitions); Result.AddPair('callbacks',Callbacks);
  for Pair in FRoutines do
  begin
    Data:=Pair.Value;
    if Value(Data,'_unit')<>FOwnUnit then Continue;
    if Value(Data,'_cpp_alias')<>'' then Names.AddPair(Pair.Key,Value(Data,'_cpp_alias'));
    A:=ArrayOf(Data,'bodyTokens'); if (A=nil) or (A.Count=0) then Continue;
    A:=CallsFor(Data,HasCallback); Calls.AddPair(Pair.Key,A);
    Definitions.AddPair(Pair.Key,CppName(Data));
    if HasCallback then Callbacks.AddPair(Pair.Key,TJSONBool.Create(True));
  end;
end;

end.
