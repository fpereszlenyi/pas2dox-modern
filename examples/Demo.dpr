program Demo;
{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Example.Store in 'Example.Store.pas',
  Example.Service in 'Example.Service.pas',
  Example.Worker in 'Example.Worker.pas';

var Worker: TExampleWorker;
begin
  Worker := TExampleWorker.Create;
  try
    Worker.Execute;
    Worker.RunSynchronized;
    Writeln('Stored value: ', Worker.Service.Store.LastValue);
  finally
    Worker.Free;
  end;
end.
