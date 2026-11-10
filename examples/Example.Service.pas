unit Example.Service;

interface

uses Example.Store;

type
  /// A service owning a synthetic memory store.
  TExampleService = class
  private
    FStore: TMemoryStore;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
    property Store: TMemoryStore read FStore;
  end;

implementation

constructor TExampleService.Create;
begin
  inherited;
  FStore := TMemoryStore.Create;
end;

destructor TExampleService.Destroy;
begin
  FStore.Free;
  inherited;
end;

procedure TExampleService.Run;
begin
  FStore.Save(42);
  FStore.Flush;
end;

end.
