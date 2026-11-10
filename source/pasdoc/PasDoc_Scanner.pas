{ Pas2Dox modification 2026-11-10. See ORIGIN.md. }
{
  Copyright 1998-2026 PasDoc developers.

  This file is part of "PasDoc".

  "PasDoc" is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  "PasDoc" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with "PasDoc"; if not, write to the Free Software
  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA

  ----------------------------------------------------------------------------
}

{ @abstract(Scanner for Pascal, producing tokens and interpreting conditionals.)

  @author(Johannes Berg <johannes@sipsolutions.de>)
  @author(Ralf Junker (delphi@zeitungsjunge.de))
  @author(Marco Schmidt (marcoschmidt@geocities.com))
  @author(Michalis Kamburelis)
  @author(Arno Garrels <first name.name@nospamgmx.de>) }
unit PasDoc_Scanner;

{$I pasdoc_defines.inc}

interface

uses
  SysUtils,
  Classes, Contnrs, Types,
  PasDoc_Types,
  PasDoc_Tokenizer,
  PasDoc_StringVector,
  PasDoc_StreamUtils,
  PasDoc_StringPairVector;

const
  { maximum number of streams we can recurse into; first one is the unit
    stream, any other stream an include file; current value is 32, increase
    this if you have more include files recursively including others }
  MAX_TOKENIZERS = 32;

type
  { subrange type that has the 26 lower case letters from a to z }
  TUpperCaseLetter = 'A'..'Z';
  { an array of boolean values, index type is @link(TUpperCaseLetter) }
  TSwitchOptions = array[TUpperCaseLetter] of Boolean;

  ETokenizerStreamEnd = class(EPasDoc);
  EInvalidIfCondition = class(EPasDoc);

  { All directives a scanner is going to regard. }
  TDirectiveType = (DT_UNKNOWN, DT_DEFINE, DT_ELSE, DT_ENDIF, DT_IFDEF,
    DT_IFNDEF, DT_IFOPT, DT_INCLUDE_FILE, DT_UNDEF, DT_INCLUDE_FILE_2,
    DT_IF, DT_ELSEIF, DT_IFEND);

  { Scanner for Pascal, producing tokens and interpreting conditionals

    Returns tokens from a Pascal language source code input stream.
    Uses the @link(PasDoc_Tokenizer) unit to get tokens,
    processes directives that might lead to

    @unorderedList(
      @item(including other files)
      @item(define / undefine symbols)
      @item(processes conditional directives)
      @item(handles FPC macros (when HandleMacros is true).)
    )

    Effectively this is a combined tokenizer and pre-processor.

    Single TScanner instance scans one unit using one or more @link(TTokenizer)
    instances (to scan the unit and all nested include files). }
  TConsumedTokenEvent = procedure(Token: TToken) of object;
  TScanner = class(TObject)
  private
    FCurrentTokenizer: Integer;
    FRootLines: array[0..MAX_TOKENIZERS-1] of Integer;
    FNextRootLine: Integer;
    FEvaluationDepth: Integer;
    FDirectiveLevel: Integer;
    FTokenizers: array[0..MAX_TOKENIZERS - 1] of TTokenizer;
    FSwitchOptions: TSwitchOptions;
    FBufferedTokens: TTokenList;
    FOnConsumedToken: TConsumedTokenEvent;

    { For each symbol:
        Name is the unique Name,
        Value is the string to be expanded into (in case of a macro),
        Data is SymbolIsMacro or SymbolIsNotMacro to say if this is a macro
          (i.e. should it be expanded).

      Note the important fact: we can't use Value <> '' to decide
      if symbol is a macro. A non-macro symbol is something
      different than a macro that expands to nothing. }
    FSymbols: TStringPairVector;
    FDeclarations: TStringList;
    FConstants: TStringPairVector;
    FLongOptions: TStringList;
    FOptionStack: TObjectList;

    FIncludeFilePaths: TStringVector;
    FOnMessage: TPasDocMessageEvent;
    FVerbosity: Cardinal;
    FHandleMacros: boolean;

    { Removes symbol Name from the internal list of symbols.
      If Name was not in that list, nothing is done. }
    procedure DeleteSymbol(const Name: string);

    { Returns if a given symbol Name is defined at the moment. }
    function IsSymbolDefined(const Name: string): Boolean;

    function IsSwitchDefined(n: string): Boolean;

    { This creates and adds new Tokenizer to FTokenizers list and makes
      it the current tokenizer. It also checks MAX_TOKENIZERS limit.
      After calling this procedure, don't free Stream -- it will be
      owned by created Tokenizer, and created Tokenizer will be managed
      as part of FTokenizers list. }
    procedure OpenNewTokenizer(Stream: TStream;
      const StreamName, StreamAbsoluteFileName: string);

    procedure OpenIncludeFile(n: string);

    { Skip (discard all the tokens) until $else, $elseif, $endif, $ifend is found.
      Returns the directive that stopped the scanning,
      it is always one of [DT_ELSE, DT_ELSEIF, DT_ENDIF, DT_IFEND].

      It consumes all the tokens from FTokenizers[FCurrentTokenizer],
      including the final one ($ifend and so on).
      If final token is $elseif and you used overloaded version with ElseifToken,
      then the final token is returned.

      Note that for pasdoc, $endif and $ifend directives are always exactly
      equivalent and interchangeable. For Delphi, it used to be that
      $if / $elseif had to be terminated with $ifend
      (to be able to nest $if...$ifend within $ifdef...$endif
      on older Delphi versions that don't support $if,
      see Borland Delphi docs about this).
      For FPC, $endif is valid terminator for $if. }
    function SkipUntilElseOrEndif(out ElseifToken: TToken): TDirectiveType; overload;
    function SkipUntilElseOrEndif: TDirectiveType; overload;

    { Skip until $endif, $ifend.
      Consumes all the tokens from FTokenizers[FCurrentTokenizer]
      including the final one. }
    procedure SkipUntilEndif;

    procedure ResolveSwitchDirectives(const Comment: String);

    procedure SetIncludeFilePaths(Value: TStringVector);

    { Calculate boolean condition, like the one allowed at $if and $elseif. }
    function IfCondition(const Condition: String): Boolean;
    function EvaluateExpression(const Condition: String): Variant;
  protected
    procedure DoError(const AMessage: string;
      const AArguments: array of const);
    procedure DoMessage(const AVerbosity: Cardinal; const MessageType:
      TPasDocMessageType; const AMessage: string; const AArguments: array of const);
  public
    { Creates a TScanner object that scans the given input stream.

      Note that the stream S will be freed by this object
      (at destruction or when we will read all it's tokens),
      so after creating TScanner you should leave the stream
      to be managed completely by this TScanner. }
    constructor Create(
      const s: TStream;
      const OnMessageEvent: TPasDocMessageEvent;
      const VerbosityLevel: Cardinal;
      const AStreamName, AStreamAbsoluteFileName: string;
      const AHandleMacros: boolean);
    destructor Destroy; override;

    { Adds Name to the list of symbols (as a normal symbol, not macro). }
    procedure AddSymbol(const Name: string);

    { Adds all symbols in the NewSymbols collection by calling
      @link(AddSymbol) for each of the strings in that collection. }
    procedure AddSymbols(const NewSymbols: TStringVector);

    { Adds Name as a symbol that is a macro, that expands to Value. }
    procedure AddMacro(const Name, Value: string);
    function OptionIs(const Name, Value: string): Boolean;
    procedure DeclareIdentifier(const Name: string; const Value: string = '');

    { Gets next token and throws it away. }
    procedure ConsumeToken;

    { Returns next token.
      Always non-nil (will raise exception in case of any problem). }
    function GetToken: TToken;

    { Returns the name of the file that is currently processed and the line
      number. Good for meaningful error messages. }
    function GetStreamInfo: string;

    { Paths to search for include files.
      When you assign something to this property
      it causes Assign(Value) call, not a real reference copy. }
    property IncludeFilePaths: TStringVector read FIncludeFilePaths
      write SetIncludeFilePaths;

    { Look at next token, but don't advance to the next token.
      Do not free the returned TToken instance, @italic(unless you
      call ConsumeToken), in which case you should free this. }
    function PeekToken: TToken;

    { Place T in the buffer. Next time you will call GetToken you will
      get T. This also sets T to nil (because you shouldn't free T
      anymore after ungetting it). Note that the buffer has room only
      for 1 token, so you have to make sure that you will never unget
      more than two tokens. Practically, always call UnGetToken right
      after some GetToken. }
    procedure UnGetToken(var t: TToken);

    property OnMessage: TPasDocMessageEvent read FOnMessage write FOnMessage;
    property OnConsumedToken: TConsumedTokenEvent read FOnConsumedToken write FOnConsumedToken;
    property Verbosity: Cardinal read FVerbosity write FVerbosity;
    property SwitchOptions: TSwitchOptions read FSwitchOptions;

    property HandleMacros: boolean read FHandleMacros;
  end;

implementation

uses PasDoc_Utils, Variants;

const
  DirectiveNames: array[DT_DEFINE..High(TDirectiveType)] of string =
  ( 'DEFINE', 'ELSE', 'ENDIF', 'IFDEF', 'IFNDEF', 'IFOPT', 'I', 'UNDEF',
    'INCLUDE', 'IF', 'ELSEIF', 'IFEND' );

  SymbolIsNotMacro = nil;
  SymbolIsMacro = Pointer(1);

{ ---------------------------------------------------------------------------- }

(*Assumes that CommentContent is taken from a Token.CommentContent where
  Token.MyType was TOK_DIRECTIVE.

  Extracts DirectiveName and DirectiveParam from CommentContent.
  DirectiveName is the thing right after $ sign, uppercased.
  DirectiveParam (in two versions: Black and White) is what followed
  after DirectiveName.

  E.g. for CommentContent = {$define My_Symbol} we get
  DirectiveName = 'DEFINE' and
  DirectiveParamBlack = 'My_Symbol'
  (and DirectiveParamWhite also = 'My_Symbol').

  We get two versions of DirectiveParam:
  @orderedList(
    @item(DirectiveParamBlack is what followed DirectiveName and
      ended at the 1st whitespace. So DirectiveParamBlack
      never contains any white char.)

    @item(DirectiveParamWhite is what followed DirectiveName and
      ended at end of CommentContent. So DirectiveParamWhite
      may contain white characters.)
  )

  So DirectiveParamBlack is always a prefix of DirectiveParamWhite.

  Some directives use DirectiveParamBlack and some use
  DirectiveParamWhite, that's why we return both.
  E.g. {$ifdef foo bar xyz} is equivalent to {$ifdef foo}
  (bar and xyz are simply ignored by Pascal compilers).
  When using FPC and macro is off, or when using other compilers,
  {$define foo := bar xyz} means just {$define foo}.
  So you use DirectiveParamBlack.
  However when using FPC and macro is on,
  then {$define foo := bar xyz} means "define foo as a macro
  that expands to ``bar xyz'', so in this case you will need to use
  DirectiveParamWhite.
*)
function SplitDirective(const CommentContent: string;
  out DirectiveName, DirectiveParamBlack, DirectiveParamWhite: string): Boolean;
var
  i: Integer;
  l: Integer;
begin
  Result := False;
  DirectiveName := '';
  DirectiveParamBlack := '';
  DirectiveParamWhite := '';

  l := Length(CommentContent);

  { skip dollar sign from CommentContent }
  i := 2;
  if i > l then Exit;

  { get directive name }
  while (i <= l) and (CommentContent[i] <> ' ') do
  begin
    DirectiveName := DirectiveName + UpCase(CommentContent[i]);
    Inc(i);
  end;
  Result := True;

  { skip spaces }
  while (i <= l) and (CommentContent[i] = ' ') do
    Inc(i);
  if i > l then Exit;

  { get parameters - no conversion to uppercase here, it could be an include
    file name whose name need not be changed (platform.inc <> PLATFORM.INC) }
  while (i <= l) and (CommentContent[i] <> ' ') do
  begin
    DirectiveParamBlack := DirectiveParamBlack + CommentContent[i];
    Inc(i);
  end;

  DirectiveParamWhite := DirectiveParamBlack;
  while (i <= l) do
  begin
    DirectiveParamWhite := DirectiveParamWhite + CommentContent[i];
    Inc(i);
  end;
end;

{ First, splits CommentContent like SplitDirective.

  Then returns true and sets Dt to appropriate directive type,
  if DirectiveName was something known (see array DirectiveNames).
  Else returns false. }
function IdentifyDirective(const CommentContent: string;
  out dt: TDirectiveType;
  out DirectiveName, DirectiveParamBlack, DirectiveParamWhite: string): Boolean;
var
  i: TDirectiveType;
begin
  Result := false;
  if SplitDirective(CommentContent,
    DirectiveName, DirectiveParamBlack, DirectiveParamWhite) then
  begin
    for i := DT_DEFINE to High(TDirectiveType) do
    begin
      if UpperCase(DirectiveName) = DirectiveNames[i] then
      begin
        dt := i;
        Result := True;
        break;
      end;
    end;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ TScanner }
{ ---------------------------------------------------------------------------- }

constructor TScanner.Create(
  const s: TStream;
  const OnMessageEvent: TPasDocMessageEvent;
  const VerbosityLevel: Cardinal;
  const AStreamName, AStreamAbsoluteFileName: string;
  const AHandleMacros: boolean);
var
  c: TUpperCaseLetter;
begin
  inherited Create;
  FOnMessage := OnMessageEvent;
  FVerbosity := VerbosityLevel;
  FHandleMacros := AHandleMacros;

  { Set default switch directives (according to the Delphi 4 Help). }
  for c := Low(SwitchOptions) to High(SwitchOptions) do
    FSwitchOptions[c] := False;
  FSwitchOptions['A'] := True;
  FSwitchOptions['C'] := True;
  FSwitchOptions['D'] := True;
  FSwitchOptions['G'] := True;
  FSwitchOptions['H'] := True;
  FSwitchOptions['I'] := True;
  FSwitchOptions['J'] := True;
  FSwitchOptions['L'] := True;
  FSwitchOptions['P'] := True;
  FSwitchOptions['O'] := True;
  FSwitchOptions['V'] := True;
  FSwitchOptions['X'] := True;

  FSymbols := TStringPairVector.Create(true);
  FDeclarations := TStringList.Create;
  FConstants := TStringPairVector.Create(True);
  FLongOptions:=TStringList.Create;
  FLongOptions.Values['SCOPEDENUMS']:='OFF';
  FLongOptions.Values['INLINE']:='ON';
  FLongOptions.Values['TEXTBLOCK']:='NATIVE';
  FOptionStack:=TObjectList.Create(True);
  FDeclarations.CaseSensitive := False;

  FTokenizers[0] := TTokenizer.Create(s, OnMessageEvent, VerbosityLevel,
    AStreamName, AStreamAbsoluteFileName);
  FCurrentTokenizer := 0;
  FBufferedTokens := TTokenList.Create(true);

  FIncludeFilePaths := TStringVector.Create;
end;

{ ---------------------------------------------------------------------------- }

destructor TScanner.Destroy;
var
  i: Integer;
begin
  FSymbols.Free;
  FDeclarations.Free;
  FConstants.Free;
  FLongOptions.Free;
  FOptionStack.Free;

  for i := 0 to FCurrentTokenizer do begin
    FTokenizers[i].Free;
  end;

  FBufferedTokens.Free;

  FIncludeFilePaths.Free;

  inherited;
end;

{ ---------------------------------------------------------------------------- }

procedure TScanner.SetIncludeFilePaths(Value: TStringVector);
begin
  FIncludeFilePaths.Assign(Value);
end;

{ ---------------------------------------------------------------------------- }

procedure TScanner.AddSymbol(const Name: string);
begin
  if not IsSymbolDefined(Name) then
  begin
    DoMessage(6, pmtInformation, 'Symbol "%s" defined', [Name]);
    FSymbols.Add(TStringPair.Create(Name, '', SymbolIsNotMacro));
  end;
end;

{ ---------------------------------------------------------------------------- }

procedure TScanner.AddSymbols(const NewSymbols: TStringVector);
var
  i: Integer;
begin
  if NewSymbols <> nil then
    for i := 0 to NewSymbols.Count - 1 do
    begin
      if Pos('=', NewSymbols[i]) > 0 then
        AddMacro(Copy(NewSymbols[i], 1, Pos('=', NewSymbols[i])-1),
          Copy(NewSymbols[i], Pos('=', NewSymbols[i])+1, MaxInt))
      else AddSymbol(NewSymbols[i]);
    end
end;

{ ---------------------------------------------------------------------------- }

procedure TScanner.AddMacro(const Name, Value: string);
var
  i: Integer;
begin
  if SameText(Copy(Name,1,Length('PAS2DOX_OPTION_')),'PAS2DOX_OPTION_') then
    FLongOptions.Values[UpperCase(Copy(Name,Length('PAS2DOX_OPTION_')+1,MaxInt))]:=UpperCase(Value);
  i := FSymbols.FindName(Name);
  if i = -1 then
  begin
    DoMessage(6, pmtInformation, 'Macro "%s" defined as "%s"', [Name, Value]);
    FSymbols.Add(TStringPair.Create(Name, Value, SymbolIsMacro));
  end else
  begin
    DoMessage(6, pmtInformation, 'Macro "%s" RE-defined as "%s"', [Name, Value]);
    { Redefine macro in this case. }
    FSymbols.Items[i].Value := Value;
  end;
end;

{ ---------------------------------------------------------------------------- }

function TScanner.OptionIs(const Name, Value: string): Boolean;
begin Result:=IsSwitchDefined(Name+' '+Value); end;

procedure TScanner.DeclareIdentifier(const Name, Value: string);
begin
  if FDeclarations.IndexOf(Name)<0 then FDeclarations.Add(Name);
  if (Value<>'') and (FConstants.FindName(Name)<0) then FConstants.Add(TStringPair.Create(Name,Value,nil));
end;

procedure TScanner.ConsumeToken;
var
  LastToken: TToken;
begin
  if FBufferedTokens.Count > 0 then
  Begin
    LastToken := FBufferedTokens.Last;
    if Assigned(FOnConsumedToken) then FOnConsumedToken(LastToken);
    FBufferedTokens.Extract(LastToken);
  end;
end;

{ ---------------------------------------------------------------------------- }

procedure TScanner.DeleteSymbol(const Name: string);
begin
  FSymbols.DeleteName(Name);
end;

{ ---------------------------------------------------------------------------- }

function TScanner.GetStreamInfo: string;
begin
  if (FCurrentTokenizer >= 0) then begin
    Result := FTokenizers[FCurrentTokenizer].GetStreamInfo
  end else begin
    Result := '';
  end;
end;

{ ---------------------------------------------------------------------------- }

function TScanner.GetToken: TToken;

  { Call this when you get $define directive }
  procedure HandleDefineDirective(
    const DirectiveParamBlack, DirectiveParamWhite: string);
  var
    i: Integer;
    SymbolName: string;
  begin
    if not HandleMacros then
      AddSymbol(DirectiveParamBlack) else
    begin
      i := 1;
      while SCharIs(DirectiveParamWhite, i, ['a'..'z', 'A'..'Z', '1'..'9', '_']) do
        Inc(i);

      SymbolName := Copy(DirectiveParamWhite, 1, i - 1);

      while SCharIs(DirectiveParamWhite, i, WhiteSpace) do
        Inc(i);

      if Copy(DirectiveParamWhite, i, 2) = ':=' then
        AddMacro(SymbolName, Copy(DirectiveParamWhite, i + 2, MaxInt)) else
        AddSymbol(SymbolName);
    end;
  end;

  { If T is an identifier that expands to a macro, then it handles it
    (i.e. opens a new tokenizer that expands a macro) and returns true.
    Else returns false. }
  function ExpandMacro(T: TToken): boolean;
  var
    SymbolIndex: Integer;
  begin
    Result := HandleMacros and (T.MyType = TOK_IDENTIFIER);
    if Result then
    begin
      SymbolIndex := FSymbols.FindName(T.Data);
      Result := (SymbolIndex <> -1) and
         (FSymbols[SymbolIndex].Data = SymbolIsMacro);
      if Result then
        OpenNewTokenizer(TStringStream.Create(
          FSymbols[SymbolIndex].Value),
          '<' + FSymbols[SymbolIndex].Name + ' macro>',
          { Expanded macro text inherits current StreamAbsoluteFileName }
          FTokenizers[FCurrentTokenizer].StreamAbsoluteFileName);
    end;
  end;

  { Call this on $ifdef, $ifndef, $ifopt, $if directives.
    This "consumes" all the tokens up to the "active" (with satisfied
    condition) block of $ifdef / $if / $else / $elseif sequence.
    So the outside code can just pass-through the remaining tokens,
    and ignore everything after any $else or $elseif,
    up to the matching $endif / $ifend.

    @param(IsTrue says if condition is true.))
    @param(DirectiveName is used for debug messages.)
    @param(DirectiveParam is also used for debug messages.) }
  procedure HandleIfDirective(IsTrue: boolean;
    const DirectiveName, DirectiveParam: string);

    function ExtractElseifCondition(const ElseifToken: TToken): String;
    var
      DT: TDirectiveType;
      DirectiveName, DirectiveParamBlack, DirectiveParamWhite: String;
    begin
      Assert(ElseifToken.MyType = TOK_DIRECTIVE);
      if not IdentifyDirective(ElseifToken.CommentContent, DT,
        DirectiveName, DirectiveParamBlack, DirectiveParamWhite) then
        DoError('IdentifyDirective returned false, but we know it should be $elseif', []);
      Assert(DT = DT_ELSEIF);
      Result := DirectiveParamWhite;
    end;

  var
    ElseifToken: TToken;
    EndingDirective: TDirectiveType;
    ElseifCondition: String;
  begin
    DoMessage(6, pmtInformation,
      '$%s encountered (%s), condition is %s, level %d',
      [DirectiveName, DirectiveParam, BoolToStr(IsTrue, True), FDirectiveLevel]);
    if IsTrue then
    begin
      Inc(FDirectiveLevel);
    end else
    begin
      { The implementation outside assumes that HandleIfDirective
        always "consumes" all the tokens up to the "active" (with satisfied
        condition) block of $ifdef / $if / $else / $elseif sequence.
        This way the implementation outside can just pass through all tokens,
        and "skip until endif" when it sees $else / $elseif.

        This gets complicated in case of $elseif: we must now find the first
        $elseif that has satisfied condition, and then break. }

      repeat
        EndingDirective := SkipUntilElseOrEndif(ElseifToken);
        case EndingDirective of
          DT_ELSE:
            begin
              Inc(FDirectiveLevel);
              Break;
            end;
          DT_ELSEIF:
            begin
              ElseifCondition := ExtractElseifCondition(ElseifToken);
              if IfCondition(ElseifCondition) then
              begin
                Inc(FDirectiveLevel);
                Break;
              end; // otherwise do nothing, let the loop continue
            end;
          else
            { Then it ended with endif / ifend, in which case we just exit
              the loop without touching the FDirectiveLevel. }
            Break;
        end;
        FreeAndNil(ElseifToken);
      until false;
      FreeAndNil(ElseifToken);
    end;
  end;

var
  dt: TDirectiveType;
  Finished: Boolean;
  DirectiveName, DirectiveParamBlack, DirectiveParamWhite: string;
begin
  if FBufferedTokens.Count > 0 then
  begin
    { we have a token buffered, we'll return this one }
    Result := FBufferedTokens.Last;
    FBufferedTokens.Extract(Result);
    Exit;
  end;

  Finished := False;
  repeat
    { check if we have a tokenizer left }
    if (FCurrentTokenizer = -1) then
      raise ETokenizerStreamEnd.Create('Unexpected end of stream', [], 1);

    if FTokenizers[FCurrentTokenizer].HasData then
    begin
      { get next token from tokenizer }
      Result := FTokenizers[FCurrentTokenizer].GetToken;
      if FCurrentTokenizer=0 then Result.RootLine:=Result.Line
      else Result.RootLine:=FRootLines[FCurrentTokenizer];
      try
        { if token is a directive, then we handle it }
        if Result.MyType = TOK_DIRECTIVE then
        begin
          if IdentifyDirective(Result.CommentContent, dt,
            DirectiveName, DirectiveParamBlack, DirectiveParamWhite) then
          begin
            case dt of
              DT_DEFINE:
                HandleDefineDirective(DirectiveParamBlack, DirectiveParamWhite);
              DT_ELSE:
                begin
                  DoMessage(5, pmtInformation, '$ELSE encountered', []);

                  { We encountered $else that should not be entered further
                    (after $ifdef / $if or such with a satisfied condition).

                    Note: An $else that should be entered is always consumed
                    inside HandleIfDirective when the $ifxxx is false.

                    So the only thing we can do is to skip to $endif now. }
                  if FDirectiveLevel <= 0 then
                    DoError(GetStreamInfo + ': unexpected $ELSE directive, without $IFDEF / $IF beginning', [])
                  else
                  if SkipUntilElseOrEndif in [DT_ELSE, DT_ELSEIF] then
                    DoError(GetStreamInfo + ': unexpected $ELSE / $ELSEIF directive, expected $ENDIF / $IFEND now', [])
                  else
                    Dec(FDirectiveLevel);
                end;
              DT_ELSEIF:
                begin
                  DoMessage(5, pmtInformation, '$ELSEIF encountered', []);

                  { We encountered $elseif that should not be entered further
                    (after $ifdef / $if or even previous $elseif
                    with a satisfied condition).
                    So we skip to $endif now. }

                  if FDirectiveLevel <= 0 then
                    DoError(GetStreamInfo + ': unexpected $ELSEIF directive, without $IFDEF / $IF beginning', [])
                  else
                  begin
                    SkipUntilEndif;
                    Dec(FDirectiveLevel);
                  end;
                end;
              DT_ENDIF, DT_IFEND:
                begin
                  DoMessage(5, pmtInformation, '$%s encountered', [DirectiveName]);
                  if (FDirectiveLevel > 0) then
                  begin
                    Dec(FDirectiveLevel);
                    DoMessage(6, pmtInformation, 'FDirectiveLevel = ' + IntToStr(FDirectiveLevel), []);
                  end else
                    DoError(GetStreamInfo + ': unexpected $%s directive', [DirectiveName]);
                end;
              DT_IFDEF: HandleIfDirective(IsSymbolDefined(DirectiveParamBlack),
                'IFDEF', DirectiveParamBlack);
              DT_IFNDEF: HandleIfDirective(not IsSymbolDefined(DirectiveParamBlack),
                'IFNDEF', DirectiveParamBlack);
              DT_IFOPT: HandleIfDirective(IsSwitchDefined(DirectiveParamWhite),
                'IFOPT', DirectiveParamBlack);
              DT_IF: HandleIfDirective(IfCondition(DirectiveParamWhite),
                'IF', DirectiveParamWhite);
              DT_INCLUDE_FILE, DT_INCLUDE_FILE_2:
                begin
                  if (Length(DirectiveParamBlack) >= 2) and
                     (DirectiveParamBlack[1] = '%') and
                     (DirectiveParamBlack[Length(DirectiveParamBlack)] = '%') then
                  begin
                    (* Then this is FPC's feature, see
                      "$I or $INCLUDE : Include compiler info" on
                      @url(http://www.freepascal.org/docs-html/prog/progsu30.html FPC $I compiler info documentation).

                      Unlike FPC, PasDoc will not expand the %variable%
                      (for reasoning, see comments in
                      ../../tests/ok_include_environment.pas file).
                      We change Result to say that it's a string literal
                      (but we leave Result.Data as it is, to show exact
                      info to the user). We do *not* want to enclose it in
                      quotes, because then real string literal '{$I %DATE%}'
                      wouldn't be different than using {$I %DATE%} feature. *)

                    Result.MyType := TOK_STRING;
                    Break;
                  end else
                  begin
                    FNextRootLine:=Result.RootLine;
                    OpenIncludeFile(DirectiveParamBlack);
                  end;
                end;
              DT_UNDEF:
                begin
                  DoMessage(6, pmtInformation, 'UNDEF encountered (%s)', [DirectiveParamBlack]);
                  DeleteSymbol(DirectiveParamBlack);
                end;
            end;
          end else
          begin
            ResolveSwitchDirectives(Result.Data);
          end;

          FreeAndNil(Result);
        end else
        if ExpandMacro(Result) then
        begin
          FreeAndNil(Result);
        end else
        begin
          { If the token is not a directive, and not an identifier that expands
            to a macro, then we just return it. }
          Finished := True;
        end;

      except
        FreeAndNil(Result);
        raise;
      end;

    end else
    begin
      DoMessage(5, pmtInformation, 'Closing file "%s"',
        [FTokenizers[FCurrentTokenizer].GetStreamInfo]);
      FTokenizers[FCurrentTokenizer].Free;
      FTokenizers[FCurrentTokenizer] := nil;
      Dec(FCurrentTokenizer);
    end;
  until Finished;
end;

{ ---------------------------------------------------------------------------- }

function TScanner.IsSymbolDefined(const Name: string): Boolean;
begin
  Result := FSymbols.FindName(Name) <> -1;
end;

{ ---------------------------------------------------------------------------- }

function SwitchLongName(const Letter: Char): string;
begin
  case Letter of
    'A': Result:='ALIGN'; 'B': Result:='BOOLEVAL'; 'C': Result:='ASSERTIONS';
    'D': Result:='DEBUGINFO'; 'E': Result:='OLDOBJWARN'; 'G': Result:='IMPORTEDDATA';
    'H': Result:='LONGSTRINGS'; 'I': Result:='IOCHECKS'; 'J': Result:='WRITEABLECONST';
    'L': Result:='LOCALSYMBOLS'; 'M': Result:='TYPEINFO'; 'O': Result:='OPTIMIZATION';
    'P': Result:='OPENSTRINGS'; 'Q': Result:='OVERFLOWCHECKS'; 'R': Result:='RANGECHECKS';
    'S': Result:='STACKCHECKS'; 'T': Result:='TYPEDADDRESS'; 'U': Result:='SAFEDIVIDE';
    'V': Result:='VARSTRINGCHECKS'; 'W': Result:='STACKFRAMES'; 'X': Result:='EXTENDEDSYNTAX';
    'Y': Result:='REFERENCEINFO'; 'Z': Result:='MINENUMSIZE';
  else Result:=''; end;
end;

function TScanner.IsSwitchDefined(N: string): Boolean;
var P, Index, OperatorPosition: Integer; Key, Expected, Actual, Comparison: string; Letter: Char;
begin
  N:=UpperCase(Trim(N));
  if (Length(N)=2) and CharInSet(N[1],['A'..'Z']) and CharInSet(N[2],['+','-']) then
  begin
    Key:=SwitchLongName(N[1]); Actual:=FLongOptions.Values[Key];
    if Actual='' then
    begin
      Index:=FSymbols.FindName('PAS2DOX_OPTION_'+Key);
      if Index>=0 then Actual:=FSymbols[Index].Value;
    end;
    if Actual<>'' then Exit((not SameText(Actual,'OFF') and (Actual<>'0'))=(N[2]='+'));
    Exit(FSwitchOptions[N[1]]=(N[2]='+'));
  end;
  Comparison:=''; OperatorPosition:=0;
  for P:=1 to Length(N) do if CharInSet(N[P],['<','>','=']) then begin OperatorPosition:=P; Break; end;
  if OperatorPosition>0 then
  begin
    P:=OperatorPosition;
    Comparison:=N[P];
    if (P<Length(N)) and CharInSet(N[P+1],['<','>','=']) then Comparison:=Comparison+N[P+1];
    N:=Copy(N,1,P-1)+' '+Copy(N,P+Length(Comparison),MaxInt);
  end;
  P:=Pos(' ',N);
  if P=0 then DoError('Long IFOPT requires an option name and value',[]);
  Key:=Copy(N,1,P-1); Expected:=Trim(Copy(N,P+1,MaxInt));
  if Key='SETOSVERSION' then Key:='SETPEOSVERSION';
  if Key='SETSUBVERSION' then Key:='SETPESUBSYSVERSION';
  if Key='SETUSERVERSION' then Key:='SETPEUSERVERSION';
  if (Key='WARN') and (Pos(' ',Expected)>0) then
  begin
    P:=Pos(' ',Expected); Key:=Key+' '+Copy(Expected,1,P-1); Expected:=Trim(Copy(Expected,P+1,MaxInt));
  end;
  Actual:=FLongOptions.Values[Key];
  if (Actual='') and (Copy(Key,1,5)='WARN ') then Actual:=FLongOptions.Values['WARN ALL'];
  if Actual='' then
  begin
    Index:=FSymbols.FindName('PAS2DOX_OPTION_'+Key);
    if Index>=0 then Actual:=FSymbols[Index].Value;
  end;
  if Actual='' then
    for Letter:='A' to 'Z' do
      if (SwitchLongName(Letter)=Key) and not CharInSet(Letter,['A','D','Z']) then
        if FSwitchOptions[Letter] then Actual:='ON' else Actual:='OFF';
  if Actual='' then DoError('IFOPT needs an explicit setting for %s; use --option=NAME=VALUE',[Key]);
  if Comparison<>'' then Exit(IfCondition('('+Actual+') '+Comparison+' ('+Expected+')'));
  if (Key='SETPEFLAGS') or (Key='SETPEOPTFLAGS') then Exit(IfCondition('('+Actual+' and '+Expected+') = '+Expected));
  Result:=SameText(Actual,Expected);
end;

{ ---------------------------------------------------------------------------- }

procedure TScanner.OpenNewTokenizer(Stream: TStream;
  const StreamName, StreamAbsoluteFileName: string);
var
  Tokenizer: TTokenizer;
begin
  { check if maximum number of FTokenizers has been reached }
  if FCurrentTokenizer = MAX_TOKENIZERS - 1 then
  begin
    Stream.Free;
    DoError('%s: Maximum level of recursion (%d) reached when trying to ' +
      'create new tokenizer "%s" (Probably you have recursive file inclusion ' +
      '(with $include directive) or macro expansion)',
      [GetStreamInfo, MAX_TOKENIZERS, StreamName]);
  end;

  Tokenizer := TTokenizer.Create(Stream, FOnMessage, FVerbosity,
    StreamName, StreamAbsoluteFileName);

  { add new tokenizer }
  Inc(FCurrentTokenizer);
  FRootLines[FCurrentTokenizer]:=FNextRootLine;
  FTokenizers[FCurrentTokenizer] := Tokenizer;
end;

{ ---------------------------------------------------------------------------- }

procedure TScanner.OpenIncludeFile(n: string);
var
  NLowerCase: string;
  UseLowerCase: boolean;

  { Check for availability of file N inside given Path
    (that must be like after IncludeTrailingPathDelimiter --- either
    '' or ends with PathDelim).
    It yes, then returns @true and opens new tokenizer with
    appropriate stream, else returns false.

    Check both N and NLowerCase
    (on case-sensitive system, filename may be written in exact
    case or lowercase). }
  function TryOpen(const Path: string): boolean;
  var
    Name: string;
    IncludeStream: TStream;
  begin
    Name := Path + N;
    DoMessage(5, pmtInformation, 'Trying to open include file "%s"...', [Name]);
    Result := FileExists(Name);

    if (not Result) and UseLowerCase then
    begin
      Name := Path + NLowerCase;
      DoMessage(5, pmtInformation, 'Trying to open include file "%s" (lowercased)...', [Name]);
      Result := FileExists(Name);
    end;

    if Result then
    begin
      { create new tokenizer with stream }
      IncludeStream := TBufferedFileStream.Create(Name, fmOpenRead or fmShareDenyWrite);
      {$ifndef STRING_UNICODE}
      { SkipBOM is only used when we don't use TStreamReader.
        TStreamReader handles BOM already by itself. }
      SkipBOM(IncludeStream);
      {$endif}
      OpenNewTokenizer(IncludeStream, Name, ExpandFileName(Name));
    end;
  end;

  function TryOpenIncludeFilePaths: boolean;
  var
    I: Integer;
  begin
    for I := 0 to IncludeFilePaths.Count - 1 do
      if IncludeFilePaths[I] <> '' then
      begin
        Result := TryOpen(IncludeFilePaths[I]);
        if Result then Exit;
      end;

    Result := false;
  end;

  function ExtractFileNameNoExt(const FileName: string): string;
  begin
    Result := ChangeFileExt(ExtractFileName(FileName), '');
  end;

begin
  // Dequote name if necessary
  if (Length(N) > 2) and (N[1] = '''') and (N[Length(N)] = '''') then
    N := Copy(N, 2, Length(N) - 2);
  // "*.inc" is possible - substitute name of container file
  if ExtractFileNameNoExt(N) = '*' then
    N := ExtractFilePath(N) + ExtractFileNameNoExt(FTokenizers[FCurrentTokenizer].StreamName) +
      ExtractFileExt(N);
  (*Replace \ with path delimiter, to make {$I ..\sample_include.inc} work
    even on Unix. See tests/testcases/test_subdir/ok_include_from_parent_dir.pas *)
  N := SCharsReplace(N, ['/', '\'], PathDelim);

  NLowerCase := LowerCase(N);
  { If NLowerCase = N, avoid calling FileExists twice (as FileExists
    may be costly when generating large docs from many files) }
  UseLowerCase := NLowerCase <> N;

  // try various paths, make error if none works
  if (FTokenizers[FCurrentTokenizer].StreamAbsoluteFileName <> '') and
     TryOpen(ExtractFilePath(FTokenizers[FCurrentTokenizer].StreamAbsoluteFileName)) then
    Exit;
  if TryOpenIncludeFilePaths then
    Exit;
  if TryOpen('') then
    Exit;
  DoError('%s: could not open include file %s', [GetStreamInfo, n]);
end;

{ ---------------------------------------------------------------------------- }

function TScanner.PeekToken: TToken;
begin
  Result := GetToken;
  FBufferedTokens.Add(Result);
end;

{ ---------------------------------------------------------------------------- }

function TScanner.SkipUntilElseOrEndif(out ElseifToken: TToken): TDirectiveType;
var
  dt: TDirectiveType;
  Level: Integer;
  DirectiveName, DirectiveParamBlack, DirectiveParamWhite: string;
  t: TToken;
  Stop: Boolean;
begin
  Level := 1;
  ElseifToken := nil;
  repeat
    t := FTokenizers[FCurrentTokenizer].SkipUntilCompilerDirective;
    if t = nil then
      DoError('Unexpected end of code when looking for matching $ELSE / $ELSEIF / $ENDIF / $IFEND', []);

    Assert(T <> nil);
    Assert(T.MyType = TOK_DIRECTIVE);

    if IdentifyDirective(t.CommentContent,
      dt, DirectiveName, DirectiveParamBlack, DirectiveParamWhite) then
    begin
      // We don't need it actually so can modify freely
      if DirectiveParamBlack <> '' then
        DirectiveParamBlack := ' "'+DirectiveParamBlack+'"';
      DoMessage(6, pmtInformation, 'SkipUntilElseOrEndif: encountered directive %s%s',
        [DirectiveNames[dt], DirectiveParamBlack]);
      case dt of
        DT_IFDEF, DT_IFNDEF, DT_IFOPT, DT_IF: Inc(Level);
        DT_ELSE, DT_ELSEIF:
          { RJ: We must jump over all nested $IFDEFs until its $ENDIF is
            encountered, ignoring all $ELSEs. We must therefore not
            decrement Level at $ELSE if it is part of such a nested $IFDEF.
            $ELSE must decrement Level only for the initial $IFDEF.
            That's why we test Level for 1 (initial $IFDEF) here. }
          if Level = 1 then Dec(Level);
        DT_ENDIF, DT_IFEND: Dec(Level);
      end;
    end else
      DoMessage(6, pmtInformation, 'SkipUntilElseOrEndif: encountered unknown directive %s', [t.CommentContent]);

    Stop := (Level = 0) and
      (T.MyType = TOK_DIRECTIVE) and
      (dt in [DT_ELSE, DT_ELSEIF, DT_ENDIF, DT_IFEND]);
    if Stop and (dt = DT_ELSEIF) then
    begin
      ElseifToken := T;
      T := nil;
    end;
    FreeAndNil(T);
  until Stop;
  Result := dt;
  DoMessage(6, pmtInformation, 'Skipped code, last directive is %s', [DirectiveNames[dt]]);
end;

function TScanner.SkipUntilElseOrEndif: TDirectiveType;
var
  ElseifToken: TToken;
begin
  Result := SkipUntilElseOrEndif(ElseifToken);
  FreeAndNil(ElseifToken);
end;

procedure TScanner.SkipUntilEndif;
var
  EndingDirective: TDirectiveType;
begin
  repeat
    EndingDirective := SkipUntilElseOrEndif;
  until EndingDirective in [DT_ENDIF, DT_IFEND];
end;

{ ---------------------------------------------------------------------------- }

procedure TScanner.UnGetToken(var t: TToken);
begin
  FBufferedTokens.Add(t);
  t := nil;
end;

{ ---------------------------------------------------------------------------- }

procedure TScanner.DoError(const AMessage: string;
  const AArguments: array of const);
begin
  raise EPasDoc.Create(AMessage, AArguments, 1);
end;

{ ---------------------------------------------------------------------------- }

procedure TScanner.DoMessage(const AVerbosity: Cardinal; const MessageType:
  TPasDocMessageType; const AMessage: string; const AArguments: array of const);
begin
  if Assigned(FOnMessage) then
    FOnMessage(MessageType, Format(AMessage, AArguments), AVerbosity);
end;

{ ---------------------------------------------------------------------------- }

procedure TScanner.ResolveSwitchDirectives(const Comment: String);
var
  p: PChar;
  l: Cardinal;
  c, Letter: Char;
  Content, OptionName, Black, Value, Eligible, SwitchValue: string;
  Snapshot: TStringList;
  Index: Integer;

  procedure SkipWhiteSpace;
  begin
    while (l > 0) and (p^ <= #32) do
      begin
        Inc(p);
        Dec(l);
      end;
  end;

begin
  if Copy(Comment,1,2)='{$' then Content:=Copy(Comment,2,Length(Comment)-2)
  else if Copy(Comment,1,3)='(*$' then Content:=Copy(Comment,3,Length(Comment)-4)
  else Exit;
  SplitDirective(Content,OptionName,Black,Value);
  OptionName:=UpperCase(OptionName); Value:=UpperCase(Trim(Value));
  Eligible:='|ALIGN|BOOLEVAL|ASSERTIONS|DEBUGINFO|OLDOBJWARN|IMPORTEDDATA|LONGSTRINGS|IOCHECKS|WRITEABLECONST|LOCALSYMBOLS|TYPEINFO|OPTIMIZATION|OPENSTRINGS|OVERFLOWCHECKS|RANGECHECKS|STACKCHECKS|TYPEDADDRESS|SAFEDIVIDE|VARSTRINGCHECKS|STACKFRAMES|EXTENDEDSYNTAX|' +
    'REFERENCEINFO|DEFINITIONINFO|MINENUMSIZE|AUTOBOX|FINITEFLOAT|HINTS|IMPLICITBUILD|REALCOMPATIBILITY|UNSAFECODE|METHODINFO|NATIVE_CPP_INTERFACES|SCOPEDENUMS|POINTERMATH|COMPATIBLELITERALS|HIGHCHARUNICODE|OLDTYPELAYOUT|WEAKLINKRTTI|STRONGLINKTYPES|' +
    'EXCESSPRECISION|EXTENDEDCOMPATIBILITY|ZEROBASEDSTRINGS|LEGACYIFEND|WARN|CODEALIGN|MAXPAGESIZE|DESIGNONLY|RUNONLY|VARPROPSETTER|DUPLICATEENABLE|RTTI|INLINE|WARNINGS|TEXTBLOCK|';
  if OptionName='PUSHOPT' then
  begin
    if Value<>'' then DoError('PUSHOPT subsets require explicit compiler option configuration',[]);
    Snapshot:=TStringList.Create;
    Snapshot.Assign(FLongOptions);
    for Letter:='A' to 'Z' do Snapshot.Values['__'+Letter]:=IntToStr(Ord(FSwitchOptions[Letter]));
    FOptionStack.Add(Snapshot); Exit;
  end;
  if OptionName='POPOPT' then
  begin
    if FOptionStack.Count=0 then DoError('POPOPT has no matching PUSHOPT',[]);
    Snapshot:=TStringList(FOptionStack.Last);
    for Letter:='A' to 'Z' do FSwitchOptions[Letter]:=Snapshot.Values['__'+Letter]='1';
    for Index:=FLongOptions.Count-1 downto 0 do
      if (Pos('|'+FLongOptions.Names[Index]+'|',Eligible)>0) or (Copy(FLongOptions.Names[Index],1,5)='WARN ') then FLongOptions.Delete(Index);
    for Index:=0 to Snapshot.Count-1 do
      if (Pos('|'+Snapshot.Names[Index]+'|',Eligible)>0) or (Copy(Snapshot.Names[Index],1,5)='WARN ') then
        FLongOptions.Values[Snapshot.Names[Index]]:=Snapshot.ValueFromIndex[Index];
    FOptionStack.Delete(FOptionStack.Count-1); Exit;
  end;
  if (OptionName='WARN') and (Pos(' ',Value)>0) then
  begin
    Index:=Pos(' ',Value); OptionName:=OptionName+' '+Copy(Value,1,Index-1); Value:=Trim(Copy(Value,Index+1,MaxInt));
  end;
  if (Value<>'') and (OptionName<>'') then FLongOptions.Values[OptionName]:=Value;
  if (Value='ON') or (Value='OFF') then
  begin
    for Letter:='A' to 'Z' do
      if SwitchLongName(Letter)=OptionName then FSwitchOptions[Letter]:=Value='ON';
  end;
  p := Pointer(Comment);
  l := Length(Comment);

  if l < 4 then Exit;
  case p^ of
    '{':
      begin
        if p[1] <> '$' then Exit;
        Inc(p, 2);
        Dec(l, 2);
      end;
    '(':
      begin
        if (p[1] <> '*') or (p[2] <> '$') then Exit;
        Inc(p, 3);
        Dec(l, 3);
      end;
  else
    Exit;
  end;

  repeat
    SkipWhiteSpace;
    if l < 3 then Exit;

    c := p^;
    if CharInSet(c, ['a'..'z']) then
      Dec(c, 32);

    if not CharInSet(c, ['A'..'Z']) then Exit;
    Inc(p); Dec(l); SwitchValue:='';
    if CharInSet(p^,['-','+']) then
    begin
      FSwitchOptions[c]:=p^='+';
      if p^='+' then SwitchValue:='ON' else SwitchValue:='OFF';
      Inc(p); Dec(l);
    end else if CharInSet(c,['A','D','Z']) then
    begin
      while (l>0) and CharInSet(p^,['0'..'9']) do
      begin SwitchValue:=SwitchValue+p^; Inc(p); Dec(l); end;
      if SwitchValue='' then Exit;
      FSwitchOptions[c]:=SwitchValue<>'0';
    end else Exit;
    if SwitchLongName(c)<>'' then FLongOptions.Values[SwitchLongName(c)]:=SwitchValue;

    SkipWhiteSpace;

    // Skip comma
    if (l = 0) or (p^ <> ',') then Exit;
    Inc(p);
    Dec(l);
  until False;
end;

{ ---------------------------------------------------------------------------- }

{ FPC makes a number of notes that variant operators are not inlined. }
{$ifdef FPC}
  {$notes off}
{$endif}

function TScanner.EvaluateExpression(const Condition: String): Variant;
var
  Tokenizer: TTokenizer;

  { Get next token that is not whitespace from Tokenizer.
    Return @nil if end of stream. }
  function NextToken: TToken;
  begin
    Result := nil;
    repeat
      FreeAndNil(Result);
      Result := Tokenizer.GetToken(true);
    until (Result = nil) or (Result.MyType <> TOK_WHITESPACE);
  end;

  procedure UndoToken(var T: TToken);
  begin
    Tokenizer.UnGetToken(T);
  end;

  (* Consume tokens after "defined.
     We handle two forms:
       {$IF DEFINED(MySym)}
     or
       {$IF DEFINED MySym}
  *)
  function ParseDefinedFunctionParameter: Boolean;
  var
    T: TToken;
    SymbolName: string;
  begin
    T := NextToken;
    if T.IsSymbol(SYM_LEFT_PARENTHESIS) then
    begin
      FreeAndNil(T);

      T := NextToken;
      if T.MyType <> TOK_IDENTIFIER then
        raise EInvalidIfCondition.CreateFmt('Expected identifier (symbol name), got %s', [T.Description]);
      SymbolName := T.Data;
      FreeAndNil(T);

      T := NextToken;
      if not T.IsSymbol(SYM_RIGHT_PARENTHESIS) then
        raise EInvalidIfCondition.CreateFmt('Expected ")", got %s', [T.Description]);
      FreeAndNil(T);
    end else
    if T.MyType = TOK_IDENTIFIER then
    begin
      SymbolName := T.Data;
      FreeAndNil(T);
    end else
      raise EInvalidIfCondition.CreateFmt('Expected "(" or symbol name, got %s', [T.Description]);

    Result := IsSymbolDefined(SymbolName);
  end;

  function ParseTypeParameter: string;
  var T: TToken;
  begin
    T:=NextToken;
    try
      if not T.IsSymbol(SYM_LEFT_PARENTHESIS) then raise EInvalidIfCondition.Create('Expected type argument in parentheses',[]);
    finally T.Free; end;
    Result:='';
    repeat
      T:=NextToken;
      if T=nil then raise EInvalidIfCondition.Create('Unclosed type argument',[]);
      try
        if T.IsSymbol(SYM_RIGHT_PARENTHESIS) then Break;
        Result:=Result+T.Data;
      finally T.Free; end;
    until False;
  end;

  function ParseOptionFunctionParameter: String;
  var
    T: TToken;
  begin
    T := NextToken;
    if not T.IsSymbol(SYM_LEFT_PARENTHESIS) then
      raise EInvalidIfCondition.CreateFmt('Expected "(", got %s', [T.Description]);
    FreeAndNil(T);

    T := NextToken;
    if T.MyType <> TOK_IDENTIFIER then
      raise EInvalidIfCondition.CreateFmt('Expected identifier (option name), got %s', [T.Description]);
    Result := T.Data;
    FreeAndNil(T);

    T := NextToken;
    if T.MyType <> TOK_SYMBOL then
      raise EInvalidIfCondition.CreateFmt('Expected symbol (+ or -), got %s', [T.Description]);
    Result := Result + T.Data;
    FreeAndNil(T);

    T := NextToken;
    if not T.IsSymbol(SYM_RIGHT_PARENTHESIS) then
      raise EInvalidIfCondition.CreateFmt('Expected ")", got %s', [T.Description]);
    FreeAndNil(T);
  end;

(*
  function ParseSimpleFunctionParameter: String;
  var
    T: TToken;
  begin
    T := NextToken;
    if not T.IsSymbol(SYM_LEFT_PARENTHESIS) then
      raise EInvalidIfCondition.CreateFmt('Expected "(", got %s', [T.Description]);
    FreeAndNil(T);

    T := NextToken;
    if T.MyType <> TOK_IDENTIFIER then
      raise EInvalidIfCondition.CreateFmt('Expected identifier (function parameter), got %s', [T.Description]);
    Result := T.Data;
    FreeAndNil(T);

    T := NextToken;
    if not T.IsSymbol(SYM_RIGHT_PARENTHESIS) then
      raise EInvalidIfCondition.CreateFmt('Expected ")", got %s', [T.Description]);
    FreeAndNil(T);
  end;
*)

  function ParseExpression: Variant; forward;

  { Convert Boolean to Int64, as expected by expressions in $if.
    Do not use just Int64(Boolean), to not depend on how compiler
    casts Boolean to Int64 and to make the intention obvious. }
  const
    BoolToInt64: array[Boolean] of Int64 = (0, 1);

  { Read literal Data to Int64, Double or String. }
  function ParseLiteral(const Data: String): Variant;
  var
    Int64Value: Int64;
    FloatValue: Double;
    ErrorPos: Integer;
  begin
    Val(Data, Int64Value, ErrorPos);
    if ErrorPos = 0 then
      Exit(Int64Value)
    else
    begin
      Val(Data, FloatValue, ErrorPos);
      if ErrorPos = 0 then
        Exit(FloatValue)
      else
        Exit(Data); // string
    end;
  end;

  function IsNumber(const Value: Variant): boolean;
  begin
    result := VarType(Value) in [varInt64, varDouble];
  end;

  { Consume tokens constituting a function, like "defined(xxx)".
    See @url(https://freepascal.org/docs-html/current/prog/progsu127.html FPC $IF expressions). }
  function ParseFunction: Variant;
  var
    T: TToken;
    Identifier: String;
    SymbolIndex: Integer;
    TypeName: string;
  begin
    T := NextToken;
    If T.IsSymbol(SYM_LEFT_PARENTHESIS) then
    begin
      FreeAndNil(T);
      result := ParseExpression;
      T := NextToken;
      If not T.IsSymbol(SYM_RIGHT_PARENTHESIS) then
      begin
        FreeAndNil(T);
        raise EInvalidIfCondition.Create('Closing bracket expected but %s found', [T.Description]);
      end;
      FreeAndNil(T);
      exit;
    end;
    try
      if T.MyType = TOK_NUMBER then
      begin
        result := ParseLiteral(T.Data);
        if Not IsNumber(result) then
          raise EInvalidIfCondition.CreateFmt('Invalid numeric value "%s"', [T.Data]);
        exit;
      end else
      if T.MyType = TOK_STRING then
      begin
        Exit(T.StringContent);
      end;

      if T.MyType <> TOK_IDENTIFIER then
        raise EInvalidIfCondition.CreateFmt('Expected identifier (function name), got %s', [T.Description]);
      Identifier := LowerCase(T.Data);
    finally FreeAndNil(T) end;

    if Identifier = 'false' then
      Result := BoolToInt64[false]
    else
    if Identifier = 'true' then
      Result := BoolToInt64[true]
    else
    if Identifier = 'defined' then
      Result := BoolToInt64[ParseDefinedFunctionParameter]
    else
    if Identifier = 'undefined' then
      // just negate the result defined(xxx) would have
      Result := BoolToInt64[not ParseDefinedFunctionParameter]
    else
    if Identifier = 'option' then
      Result := BoolToInt64[IsSwitchDefined(ParseOptionFunctionParameter)]
    else
    if Identifier = 'sizeof' then
    begin
      TypeName:=LowerCase(ParseTypeParameter);
      if (TypeName='byte') or (TypeName='shortint') or (TypeName='ansichar') or (TypeName='boolean') then Result:=Int64(1)
      else if (TypeName='word') or (TypeName='smallint') or (TypeName='char') or (TypeName='widechar') then Result:=Int64(2)
      else if (TypeName='integer') or (TypeName='cardinal') or (TypeName='longint') or (TypeName='single') then Result:=Int64(4)
      else if (TypeName='int64') or (TypeName='uint64') or (TypeName='double') then Result:=Int64(8)
      else if (TypeName='pointer') or (TypeName='nativeint') or (TypeName='nativeuint') or (TypeName='string') then
      begin if IsSymbolDefined('CPU64BITS') then Result:=Int64(8) else Result:=Int64(4); end
      else
      begin
        SymbolIndex:=FSymbols.FindName('PAS2DOX_SIZEOF_'+TypeName);
        if SymbolIndex<0 then raise EInvalidIfCondition.Create('SizeOf requires -DPAS2DOX_SIZEOF_Type=value for this type',[]);
        Result:=ParseLiteral(FSymbols[SymbolIndex].Value);
      end;
    end
    else
    if Identifier = 'declared' then
    begin
      TypeName:=ParseTypeParameter;
      Result:=BoolToInt64[(FDeclarations.IndexOf(TypeName)>=0) or IsSymbolDefined('PAS2DOX_DECLARED_'+TypeName)];
    end
    else
    begin
      SymbolIndex := FConstants.FindName(Identifier);
      if SymbolIndex<>-1 then Exit(EvaluateExpression(FConstants[SymbolIndex].Value));
      SymbolIndex := FSymbols.FindName(Identifier);
      if SymbolIndex <> -1 then
      begin
        If FSymbols[SymbolIndex].Value = '' then
          raise EInvalidIfCondition.CreateFmt('Macro "%s" doesn''t have a value', [Identifier]);
        Result := EvaluateExpression(FSymbols[SymbolIndex].Value);
      end
      else
        Result:=Int64(0); // Delphi: unknown identifiers in IF evaluate as False.

    end;
  end;

  function NeedInt64(const Value: Variant): int64;
  begin
    if VarType(Value) = varInt64 then
      Exit(Value)
    else
      raise EInvalidIfCondition.Create('Int64 value expected but "%s" found', [Value]);
  end;

  { Consume tokens constituting a function
    or a function with "not" at the beginning, like "not defined(xxx)". }
  function ParseFunctionNegated: Variant;
  var
    T: TToken;
    Operand: Int64;
  begin
    T := NextToken;
    if T=nil then raise EInvalidIfCondition.Create('Incomplete conditional expression',[]);
    if T.IsSymbol(SYM_MINUS) then
    begin FreeAndNil(T); Exit(-ParseFunctionNegated); end;
    if T.IsSymbol(SYM_PLUS) then
    begin FreeAndNil(T); Exit(ParseFunctionNegated); end;
    if T.IsKeyWord(KEY_NOT) then
    begin
      FreeAndNil(T);
      // the NOT operator accepts any integer
      Operand := NeedInt64(ParseFunction);
      If (Operand = 0) or (Operand = 1) then
        Result := 1 - Operand
      else
        Result := not Operand;
    end else
    begin
      UndoToken(T);
      Result := ParseFunction;
    end;
  end;

  procedure CheckNumberTypes(const LeftOperand, RightOperand: Variant);
  begin
    If not IsNumber(LeftOperand) then
      raise EInvalidIfCondition.Create('Number expected but "%s" found', [LeftOperand]);
    If not IsNumber(RightOperand) then
      raise EInvalidIfCondition.Create('Number expected but "%s" found', [RightOperand]);
  end;

  function ParseMultiplication: Variant;
  var
    T: TToken;
    RightOperand: Variant;
  begin
    Result := ParseFunctionNegated;
    repeat
      T := NextToken;
      if not Assigned(T) then break;
      try
        if T.IsKeyWord(KEY_AND) then
          Result := NeedInt64(Result) and NeedInt64(ParseFunctionNegated)
        else
        if T.IsKeyWord(KEY_DIV) then
          Result := NeedInt64(Result) div NeedInt64(ParseFunctionNegated)
        else
        if T.IsKeyWord(KEY_MOD) then
          Result := NeedInt64(Result) mod NeedInt64(ParseFunctionNegated)
        else if T.IsKeyWord(KEY_SHL) then Result:=NeedInt64(Result) shl NeedInt64(ParseFunctionNegated)
        else if T.IsKeyWord(KEY_SHR) then Result:=NeedInt64(Result) shr NeedInt64(ParseFunctionNegated)
        else
        if T.IsSymbol(SYM_ASTERISK) then
        begin
          RightOperand := ParseFunctionNegated;
          CheckNumberTypes(Result, RightOperand);
          Result := Result * RightOperand
        end
        else
        if T.IsSymbol(SYM_SLASH) then
        begin
          RightOperand := ParseFunctionNegated;
          CheckNumberTypes(Result, RightOperand);
          Result := Result / RightOperand
        end
        else
        begin
          UndoToken(T);
          break;
        end;
      finally FreeAndNil(T) end;
    until false;
  end;

  procedure CheckComparisonTypes(const LeftOperand, RightOperand: Variant);
  begin
    If IsNumber(LeftOperand) then
    begin
      If not IsNumber(RightOperand) then
        raise EInvalidIfCondition.Create('Number expected but "%s" found', [RightOperand]);
    end else
    If IsNumber(RightOperand) then
    begin
      If not IsNumber(LeftOperand) then
        raise EInvalidIfCondition.Create('Number expected but "%s" found', [LeftOperand]);
    end;
  end;

  function ParseAddition: Variant;
  var
    T: TToken;
    RightOperand: Variant;
  begin
    Result := ParseMultiplication;
    repeat
      T := NextToken;
      if not Assigned(T) then break;
      try
        if T.IsKeyWord(KEY_OR) then
          Result := NeedInt64(Result) or NeedInt64(ParseMultiplication)
        else
        if T.IsKeyWord(KEY_XOR) then
          Result := NeedInt64(Result) xor NeedInt64(ParseMultiplication)
        else
        if T.IsSymbol(SYM_PLUS) then
        begin
          RightOperand := ParseMultiplication;
          // strings can be concatenated with "+"
          CheckComparisonTypes(Result, RightOperand);
          Result := Result + RightOperand
        end
        else
        if T.IsSymbol(SYM_MINUS) then
        begin
          RightOperand := ParseMultiplication;
          CheckNumberTypes(Result, RightOperand);
          Result := Result - RightOperand
        end
        else
        begin
          UndoToken(T);
          break;
        end;
      finally FreeAndNil(T) end;
    until false;
  end;

  { Consume tokens constituting an expression, like "defined(xxx) or defined(yyy)".
    See @url(https://freepascal.org/docs-html/current/prog/progsu127.html FPC $IF expressions). }
  function ParseExpression: Variant;
  var
    T: TToken;
    RightOperand: Variant;
  begin
    Result := ParseAddition;
    repeat
      T := NextToken;
      if not Assigned(T) then break;
      try
        if T.IsSymbol(SYM_EQUAL) then
        begin
          RightOperand := ParseAddition;
          CheckComparisonTypes(Result, RightOperand);
          Result := BoolToInt64[Result = RightOperand]
        end
        else
        if T.IsSymbol(SYM_LESS_THAN) then
        begin
          RightOperand := ParseAddition;
          CheckComparisonTypes(Result, RightOperand);
          Result := BoolToInt64[Result < RightOperand]
        end
        else
        if T.IsSymbol(SYM_LESS_THAN_EQUAL) then
        begin
          RightOperand := ParseAddition;
          CheckComparisonTypes(Result, RightOperand);
          Result := BoolToInt64[Result <= RightOperand]
        end
        else
        if T.IsSymbol(SYM_GREATER_THAN) then
        begin
          RightOperand := ParseAddition;
          CheckComparisonTypes(Result, RightOperand);
          Result := BoolToInt64[Result > RightOperand]
        end
        else
        if T.IsSymbol(SYM_GREATER_THAN_EQUAL) then
        begin
          RightOperand := ParseAddition;
          CheckComparisonTypes(Result, RightOperand);
          Result := BoolToInt64[Result >= RightOperand]
        end
        else
        begin
          UndoToken(T);
          break;
        end;
      finally FreeAndNil(T) end;
    until false;
  end;

  function NeedBoolean(const Value: Variant): boolean;
  begin
    // in directives, a boolean is an integer equal to 0 or 1
    if VarType(Value) = varInt64 then
    begin
      if Value = 1 then Exit(true);
      if Value = 0 then Exit(false);
    end;
    raise EInvalidIfCondition.Create('Boolean value expected but "%s" found', [Value]);
  end;

  procedure CheckLastToken;
  var
    T: TToken;
  begin
    T := NextToken;
    if Assigned(T) then
    begin
      DoError('Unexpected trailing token in conditional expression', []);
      FreeAndNil(T);
    end;
  end;

begin
  Inc(FEvaluationDepth);
  if FEvaluationDepth>64 then
  begin Dec(FEvaluationDepth); DoError('Recursive constant expression',[]); end;
  Tokenizer := TTokenizer.Create(TStringStream.Create(#$FEFF+Condition,TEncoding.UTF8),
    FOnMessage, FVerbosity, '$if / $elseif condition', '');
  try
    try
      Result := ParseExpression;
      CheckLastToken;
    except
      on E: EInvalidIfCondition do
      begin
        DoError('Cannot evaluate conditional expression: %s', [E.Message]);
        Result:=False; // DoError always raises.
      end;
    end;

    { To test NextToken and tokenizer:
    repeat
      T := NextToken;
      if T = nil then Break;
      Writeln('Got token ', T.Description);
      FreeAndNil(T);
    until false;
    }
  finally FreeAndNil(Tokenizer); Dec(FEvaluationDepth); end;
end;

function TScanner.IfCondition(const Condition: String): Boolean;
var Value: Variant;
begin
  Value:=EvaluateExpression(Condition);
  if VarType(Value)<>varInt64 then DoError('Boolean conditional expression required',[]);
  if (Value<>0) and (Value<>1) then DoError('Boolean conditional expression required',[]);
  Result:=Value=1;
end;

end.
