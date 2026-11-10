unit Dox_Target;

{ Pas2Dox Modern, 2026-11-10. GPL-2.0; see LICENSE.
  Core target symbols from the Embarcadero predefined-conditionals table.
  Project-specific defines remain command-line configuration. }

interface
uses PasDoc_StringVector;
procedure AddTargetSymbols(Defines: TStringVector; const Platform: string);

implementation
uses System.SysUtils, System.StrUtils;

procedure AddTargetSymbols(Defines: TStringVector; const Platform: string);
  procedure Add(const Names: string);
  var Name: string;
  begin for Name in Names.Split([' ']) do if Name<>'' then Defines.Add(Name); end;
begin
  Add('DCC NATIVECODE UNICODE CONDITIONALEXPRESSIONS WEAKREF WEAKINTFREF');
  if MatchText(Platform,['win32','win64','winarm64ec']) then Add('MSWINDOWS ASSEMBLER');
  if Platform='win32' then Add('WIN32 CPU386 CPUX86 CPU32BITS UNDERSCOREIMPORTNAME')
  else if Platform='win64' then Add('WIN64 CPUX64 CPU64BITS')
  else if Platform='winarm64ec' then Add('WIN64 CPUARM CPUARM64 CPU64BITS ARM64EC LLVM')
  else if Platform='linux64' then Add('LINUX LINUX64 POSIX POSIX64 CPUX64 CPU64BITS PIC ELF')
  else if Platform='android32' then Add('ANDROID ANDROID32 POSIX POSIX32 CPUARM CPUARM32 CPU32BITS PIC')
  else if Platform='android64' then Add('ANDROID ANDROID64 POSIX POSIX64 CPUARM CPUARM64 CPU64BITS PIC')
  else if Platform='ios64' then Add('IOS IOS64 MACOS MACOS64 POSIX POSIX64 CPUARM CPUARM64 CPU64BITS PIC')
  else if Platform='iossimarm64' then Add('IOS IOS64 MACOS MACOS64 POSIX POSIX64 CPUARM CPUARM64 CPU64BITS PIC IOSSIMULATOR')
  else if Platform='macosx64' then Add('OSX OSX64 MACOS MACOS64 POSIX POSIX64 CPUX64 CPU64BITS PIC')
  else if Platform='macosarm64' then Add('OSX OSX64 MACOS MACOS64 POSIX POSIX64 CPUARM CPUARM64 CPU64BITS PIC')
  else raise Exception.Create('Unknown platform; use an explicit OS and CPU target from --help');
end;

end.
