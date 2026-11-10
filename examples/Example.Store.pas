unit Example.Store;

interface

type
  /// A synthetic in-memory store. No database or external device is involved.
  TMemoryStore = class
  private
    FLastValue: Integer;
  public
    /// Return whether a value is accepted by this example.
    function Validate(Value: Integer): Boolean;
    /// Save a value in memory.
    procedure Save(Value: Integer);
    /// Explicit extension point for the example's caller/callee graph.
    procedure Flush;
    property LastValue: Integer read FLastValue;
  end;

implementation

function TMemoryStore.Validate(Value: Integer): Boolean;
begin
  Result := Value >= 0;
end;

procedure TMemoryStore.Save(Value: Integer);
begin
  // TODO 2 -oAlex -cStorage : Add an in-memory audit entry.
  if Validate(Value) then
    FLastValue := Value;
end;

procedure TMemoryStore.Flush;
begin
  { TODO: Consider a separate persistence adapter in a future example. }
end;

end.
