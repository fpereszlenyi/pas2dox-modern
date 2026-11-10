unit Dox_Syntax;

{ Pas2Dox Modern, 2026-11-10. GPL-2.0; see LICENSE.
  Declaration rendering only. Pascal parsing is performed by PasDoc. }

interface

uses System.SysUtils, System.StrUtils, System.Classes, System.Generics.Collections;

type
  TWords = TArray<string>;
  TWordGroups = TArray<TWords>;

function Lex(const Text: string): TWords;
function Join(const Words: TWords; First: Integer = 0; Count: Integer = MaxInt): string;
function Slice(const Words: TWords; First: Integer; Count: Integer = MaxInt): TWords;
function FindTop(const Words: TWords; const Value: string; First: Integer = 0): Integer;
function Groups(const Words: TWords; const Separator: string): TWordGroups;
function Identifier(const Text: string): string;
function CppType(const Words: TWords): string;
function CppTypeText(const Text: string): string;
function GenericHeader(const Words: TWords; out Name: string): string;
function Parameters(const Words: TWords): string;
function Routine(const Words: TWords; const Name, Container: string): string;
function VariableDecl(const Words: TWords; const Name: string; IsConstant: Boolean): string;
function AliasDecl(const Words: TWords; const Name: string): string;
function Flat(const Text: string): string;
function Expression(const Words: TWords): string;
function ParameterNames(const Words: TWords): TWords;

implementation

uses PasDoc_Tokenizer, PasDoc_Parser, PasDoc_Items, PasDoc_Types, PasDoc_StringVector;

function InlineRecord(const Words: TWords): string;
var Parser: TParser; Parsed: TPasUnit; Empty: TStringVector; Structure: TPasCio; Field: TBaseItem;
begin
  Parsed:=nil; Empty:=TStringVector.Create;
  Parser:=TParser.Create(TStringStream.Create(#$FEFF+'unit InlineType; interface type TInline='+Join(Words)+'; implementation end.',TEncoding.UTF8),
    Empty,Empty,nil,0,'inline record','',False);
  try
    Parser.ShowVisibilities:=AllVisibilities;
    Parser.ParseUnitOrProgram(Parsed);
    Structure:=TPasCio(Parsed.CIOs[0]);
    Result:='struct { ';
    for Field in Structure.Fields do
      Result:=Result+VariableDecl(Lex(TPasItem(Field).FullDeclaration),Field.Name,False)+' ';
    Result:=Result+'}';
  finally Parsed.Free; Parser.Free; Empty.Free; end;
end;

function Lex(const Text: string): TWords;
var Scanner: TTokenizer; Token: TToken; Items: TList<string>;
begin
  Items := TList<string>.Create;
  Scanner := TTokenizer.Create(TStringStream.Create(#$FEFF+Text, TEncoding.UTF8), nil, 0, 'declaration', '');
  try
    repeat
      Token := Scanner.GetToken(True);
      if Token = nil then Break;
      try
        if not (Token.MyType in [TOK_WHITESPACE, TOK_COMMENT_EXT, TOK_COMMENT_PAS,
          TOK_COMMENT_CSTYLE, TOK_COMMENT_HELPINSIGHT, TOK_DIRECTIVE]) then
        begin
          // Split >= in a generic declaration; Pascal permits TBox<T>=class.
          if Token.Data = '>=' then begin Items.Add('>'); Items.Add('='); end
          else Items.Add(Token.Data);
        end;
      finally Token.Free; end;
    until False;
    Result := Items.ToArray;
  finally Scanner.Free; Items.Free; end;
end;

function Slice(const Words: TWords; First, Count: Integer): TWords;
begin
  if First < 0 then First := 0;
  if First > Length(Words) then First := Length(Words);
  if Count > Length(Words) - First then Count := Length(Words) - First;
  Result := Copy(Words, First, Count);
end;

function Join(const Words: TWords; First, Count: Integer): string;
var I, Last: Integer; Current: string;
begin
  Result := '';
  Last := Length(Words) - 1;
  if Count < Length(Words) - First then Last := First + Count - 1;
  for I := First to Last do
  begin
    Current := Words[I];
    if (Result <> '') and not CharInSet(Current[1], ['.', ',', ';', ':', ')', ']', '>'])
      and not CharInSet(Result[Length(Result)], ['.', '(', '[', '<', ':'])
      and (Current <> '<') then Result := Result + ' ';
    Result := Result + Current;
  end;
end;

function Flat(const Text: string): string;
begin
  Result := Text.Replace(#13, '').Replace(#10, ' ');
end;

procedure Nest(const Word: string; var Angle, Round, Square: Integer);
begin
  if Word = '<' then Inc(Angle);
  if Word = '>' then Dec(Angle);
  if Word = '(' then Inc(Round);
  if Word = ')' then Dec(Round);
  if Word = '[' then Inc(Square);
  if Word = ']' then Dec(Square);
  if (Angle=0) and SameText(Word,'record') then Inc(Round);
  if (Angle=0) and SameText(Word,'end') then Dec(Round);
end;

function FindTop(const Words: TWords; const Value: string; First: Integer): Integer;
var I, A, R, S: Integer;
begin
  A := 0; R := 0; S := 0;
  for I := First to High(Words) do
  begin
    if (A = 0) and (R = 0) and (S = 0) and SameText(Words[I], Value) then Exit(I);
    Nest(Words[I], A, R, S);
  end;
  Result := -1;
end;

function Groups(const Words: TWords; const Separator: string): TWordGroups;
var Items: TList<TWords>; Start, Position: Integer;
begin
  Items := TList<TWords>.Create;
  try
    Start := 0;
    while Start < Length(Words) do
    begin
      Position := FindTop(Words, Separator, Start);
      if Position < 0 then Position := Length(Words);
      Items.Add(Slice(Words, Start, Position - Start));
      Start := Position + 1;
    end;
    Result := Items.ToArray;
  finally Items.Free; end;
end;

function Identifier(const Text: string): string;
const Reserved = '|alignas|alignof|asm|auto|bool|break|case|catch|char|class|concept|const|constexpr|continue|decltype|default|delete|do|double|else|enum|explicit|export|extern|false|float|for|friend|if|inline|int|long|namespace|' +
  'new|noexcept|nullptr|operator|private|protected|public|register|requires|return|short|signed|sizeof|static|struct|switch|template|this|thread_local|throw|true|try|typedef|typename|union|unsigned|using|virtual|void|volatile|wchar_t|while|';
begin
  Result := Text;
  if Result.StartsWith('&') then Delete(Result, 1, 1);
  if Result.StartsWith('pas2dox_') then Result := 'pas2dox_id_' + Result
  else if Pos('|' + Result + '|', Reserved) > 0 then Result := 'pas2dox_kw_' + Result;
end;

function StripAttributes(const Words: TWords): TWords;
var I, Depth: Integer; Items: TList<string>;
begin
  Items := TList<string>.Create;
  try
    Depth := 0;
    for I := 0 to High(Words) do
    begin
      if Words[I] = '[' then Inc(Depth);
      if Depth = 0 then Items.Add(Words[I]);
      if Words[I] = ']' then Dec(Depth);
    end;
    Result := Items.ToArray;
  finally Items.Free; end;
end;

function CppType(const Words: TWords): string;
var W: TWords; I, P: Integer; Word, Lower: string;
begin
  W := Words;
  while (Length(W) > 0) and SameText(W[0], 'packed') do W := Slice(W, 1);
  if Length(W) = 0 then Exit('DelphiUntyped');
  if W[0] = '^' then Exit(CppType(Slice(W, 1)) + '*');
  if SameText(W[0], 'array') then
  begin
    P := FindTop(W, 'of');
    if P < 0 then raise Exception.Create('Array declaration has no element type');
    Result := 'DelphiArray<' + CppType(Slice(W, P + 1)) + '>';
    Exit;
  end;
  if SameText(W[0], 'set') and (Length(W) > 2) then
    Exit('DelphiSet<' + CppType(Slice(W, 2)) + '>');
  if SameText(W[0], 'file') then
  begin
    if Length(W) > 2 then Exit('DelphiFile<' + CppType(Slice(W, 2)) + '>');
    Exit('DelphiFile');
  end;
  if SameText(W[0], 'class') and (Length(W) > 2) and SameText(W[1], 'of') then
    Exit('DelphiClassRef<' + CppType(Slice(W, 2)) + '>');
  if SameText(W[0], 'reference') or SameText(W[0], 'procedure') or SameText(W[0], 'function') then
    Exit('DelphiCallback');
  if SameText(W[0], 'record') then Exit(InlineRecord(W));
  if W[0]='(' then Exit('enum { '+Join(Slice(W,1,Length(W)-2))+' }');
  if FindTop(W, '..') >= 0 then Exit('DelphiOrdinalRange');
  for Word in W do if Word.Contains('..') and not Word.StartsWith('''') then Exit('DelphiOrdinalRange');
  Result := '';
  for I := 0 to High(W) do
  begin
    Word := W[I]; Lower := LowerCase(Word);
    if Word = '.' then Word := '::'
    else if Word = '..' then Word := '::'
    else if SameText(Word, 'type') then Continue;
    Word:=Identifier(Word);
    if (Word = '[') and (I > 0) and SameText(W[I-1], 'string') then Break;
    if (Lower = 'deprecated') or (Lower = 'platform') or (Lower = 'experimental') or (Word = ';') then Break;
    if (Result <> '') and not CharInSet(Word[1], ['<','>',',',':',')',']'])
      and not CharInSet(Result[Length(Result)], ['<',':','(','[']) then Result := Result + ' ';
    Result := Result + Word;
  end;
  Result := Trim(Result);
end;

function CppTypeText(const Text: string): string;
begin Result := CppType(Lex(Text)); end;

function GenericHeader(const Words: TWords; out Name: string): string;
var Open, P: Integer; Group, Names, Part: TWords; All: TWordGroups;
begin
  if Length(Words)=0 then begin Name:=''; Exit(''); end;
  Name := Identifier(Words[0]); Result := '';
  Open := FindTop(Words, '<');
  if Open < 0 then Exit;
  All := Groups(Slice(Words, Open + 1, Length(Words) - Open - 2), ';');
  for Group in All do
  begin
    P := FindTop(Group, ':');
    if P < 0 then P := Length(Group);
    Names := Slice(Group, 0, P);
    for Part in Groups(Names, ',') do
      if Length(Part) > 0 then
      begin
        if Result <> '' then Result := Result + ', ';
        Result := Result + 'class ' + Identifier(Part[0]);
      end;
  end;
  Result := 'template<' + Result + '> ';
end;

function Expression(const Words: TWords): string;
var W: TWords; I: Integer;
begin
  W := Copy(Words);
  for I := 0 to High(W) do
  begin
    if SameText(W[I], 'nil') then W[I] := 'nullptr'
    else if W[I].StartsWith('$') then W[I] := '0x'+Copy(W[I],2,MaxInt)
    else if W[I].StartsWith('''') then
      W[I] := '"' + Copy(W[I],2,Length(W[I])-2).Replace('''''','''').Replace('"','\"').Replace(#13,'').Replace(#10,'\n') + '"';
  end;
  Result := Join(W);
end;

function Parameters(const Words: TWords): string;
var RawGroup, Group, Names, NameWords, TypeWords: TWords; P, Equal: Integer; Prefix, TypeName, Suffix, Default: string; ByReference: Boolean;
begin
  Result := '';
  for RawGroup in Groups(Words, ';') do
  begin
    Group := StripAttributes(RawGroup);
    Prefix := ''; Suffix := ''; Default := '';
    ByReference:=Join(RawGroup).ToLower.Contains('[ref]');
    if Length(Group) = 0 then Continue;
    if SameText(Group[0], 'const') then begin Prefix := 'const '; if ByReference then Suffix:='&'; Group := Slice(Group,1); end
    else if SameText(Group[0], 'var') or SameText(Group[0], 'out') then
    begin Suffix := '&'; Group := Slice(Group,1); end;
    P := FindTop(Group, ':');
    if P < 0 then begin Names:=Group; TypeName:='DelphiUntyped'; end
    else
    begin
      Names := Slice(Group,0,P); TypeWords := Slice(Group,P+1);
      Equal := FindTop(TypeWords,'=');
      if Equal >= 0 then
      begin Default := ' = ' + Expression(Slice(TypeWords,Equal+1)); TypeWords := Slice(TypeWords,0,Equal); end;
      TypeName := CppType(TypeWords);
    end;
    for NameWords in Groups(Names, ',') do
      if Length(NameWords) > 0 then
      begin
        if Result <> '' then Result := Result + ', ';
        Result := Result + Prefix + TypeName + Suffix + ' ' + Identifier(NameWords[0]) + Default;
      end;
  end;
end;

function ParameterNames(const Words: TWords): TWords;
var Open, Close, Depth, P: Integer; Group, W, Names: TWords; Parts: TList<string>;
begin
  Parts:=TList<string>.Create;
  try
    Open:=FindTop(Words,'(');
    if Open<0 then Open:=FindTop(Words,'[');
    if Open<0 then Exit(nil);
    Close:=Open+1; Depth:=1;
    while (Close<Length(Words)) and (Depth>0) do
    begin
      if Words[Close]=Words[Open] then Inc(Depth);
      if ((Words[Open]='(') and (Words[Close]=')')) or ((Words[Open]='[') and (Words[Close]=']')) then Dec(Depth);
      if Depth>0 then Inc(Close);
    end;
    for Group in Groups(Slice(Words,Open+1,Close-Open-1),';') do
    begin
      W:=StripAttributes(Group);
      if (Length(W)>0) and MatchText(W[0],['const','var','out']) then W:=Slice(W,1);
      P:=FindTop(W,':'); if P<0 then P:=Length(W);
      for Names in Groups(Slice(W,0,P),',') do
        if Length(Names)>0 then Parts.Add(Identifier(Names[0]));
    end;
    Result:=Parts.ToArray;
  finally Parts.Free; end;
end;

function Routine(const Words: TWords; const Name, Container: string): string;
var W, NameWords, Params, ReturnWords: TWords; Start, Open, Close, Depth, I, P: Integer;
  IsClass: Boolean; Kind, ResultType, MethodName, Header: string;
begin
  W := Words; IsClass := False; Start := 0;
  if SameText(W[0], 'class') then begin IsClass := True; Inc(Start); end;
  Kind := LowerCase(W[Start]); Inc(Start);
  Open := FindTop(W, '(', Start);
  P := FindTop(W, ';', Start); if P < 0 then P := Length(W);
  if (Open >= 0) and (Open < P) then
  begin
    NameWords := Slice(W,Start,Open-Start); Depth:=1; Close:=Open+1;
    while (Close < Length(W)) and (Depth > 0) do
    begin
      if W[Close]='(' then Inc(Depth); if W[Close]=')' then Dec(Depth);
      if Depth>0 then Inc(Close);
    end;
    if Depth<>0 then raise Exception.Create('Unclosed routine parameter list');
    Params := Slice(W,Open+1,Close-Open-1); Start:=Close+1;
  end else
  begin
    I:=FindTop(W, ':', Start); if (I<0) or (I>P) then I:=P;
    NameWords:=Slice(W,Start,I-Start); Start:=I; Params:=nil;
  end;
  ResultType:='void';
  if (Start<Length(W)) and (W[Start]=':') then
  begin
    P:=FindTop(W,';',Start); if P<0 then P:=Length(W);
    ReturnWords:=Slice(W,Start+1,P-Start-1); ResultType:=CppType(ReturnWords);
  end;
  MethodName := Identifier(Name);
  Header := GenericHeader(NameWords, MethodName);
  if ((Kind='constructor') or (Kind='destructor')) and IsClass then MethodName := 'DelphiClass_' + Name;
  Result := Header;
  if IsClass then Result:=Result+'static ';
  Result:=Result+ResultType+' ';
  Result := Result + MethodName + '(' + Parameters(Params) + ')';
  Result := Result + ';';
end;

function VariableDecl(const Words: TWords; const Name: string; IsConstant: Boolean): string;
var P, Equal: Integer; W, TypeWords: TWords; Prefix, TypeName: string;
begin
  W:=Words; Prefix:='';
  if (Length(W)>0) and SameText(W[0],'class') then begin Prefix:='static '; W:=Slice(W,1); end;
  if (Length(W)>0) and SameText(W[0],'var') then W:=Slice(W,1);
  P:=FindTop(W,':'); Equal:=FindTop(W,'=');
  if P>=0 then
  begin
    if Equal<0 then Equal:=FindTop(W,';');
    if Equal<0 then Equal:=Length(W);
    TypeWords:=Slice(W,P+1,Equal-P-1);
    TypeName:=CppType(TypeWords);
  end else TypeName:='auto';
  if IsConstant then Prefix:=Prefix+'const ';
  Result:=Prefix+TypeName+' '+Identifier(Name);
  // Initializers are retained in the original declaration documentation.
  // Pascal record/set/array constants must not be mistaken for C++ expressions.
  Result:=Result+';';
end;

function AliasDecl(const Words: TWords; const Name: string): string;
var P, K, Open, Close, Depth, I: Integer; Header, AliasName, ReturnType: string; Left, Right, Args: TWords;
begin
  P:=FindTop(Words,'=');
  if P<0 then raise Exception.Create('Missing type alias assignment');
  Left:=Slice(Words,0,P); Right:=Slice(Words,P+1);
  Header:=GenericHeader(Left,AliasName);
  K:=0;
  if (Length(Right)>0) and SameText(Right[0],'reference') then K:=2;
  if (K<Length(Right)) and MatchText(Right[K],['procedure','function']) then
  begin
    ReturnType:='void'; Args:=nil;
    Open:=FindTop(Right,'(',K+1); Close:=K;
    if Open>=0 then
    begin
      Close:=Open+1; Depth:=1;
      while (Close<Length(Right)) and (Depth>0) do
      begin
        if Right[Close]='(' then Inc(Depth); if Right[Close]=')' then Dec(Depth);
        if Depth>0 then Inc(Close);
      end;
      if Depth<>0 then raise Exception.Create('Unclosed callback parameters');
      Args:=Slice(Right,Open+1,Close-Open-1);
    end;
    I:=FindTop(Right,':',Close+1);
    if I>=0 then ReturnType:=CppType(Slice(Right,I+1));
    Exit(Header+'using '+AliasName+' = '+ReturnType+' (*)('+Parameters(Args)+');');
  end;
  if Header<>'' then Result:=Header+'using '+AliasName+' = '+CppType(Right)+';'
  else Result:='typedef '+CppType(Right)+' '+Identifier(Name)+';';
end;

end.
