unit CompiledModern11;

interface

uses System.SysUtils, System.Generics.Collections;

{$SCOPEDENUMS ON}

type
  TMarker = class(TCustomAttribute);
  TState = (Ready = 1, Busy = 4);
  TCallback = reference to procedure(const Value: string);

  /// Container used only by the compiler and documentation tests.
  [TMarker]
  TBox<T: class, constructor> = class
  strict private
    FValue: T;
  public type
    TInfo = record
      Code: Integer;
    end;
  public
    constructor Create;
    constructor FromValue(const Value: T);
    function Map<TItem>(const Value: TItem): TItem;
    property Value: T read FValue write FValue;
  end;

  TManaged = record
    Value: Integer;
    class operator Initialize(out Dest: TManaged);
    class operator Finalize(var Dest: TManaged);
    class operator Assign(var Dest: TManaged; const [ref] Src: TManaged);
  end;

  TVariant = record
    case Kind: Boolean of
      True: (Number: Integer);
      False: (Address: Pointer);
  end;

  TIntListHelper = class helper for TList<Integer>
    procedure Touch;
  end;

function Calculate(const Values: TArray<Integer>): Integer;

implementation

constructor TBox<T>.Create;
begin
  inherited Create;
  FValue := nil;
end;

constructor TBox<T>.FromValue(const Value: T);
begin
  inherited Create;
  FValue := Value;
end;

function TBox<T>.Map<TItem>(const Value: TItem): TItem;
begin
  Result := Value;
end;

class operator TManaged.Initialize(out Dest: TManaged);
begin
  Dest.Value := 0;
end;

class operator TManaged.Finalize(var Dest: TManaged);
begin
  Dest.Value := 0;
end;

class operator TManaged.Assign(var Dest: TManaged; const [ref] Src: TManaged);
begin
  Dest.Value := Src.Value;
end;

procedure TIntListHelper.Touch;
begin
end;

function Calculate(const Values: TArray<Integer>): Integer;
begin
  var Total := 0;
  var Accumulate: TProc<Integer> :=
    procedure(Value: Integer)
    begin
      Inc(Total, Value);
    end;
  for var Value in Values do
    Accumulate(Value);
  Result := Total;
end;

end.
