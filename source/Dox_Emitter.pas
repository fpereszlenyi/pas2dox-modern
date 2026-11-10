unit Dox_Emitter;

{ Pas2Dox Modern, 2026-11-10. GPL-2.0; see LICENSE. }

interface

uses System.SysUtils, System.Classes, System.Generics.Collections,
  PasDoc_Items, System.JSON;

type
  TDoxEmitter = class
  private
    FLines: TStringList;
    FInput: string;
    FAnchorLine: Integer;
    FExpanded: Boolean;
    FSpecialized: TDictionary<TPasItem,Boolean>;
    FNamespace: string;
    FCallMap: TJSONObject;
    FDefinitions: TStringList;
    FUnitItem: TPasUnit;
    function LineOf(Item: TPasItem): Integer;
    procedure Put(Line: Integer; const Text: string);
    procedure Description(Item: TPasItem; Line: Integer);
    function Emit(Item: TPasItem; const Container: string): Integer;
    function EmitItems(Items: TPasItems; const Container: string): Integer;
    function EmitCio(Cio: TPasCio): Integer;
    function Documentation(Item: TPasItem; const Description: string): string;
  public
    constructor Create(const InputFile: string; Expanded: Boolean; const CallMapFile: string = ''; AutoMap: TJSONObject = nil);
    destructor Destroy; override;
    function Render(UnitItem: TPasUnit): string;
  end;

implementation

uses System.IOUtils, System.StrUtils, System.Math, System.RegularExpressions, System.Generics.Defaults, Dox_Syntax,
  PasDoc_Tokenizer, PasDoc_StringPairVector, Dox_Manifest;

constructor TDoxEmitter.Create(const InputFile: string; Expanded: Boolean; const CallMapFile: string; AutoMap: TJSONObject);
var Source: string; I: Integer; Reader: TStreamReader;
begin
  inherited Create;
  FInput:=ExpandFileName(InputFile); FExpanded:=Expanded;
  FLines:=TStringList.Create;
  FDefinitions:=TStringList.Create;
  FSpecialized:=TDictionary<TPasItem,Boolean>.Create;
  FCallMap:=AutoMap;
  if CallMapFile<>'' then
  begin
    FCallMap:=TJSONObject.ParseJSONValue(TFile.ReadAllText(CallMapFile,TEncoding.UTF8)) as TJSONObject;
    if FCallMap=nil then raise Exception.Create('Invalid call-map JSON');
  end;
  Reader:=TStreamReader.Create(InputFile,DefaultInputEncoding,True);
  try Source:=Reader.ReadToEnd; finally Reader.Free; end;
  FLines.Text:=Source;
  for I:=0 to FLines.Count-1 do FLines[I]:='';
  if FLines.Count=0 then FLines.Add('');
  FAnchorLine:=1;
end;

destructor TDoxEmitter.Destroy;
begin FDefinitions.Free; FCallMap.Free; FSpecialized.Free; FLines.Free; inherited; end;

function TDoxEmitter.LineOf(Item: TPasItem): Integer;
begin
  Result:=Item.SourceLine;
  if (Item.SourceAbsoluteFileName<>'') and not SameFileName(ExpandFileName(Item.SourceAbsoluteFileName),FInput) then
  begin
    Result:=Item.SourceRootLine;
    if Result=0 then Result:=FAnchorLine;
  end;
  if Result<1 then Result:=1;
  if Result>FLines.Count then Result:=FLines.Count;
end;

procedure TDoxEmitter.Put(Line: Integer; const Text: string);
begin
  if FExpanded then begin FLines.Add(Text); Exit; end;
  if Line<1 then Line:=1;
  while Line>FLines.Count do FLines.Add('');
  if FLines[Line-1]<>'' then FLines[Line-1]:=FLines[Line-1]+' ';
  FLines[Line-1]:=FLines[Line-1]+Flat(Text);
end;

function DocLiteral(const Text: string): string;
begin
  Result:=Text.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('\','\\')
    .Replace('/*','/<em></em>*').Replace('*/','*<em></em>/');
end;

function TDoxEmitter.Documentation(Item: TPasItem; const Description: string): string;
var A: TStringPair;
begin
  Result:=Description;
  // The original Pascal signature retains information without a C++ equivalent.
  if Item.FullDeclaration<>'' then
    Result:=Result+#10+'\par Delphi declaration'+#10+'<pre>'+DocLiteral(Item.FullDeclaration)+'</pre>';
  if Item is TPasCio then
    Result:=Result+#10+'\note Delphi type: <tt>'+DocLiteral(TPasCio(Item).NameWithGeneric)+'</tt>';
  for A in Item.Attributes do
    Result:=Result+#10+'\note Delphi attribute: <tt>'+DocLiteral(A.Name+A.Value)+'</tt>';
  if Item.Visibility in [viStrictPrivate,viStrictProtected,viPublished,viAutomated] then
    Result:=Result+#10+'\note Delphi visibility: '+string(VisibilityStr[Item.Visibility]);
  if (Item.SourceAbsoluteFileName<>'') and not SameFileName(ExpandFileName(Item.SourceAbsoluteFileName),FInput) then
    Result:=Result+#10+'\note Declared in '+ExtractFileName(Item.SourceAbsoluteFileName)+':'+IntToStr(Item.SourceLine);
end;

function ConvertComment(const Text: string): string;
const Options: TRegExOptions = [roIgnoreCase];
begin
  Result:=Text;
  if Result.Contains('<summary') or Result.Contains('<param') or Result.Contains('<returns') then
    Result:=Result.Replace('\','\\');
  Result:=TRegEx.Replace(Result,'<summary\s*>','\brief ',Options);
  Result:=TRegEx.Replace(Result,'</summary\s*>','',Options);
  Result:=TRegEx.Replace(Result,'<param\s+name="([^"]+)"\s*>','\param $1 ',Options);
  Result:=TRegEx.Replace(Result,'</param\s*>','',Options);
  Result:=TRegEx.Replace(Result,'<returns\s*>','\return ',Options);
  Result:=TRegEx.Replace(Result,'</returns\s*>','',Options);
  Result:=TRegEx.Replace(Result,'<remarks\s*>','',Options);
  Result:=TRegEx.Replace(Result,'</remarks\s*>','',Options);
  Result:=TRegEx.Replace(Result,'<exception\s+cref="([^"]+)"\s*>','\exception $1 ',Options);
  Result:=TRegEx.Replace(Result,'</exception\s*>','',Options);
  Result:=TRegEx.Replace(Result,'<see\s+cref="([^"]+)"\s*/>','\ref $1 ',Options);
  Result:=TRegEx.Replace(Result,'<c>','<tt>',Options);
  Result:=TRegEx.Replace(Result,'</c>','</tt>',Options);
  Result:=TRegEx.Replace(Result,'<code>','\code{.pascal}',Options);
  Result:=TRegEx.Replace(Result,'</code>','\endcode',Options);
  Result:=TRegEx.Replace(Result,'<emphasis>','<em>',Options);
  Result:=TRegEx.Replace(Result,'</emphasis>','</em>',Options);
end;

procedure TDoxEmitter.Description(Item: TPasItem; Line: Integer);
var Text, Name, Replacement: string; Comments: TStringList; I, Start, MatchIndex: Integer;
  HasSpace: Boolean; Names: TWords; Matches: TMatchCollection; Match: TMatch;
  Todo: TPasSourceTodo; TodoText: string;
begin
  Text:=ConvertComment(Item.RawDescription).Replace('*/','* /');
  if (Item is TPasRoutine) and (TPasRoutine(Item).What in
    [ROUTINE_PROCEDURE,ROUTINE_CONSTRUCTOR,ROUTINE_DESTRUCTOR]) then
  begin
    Text:=TRegEx.Replace(Text,'[@\\]returns?\b','\par Delphi return documentation'+#10,[roIgnoreCase]);
    Text:=TRegEx.Replace(Text,'[@\\]retval\b','\par Delphi result annotation'+#10,[roIgnoreCase]);
  end;
  if Item.FullDeclaration<>'' then
  begin
    Names:=ParameterNames(Lex(Item.FullDeclaration));
    Matches:=TRegEx.Matches(Text,'([@\\]param\s+(?:\[[^\]]+\]\s*)?)([\w]+)');
    for MatchIndex:=Matches.Count-1 downto 0 do
    begin
      Match:=Matches[MatchIndex]; Replacement:=Match.Value;
      for Name in Names do if SameText(Name,Match.Groups[2].Value) then Replacement:=Match.Groups[1].Value+Name;
      Delete(Text,Match.Index,Match.Length); Insert(Replacement,Text,Match.Index);
    end;
  end;
  for Todo in FUnitItem.SourceTodos do
    if (Todo.Owner=Item) or ((Item=FUnitItem) and (Todo.Owner=nil)) then
    begin
      TodoText:=Trim(Copy(Todo.Text,5,MaxInt));
      if TodoText.StartsWith(':') then TodoText:=Trim(Copy(TodoText,2,MaxInt));
      TodoText:=Flat(TodoText);
      Text:=Text+#10+#10+'\todo '+DocLiteral(TodoText).Replace('@','\@')+
        ' (Delphi: <tt>'+DocLiteral(ExtractFileName(Todo.SourceFile))+':'+IntToStr(Todo.Line)+'</tt>)'+#10+#10;
    end;
  // Preserve documentation paragraphs and commands in their original line gap.
  // Full original signatures are in expanded mode and the optional JSON AST.
  if FExpanded then Text:=Documentation(Item,Text);
  if Text='' then Exit;
  Comments:=TStringList.Create;
  try
    Comments.Text:=Text;
    Start:=Line-Comments.Count;
    HasSpace:=(Start>=1) and not FExpanded and ((Item.SourceAbsoluteFileName='') or SameFileName(Item.SourceAbsoluteFileName,FInput));
    if HasSpace then
      for I:=Start to Line-1 do if FLines[I-1]<>'' then HasSpace:=False;
    if HasSpace then
    begin
      for I:=0 to Comments.Count-1 do
      begin
        Text:=Comments[I];
        if I=0 then Text:='/** '+Text;
        if I=Comments.Count-1 then Text:=Text+' */';
        FLines[Start+I-1]:=Text;
      end;
    end else if FExpanded then
    begin
      FLines.Add('/**');
      for I:=0 to Comments.Count-1 do FLines.Add(Comments[I]);
      FLines.Add('*/');
    end else if (FCallMap<>nil) and (FCallMap.GetValue('automatic')<>nil) then
    begin
      // Graph mode already adds generated definition lines. Preserve comment
      // newlines too: flattening a heading/\par makes later commands its title.
      FLines[Line-1]:=FLines[Line-1]+#10+'/**'+#10+Text+#10+'*/'+#10;
    end else Put(Line,'/** '+Flat(Text)+' */');
  finally Comments.Free; end;
end;

function Visibility(Item: TPasItem): string;
begin
  case Item.Visibility of
    viPrivate,viStrictPrivate: Result:='private: ';
    viProtected,viStrictProtected: Result:='protected: ';
  else Result:='public: ';
  end;
end;

function TDoxEmitter.EmitCio(Cio: TPasCio): Integer;
var Header, Name, Parents, Kind, Arguments: string; A: TStringPair; Start, Ending: Integer;
begin
  Start:=LineOf(Cio); FAnchorLine:=Start;
  Header:=GenericHeader(Lex(Cio.NameWithGeneric),Name);
  if (Header<>'') and FSpecialized.ContainsKey(Cio) then
  begin
    Arguments:=Header.Replace('template<','').Replace('class ','').Replace('> ','');
    Name:=Name+'<'+Arguments+'>';
  end;
  Kind:='class';
  if Cio.MyType in [CIO_RECORD,CIO_PACKEDRECORD,CIO_OBJECT,CIO_PACKEDOBJECT] then Kind:='struct';
  Parents:='';
  for A in Cio.Ancestors do
  begin
    if Parents<>'' then Parents:=Parents+', ';
    Arguments:=CppTypeText(A.Value);
    if SameText(A.Name,Cio.Name) and (Cio.NameWithGeneric<>A.Value) then
      Arguments:='::'+FNamespace+'::'+Arguments;
    Parents:=Parents+'public '+Arguments;
  end;
  if Parents<>'' then Parents:=' : '+Parents;
  if Cio.ClassDirective=CT_HELPER then
    Put(Start,'/** \note Delphi helper for '+CppTypeText(Cio.HelperTypeIdentifier)+' */');
  if Cio.ClassDirective=CT_ABSTRACT then Put(Start,'/** \note Delphi abstract class */');
  if Cio.ClassDirective=CT_SEALED then Put(Start,'/** \note Delphi sealed class */');
  Put(Start,Header+Kind+' '+Name+Parents+' { public:');
  Ending:=Start;
  Ending:=Max(Ending,EmitItems(Cio.Cios,Name));
  Ending:=Max(Ending,EmitItems(Cio.Types,Name));
  Ending:=Max(Ending,EmitItems(Cio.Fields,Name));
  Ending:=Max(Ending,EmitItems(Cio.Constants,Name));
  Ending:=Max(Ending,EmitItems(Cio.Methods,Name));
  Ending:=Max(Ending,EmitItems(Cio.Properties,Name));
  if (Cio.SourceEndLine>0) and SameFileName(Cio.SourceAbsoluteFileName,FInput) then Ending:=Max(Ending,Cio.SourceEndLine);
  Put(Ending,'};');
  Result:=Ending;
end;

function TDoxEmitter.Emit(Item: TPasItem; const Container: string): Integer;
var Line, Colon, Ending, I: Integer; Code, Prefix, Original, DeclarationCode, RenderedName: string; W: TWords; Enum: TPasEnum; Member: TBaseItem; P: TPasProperty; Attribute: TStringPair;
  Calls, Call, Map, Names, Alias, Definitions: TJSONValue;
  Automatic: Boolean;
begin
  if GetEnvironmentVariable('PAS2DOX_TRACE')='1' then begin Writeln(ErrOutput,'emit ',Item.ClassName,' ',Item.Name); Flush(ErrOutput); end;
  Line:=LineOf(Item); Result:=Line;
  Description(Item,Line);
  Original:=Item.FullDeclaration;
  if Item is TPasCio then Original:=TPasCio(Item).NameWithGeneric;
  if (Original<>'') and not FExpanded then
    Put(Line,'/** \note Delphi: <tt>'+DocLiteral(Flat(Original))+'</tt> */');
  if not FExpanded then
    for Attribute in Item.Attributes do
      Put(Line,'/** \note Delphi attribute: <tt>'+DocLiteral(Flat(Attribute.Name+Attribute.Value))+'</tt> */');
  if (Item.SourceAbsoluteFileName<>'') and not SameFileName(Item.SourceAbsoluteFileName,FInput) then
    Put(Line,'/** \note Delphi source: '+ExtractFileName(Item.SourceAbsoluteFileName)+':'+IntToStr(Item.SourceLine)+' */');
  Prefix:='';
  if Container<>'' then Prefix:=Visibility(Item);
  if Item is TPasCio then
  begin
    if Prefix<>'' then Put(Line,Prefix);
    Result:=EmitCio(TPasCio(Item)); Exit;
  end;
  W:=Lex(Item.FullDeclaration);
  if Item is TPasEnum then
  begin
    Enum:=TPasEnum(Item); Code:='enum ';
    if Enum.Scoped then Code:=Code+'class ';
    Put(Line,Prefix+Code+Identifier(Item.Name)+' {');
    for Member in Enum.Members do
    begin
      I:=LineOf(TPasItem(Member));
      Description(TPasItem(Member),I);
      W:=Lex(TPasItem(Member).FullDeclaration);
      Colon:=FindTop(W,'=');
      Code:=Identifier(Member.Name);
      if Colon>=0 then Code:=Code+' = '+Expression(Slice(W,Colon+1));
      Put(I,Code+',');
      Result:=Max(Result,I);
    end;
    if SameFileName(Enum.SourceAbsoluteFileName,FInput) then Result:=Max(Result,Enum.SourceEndLine);
    Put(Result,'};'); Exit;
  end else if Item is TPasRoutine then
  begin
    if TPasRoutine(Item).IsType then Code:=AliasDecl(W,Item.Name)
    else Code:=Routine(W,Item.Name,Container);
    if (FCallMap<>nil) and not TPasRoutine(Item).IsType then
    begin
      RenderedName:=Identifier(Item.Name);
      if Item.FullDeclaration.ToLower.StartsWith('class ') and
        (TPasRoutine(Item).What in [ROUTINE_CONSTRUCTOR,ROUTINE_DESTRUCTOR]) then RenderedName:='DelphiClass_'+Item.Name;
      Names:=FCallMap.GetValue('names');
      if Names is TJSONObject then
      begin
        Alias:=TJSONObject(Names).GetValue(ItemKey(Item));
        if Alias<>nil then
        begin
          Code:=StringReplace(Code,RenderedName+'(',Alias.Value+'(',[]);
          RenderedName:=Alias.Value;
        end;
      end;
      Map:=FCallMap.GetValue('calls'); if not (Map is TJSONObject) then Map:=FCallMap;
      Calls:=TJSONObject(Map).GetValue(ItemKey(Item));
      if Calls is TJSONArray then
      begin
        DeclarationCode:=Code;
        Code:=Copy(Code,1,Length(Code)-1)+#10+'{'+#10;
        for Call in TJSONArray(Calls) do Code:=Code+'  '+Call.Value+';'+#10;
        Code:=Code+'}';
        Automatic:=FCallMap.GetValue('automatic')<>nil;
        if Automatic then
        begin
          Definitions:=FCallMap.GetValue('definitions');
          Alias:=TJSONObject(Definitions).GetValue(ItemKey(Item));
          Original:=Alias.Value;
          if Original.StartsWith('::') then Delete(Original,1,2);
          Code:=StringReplace(Code,RenderedName+'(',Original+'(',[]);
          if Code.StartsWith('static ') then Delete(Code,1,7);
          FDefinitions.Add(Code); Code:=DeclarationCode;
          Definitions:=FCallMap.GetValue('callbacks');
          if TJSONObject(Definitions).GetValue(ItemKey(Item))<>nil then
            Put(Line,'/** \note Call graph includes call sites inside parameterless anonymous callbacks declared in this routine; callback execution is not implied. */');
        end
        else if Container='' then
        begin
          // Separate qualified definitions avoid false recursive references
          // from Doxygen's namespace-level source scanner.
          FDefinitions.Add(StringReplace(Code,RenderedName+'(',FNamespace+'::'+RenderedName+'(',[]));
          Code:=DeclarationCode;
        end;
      end;
    end;
  end
  else if Item is TPasProperty then
  begin
    P:=TPasProperty(Item);
    W:=Lex(P.FullDeclaration); Colon:=FindTop(W,':');
    if Colon>=0 then
    begin
      Ending:=Length(W);
      for I:=Colon+1 to High(W) do
        if MatchText(W[I],['read','write','stored','default','nodefault','index','dispid','implements',';']) then
        begin Ending:=I; Break; end;
      Code:=CppType(Slice(W,Colon+1,Ending-Colon-1));
    end else Code:=P.Proptype;
    if P.Proptype='' then Code:='DelphiInheritedProperty '+Identifier(P.Name)+';'
    else if P.IndexDecl='' then Code:=Code+' '+Identifier(P.Name)+';'
    else
    begin
      W:=Lex(P.FullDeclaration);
      I:=FindTop(W,'['); Ending:=FindTop(W,']',I+1);
      Code:=Code+' '+Identifier(P.Name)+'('+Parameters(Slice(W,I+1,Ending-I-1))+');';
    end;
    if P.FullDeclaration.ToLower.StartsWith('class ') then Code:='static '+Code;
  end else if Item is TPasFieldVariable then Code:=VariableDecl(W,Item.Name,False)
  else if Item is TPasConstant then Code:=VariableDecl(W,Item.Name,True)
  else if Item is TPasType then Code:=AliasDecl(W,Item.Name)
  else raise Exception.Create('Unrecognized AST item '+Item.ClassName);
  Put(Line,Prefix+Code);
end;

function TDoxEmitter.EmitItems(Items: TPasItems; const Container: string): Integer;
var Item, Other: TBaseItem;
begin
  Result:=0;
  for Item in Items do
    if Item is TPasCio then
      for Other in Items do
        if (Other<>Item) and SameText(Other.Name,Item.Name) then FSpecialized.AddOrSetValue(TPasItem(Item),True);
  for Item in Items do Result:=Max(Result,Emit(TPasItem(Item),Container));
end;

function BalancedConditions(const Text: string): string;
var Matches: TMatchCollection; Match: TMatch; Stack: TList<Integer>;
  Remove: TDictionary<Integer,Boolean>; I, Index: Integer;
begin
  Result:=Text;
  Matches:=TRegEx.Matches(Text,'(?<![\\@\w])[@\\](cond|endcond)\b');
  Stack:=TList<Integer>.Create; Remove:=TDictionary<Integer,Boolean>.Create;
  try
    for I:=0 to Matches.Count-1 do
      if Matches[I].Groups[1].Value='cond' then Stack.Add(I)
      else if Stack.Count>0 then Stack.Delete(Stack.Count-1)
      else Remove.Add(I,True);
    for Index in Stack do Remove.Add(Index,True);
    for I:=Matches.Count-1 downto 0 do
      if Remove.ContainsKey(I) then
      begin Match:=Matches[I]; Delete(Result,Match.Index,Match.Length); end;
  finally Remove.Free; Stack.Free; end;
end;

function TDoxEmitter.Render(UnitItem: TPasUnit): string;
var Parts: TArray<string>; Part: string; I: Integer;
begin
  FUnitItem:=UnitItem;
  if FExpanded then FLines.Clear;
  Description(UnitItem,1);
  Parts:=UnitItem.Name.Split(['.']);
  FNamespace:=UnitItem.Name.Replace('.','::');
  for Part in Parts do Put(1,'namespace '+Identifier(Part)+' {');
  EmitItems(UnitItem.CIOs,''); EmitItems(UnitItem.Types,'');
  EmitItems(UnitItem.Constants,''); EmitItems(UnitItem.Variables,''); EmitItems(UnitItem.FuncsProcs,'');
  for I:=0 to High(Parts) do Put(FLines.Count,'}');
  FLines.AddStrings(FDefinitions);
  Result:=FLines.Text.Replace(#13#10,#10);
  Result:=BalancedConditions(Result);
end;

end.
