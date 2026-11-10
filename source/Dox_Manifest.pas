unit Dox_Manifest;

{ Pas2Dox Modern, 2026-11-10. GPL-2.0; see LICENSE. }

interface
uses PasDoc_Items;
function AstJson(UnitItem: TPasUnit): string;
function ItemKey(Item: TPasItem): string;

implementation
uses System.SysUtils, System.JSON, System.Hash, PasDoc_StringPairVector, Dox_Syntax;

function ItemKey(Item: TPasItem): string;
begin
  Result:=THashSHA2.GetHashString(LowerCase(ExpandFileName(Item.SourceAbsoluteFileName)+'|'+
    IntToStr(Item.SourceLine)+'|'+Item.Name+'|'+Item.FullDeclaration));
end;

procedure AddItem(Items: TJSONArray; Item: TPasItem; const Scope: string); forward;

procedure AddItems(Items: TJSONArray; List: TPasItems; const Scope: string);
var Item: TBaseItem;
begin for Item in List do AddItem(Items,TPasItem(Item),Scope); end;

procedure AddItem(Items: TJSONArray; Item: TPasItem; const Scope: string);
var Data: TJSONObject; Attributes, Ancestors, Tokens, Names, Types: TJSONArray; Pair: TStringPair;
  Cio: TPasCio; R: TPasRoutine; ChildScope, S: string;
begin
  Data:=TJSONObject.Create;
  Items.AddElement(Data);
  Data.AddPair('name',Item.Name);
  Data.AddPair('id',ItemKey(Item));
  Data.AddPair('scope',Scope);
  Data.AddPair('kind',Item.ClassName);
  Data.AddPair('declaration',Item.FullDeclaration);
  Data.AddPair('description',Item.RawDescription);
  Data.AddPair('source',Item.SourceAbsoluteFileName);
  Data.AddPair('line',TJSONNumber.Create(Item.SourceLine));
  Data.AddPair('endLine',TJSONNumber.Create(Item.SourceEndLine));
  Data.AddPair('unitLine',TJSONNumber.Create(Item.SourceRootLine));
  Data.AddPair('visibility',string(VisibilityStr[Item.Visibility]));
  Attributes:=TJSONArray.Create; Data.AddPair('attributes',Attributes);
  for Pair in Item.Attributes do
    Attributes.AddElement(TJSONObject.Create.AddPair('name',Pair.Name).AddPair('value',Pair.Value));
  if Item is TPasRoutine then
  begin
    R:=TPasRoutine(Item);
    Data.AddPair('routineKind',RoutineTypeToString(R.What));
    Data.AddPair('isType',TJSONBool.Create(R.IsType));
    Names:=TJSONArray.Create; Data.AddPair('parameterNames',Names);
    for S in ParameterNames(Lex(R.FullDeclaration)) do Names.Add(S);
    Types:=TJSONArray.Create; Data.AddPair('parameterTypes',Types);
    for S in R.ParamTypes do Types.Add(S);
    if R.BodyTokens.Count>0 then
    begin
      Tokens:=TJSONArray.Create; Data.AddPair('bodyTokens',Tokens);
      for S in R.BodyTokens do Tokens.Add(S);
      Data.AddPair('bodyLine',TJSONNumber.Create(R.BodyLine));
    end;
  end;
  if Item is TPasCio then
  begin
    Cio:=TPasCio(Item); Data.AddPair('genericName',Cio.NameWithGeneric);
    Data.AddPair('typeKind',CioTypeToString(Cio.MyType));
    case Cio.ClassDirective of
      CT_ABSTRACT: Data.AddPair('modifier','abstract');
      CT_SEALED: Data.AddPair('modifier','sealed');
      CT_HELPER: Data.AddPair('modifier','helper');
    end;
    Ancestors:=TJSONArray.Create; Data.AddPair('ancestors',Ancestors);
    for Pair in Cio.Ancestors do Ancestors.Add(Pair.Value);
    Data.AddPair('helperTarget',Cio.HelperTypeIdentifier);
    ChildScope:=Scope+'.'+Cio.NameWithGeneric;
    AddItems(Items,Cio.Cios,ChildScope); AddItems(Items,Cio.Types,ChildScope);
    AddItems(Items,Cio.Fields,ChildScope); AddItems(Items,Cio.Methods,ChildScope);
    AddItems(Items,Cio.Constants,ChildScope); AddItems(Items,Cio.Properties,ChildScope);
  end;
  if Item is TPasEnum then AddItems(Items,TPasEnum(Item).Members,Scope+'.'+Item.Name);
end;

function AstJson(UnitItem: TPasUnit): string;
var Data: TJSONObject; Items, Used, Todos: TJSONArray; Name: string;
  Todo: TPasSourceTodo; Entry: TJSONObject;
begin
  Data:=TJSONObject.Create;
  try
    Data.AddPair('unit',UnitItem.Name);
    Used:=TJSONArray.Create; Data.AddPair('uses',Used);
    for Name in UnitItem.UsesUnits do Used.Add(Name);
    Todos:=TJSONArray.Create; Data.AddPair('todos',Todos);
    for Todo in UnitItem.SourceTodos do
    begin
      Entry:=TJSONObject.Create; Todos.AddElement(Entry);
      Entry.AddPair('text',Todo.Text); Entry.AddPair('source',Todo.SourceFile);
      Entry.AddPair('line',TJSONNumber.Create(Todo.Line));
      if Todo.Owner<>nil then Entry.AddPair('owner',ItemKey(Todo.Owner));
    end;
    Items:=TJSONArray.Create; Data.AddPair('items',Items);
    AddItems(Items,UnitItem.CIOs,UnitItem.Name); AddItems(Items,UnitItem.Types,UnitItem.Name);
    AddItems(Items,UnitItem.Variables,UnitItem.Name); AddItems(Items,UnitItem.Constants,UnitItem.Name);
    AddItems(Items,UnitItem.FuncsProcs,UnitItem.Name);
    Result:=Data.ToJSON+#10;
  finally Data.Free; end;
end;

end.
