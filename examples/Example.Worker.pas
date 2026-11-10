unit Example.Worker;

interface

uses System.Classes, Example.Service;

type
  /// A worker demonstrating a cross-unit receiver and an anonymous callback.
  TExampleWorker = class
  private
    FService: TExampleService;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Execute;
    procedure RunSynchronized;
    property Service: TExampleService read FService;
  end;

implementation

constructor TExampleWorker.Create;
begin
  inherited;
  FService := TExampleService.Create;
end;

destructor TExampleWorker.Destroy;
begin
  FService.Free;
  inherited;
end;

procedure TExampleWorker.Execute;
begin
  FService.Run;
end;

procedure TExampleWorker.RunSynchronized;
begin
  TThread.Synchronize(nil,
    procedure
    begin
      FService.Run;
    end);
end;

end.
